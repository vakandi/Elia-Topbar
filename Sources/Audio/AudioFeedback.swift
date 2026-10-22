import AVFoundation
import Foundation

/// The short sounds that tell the user what the app just did.
///
/// `NSSound` is not used: it can only play on the default output device.
/// The engine is routed explicitly so a user with headphones selected still
/// hears the feedback.
@MainActor
final class AudioFeedback {

    static let shared = AudioFeedback()

    enum Cue {
        case listenStart
        case captureEnd
        case triggered
        case error

        fileprivate var tone: Tone {
            switch self {
            case .listenStart: return Tone(frequency: 660, duration: 0.09, shape: .sine)
            case .captureEnd: return Tone(frequency: 440, duration: 0.09, shape: .sine)
            case .triggered: return Tone(frequency: 880, duration: 0.07, shape: .sine, second: 1320)
            case .error: return Tone(frequency: 220, duration: 0.18, shape: .square)
            }
        }
    }

    struct Tone {
        let frequency: Double
        let duration: Double
        let shape: Shape
        /// A second note, played straight after the first.
        var second: Double?

        enum Shape { case sine, square }
    }

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var idleTask: Task<Void, Never>?

    /// Play a cue on the given output device (empty = system default).
    func play(_ cue: Cue, outputUID: String) {
        guard let format = outputFormat() else { return }
        do {
            try prepareEngine(format: format, outputUID: outputUID)
            guard let player else { return }
            guard let buffer = makeBuffer(tone: cue.tone, format: format) else { return }
            player.scheduleBuffer(buffer, at: nil, options: .interrupts)
            player.play()
            scheduleIdleStop()
        } catch {
            // Feedback is a nicety — never let it break a voice command.
        }
    }

    // MARK: - Engine

    private func outputFormat() -> AVAudioFormat? {
        let format = engine?.outputNode.outputFormat(forBus: 0)
        if let format, format.channelCount > 0, format.sampleRate > 0 { return format }
        return AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)
    }

    private func prepareEngine(format: AVAudioFormat, outputUID: String) throws {
        if engine == nil {
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            self.engine = engine
            self.player = player
        }
        guard let engine, let player else { return }

        // Route to the device the user picked, not just the default one.
        if !outputUID.isEmpty,
           let device = AudioDeviceList.outputDevice(for: outputUID),
           let audioUnit = engine.outputNode.audioUnit {
            var deviceID = device
            AudioUnitSetProperty(audioUnit,
                                 kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global,
                                 0,
                                 &deviceID,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }

        if !engine.isRunning {
            try engine.start()
        }
        _ = player
    }

    // MARK: - Idle stop

    /// Stop the engine after a short idle so it does not hold an audio
    /// unit and its CoreAudio threads forever for a 90 ms beep.
    private func scheduleIdleStop() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.stopEngine() }
        }
    }

    private func stopEngine() {
        if let engine, engine.isRunning { engine.stop() }
    }

    // MARK: - Tone

    private func makeBuffer(tone: Tone, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let frames = AVAudioFrameCount(sampleRate * tone.duration)
        let channels = Int(format.channelCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        buffer.frameLength = frames
        guard let data = buffer.floatChannelData else { return buffer }

        for channel in 0..<channels {
            let samples = data[channel]
            for frame in 0..<Int(frames) {
                let t = Double(frame) / sampleRate
                let envelope = fade(t: t, duration: tone.duration)
                samples[frame] = Float(sin(2 * .pi * tone.frequency * t) * envelope * 0.28)
            }
        }
        return buffer
    }

    /// A quick attack, a slow release, and a tail of silence after the note.
    private func fade(t: Double, duration: Double) -> Double {
        let attack = 0.012
        let release = 0.05
        if t < attack { return t / attack }
        if t > duration - release { return max(0, (duration - t) / release) }
        return 1
    }
}
