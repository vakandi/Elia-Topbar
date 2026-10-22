import AVFoundation
import Foundation

/// Anything that consumes captured audio as it arrives.
///
/// The macOS 26 speech analyzer implements this; keeping it behind a protocol
/// means the capture path does not care whether an analyzer is attached.
protocol AudioAnalyzerFeeding: AnyObject {
    /// Feed one buffer of captured audio.
    func accept(_ buffer: AVAudioPCMBuffer)
    /// The stream is over — flush whatever is left.
    func finish()
    /// Stop without flushing.
    func cancel()
}

/// An analyzer that can also be prepared for a locale and then started.
///
/// The two steps are separate because the analyzer must not start before the
/// capture runs: `analyzer.start(inputSequence:)` waits for the first audio
/// buffer, and the capture is what produces it.
protocol VoiceAnalyzerFeeding: AudioAnalyzerFeeding {
    /// Build the session and load the model.
    func prepare(locale: Locale) async throws
    /// Start consuming the audio.
    func begin() async throws
}

/// Owns the capture session, writes the WAV, and feeds the analyzer.
///
/// Deliberately not main-actor isolated: the sample buffer delegate runs on a
/// dedicated queue and must not hop to the main thread for every buffer.
final class AudioRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "com.elia.topbar.audio.capture", qos: .userInitiated)

    private var writer: WavWriter?
    private var converter: PCMConverter?
    private var analyzer: AudioAnalyzerFeeding?
    private var didConfigure = false
    /// How many buffers the session delivered. Diagnostics only.
    private var deliveredBuffers = 0
    /// The analyzer is read on the capture queue and written on the main
    /// actor, so it needs a lock.
    private let analyzerLock = NSLock()

    /// Called on the capture queue with a 0...1 level.
    var onLevel: ((Float) -> Void)?
    /// Called on the capture queue when something goes wrong.
    var onError: ((String) -> Void)?

    /// The WAV of the current capture, once stopped.
    private(set) var recordedURL: URL?

    // MARK: - Lifecycle

    /// Attach (or detach) the analyzer that receives the audio.
    ///
    /// The capture starts first and the live transcript joins when the
    /// on-device model is ready — the microphone must not wait for the
    /// model.
    func attach(analyzer: AudioAnalyzerFeeding?) {
        analyzerLock.lock()
        self.analyzer = analyzer
        analyzerLock.unlock()
    }

    /// Start capturing. Returns the WAV path that will be written.
    func start(inputUID: String, analyzer: AudioAnalyzerFeeding?) throws -> URL {
        stop()

        let device = AudioDeviceList.captureDevice(for: inputUID)
        guard let device else {
            throw RecorderError.noInputDevice
        }

        if !didConfigure {
            session.beginConfiguration()
            session.sessionPreset = .high
            // The output keeps the format of the device. Asking for 16 kHz
            // mono — which is what Whisper wants — is refused by every
            // microphone of this machine (they run at 48 kHz). The resampling
            // to 16 kHz happens in the converter, on the way to the WAV.
            // No forced format: the output keeps the format of the device.
            // Asking for another one is refused by some devices, and the
            // audio then arrives as noise the level meter reads as silence.
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                throw RecorderError.cannotAddInput
            }
            session.addOutput(output)
            // The configuration must be closed before the session starts:
            // `startRunning()` raises "may not be called between calls to
            // beginConfiguration and commitConfiguration" — an Objective-C
            // exception Swift cannot catch, so the app dies.
            session.commitConfiguration()
            didConfigure = true
        }

        session.beginConfiguration()
        for existing in session.inputs { session.removeInput(existing) }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw RecorderError.cannotAddInput
        }
        session.addInput(input)
        session.commitConfiguration()

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elia-voice-\(UUID().uuidString).wav")
        writer = try WavWriter(url: url, sampleRate: 16_000, channels: 1)
        converter = nil
        attach(analyzer: analyzer)
        recordedURL = url

        session.startRunning()
        AppLog.important("voice: capture running=\(session.isRunning) inputs=\(session.inputs.count) outputs=\(session.outputs.count) device=\(device.localizedName) uid=\(device.uniqueID)")
        return url
    }

    /// Stop capturing and finalise the WAV. Returns the file.
    @discardableResult
    func stop() -> URL? {
        if session.isRunning { session.stopRunning() }
        writer?.finalize()
        writer = nil
        analyzerLock.lock()
        let attached = analyzer
        analyzer = nil
        analyzerLock.unlock()
        attached?.finish()
        converter = nil
        return recordedURL
    }

    /// Delete the last recording.
    func discardRecording() {
        if let recordedURL {
            try? FileManager.default.removeItem(at: recordedURL)
        }
        recordedURL = nil
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        deliveredBuffers += 1
        if deliveredBuffers <= 3 || deliveredBuffers % 200 == 0 {
            let desc = CMSampleBufferGetFormatDescription(sampleBuffer)
            AppLog.d("voice: capture buffer \(deliveredBuffers) desc=\(desc != nil ? "ok" : "nil")")
        }
        guard let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }

        // Whisper wants 16 kHz mono; convert once if the device ignored the
        // rate we asked for. The level is measured on the converted buffer:
        // the raw one comes in a format the level meter does not know
        // (Int24/Int32 on some devices), and it read as pure silence.
        if converter == nil || converter!.sourceFormat != pcm.format {
            converter = try? PCMConverter(from: pcm.format, to: AudioFormats.whisperFormat())
        }
        let converted = converter?.convert(pcm)
        let level: Float = converted.map { buf in
            guard let data = buf.audioBufferList.pointee.mBuffers.mData else { return 0 }
            let count = Int(buf.frameLength)
            guard count > 0 else { return 0 }
            let samples = data.assumingMemoryBound(to: Int16.self)
            var sum: Double = 0
            for i in 0..<count {
                let value = Double(samples[i]) / 32768.0
                sum += value * value
            }
            return Float(min(1.0, sqrt(sum / Double(count)) * 4.0))
        } ?? 0
        if deliveredBuffers <= 3 {
            let ptr = converted?.audioBufferList.pointee.mBuffers.mData
            let first = ptr.map { $0.assumingMemoryBound(to: Int16.self)[0] } ?? -999
            AppLog.d("voice: capture buffer \(deliveredBuffers) raw=\(pcm.frameLength) converted=\(Int(converted?.frameLength ?? 0)) ptr=\(ptr != nil) first=\(first) level=\(String(format: "%.5f", level))")
        }
        onLevel?(level)

        if let converted {
            try? writer?.append(AudioLevels.rawBytes(converted))
        }

        analyzerLock.lock()
        let attached = analyzer
        analyzerLock.unlock()
        attached?.accept(pcm)
    }

    // MARK: - CMSampleBuffer → AVAudioPCMBuffer

    /// Turn a capture sample buffer into a PCM buffer.
    ///
    /// The buffer list of a planar (non-interleaved) format has one entry
    /// per channel, so it is written straight into the buffer the PCM
    /// object allocated for that format. Copying the channels by hand into
    /// a one-slot list — what this used to do — silently produced nothing:
    /// no level, no live transcript, no recording.
    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            AppLog.d("voice: capture: the sample buffer has no format")
            return nil
        }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0 else { return nil }
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            AppLog.d("voice: capture: no PCM buffer")
            return nil
        }
        pcm.frameLength = frames

        var blockBuffer: CMBlockBuffer?
        // The size is in BYTES, and a planar format has one buffer entry per
        // channel: passing the number of entries instead of the byte size
        // fails with `kCMSampleBufferError_ArrayTooSmall` (-12737), and the
        // capture delivers nothing at all.
        let entries = Int(pcm.mutableAudioBufferList.pointee.mNumberBuffers)
        let listSize = MemoryLayout<AudioBufferList>.size
            + max(0, entries - 1) * MemoryLayout<AudioBuffer>.size
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: pcm.mutableAudioBufferList,
            bufferListSize: listSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard status == noErr else {
            AppLog.d("voice: capture: the audio buffer list failed (\(status))")
            return nil
        }
        return pcm
    }

    enum RecorderError: LocalizedError {
        case noInputDevice
        case cannotAddInput
        case captureTimeout

        var errorDescription: String? {
            switch self {
            case .noInputDevice: return "No microphone is available."
            case .cannotAddInput: return "The microphone could not be opened."
            case .captureTimeout: return "The microphone did not open in time."
            }
        }
    }
}
