import AVFoundation
import EliaTopBarKit
import Foundation
import SwiftUI

/// What the voice feature is doing right now.
@MainActor
final class VoiceCommandRouter: ObservableObject {

    /// The one router the app uses. The settings window needs it to run the
    /// microphone self-test.
    static let shared = VoiceCommandRouter()

    enum Phase: Equatable {
        case idle
        case listening
        case transcribing
        case dispatching
        case candidates([String])
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var level: Float = 0
    @Published private(set) var partial: String = ""
    @Published private(set) var lastTranscript: String = ""

    /// The agent names that can be woken.
    var rosterProvider: () -> [String] = { [] }
    /// Fire an agent with a composed prompt.
    var triggerHandler: (_ agent: String, _ prompt: String) -> Void = { _, _ in }
    /// Where the agent prompts live.
    var repoPathProvider: () -> String = { "" }
    /// Called when the user picks an agent in the panel.
    var pickerSelectHandler: (String) -> Void = { _ in }
    /// Whether the bridge is reachable. Voice needs it.
    var serverConnectedProvider: () -> Bool = { true }

    private let recorder = AudioRecorder()
    private let keyListener = KeyTriggerListener()
    private let hotKey = GlobalHotKey()
    private let hud = VoiceHUDController.shared
    private let feedback = AudioFeedback.shared

    private var analyzer: (any VoiceAnalyzerFeeding)?
    private var captureURL: URL?
    private var startedAt: Date?
    private var sawSpeech = false
    private var silentSince: Date?
    private var wakeDetected = false
    private var behaviour: AudioSettings.KeyBehaviour = .hold
    private var alwaysListening = false
    private var maxDurationTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var liveSleepSeconds: Double = 1.5
    private var liveRunInFlight = false
    private var liveLastText = ""
    private var idleDisarmTask: Task<Void, Never>?
    private var hudFadeTask: Task<Void, Never>?
    private var pickerHideTask: Task<Void, Never>?
    private var pickerMouseWasInside = false
    private var lastHudAt = Date.distantPast
    @Published private(set) var wakeDisarmedByTimer = false

    /// The text the on-device transcriber has settled so far.
    private var committedText = ""
    /// How far into the recording that settled text reaches, in seconds.
    private var committedSeconds: Double = 0
    /// The agent named in the live transcript, for the avatar.
    private var liveAgent: String?
    /// True once the microphone question has been asked in this session.
    private var hasAskedForMicrophone = false
    /// The agent picked in the panel. The voice commands go to it when the
    /// speech does not name one.
    private(set) var selectedAgent: String?
    /// The transcription waiting for an agent to be picked.
    private var pendingTranscript: String?
    private var pendingCommand: String?
    private var pendingDispatchAgent: String?
    private var pendingDispatchTranscript: String?
    private var pendingDispatchCommand: String?
    private var dispatchTask: Task<Void, Never>?
    /// The live transcription: Whisper over the recording that is growing.
    private var liveTranscriptionTask: Task<Void, Never>?
    /// When the level meter was last written to the log.
    private var lastLevelLog = Date.distantPast
    /// The last live transcript and when it changed. Used to stop a capture
    /// when the user stops speaking, even when Whisper is the only signal.
    private var lastPartialText = ""
    private var lastPartialAt: Date?

    // MARK: - Wiring

    /// Re-read the settings and re-arm the trigger.
    func applySettings() {
        hud.model.onCancel = { [weak self] in self?.cancelCurrent() }
        AppLog.important("voice: applySettings enabled=\(AudioSettings.enabled) mode=\(AudioSettings.triggerMode.rawValue)")
        guard AudioSettings.enabled else {
            idleDisarmTask?.cancel()
            idleDisarmTask = nil
            disarm()
            hideAgentPicker()
            return
        }
        switch AudioSettings.triggerMode {
        case .key:
            hotKey.unregister()
            alwaysListening = false
            behaviour = AudioSettings.keyBehaviour
            keyListener.onPress = { [weak self] in self?.handlePress() }
            keyListener.onRelease = { [weak self] in self?.handleRelease() }
            keyListener.onPermissionNeeded = { [weak self] in
                self?.showFailure("Input Monitoring is required for the push-to-talk key. Enable it in System Settings › Privacy & Security › Input Monitoring.")
            }
            keyListener.start(key: AudioSettings.triggerKey, behaviour: AudioSettings.keyBehaviour)
        case .hotkey:
            keyListener.stop()
            alwaysListening = false
            let spec = AudioSettings.hotkey.isEmpty ? "cmd+shift+v" : AudioSettings.hotkey
            if !hotKey.register(spec: spec, onTrigger: { [weak self] in
                self?.handlePress()
            }) {
                showFailure("The shortcut \(spec) could not be registered.")
            }
        case .wake:
            keyListener.stop()
            hotKey.unregister()
            wakeDisarmedByTimer = false
            idleDisarmTask?.cancel()
            idleDisarmTask = nil
            startAlwaysListening()
        case .shortcut:
            keyListener.stop()
            hotKey.unregister()
            alwaysListening = false
            hideAgentPicker()
        }
    }

    /// The agent the panel has selected.
    func setSelectedAgent(_ agent: String?) {
        selectedAgent = agent
        if let agent {
            AudioSettings.recentVoiceAgents = [agent] + AudioSettings.recentVoiceAgents
        }
        AppLog.important("voice: the selected agent is \(agent ?? "none")")
    }

    /// Show the agent picker with the roster of the bridge. The panel is
    /// opened by the voice flow, not by the trigger: it only appears once a
    /// transcription is finished.
    func showAgentPicker() {
        let roster = rosterProvider()
        VoiceAgentPickerController.shared.show(agents: roster,
                                                selected: selectedAgent) { [weak self] agent in
            self?.setSelectedAgent(agent)
            self?.pickerSelectHandler(agent)
        }
    }

    /// Hide the agent picker.
    func hideAgentPicker() {
        VoiceAgentPickerController.shared.hide()
    }

    /// Turn the whole feature off.
    func disarm() {
        dispatchTask?.cancel()
        dispatchTask = nil
        pendingDispatchAgent = nil
        pendingDispatchTranscript = nil
        pendingDispatchCommand = nil
        keyListener.stop()
        hotKey.unregister()
        idleDisarmTask?.cancel()
        idleDisarmTask = nil
        hudFadeTask?.cancel()
        hudFadeTask = nil
        pickerHideTask?.cancel()
        pickerHideTask = nil
        stopCapture()
        alwaysListening = false
        phase = .idle
        hud.setBanner(nil)
        hud.hide()
    }

    /// Stop a capture without transcribing it.
    private func stopCapture() {
        maxDurationTask?.cancel()
        maxDurationTask = nil
        liveTranscriptionTask?.cancel()
        liveTranscriptionTask = nil
        recorder.stop()
        recorder.discardRecording()
        analyzer?.cancel()
        analyzer = nil
        captureURL = nil
        level = 0
    }

    // MARK: - Trigger handling

    private func handlePress() {
        if phase == .transcribing { return }
        if isCapturing && (AudioSettings.triggerMode == .hotkey
                           || AudioSettings.keyBehaviour == .press) {
            endCapture()
            return
        }
        guard !isCapturing else { return }
        guard serverConnectedProvider() else {
            showServerOffline()
            return
        }
        beginCapture()
    }

    private func handleRelease() {
        // Hold mode ends the moment the key is released. Press-once mode
        // waits for the system to hear the end of the sentence.
        guard behaviour == .hold else { return }
        guard isCapturing else { return }
        endCapture()
    }

    // MARK: - Always listening (wake word)

    private func startAlwaysListening() {
        guard !alwaysListening else { return }
        // The wake mode opens the microphone the moment it is armed. When the
        // microphone was refused, do not nag at every launch: the settings
        // say so, and the error only appears when the user asks for it.
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .denied || status == .restricted {
            AppLog.important("voice: the microphone is not allowed — the wake word stays off")
            return
        }
        if status == .notDetermined {
            // The question is not asked at launch. A menu-bar app has no
            // window for the system prompt to attach to, the prompt lands
            // in the corner of the screen where nobody sees it, and macOS
            // forgets the answer on every rebuild — so the question is asked
            // from the settings, where the user is looking at it.
            AppLog.important("voice: the microphone was not asked yet — the wake word stays off until it is allowed")
            return
        }
        alwaysListening = true
        wakeDetected = false
        wakeDisarmedByTimer = false
        beginCapture()
    }

    private func checkWakeWord(_ text: String) {
        guard !wakeDetected else { return }
        if VoiceCommandParser.detectWake(text, roster: rosterProvider()) {
            wakeDetected = true
            idleDisarmTask?.cancel()
            idleDisarmTask = nil
            AppLog.important("voice: wake phrase heard in “\(text)”")
        }
    }

    // MARK: - Capture

    private var isCapturing: Bool {
        captureURL != nil
    }

    private var elapsed: Double {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    private func beginCapture() {
        guard !isCapturing else { return }
        guard serverConnectedProvider() else {
            showServerOffline()
            return
        }
        transcriptionTask?.cancel()
        transcriptionTask = nil
        hudFadeTask?.cancel()
        hudFadeTask = nil
        pickerHideTask?.cancel()
        pickerHideTask = nil
        liveSleepSeconds = 1.5
        liveRunInFlight = false
        liveLastText = ""
        idleDisarmTask?.cancel()
        idleDisarmTask = nil
        dispatchTask?.cancel()
        dispatchTask = nil
        pendingDispatchAgent = nil
        pendingDispatchTranscript = nil
        pendingDispatchCommand = nil
        startedAt = Date()
        sawSpeech = false
        silentSince = nil
        wakeDetected = false
        level = 0
        partial = ""
        lastPartialText = ""
        lastPartialAt = nil
        committedText = ""
        committedSeconds = 0
        liveAgent = nil

        // The bar follows the interaction: pressing the key brings it up in
        // the push-to-talk modes, and in the wake mode it only appears once
        // "Ok <agent>" was actually said. It never sits on screen just
        // because the microphone is open.
        if alwaysListening {
            hud.hide()
        } else {
            hud.update(status: .listening,
                       transcript: "",
                       level: 0,
                       agent: nil)
        }

        // The on-device analyzer gives live text and the system's own voice
        // activity detection. When it is unavailable (no locale pack, older
        // macOS) the level meter takes over as the end-of-speech signal.
        // The microphone opens first. The on-device model can take a long
        // time to come up, and the capture must not wait for it — otherwise
        // the wake word is never heard because the microphone is still
        // closed.
        Task { [weak self] in
            guard let self else { return }
            AppLog.important("voice: the capture task started")
            await self.startRecorder()
            await self.startAnalyzer()
        }
    }

    private func startAnalyzer() async {
        guard analyzer == nil else { return }
        guard #available(macOS 26.0, *) else { return }
        let locale = Locale(identifier: AudioSettings.wakeLocale)

        // The on-device model needs its language pack. Without it the
        // analyzer never produces anything — and asking it to start anyway
        // leaves the capture waiting forever. So the status is checked
        // first, and the capture carries on without the analyzer when the
        // pack is missing (the level meter then ends the sentence).
        // The recognizer needs its own permission: without it the results
        // stream fails with `RecogRejected` and nothing is ever heard.
        let authorized = await SpeechAnalyzerService.requestRecognitionAuthorization()
        guard authorized else {
            AppLog.important("voice: the speech recognition permission was refused — no live transcript")
            analyzer = nil
            return
        }
        let status = await SpeechAnalyzerService.assetStatus(locale: locale)
        guard status == .installed else {
            AppLog.important("voice: locale asset for \(locale.identifier) is \(status) — running without the live transcript")
            if status == .supported {
                // The download runs in the background: the capture must not
                // wait for a language pack.
                Task.detached {
                    try? await SpeechAnalyzerService.installAsset(locale: locale)
                }
            }
            analyzer = nil
            return
        }

        let service = SpeechAnalyzerService()
        service.onPartial = { [weak self] text, isFinal in
            Task { @MainActor [weak self] in
                self?.handlePartial(text, isFinal: isFinal)
            }
        }
        service.onAnalyzerFailed = { [weak self] in
            Task { @MainActor [weak self] in
                self?.analyzer = nil
                // The live transcript has to take over now that the cheap
                // recognizer is gone.
                if let self, self.isCapturing { self.startLiveTranscription() }
            }
        }
        service.onSpeechActivity = { [weak self] detected in
            Task { @MainActor [weak self] in
                self?.handleSpeechActivity(detected)
            }
        }
        do {
            // The analyzer must never hold the capture hostage: if it does
            // not come up in time, the capture goes on without it.
            try await withTimeout(seconds: 20) {
                try await service.prepare(locale: locale)
            }
            // The session is ready: it now receives the audio of the capture
            // that is already running.
            recorder.attach(analyzer: service)
            analyzer = service
            try await withTimeout(seconds: 10) {
                try await service.begin()
            }
            // The on-device recognizer now owns the live text: stop the
            // Whisper fallback so it stops loading the model every 1.5 s.
            liveTranscriptionTask?.cancel()
            liveTranscriptionTask = nil
        } catch {
            AppLog.important("voice: the speech analyzer did not start: \(error.localizedDescription)")
            analyzer = nil
            recorder.attach(analyzer: nil)
        }
    }

    /// Run an async operation with a deadline.
    ///
    /// The operation runs **detached**, on its own thread, and the deadline
    /// is enforced by polling: the caller is never suspended on a
    /// continuation. Two traps are avoided at once:
    ///
    /// - a continuation resumed from another thread leaves the Swift
    ///   runtime's "current executor" in a broken state, and the next
    ///   SwiftUI layout pass then dies inside `MainActor.assumeIsolated`;
    /// - `AVCaptureDevice.requestAccess` blocks its calling thread while the
    ///   system prompt is up. Called from the main actor it froze the whole
    ///   app: the deadline could never fire, the timers never resumed, and
    ///   the SwiftUI layout ran inside a suspended task — which is exactly
    ///   where the crash came from.
    private func withTimeout<T>(seconds: Double,
                                 operation: @escaping @Sendable () async -> T) async -> T? {
        let box = ValueBox<T>()
        Task.detached {
            box.set(await operation())
        }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let value = box.get() { return value }
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { break }
        }
        return box.get()
    }

    /// Run an async operation with a deadline. Throws when it is too slow.
    private func withTimeout<T>(seconds: Double,
                                 operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let box = ValueBox<Result<T, Error>>()
        Task.detached {
            do {
                box.set(.success(try await operation()))
            } catch {
                box.set(.failure(error))
            }
        }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let result = box.get() { return try result.get() }
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { break }
        }
        throw AnalyzerError.timedOut
    }

    enum AnalyzerError: LocalizedError {
        case timedOut
        var errorDescription: String? { "The speech analyzer did not start in time." }
    }
    private func startRecorder() async {
        AppLog.important("voice: startRecorder micStatus=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
        recorder.onLevel = { [weak self] value in
            Task { @MainActor [weak self] in
                self?.handleLevel(value)
            }
        }
        // The microphone permission is asked for once, at the first capture.
        // Starting a session without it throws inside CoreMedia, and an
        // LSUIElement app cannot show the system prompt reliably — so the
        // request happens here and the answer is handled.
        guard await ensureMicrophoneAccess() else {
            showFailure("The microphone is not allowed for EliaTopBar. Open System Settings › Privacy & Security › Microphone and allow it, then try again.")
            return
        }
        do {
            // The capture session is started off the main thread:
            // `startRunning()` blocks until the device is activated, and a
            // device that refuses to activate would freeze the whole app
            // with it.
            switch await startCaptureSession() {
            case .success(let url):
                captureURL = url
                phase = .listening
                // The wake mode listens all the time: the capture is the
                // listening session and must not stop on a timer, otherwise
                // the microphone closes and the wake word is never heard.
                if !alwaysListening { startMaxDurationTimer() }
                else { scheduleIdleDisarm() }
                startLiveTranscription()
                AppLog.important("voice: the microphone is open")
            case .failure(let error):
                AppLog.important("voice: the capture did not start: \(error.localizedDescription)")
                showFailure(error.localizedDescription)
            }
        }
    }

    /// The live transcript — Whisper only where the analyzer is missing.
    ///
    /// The on-device recognizer is used when it works — instant, no cost.
    /// When the speech service refuses the session (`RecogRejected`, a
    /// missing language pack, an older macOS) Whisper takes over: the last
    /// seconds of the recording are transcribed on a timer, and the wake
    /// word is looked for in that.
    ///
    /// The loop owns the fallback state: it exits the moment the analyzer
    /// attaches (a one-shot check at start would always pass — the loop
    /// starts before the analyzer is ready by design), and it needs to be
    /// re-armed when the analyzer dies mid-session (`onAnalyzerFailed`).
    /// Each tick is single-flight, over the 15 s tail only; ticks back off
    /// when the text has not grown.
    private func startLiveTranscription() {
        liveTranscriptionTask?.cancel()
        liveSleepSeconds = 1.5
        liveRunInFlight = false
        liveLastText = ""
        liveTranscriptionTask = Task { [weak self] in
            while !Task.isCancelled {
                let sleep = await self?.liveSleepSeconds ?? 1.5
                try? await Task.sleep(nanoseconds: UInt64(sleep * 1_000_000_000))
            guard !Task.isCancelled else { return }
                guard let self, !Task.isCancelled else { continue }
                // The analyzer owns the live text once it is up: the
                // fallback stops feeding the GPU the moment the cheap,
                // instant recognizer takes over.
                guard self.analyzer == nil, self.isCapturing else { break }
                guard !self.liveRunInFlight else { continue }
                guard let url = self.captureURL else { continue }
                self.liveRunInFlight = true
                let text = await self.liveTranscript(of: url)
                await MainActor.run {
                    self.liveRunInFlight = false
                    self.finishLiveTick(text)
                }
            }
        }
    }

    private func finishLiveTick(_ text: String) {
        let grew = !text.isEmpty && text != liveLastText
        liveLastText = text
        liveSleepSeconds = grew ? 1.5 : min(6.0, liveSleepSeconds * 2)
        guard !text.isEmpty else { return }
        handlePartial(text, isFinal: false)
    }

    /// The last seconds of the recording, transcribed.
    private func liveTranscript(of url: URL) async -> String {
        do {
            let tail = WavWriter.sliceTail(url, seconds: 15) ?? url
            defer {
                if tail != url {
                    try? FileManager.default.removeItem(at: tail)
                }
            }
            let text = try await STTEngine.transcribe(wav: tail,
                                                      model: AudioSettings.sttModel,
                                                      language: AudioSettings.sttLanguage)
            return text.text
        } catch {
            return ""
        }
    }

    /// Start the capture session on its own thread, with a deadline.
    private func startCaptureSession() async -> Result<URL, Error> {
        let box = ValueBox<Result<URL, Error>>()
        let thread = Thread { () -> Void in
            do {
                let url = try self.recorder.start(inputUID: AudioSettings.inputDeviceUID, analyzer: nil)
                box.set(.success(url))
            } catch {
                box.set(.failure(error))
            }
        }
        thread.qualityOfService = .userInitiated
        thread.start()

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let result = box.get() { return result }
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { break }
        }
        return .failure(AudioRecorder.RecorderError.captureTimeout)
    }

    /// Ask for the microphone when it has never been decided. Returns false
    /// when the answer is no.
    ///
    /// A menu-bar app has no window of its own, so the system prompt may
    /// have nowhere to attach. The app is brought forward for the request
    /// and the request is given a deadline: a prompt that never appears
    /// must not leave the capture waiting forever.
    func ensureMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            // The question is asked once per launch. macOS keys its answer
            // to the app's code signature, and an ad-hoc signed build changes
            // its signature on every rebuild — so during development the
            // system would keep asking, and the user would keep clicking
            // "Allow" for nothing.
            if hasAskedForMicrophone {
                AppLog.important("voice: the microphone was already asked for in this session")
                return false
            }
            hasAskedForMicrophone = true
            AppLog.important("voice: asking for the microphone")
            // A menu-bar app has no window for the system prompt to attach
            // to. Becoming a regular app for a moment gives it one; the
            // accessory policy is restored right after.
            let previousPolicy = await MainActor.run { () -> NSApplication.ActivationPolicy in
                let policy = NSApp.activationPolicy()
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                return policy
            }
            AppLog.important("voice: the app came forward for the prompt")
            defer { Task { @MainActor in NSApp.setActivationPolicy(previousPolicy) } }
            // Let the app come forward before the prompt is asked for.
            do { try await Task.sleep(nanoseconds: 700_000_000) } catch { return false }
            AppLog.important("voice: the prompt is up")
            let granted = await withTimeout(seconds: 25) {
                await AVCaptureDevice.requestAccess(for: .audio)
            } ?? false
            AppLog.important("voice: microphone access granted=\(granted)")
            if granted { hasAskedForMicrophone = false }
            return granted
        default:
            AppLog.important("voice: microphone access was refused")
            return false
        }
    }

    private func startMaxDurationTimer() {
        maxDurationTask?.cancel()
        let limit = AudioSettings.maxCaptureSec
        maxDurationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.endCapture() }
        }
    }

    /// The always-listening session may not outlive the user's patience:
    /// after N minutes with no speech and no wake phrase the microphone
    /// closes itself, the indicator goes dark, and the machine returns to
    /// its pre-audio baseline. Any heard speech resets the timer.
    private func scheduleIdleDisarm() {
        idleDisarmTask?.cancel()
        idleDisarmTask = nil
        let minutes = AudioSettings.idleDisarmMin
        guard minutes > 0, alwaysListening else { return }
        idleDisarmTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.disarmAfterIdle(minutes: minutes) }
        }
    }

    private func disarmAfterIdle(minutes: Int) {
        guard alwaysListening, !wakeDetected else { return }
        AppLog.important("voice: the wake session disarmed after \(minutes) min without speech")
        wakeDisarmedByTimer = true
        alwaysListening = false
        idleDisarmTask = nil
        stopCapture()
        phase = .idle
        hud.hide()
        hideAgentPicker()
    }

    /// Re-arm the wake word after an idle disarm. Nothing else opens the
    /// microphone again without the user acting, so this is reachable from
    /// the URL handler and the settings.
    func rearmWake() {
        guard AudioSettings.enabled,
              AudioSettings.triggerMode == .wake,
              !alwaysListening,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        AppLog.important("voice: re-arming the wake word after idle disarm")
        startAlwaysListening()
    }

    private func handleLevel(_ value: Float) {
        let now = Date()
        if value > 0.01, now.timeIntervalSince(lastLevelLog) > 1 {
            lastLevelLog = now
            AppLog.d("voice: level \(String(format: "%.4f", value))")
        }
        if now.timeIntervalSince(lastHudAt) >= 0.1 {
            lastHudAt = now
            level = value
            if hudShouldShow {
                hud.update(status: hudStatus(),
                           transcript: displayText(),
                           level: value,
                           agent: liveAgent)
            }
        }
        if alwaysListening && !wakeDetected && value > 0.02 {
            scheduleIdleDisarm()
        }

        // Stop-talking detection. Whisper has no VAD of its own, so two
        // signals are used: the audio level, and the live transcript. When
        // the transcript stops changing for two seconds, the user has
        // stopped talking. The on-device detector, when available, does the
        // same thing.
        // In the wake mode the capture is the listening session: it stays
        // open until "Ok <agent>" was heard. A quiet room must not close
        // the microphone — the wake word would never arrive.
        if alwaysListening && !wakeDetected { return }
        if value > 0.02 {
            sawSpeech = true
            silentSince = nil
        } else if sawSpeech {
            if silentSince == nil { silentSince = Date() }
            if let silentSince, Date().timeIntervalSince(silentSince) > 0.8 {
                endCapture()
            }
        }
        // Transcript-based stop: Whisper keeps emitting the same text once
        // the sentence is finished.
        if !partial.isEmpty, let lastPartialAt,
           Date().timeIntervalSince(lastPartialAt) > 2.0 {
            endCapture()
        }
    }

    private func handlePartial(_ text: String, isFinal: Bool) {
        partial = text
        if text != lastPartialText {
            lastPartialText = text
            lastPartialAt = text.isEmpty ? nil : Date()
        }
        AppLog.d("voice: partial[\(isFinal ? "final" : "live")] \(text)")
        if alwaysListening && !wakeDetected && !text.isEmpty {
            scheduleIdleDisarm()
        }
        if isFinal, !text.isEmpty {
            // The settled text reaches this far into the recording. What
            // comes after it still has to be transcribed.
            committedText = text
            committedSeconds = elapsed
        }
        // The avatar shows the agent as soon as the live text names it.
        if liveAgent == nil {
            let parsed = VoiceCommandParser.parse(text, roster: rosterProvider(), requireAgent: false)
            if let agent = parsed.agent { liveAgent = agent }
        }
        if alwaysListening {
            checkWakeWord(text)
        }
        guard hudShouldShow else { return }
        hud.update(status: hudStatus(),
                   transcript: displayText(),
                   level: level,
                   agent: liveAgent)
    }

    /// The bar is on screen only while there is an interaction to show:
    /// the key is held, or the wake phrase was heard.
    private var hudShouldShow: Bool {
        if alwaysListening { return wakeDetected }
        return true
    }

    private func handleSpeechActivity(_ detected: Bool) {
        if detected {
            sawSpeech = true
            silentSince = nil
            if alwaysListening && !wakeDetected { scheduleIdleDisarm() }
            return
        }
        guard sawSpeech else { return }
        // Before the wake phrase the capture is the listening session and
        // must stay open.
        if alwaysListening && !wakeDetected { return }
        // A short tail catches the last syllable.
        Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            await MainActor.run { self?.endCapture() }
        }
    }

    /// What the bar shows right now.
    private func hudStatus() -> VoiceHUDStatus {
        switch phase {
        case .transcribing: return .transcribing
        case .listening: return .listening
        default: return .listening
        }
    }

    /// The text shown in the bar: the live text while speaking, the final
    /// one once it is known.
    private func displayText() -> String {
        // Whisper sometimes hallucinates a foreign script on silence or on
        // background audio (a film playing, for example). Showing that text
        // on the bar is noise, not information: keep it off the screen.
        let text = !partial.isEmpty ? partial : committedText
        guard containsDisplayableLetters(text) else { return "" }
        return text
    }

    /// Whether the transcript contains at least one Latin letter.
    ///
    /// Accented European characters count; a transcript made only of
    /// CJK / Cyrillic / Arabic glyphs does not.
    private func containsDisplayableLetters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x41...0x5A).contains(scalar.value) ||   // A-Z
            (0x61...0x7A).contains(scalar.value) ||   // a-z
            (0xC0...0x24F).contains(scalar.value)     // Latin-1 + Extended-A
        }
    }

    private func endCapture() {
        guard isCapturing else { return }
        maxDurationTask?.cancel()
        maxDurationTask = nil
        liveTranscriptionTask?.cancel()
        liveTranscriptionTask = nil

        let url = recorder.stop()
        analyzer?.finish()
        analyzer = nil
        captureURL = nil
        level = 0

        guard let url else { return }
        feedback.play(.captureEnd, outputUID: AudioSettings.outputDeviceUID)

        phase = .transcribing
        hud.update(status: .transcribing,
                   transcript: displayText(),
                   level: 0,
                   agent: liveAgent)

        // Only the part the live transcriber had not settled yet has to go
        // through Whisper — the rest is already written down.
        let total = elapsed
        let settled = committedText.isEmpty ? "" : committedText
        let tailStart = settled.isEmpty ? 0 : max(0, committedSeconds)
        let canSlice = !settled.isEmpty && tailStart < total - 0.3

        transcriptionTask?.cancel()
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let text: String
                if canSlice, let tailURL = WavWriter.slice(url, from: tailStart) {
                    let tail = try await STTEngine.transcribe(wav: tailURL,
                                                             model: AudioSettings.sttModel,
                                                             language: AudioSettings.sttLanguage)
                    try? FileManager.default.removeItem(at: tailURL)
                    text = VoiceTranscriptMerger.merge(committed: settled, tail: tail.text)
                } else {
                    let full = try await STTEngine.transcribe(wav: url,
                                                             model: AudioSettings.sttModel,
                                                             language: AudioSettings.sttLanguage)
                    text = VoiceTranscriptMerger.merge(committed: settled, tail: full.text)
                }
                try? FileManager.default.removeItem(at: url)
                await MainActor.run { self.handleTranscript(text) }
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: url)
            } catch {
                try? FileManager.default.removeItem(at: url)
                await MainActor.run { self.showFailure(error.localizedDescription) }
            }
        }
    }

    // MARK: - Microphone self-test

    /// When set, the transcript is handed here instead of being dispatched.
    private var micTestCompletion: ((String?) -> Void)?

    /// Record a few seconds and transcribe them, without firing any agent.
    ///
    /// This is the only way to prove the whole capture path — device, format,
    /// Whisper — without a key press and without a live agent run.
    func runMicTest(completion: @escaping (String?) -> Void) {
        guard !isCapturing else { return }
        micTestCompletion = completion
        beginCapture()
        // The test is short: it ends on silence, or here.
        maxDurationTask?.cancel()
        maxDurationTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
            await MainActor.run { self?.endCapture() }
        }
    }

    // MARK: - Transcript handling

    private func handleTranscript(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        AppLog.important("voice: transcript = “\(clean)”")
        if let completion = micTestCompletion {
            micTestCompletion = nil
            completion(clean.isEmpty ? nil : clean)
            phase = .idle
            hud.hide()
            return
        }
        guard !clean.isEmpty else {
            showFailure("Nothing was heard.")
            return
        }
        lastTranscript = clean

        let roster = rosterProvider()
        let parsed = VoiceCommandParser.parse(clean,
                                              roster: roster,
                                              requireAgent: false)
        // The agent picked in the panel wins when the speech does not name
        // one: the three audio modes all use the panel, and naming an agent
        // out loud is optional.
        guard serverConnectedProvider() else {
            showServerOffline()
            return
        }
        if let agent = parsed.agent ?? selectedAgent {
            scheduleDispatch(agent: agent, transcript: clean, command: parsed.command)
        } else if !roster.isEmpty {
            // One prompt, not two: the panel is the question. The parser's
            // near-misses lead the row; the roster follows.
            phase = .candidates(parsed.candidates)
            showAgentPicker(for: clean, command: parsed.command, candidates: parsed.candidates)
        } else {
            showFailure("No agent name heard in “\(clean)”.")
        }
    }

    /// Open the agent panel after a finished transcription. The pick goes
    /// to the agent the user clicks.
    private func showAgentPicker(for transcript: String, command: String, candidates: [String] = []) {
        let roster = rosterProvider()
        guard !roster.isEmpty else { return }
        pickerMouseWasInside = false
        // The picker replaces the listening bar: hide the bar so its status
        // ring stops spinning and the picker is the only thing on screen.
        hud.hide()
        pendingTranscript = transcript
        pendingCommand = command
        VoiceAgentPickerController.shared.show(agents: roster,
                                                selected: selectedAgent,
                                                candidates: candidates,
                                                subtitle: transcript,
                                                onClose: { [weak self] in
                                                    guard let self else { return }
                                                    self.pendingTranscript = nil
                                                    self.pendingCommand = nil
                                                    self.pickerHideTask?.cancel()
                                                    self.pickerHideTask = nil
                                                    VoiceAgentPickerController.shared.hide()
                                                }) { [weak self] agent in
            guard let self else { return }
            self.setSelectedAgent(agent)
            self.pendingTranscript = nil
            self.pendingCommand = nil
            self.pickerHideTask?.cancel()
            self.pickerHideTask = nil
            VoiceAgentPickerController.shared.hide()
            self.dispatch(agent: agent,
                          transcript: transcript,
                          command: command)
        }
        // Hovering pauses the auto-hide (stays indefinitely); leaving
        // restarts an 8 s countdown.
        VoiceAgentPickerController.shared.model.onMouseEnter = { [weak self] in
            guard let self, self.pendingTranscript != nil else { return }
            self.pickerMouseWasInside = true
            self.pickerHideTask?.cancel()
            self.pickerHideTask = nil
        }
        VoiceAgentPickerController.shared.model.onMouseLeave = { [weak self] in
            guard let self, self.pendingTranscript != nil else { return }
            // Ignore the spurious exit that fires when the panel appears
            // under the cursor.
            guard self.pickerMouseWasInside else { return }
            self.pickerMouseWasInside = false
            self.pickerHideTask?.cancel()
            self.pickerHideTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
                guard let self, self.pendingTranscript != nil else { return }
                self.pendingTranscript = nil
                self.pendingCommand = nil
                VoiceAgentPickerController.shared.hide()
                self.hud.hide()
            }
        }
        pickerHideTask?.cancel()
        pickerHideTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
                guard let self, self.pendingTranscript != nil else { return }
            self.pendingTranscript = nil
            self.pendingCommand = nil
            VoiceAgentPickerController.shared.hide()
            self.hud.hide()
        }
    }

    /// Delay the dispatch by three seconds so the user can change the
    /// agent the transcript named. The bar stays on screen with a large
    /// "Change agent" button during that window.
    private func scheduleDispatch(agent: String, transcript: String, command: String) {
        dispatchTask?.cancel()
        pendingDispatchAgent = agent
        pendingDispatchTranscript = transcript
        pendingDispatchCommand = command
        hud.update(status: .listening,
                   transcript: "Sending to \(agent) in 3s…",
                   level: 0,
                   agent: agent,
                   onChangeAgent: { [weak self] in self?.changePendingAgent() })
        dispatchTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            await MainActor.run {
                guard let self, self.pendingDispatchAgent == agent else { return }
                self.hud.update(status: .listening,
                                transcript: "Sending to \(agent) in 2s…",
                                level: 0,
                                agent: agent,
                                onChangeAgent: { [weak self] in self?.changePendingAgent() })
            }
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            await MainActor.run {
                guard let self, self.pendingDispatchAgent == agent else { return }
                self.hud.update(status: .listening,
                                transcript: "Sending to \(agent) in 1s…",
                                level: 0,
                                agent: agent,
                                onChangeAgent: { [weak self] in self?.changePendingAgent() })
            }
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            await MainActor.run { self?.dispatchPending() }
        }
    }

    private func changePendingAgent() {
        dispatchTask?.cancel()
        dispatchTask = nil
        guard let transcript = pendingDispatchTranscript,
              let command = pendingDispatchCommand else { return }
        pendingDispatchAgent = nil
        pendingDispatchTranscript = nil
        pendingDispatchCommand = nil
        showAgentPicker(for: transcript, command: command)
    }

    private func dispatchPending() {
        guard let agent = pendingDispatchAgent,
              let transcript = pendingDispatchTranscript,
              let command = pendingDispatchCommand else { return }
        dispatchTask = nil
        pendingDispatchAgent = nil
        pendingDispatchTranscript = nil
        pendingDispatchCommand = nil
        dispatch(agent: agent, transcript: transcript, command: command)
    }

    private func dispatch(agent: String, transcript: String, command: String) {
        AudioSettings.recentVoiceAgents = [agent] + AudioSettings.recentVoiceAgents
        let prompt = VoicePromptBuilder.compose(agent: agent,
                                                transcript: transcript,
                                                command: command,
                                                repoPath: repoPathProvider())
        phase = .dispatching
        AppLog.important("voice: dispatching to \(agent) — “\(command)” (\(prompt.count) chars)")
        feedback.play(.triggered, outputUID: AudioSettings.outputDeviceUID)
        hud.update(status: .sent(agent),
                   transcript: command.isEmpty ? transcript : command,
                   level: 0,
                   agent: agent)
        triggerHandler(agent, prompt)
        partial = ""

        // The bar retracts on its own.
        hudFadeTask?.cancel()
        hudFadeTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_800_000_000) } catch { return }
            await MainActor.run {
                guard let self, self.phase == .dispatching else { return }
                self.hudFadeTask = nil
                self.phase = .idle
                self.hud.hide()
            }
        }
    }

    private func showServerOffline() {
        dispatchTask?.cancel()
        dispatchTask = nil
        AppLog.important("voice: server not connected — voice disabled")
        phase = .failed("Server not connected")
        feedback.play(.error, outputUID: AudioSettings.outputDeviceUID)
        hud.setBanner("Server not connected — voice needs the Elia bridge")
        hud.update(status: .failed("Server not connected"),
                   transcript: "Reconnect the bridge, then try again.",
                   level: 0,
                   agent: liveAgent)
        Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
            await MainActor.run {
                guard let self, self.phase == .failed("Server not connected") else { return }
                self.hud.setBanner(nil)
                self.phase = .idle
                self.hud.hide()
            }
        }
    }

    /// Cancel whatever the voice flow is doing right now: capture,
    /// transcription, dispatch countdown, picker. The X button on the
    /// listening popup calls this.
    func cancelCurrent() {
        dispatchTask?.cancel()
        dispatchTask = nil
        pendingDispatchAgent = nil
        pendingDispatchTranscript = nil
        pendingDispatchCommand = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        liveTranscriptionTask?.cancel()
        liveTranscriptionTask = nil
        maxDurationTask?.cancel()
        maxDurationTask = nil
        idleDisarmTask?.cancel()
        idleDisarmTask = nil
        hudFadeTask?.cancel()
        hudFadeTask = nil
        pickerHideTask?.cancel()
        pickerHideTask = nil
        if isCapturing {
            recorder.stop()
            recorder.discardRecording()
            analyzer?.cancel()
            analyzer = nil
            captureURL = nil
        }
        phase = .idle
        partial = ""
        hud.setBanner(nil)
        hud.hide()
        hideAgentPicker()
    }

    private func showFailure(_ message: String) {
        dispatchTask?.cancel()
        dispatchTask = nil
        pendingDispatchAgent = nil
        pendingDispatchTranscript = nil
        pendingDispatchCommand = nil
        if let completion = micTestCompletion {
            micTestCompletion = nil
            completion(nil)
        }
        AppLog.important("voice: \(message)")
        phase = .failed(message)
        feedback.play(.error, outputUID: AudioSettings.outputDeviceUID)
        hud.update(status: .failed(message),
                   transcript: message,
                   level: 0,
                   agent: liveAgent)
        hudFadeTask?.cancel()
        hudFadeTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            await MainActor.run {
                guard let self, self.phase == .failed(message) else { return }
                self.hudFadeTask = nil
                self.phase = .idle
                self.hud.hide()
            }
        }
    }

    private func agentHint() -> String {
        rosterProvider().first ?? "agent"
    }

    // MARK: - External trigger (system shortcut)

    /// Handle `elia://voice?text=…` — the contract for the Dictation and
    /// Siri routes, where the OS owns the microphone.
    /// `elia://mic-test` runs the microphone self-test and writes the
    /// transcript to a file, so the capture path can be verified without
    /// speaking into a real microphone.
    func handle(url: URL) {
        guard url.scheme?.lowercased() == "elia" else { return }
        if url.host == "mic-test" {
            runMicTest { result in
                let text = result ?? "NO RESULT"
                guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                          in: .userDomainMask).first else { return }
                let folder = base.appendingPathComponent("EliaTopBar")
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? text.write(to: folder.appendingPathComponent("mic-test-result.txt"),
                                atomically: true, encoding: .utf8)
            }
            return
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        guard let text = items.first(where: { $0.name == "text" })?.value,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // An idle disarm has to be undone the moment the user speaks to
        // the app again.
        rearmWake()
        let requested = items.first(where: { $0.name == "agent" })?.value
        let roster = rosterProvider()
        let parsed = VoiceCommandParser.parse(text, roster: roster, requireAgent: false)
        let agent = requested ?? parsed.agent
        guard let agent else {
            if roster.isEmpty {
                showFailure("No agent name heard in “\(text)”.")
            } else {
                showAgentPicker(for: text, command: parsed.command, candidates: parsed.candidates)
            }
            return
        }
        guard serverConnectedProvider() else {
            showServerOffline()
            return
        }
        scheduleDispatch(agent: agent, transcript: text, command: parsed.command)
    }
}
