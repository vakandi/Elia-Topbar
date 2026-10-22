import Foundation

/// A resident Whisper process that loads the model once and answers
/// transcription requests over stdin/stdout. The process is spawned lazily
/// on the first request after "keep loaded" is turned on, and exits after
/// a configurable idle time so the RAM/VRAM goes back.
///
/// The protocol is line-oriented: one JSON object per request on stdin,
/// one `__ELIA_JSON__`-prefixed line per response on stdout.
actor STTDaemon {

    static let shared = STTDaemon()

    enum DaemonError: LocalizedError {
        case notAvailable(String)
        case timeout
        case badOutput(String)
        case processDied(String)

        var errorDescription: String? {
            switch self {
            case .notAvailable(let m): return m
            case .timeout: return "The resident Whisper process did not answer in time."
            case .badOutput(let m): return "Unexpected helper output: \(m)"
            case .processDied(let m): return "The resident Whisper process died: \(m)"
            }
        }
    }

    private struct Pending {
        let continuation: CheckedContinuation<[String: Any], Error>
        let timeoutTask: Task<Void, Never>
    }

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var linePump: LinePump?
    private var nextID = 0
    private var pending: [Int: Pending] = [:]
    private var idleUnloadTask: Task<Void, Never>?
    private var dying = false
    private var ready = false
    private var readyContinuation: CheckedContinuation<Void, Error>?

    /// Transcribe one file through the daemon. Falls back to the one-shot
    /// path in `STTEngine` if the daemon cannot be used; this method
    /// throws on failure.
    func transcribe(wav: URL,
                    model: AudioSettings.SttModel,
                    language: String,
                    timeout: TimeInterval) async throws -> (text: String, language: String?) {
        let payload: [String: Any] = [
            "cmd": "transcribe",
            "audio": wav.path,
            "model": model.repoID,
            "language": language.isEmpty ? "auto" : language,
        ]
        let response = try await request(payload, timeout: timeout)
        guard response["ok"] as? Bool == true else {
            throw DaemonError.notAvailable(response["error"] as? String ?? "The transcription failed.")
        }
        return (text: response["text"] as? String ?? "",
                language: response["language"] as? String)
    }

    /// Send one request and wait for the matching response.
    private func request(_ payload: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        try await ensureRunning()
        let id = nextID
        nextID += 1
        var body = payload
        body["id"] = id

        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw DaemonError.badOutput("could not encode request")
        }

        return try await withCheckedThrowingContinuation { cont in
            // Write on this actor (we are isolated); the continuation is
            // resumed from the line pump callback.
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.timeout(id: id)
            }
            self.pending[id] = Pending(continuation: cont, timeoutTask: timeoutTask)
            do {
                var line = data
                line.append(contentsOf: "\n".utf8)
                try self.stdinHandle?.write(contentsOf: line)
            } catch {
                self.pending.removeValue(forKey: id)
                timeoutTask.cancel()
                cont.resume(throwing: DaemonError.processDied(error.localizedDescription))
                return
            }
        }
    }

    private func timeout(id: Int) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timeoutTask.cancel()
        entry.continuation.resume(throwing: DaemonError.timeout)
        // A hung process is unusable; take it down so the next request
        // starts a fresh one.
        terminateProcess(reason: "timeout")
    }

    /// Make sure the process is alive, spawning it if needed.
    private func ensureRunning() async throws {
        if let p = process, p.isRunning, ready {
            return
        }
        // Clean any dead process first.
        if let p = process, !p.isRunning {
            process = nil
            stdinHandle = nil
            stdoutHandle = nil
            linePump = nil
            ready = false
        }
        guard process == nil else { return }

        guard let python = await STTEngine.interpreter() else {
            throw DaemonError.notAvailable("No Python with mlx-whisper was found. Install it with: pip3 install mlx-whisper")
        }
        let script = try STTHelper.install()
        dying = false
        ready = false

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [script.path, "--model", AudioSettings.sttModel.repoID, "--daemon"]

        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = outPipe
        // Discard stderr noise on a background queue so the pipe never fills.
        let pump = LinePump()
        self.linePump = pump
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                Task { await self?.processExited() }
                return
            }
            let lines = pump.push(data)
            for line in lines {
                Task { await self?.handleLine(line) }
            }
        }
        self.stdinHandle = inPipe.fileHandleForWriting
        self.stdoutHandle = outPipe.fileHandleForReading

        proc.terminationHandler = { [weak self] _ in
            Task { await self?.processExited() }
        }

        do {
            try proc.run()
        } catch {
            throw DaemonError.processDied("Could not start \(python): \(error.localizedDescription)")
        }
        self.process = proc

        // Wait for the handshake (the model import on the Python side).
        do {
            try await waitForReady(timeout: 30)
        } catch {
            terminateProcess(reason: "startup failed")
            throw error
        }
    }

    private func waitForReady(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.readyContinuation = cont
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.readyTimeout()
            }
        }
    }

    private func readyTimeout() {
        if let cont = readyContinuation {
            readyContinuation = nil
            cont.resume(throwing: DaemonError.timeout)
        }
        terminateProcess(reason: "ready timeout")
    }

    private func handleLine(_ line: String) {
        guard line.hasPrefix(STTHelper.jsonPrefix) else { return }
        let json = line.dropFirst(STTHelper.jsonPrefix.count)
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // Handshake / lifecycle events.
        if obj["event"] as? String == "ready" {
            ready = true
            if let cont = readyContinuation {
                readyContinuation = nil
                cont.resume()
            }
            return
        }
        if obj["event"] as? String == "shutdown" {
            return
        }

        guard let id = obj["id"] as? Int,
              let entry = pending.removeValue(forKey: id) else { return }
        entry.timeoutTask.cancel()
        // A successful answer reschedules the idle unload.
        scheduleIdleUnload()
        entry.continuation.resume(returning: obj)
    }

    private func processExited() {
        // Fail everything pending; the next request respawns.
        let ps = pending
        pending.removeAll()
        for (_, entry) in ps {
            entry.timeoutTask.cancel()
            entry.continuation.resume(throwing: DaemonError.processDied("the process exited"))
        }
        stdoutHandle?.readabilityHandler = nil
        process = nil
        stdinHandle = nil
        stdoutHandle = nil
        linePump = nil
        ready = false
    }

    private func terminateProcess(reason: String) {
        guard let p = process, p.isRunning else {
            process = nil
            return
        }
        p.terminate()
        // Give it a moment, then force.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await self?.forceKillAfterGrace()
        }
        AppLog.important("voice: daemon terminated (\(reason))")
    }

    /// Schedule the idle unload. Replaces any previous timer.
    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        let minutes = max(1, AudioSettings.sttUnloadMin)
        idleUnloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.shutDown(idle: true)
        }
    }

    /// Shut the daemon down. Called on idle unload or when "keep loaded"
    /// is turned off.
    func shutDown(idle: Bool) async {
        guard process != nil else { return }
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        dying = true
        // Polite request; the process exits its loop on this.
        if let handle = stdinHandle {
            var line = Data()
            if let data = try? JSONSerialization.data(withJSONObject: ["id": -1, "cmd": "shutdown"]) {
                line.append(data)
                line.append(contentsOf: "\n".utf8)
                try? handle.write(contentsOf: line)
            }
        }
        // Grace period, then force.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await self?.forceKill()
        }
        AppLog.important("voice: daemon shutting down (idle=\(idle))")
    }

    private func forceKillAfterGrace() async {
        if let p = process, p.isRunning {
            kill(p.processIdentifier, SIGKILL)
        }
        process = nil
        stdinHandle = nil
        stdoutHandle = nil
        linePump = nil
        ready = false
    }

    private func forceKill() {
        guard let p = process, p.isRunning else {
            process = nil
            return
        }
        p.terminate()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await self?.forceKillAfterGrace()
        }
    }

    /// Called when "keep loaded" is toggled off.
    func onKeepLoadedDisabled() async {
        await shutDown(idle: false)
    }
}

/// A small byte buffer that accumulates pipe output and returns complete
/// lines. Safe to call from the readability handler's background queue.
private final class LinePump: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func push(_ data: Data) -> [String] {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let range = buffer.range(of: Data("\n".utf8)) {
            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex...range.lowerBound)
            if let text = String(data: lineData, encoding: .utf8) {
                lines.append(text)
            }
        }
        lock.unlock()
        return lines
    }
}