import Foundation
import os

/// Off-main-thread, size-capped, coalescing append-only log writer.
///
/// Why this exists: the app used to open `/tmp/EliaTopBar.log` with four
/// synchronous `FileHandle` operations **per line** on the main thread, while a
/// drop animation was playing, with no size cap. A burst of 30 run popups
/// meant 30 main-thread file opens, and the file grew for the lifetime of the
/// boot (observed: 4.24 MB after minutes of uptime).
///
/// Behaviour:
/// - Lines are appended to an in-memory buffer on the calling thread (cheap).
/// - A background serial queue coalesces the buffer into **one** open/write/
///   close per flush interval, regardless of how many lines arrived.
/// - The file is capped at `byteLimit`. When the cap is exceeded the writer
///   keeps the newest `byteLimit` bytes and drops the older head, so the file
///   never grows past the limit for the lifetime of the process.
///
/// The writer is a `final class` guarded by an `NSLock` rather than an actor so
/// it can be called from any isolation domain without `await`, including from
/// the main actor inside a synchronous callback.
public final class BoundedLogWriter {

public static let sharedDrop = BoundedLogWriter(path: "/tmp/EliaTopBar.log", byteLimit: 2 * 1024 * 1024)
public static let sharedClick = BoundedLogWriter(path: "/tmp/EliaTopBar-clicks.log", byteLimit: 512 * 1024)
    public static let sharedHealth = BoundedLogWriter(
        path: NSString(string: "~/Library/Logs/EliaTopBar/health.log").expandingTildeInPath,
        byteLimit: 512 * 1024
    )

    /// Flush at most this often. Coalescing window: a burst of N lines costs
    /// 1 write, not N.
    private static let flushInterval: TimeInterval = 0.25
    /// Flush early once this many bytes are buffered, so a very long burst
    /// cannot grow the in-memory buffer without bound.
    private static let flushByteThreshold = 64 * 1024
    /// Hard cap on the in-memory buffer. Beyond this, oldest lines are dropped
    /// rather than allowed to accumulate.
    private static let maxBufferBytes = 256 * 1024

    public let byteLimit: Int
    private let queue = DispatchQueue(label: "com.elia.topbar.boundedlog", qos: .utility)
    public var pathURL: URL { URL(fileURLWithPath: path) }
    public let path: String

    private let lock = NSLock()
    private var buffer = Data()
    private var flushScheduled = false

    /// Test hook: number of bytes currently waiting to be flushed.
    public var pendingBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return buffer.count
    }

    public init(path: String, byteLimit: Int) {
        self.path = path
        self.byteLimit = byteLimit
    }

    /// Append one line. Thread-safe and non-blocking; never touches the file.
    public func log(_ msg: String) {
        let line = Data("[\(Date())] \(msg)\n".utf8)
        var dropped = false
        lock.lock()
        // Discard the backlog rather than grow. Keeping capacity would let the
        // next append share storage with an in-flight flush payload (COW race).
        if buffer.count + line.count > Self.maxBufferBytes {
            buffer = Data()
            dropped = true
        }
        buffer.append(line)
        let needsFlush = !flushScheduled || buffer.count >= Self.flushByteThreshold
        if !flushScheduled { flushScheduled = true }
        lock.unlock()

        if dropped {
            os_log("BoundedLogWriter %{public}@ buffer overflow, backlog dropped", log: .default, type: .info, path)
        }
        if needsFlush { scheduleFlush() }
    }

    private func scheduleFlush() {
        queue.asyncAfter(deadline: .now() + Self.flushInterval) { [weak self] in
            self?.flush()
        }
    }

    /// Drain the buffer to disk on the background queue, then enforce the cap.
    public func flush() {
        lock.lock()
        let payload = buffer
        // Fresh storage (not keepingCapacity) so `payload` is uniquely
        // referenced and the next append cannot mutate it under us.
        buffer = Data()
        flushScheduled = false
        lock.unlock()

        guard !payload.isEmpty else { return }

        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? payload.write(to: url)
        } else if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(payload)
            try? h.close()
        }

        trimIfNeeded(url: url)
    }

    /// Keep only the newest `byteLimit` bytes. Runs on the background queue so
    /// the main thread never pays for it.
    private func trimIfNeeded(url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > byteLimit else { return }
        let keep = byteLimit / 2
        guard let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        try? h.seek(toOffset: UInt64(size - keep))
        guard let tail = try? h.readToEnd(), !tail.isEmpty else { return }
        // Atomic-ish replace so a crash mid-trim cannot leave a 0-byte log.
        try? tail.write(to: url, options: .atomic)
    }
}