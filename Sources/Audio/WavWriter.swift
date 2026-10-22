import Foundation

/// Writes a 16 kHz mono PCM16 WAV file.
///
/// Whisper wants exactly that shape, so the capture path never has to
/// resample twice: the system hands us 16 kHz mono and these bytes go
/// straight into the file.
final class WavWriter {

    let url: URL
    let sampleRate: Double
    let channels: Int

    private let handle: FileHandle
    private var dataBytes: Int = 0
    private var closed = false

    init(url: URL, sampleRate: Double = 16_000, channels: Int = 1) throws {
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: WavWriter.header(sampleRate: sampleRate, channels: channels))
    }

    /// Append interleaved 16-bit samples.
    func append(_ data: Data) throws {
        guard !closed, !data.isEmpty else { return }
        try handle.write(contentsOf: data)
        dataBytes += data.count
    }

    /// Patch the sizes and close.
    func finalize() {
        guard !closed else { return }
        closed = true
        // RIFF chunk size = 36 + data size; data chunk size = data bytes.
        let riffSize = UInt32(36 + dataBytes)
        let dataSize = UInt32(dataBytes)
        try? handle.seek(toOffset: 4)
        try? handle.write(contentsOf: Data([UInt8(riffSize & 0xff),
                                             UInt8((riffSize >> 8) & 0xff),
                                             UInt8((riffSize >> 16) & 0xff),
                                             UInt8((riffSize >> 24) & 0xff)]))
        try? handle.seek(toOffset: 40)
        try? handle.write(contentsOf: Data([UInt8(dataSize & 0xff),
                                             UInt8((dataSize >> 8) & 0xff),
                                             UInt8((dataSize >> 16) & 0xff),
                                             UInt8((dataSize >> 24) & 0xff)]))
        try? handle.close()
    }

    /// Bytes of PCM written so far.
    var writtenBytes: Int { dataBytes }

    /// The 44-byte canonical WAV header.
    static func header(sampleRate: Double, channels: Int) -> Data {
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate * Double(channels) * Double(bitsPerSample) / 8)
        let blockAlign = UInt16(channels * Int(bitsPerSample) / 8)
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(contentsOf: UInt32(0).littleEndianBytes)   // patched on finalize
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(contentsOf: UInt32(16).littleEndianBytes)
        data.append(contentsOf: UInt16(1).littleEndianBytes)    // PCM
        data.append(contentsOf: UInt16(channels).littleEndianBytes)
        data.append(contentsOf: UInt32(sampleRate).littleEndianBytes)
        data.append(contentsOf: byteRate.littleEndianBytes)
        data.append(contentsOf: blockAlign.littleEndianBytes)
        data.append(contentsOf: bitsPerSample.littleEndianBytes)
        data.append(contentsOf: Array("data".utf8))
        data.append(contentsOf: UInt32(0).littleEndianBytes)   // patched on finalize
        return data
    }

    // MARK: - Tail slicing (cheap, for live reads)

    /// Cut the last `seconds` of a WAV file WITHOUT reading the whole file.
    /// Used by the live transcription loop so it does not re-read the
    /// growing recording on every tick.
    static func sliceTail(_ url: URL, seconds: Double) -> URL? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 44), head.count >= 44 else { return nil }
        guard head.prefix(4) == Data("RIFF".utf8), head.subdata(in: 8..<12) == Data("WAVE".utf8) else { return nil }
        let channels = Int(head[22]) | (Int(head[23]) << 8)
        let sampleRate = Int(head[24]) | (Int(head[25]) << 8)
            | (Int(head[26]) << 16) | (Int(head[27]) << 24)
        let bitsPerSample = Int(head[34]) | (Int(head[35]) << 8)
        guard channels > 0, sampleRate > 0, bitsPerSample == 16 else { return nil }
        let bytesPerFrame = channels * (bitsPerSample / 8)
        let frameCount = Int(seconds * Double(sampleRate))
        let tailBytes = frameCount * bytesPerFrame
        let size = (try? handle.seekToEnd()) ?? 0
        guard size > 44 + UInt64(tailBytes) else { return nil }
        let start = size - UInt64(tailBytes)
        try? handle.seek(toOffset: start)
        guard let payload = try? handle.readToEnd() else { return nil }
        let outURL = url.deletingPathExtension().appendingPathExtension("tail.wav")
        var out = Data(WavWriter.header(sampleRate: Double(sampleRate), channels: channels))
        out.append(payload)
        let riffSize = UInt32(36 + payload.count)
        let dataSize = UInt32(payload.count)
        out.replaceSubrange(4..<8, with: Data(riffSize.littleEndianBytes))
        out.replaceSubrange(40..<44, with: Data(dataSize.littleEndianBytes))
        try? out.write(to: outURL, options: .atomic)
        return outURL
    }

    // MARK: - Slicing

    /// Cut a time range out of a WAV file.
    ///
    /// Used to transcribe only the part of the recording that the live
    /// transcriber had not settled yet — the whole point of transcribing
    /// while the user speaks.
    static func slice(_ url: URL, from startSeconds: Double, to endSeconds: Double? = nil) -> URL? {
        guard let source = try? Data(contentsOf: url), source.count > 44 else { return nil }
        guard source.prefix(4) == Data("RIFF".utf8), source.subdata(in: 8..<12) == Data("WAVE".utf8) else {
            return nil
        }
        // The header we write is canonical: 44 bytes, PCM 16-bit.
        let channels = Int(source[22]) | (Int(source[23]) << 8)
        let sampleRate = Int(source[24]) | (Int(source[25]) << 8)
            | (Int(source[26]) << 16) | (Int(source[27]) << 24)
        let bitsPerSample = Int(source[34]) | (Int(source[35]) << 8)
        guard channels > 0, sampleRate > 0, bitsPerSample == 16 else { return nil }

        let bytesPerFrame = channels * (bitsPerSample / 8)
        let totalFrames = (source.count - 44) / bytesPerFrame
        let startFrame = max(0, min(totalFrames, Int(startSeconds * Double(sampleRate))))
        let endFrame = max(startFrame, min(totalFrames, endSeconds.map { Int($0 * Double(sampleRate)) } ?? totalFrames))
        guard endFrame > startFrame else { return nil }

        let from = 44 + startFrame * bytesPerFrame
        let to = 44 + endFrame * bytesPerFrame
        let payload = source.subdata(in: from..<to)

        let outURL = url.deletingPathExtension().appendingPathExtension("tail.wav")
        var out = Data(WavWriter.header(sampleRate: Double(sampleRate), channels: channels))
        out.append(payload)
        // Patch the sizes.
        let riffSize = UInt32(36 + payload.count)
        let dataSize = UInt32(payload.count)
        out.replaceSubrange(4..<8, with: Data(riffSize.littleEndianBytes))
        out.replaceSubrange(40..<44, with: Data(dataSize.littleEndianBytes))
        try? out.write(to: outURL, options: .atomic)
        return outURL
    }
}

extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: littleEndian) { Array($0) }
    }
}
