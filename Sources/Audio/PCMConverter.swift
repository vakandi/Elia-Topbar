import AVFoundation

/// Converts captured audio to one target format.
///
/// `AVAudioConverter` is used rather than hand-rolled resampling because the
/// capture system can hand us a different rate than we asked for (a Bluetooth
/// headset ignores the requested rate) and a wrong-rate WAV transcribes
/// badly.
final class PCMConverter {

    /// The target format.
    let format: AVAudioFormat
    /// The format the converter reads. It has to be known: a converter that
    /// is kept while the device changes its format converts the audio with
    /// the wrong rate, and the result is silence.
    let sourceFormat: AVAudioFormat
    private var converter: AVAudioConverter

    init(from input: AVAudioFormat, to target: AVAudioFormat) throws {
        self.format = target
        self.sourceFormat = input
        guard let converter = AVAudioConverter(from: input, to: target) else {
            throw ConverterError.cannotCreate
        }
        self.converter = converter
    }

    enum ConverterError: LocalizedError {
        case cannotCreate
        var errorDescription: String? { "The audio format could not be converted." }
    }

    /// Convert one buffer. Returns nil when the input was not convertible.
    func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(Double(input.frameLength) * format.sampleRate / max(1, input.format.sampleRate)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, conversionError == nil, output.frameLength > 0 else { return nil }
        return output
    }
}

enum AudioFormats {
    /// The format Whisper wants.
    static func whisperFormat() -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16,
                      sampleRate: 16_000,
                      channels: 1,
                      interleaved: true)!
    }

    /// The format we ask the capture system for.
    ///
    /// 48 kHz stereo Int16: the rate every device of this machine runs at,
    /// and two channels, because a device with more (BlackHole 64ch) has to
    /// be downmixed by the capture stack — a 64-channel buffer crashes the
    /// PCM allocation. The resampling to the 16 kHz mono Whisper wants
    /// happens in the converter.
    static func captureFormat() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000.0,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }
}

enum AudioLevels {
    /// Root-mean-square of a buffer, normalised to 0...1.
    ///
    /// Every layout is handled: an interleaved buffer has one data pointer
    /// that holds the channels one after the other, a planar buffer has one
    /// pointer per channel. Getting this wrong reads the silence of a
    /// capture that is full of sound.
    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        let channels = max(1, Int(buffer.format.channelCount))
        guard frames > 0 else { return 0 }
        let interleaved = buffer.format.isInterleaved

        var sum: Double = 0
        var count = 0

        if let ints = buffer.int16ChannelData {
            let data = ints[0]
            let step = interleaved ? channels : 1
            var i = 0
            while i < frames {
                let value = Double(data[i]) / 32768.0
                sum += value * value
                count += 1
                i += step
            }
        } else if let floats = buffer.floatChannelData {
            let data = floats[0]
            let step = interleaved ? channels : 1
            var i = 0
            while i < frames {
                let value = Double(data[i])
                sum += value * value
                count += 1
                i += step
            }
        } else {
            let list = buffer.audioBufferList
            guard let bytes = list.pointee.mBuffers.mData else { return 0 }
            let byteCount = Int(list.pointee.mBuffers.mDataByteSize)
            let bytesPerSample = buffer.format.commonFormat == .pcmFormatFloat32 ? 4 : 2
            let step = bytesPerSample * (interleaved ? channels : 1)
            var offset = 0
            while offset + bytesPerSample <= byteCount {
                var raw: Int16 = 0
                var rawFloat: Float = 0
                if bytesPerSample == 2 {
                    memcpy(&raw, bytes + offset, 2)
                    let value = Double(raw) / 32768.0
                    sum += value * value
                } else {
                    memcpy(&rawFloat, bytes + offset, 4)
                    let value = Double(rawFloat)
                    sum += value * value
                }
                count += 1
                offset += step
            }
        }

        guard count > 0 else { return 0 }
        return Float(min(1.0, sqrt(sum / Double(count)) * 4.0))
    }

    /// The raw interleaved bytes of a PCM buffer, for the WAV writer.
    static func rawBytes(_ buffer: AVAudioPCMBuffer) -> Data {
        if let ints = buffer.int16ChannelData, buffer.format.isInterleaved {
            let count = Int(buffer.frameLength) * Int(buffer.format.channelCount)
            return Data(bytes: ints, count: count * MemoryLayout<Int16>.size)
        }
        if let ints = buffer.int16ChannelData {
            // Non-interleaved: merge the channels.
            let channels = Int(buffer.format.channelCount)
            let frames = Int(buffer.frameLength)
            var merged = [Int16](repeating: 0, count: frames * channels)
            for channel in 0..<channels {
                let data = ints[channel]
                for i in 0..<frames {
                    merged[i * channels + channel] = data[i]
                }
            }
            return merged.withUnsafeBytes { Data($0) }
        }
        return Data()
    }
}
