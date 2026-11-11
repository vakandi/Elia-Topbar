import AVFoundation
import Foundation
import Speech

/// Wraps the macOS 26 on-device speech stack.
///
/// Two modules, one session:
/// - `SpeechTranscriber` with `.volatileResults` → the live partial text that
///   fills the listening bar and feeds the wake-word matcher.
/// - `SpeechDetector` → the system's own voice activity detection, used to
///   close the microphone the moment the user stops talking.
///
/// Three documented Apple traps this class exists to respect:
/// 1. the analyzer does **not** resample — we convert the buffers ourselves;
/// 2. `finalizeAndFinishThroughEndOfInput()` must be called or the tail of
///    the transcript is lost;
/// 3. without the locale asset installed, transcription silently does
///    nothing — so the status is checked and surfaced.
@available(macOS 26.0, *)
final class SpeechAnalyzerService: VoiceAnalyzerFeeding {

    enum ServiceError: LocalizedError {
        case assetMissing
        case noFormat
        case transcriberUnavailable

        var errorDescription: String? {
            switch self {
            case .assetMissing:
                return "The speech language pack for this locale is not installed yet."
            case .noFormat:
                return "No audio format works with the on-device speech model."
            case .transcriberUnavailable:
                return "On-device speech recognition is not available on this Mac."
            }
        }
    }

    /// Live text from the transcriber. `isFinal` marks the settled result.
    var onPartial: ((String, Bool) -> Void)?
    /// Called when the speech service refuses the session.
    var onAnalyzerFailed: (() -> Void)?
    /// True when speech started, false when the voice activity ended.
    var onSpeechActivity: ((Bool) -> Void)?

    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var stream: AsyncStream<AnalyzerInput>?
    private var transcriber: SpeechTranscriber?
    private var detector: SpeechDetector?
    private var tasks: [Task<Void, Never>] = []
    private var converter: PCMConverter?
    private var targetFormat: AVAudioFormat?
    private let lock = NSLock()
    private var isFinished = false
    /// How many buffers the capture delivered. Diagnostics only.
    private var bufferCount = 0
    /// The position of the audio already fed to the analyzer, in frames.
    private var samplePosition: AVAudioFramePosition = 0

    // MARK: - Locale assets

    /// The locales the system can transcribe.
    static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    /// The locales whose model is already on disk.
    static func installedLocales() async -> [Locale] {
        await SpeechTranscriber.installedLocales
    }

    /// The transcriber used by the live session.
    ///
    /// The asset variant depends on the reporting options, so the status
    /// has to be asked about the *same* module that will be started —
    /// otherwise the app asks about a variant it will never use and
    /// wrongly concludes that the pack is missing.
    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale,
                          transcriptionOptions: [],
                          reportingOptions: [.volatileResults],
                          attributeOptions: [])
    }

    /// Ask for the speech recognition permission.
    ///
    /// The on-device recognizer refuses to work when the app was never
    /// authorized: the results stream fails with `RecogRejected` and the
    /// live transcript stays empty. The microphone permission is not enough.
    static func requestRecognitionAuthorization() async -> Bool {
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { _ in
                continuation.resume(returning: true)
            }
        }
        let current = SFSpeechRecognizer.authorizationStatus()
        AppLog.important("voice: the speech recognition authorization is \(current.rawValue)")
        return current == .authorized
    }

    /// Whether the model for this locale is ready to use.
    static func assetStatus(locale: Locale) async -> AssetInventory.Status {
        let status = await AssetInventory.status(forModules: [makeTranscriber(locale: locale)])
        AppLog.important("voice: wake asset status for \(locale.identifier) = \(status)")
        return status
    }

    /// Download the model for this locale.
    static func installAsset(locale: Locale) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(
            supporting: [makeTranscriber(locale: locale)]
        ) else {
            return
        }
        try await request.downloadAndInstall()
        _ = try? await AssetInventory.reserve(locale: locale)
    }

    // MARK: - Session

    /// Start the analyzer. Throws when the locale pack is missing.
    ///
    /// Split in two on purpose. `prepare` builds the session and makes it
    /// ready to receive audio; `begin` starts consuming it. The order
    /// matters: `analyzer.start(inputSequence:)` waits for the first
    /// buffer, so it must be called *after* the capture is running —
    /// starting it first waits for audio that only the capture can produce,
    /// and the microphone never opens.
    func prepare(locale: Locale) async throws {
        guard SpeechTranscriber.isAvailable else { throw ServiceError.transcriberUnavailable }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        let detector = SpeechDetector(
            detectionOptions: .init(sensitivityLevel: .medium),
            reportResults: true
        )
        let modules: [any SpeechModule] = [transcriber, detector]

        // The asset has to be there for **this** module: the variant
        // depends on the reporting options, and a session whose model is
        // missing is rejected with `RecogRejected`.
        var status = await AssetInventory.status(forModules: [transcriber])
        AppLog.important("voice: analyzer: the asset for the session module is \(status)")
        if status == .supported {
            AppLog.important("voice: analyzer: installing the asset")
            if let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try? await request.downloadAndInstall()
            }
            status = await AssetInventory.status(forModules: [transcriber])
            AppLog.important("voice: analyzer: the asset is now \(status)")
        }
        guard status == .installed else {
            throw ServiceError.assetMissing
        }

        // Apple's setup sequence reserves the locale before building the
        // analyzer. Without the reservation the streaming session can be
        // refused with `RecogRejected` even though the asset is installed.
        let reserved = (try? await AssetInventory.reserve(locale: locale)) ?? false
        AppLog.important("voice: analyzer: locale reserved=\(reserved)")

        AppLog.important("voice: analyzer: looking for a format")
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw ServiceError.noFormat
        }

        let analyzer = SpeechAnalyzer(
            modules: modules,
            options: .init(priority: .userInitiated, modelRetention: .lingering)
        )
        AppLog.important("voice: analyzer: preparing the model")
        try await analyzer.prepareToAnalyze(in: format)
        AppLog.important("voice: analyzer: the model is ready")

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        setSession(analyzer: analyzer,
                   continuation: continuation,
                   format: format,
                   stream: stream,
                   transcriber: transcriber,
                   detector: detector)
    }

    /// Start consuming the audio that `accept(_:)` yields.
    func begin() async throws {
        lock.lock()
        let analyzer = self.analyzer
        let stream = self.stream
        let transcriber = self.transcriber
        let detector = self.detector
        lock.unlock()
        guard let analyzer, let stream else { throw ServiceError.noFormat }
        guard let transcriber, let detector else { throw ServiceError.noFormat }

        AppLog.important("voice: analyzer: starting the session")
        try await analyzer.start(inputSequence: stream)
        AppLog.important("voice: analyzer: the session is running")

        AppLog.important("voice: analyzer: target format \(targetFormat?.sampleRate ?? 0)Hz x\(targetFormat?.channelCount ?? 0)")
        tasks.append(Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let isFinal = result.isFinal
                    await MainActor.run { self?.onPartial?(text, isFinal) }
                }
                AppLog.important("voice: analyzer: the results stream ended")
            } catch {
                let nsError = error as NSError
                AppLog.important("voice: analyzer: the results stream failed: \(error.localizedDescription) (\(nsError.domain) \(nsError.code))")
                // The speech service refused the session: the live
                // transcript has to come from Whisper instead, and the
                // level meter has to take over the end of the sentence.
                await MainActor.run {
                    self?.onAnalyzerFailed?()
                    self?.onPartial?("", true)
                }
            }
        })
        tasks.append(Task { [weak self] in
            do {
                for try await result in detector.results {
                    let detected = result.speechDetected
                    await MainActor.run { self?.onSpeechActivity?(detected) }
                }
            } catch {
                // The stream ended — nothing to report.
            }
        })
    }

    // MARK: - AudioAnalyzerFeeding

    /// Store the session. Not async on purpose: a lock must never be taken
    /// from an async context.
    private func setSession(analyzer: SpeechAnalyzer,
                            continuation: AsyncStream<AnalyzerInput>.Continuation,
                            format: AVAudioFormat,
                            stream: AsyncStream<AnalyzerInput>,
                            transcriber: SpeechTranscriber,
                            detector: SpeechDetector) {
        lock.lock()
        self.analyzer = analyzer
        self.continuation = continuation
        self.targetFormat = format
        self.stream = stream
        self.transcriber = transcriber
        self.detector = detector
        // No converter here: the capture format is not the analyzer format,
        // and a converter built for the wrong pair turns the audio into
        // silence.
        self.converter = nil
        lock.unlock()
    }

    func accept(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let continuation = self.continuation
        let target = self.targetFormat
        let seen = bufferCount
        bufferCount += 1
        let samplePosition = self.samplePosition
        self.samplePosition += AVAudioFramePosition(buffer.frameLength)
        lock.unlock()
        if seen < 3 {
            AppLog.d("voice: analyzer: buffer \(seen) \(buffer.format.sampleRate)Hz x\(buffer.format.channelCount) frames=\(buffer.frameLength) continuation=\(continuation != nil) target=\(target != nil)")
        }
        guard let continuation, let target else { return }

        let converted: AVAudioPCMBuffer
        if buffer.format == target {
            converted = buffer
        } else {
            lock.lock()
            // The converter has to match BOTH ends: a converter that was
            // built for another input format converts the audio with the
            // wrong rate, and the transcriber hears nothing.
            if converter == nil
                || converter!.format != target
                || converter!.sourceFormat != buffer.format {
                converter = try? PCMConverter(from: buffer.format, to: target)
            }
            let converter = self.converter
            lock.unlock()
            guard let converter, let result = converter.convert(buffer) else { return }
            converted = result
        }

        // The analyzer needs a monotonic start time on every input. A stream
        // of buffers that all carry the same timestamp is dropped, and the
        // transcriber then never says a word.
        let seconds = Double(samplePosition) / max(1, target.sampleRate)
        let startTime = CMTime(value: CMTimeValue(seconds * 1_000_000_000), timescale: 1_000_000_000)
        continuation.yield(AnalyzerInput(buffer: converted, bufferStartTime: startTime))
    }

    func finish() {
        lock.lock()
        guard !isFinished else { lock.unlock(); return }
        isFinished = true
        let continuation = self.continuation
        let analyzer = self.analyzer
        let tasks = self.tasks
        self.continuation = nil
        self.analyzer = nil
        self.tasks = []
        lock.unlock()

        continuation?.finish()
        Task {
            // Mandatory: without this the tail of the transcript is dropped.
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
            for task in tasks { await task.value }
        }
    }

    /// Stop everything, including a capture that is still running.
    func cancel() {
        lock.lock()
        let analyzer = self.analyzer
        self.analyzer = nil
        let continuation = self.continuation
        self.continuation = nil
        let tasks = self.tasks
        self.tasks = []
        isFinished = true
        lock.unlock()

        continuation?.finish()
        for task in tasks { task.cancel() }
        Task { try? await analyzer?.cancelAndFinishNow() }
    }
}
