import Foundation

/// Runs the Whisper helper in a separate interpreter.
///
/// The interpreter is discovered by probing for `mlx_whisper`, because the
/// python that owns it is not the one on the app's PATH (an app launched
/// from Finder gets a minimal PATH, and `/usr/bin/python3` has no mlx).
enum STTEngine {

    enum EngineError: LocalizedError {
        case noInterpreter
        case helperFailed(String)
        case timeout
        case badOutput(String)

        var errorDescription: String? {
            switch self {
            case .noInterpreter:
                return "No Python with mlx-whisper was found. Install it with: pip3 install mlx-whisper"
            case .helperFailed(let message):
                return message
            case .timeout:
                return "The transcription timed out."
            case .badOutput(let message):
                return "Unexpected helper output: \(message)"
            }
        }
    }

    struct Result {
        let text: String
        let language: String?
    }

    private static var cachedInterpreter: String?

    /// The interpreter cache lives in an actor so the async probe never
    /// touches a lock from an async context.
    private actor InterpreterCache {
        static let shared = InterpreterCache()
        private var path: String?
        func cached() -> String? { path }
        func store(_ value: String) { path = value }
    }

    // MARK: - Interpreter discovery

    /// Candidate interpreters, best first.
    ///
    /// The Python framework is installed system-wide in `/Library`, and
    /// sometimes per-user in `~/Library` — both are checked, because the
    /// mlx-whisper install is per-interpreter.
    static var interpreterCandidates: [String] {
        var out: [String] = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
        ]
        let roots = [
            "/Library/Frameworks/Python.framework/Versions",
            NSString(string: "~/Library/Frameworks/Python.framework/Versions").expandingTildeInPath,
        ]
        for root in roots {
            // Every installed version, newest first. `Current` is tried last:
            // on this machine it points at an older 3.13 that has no
            // mlx-whisper, while 3.14 does.
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: root) {
                let sorted = entries
                    .filter { $0 != "Current" }
                    .sorted { lhs, rhs in
                        let l = Double(lhs) ?? 0, r = Double(rhs) ?? 0
                        return l > r
                    }
                out.append(contentsOf: sorted.map { "\(root)/\($0)/bin/python3" })
            }
            out.append("\(root)/Current/bin/python3")
        }
        out.append(NSString(string: "~/.local/bin/python3").expandingTildeInPath)
        out.append("/usr/bin/python3")
        return out
    }

    /// The first interpreter that can import mlx_whisper. Cached after the
    /// first successful probe.
    static func interpreter() async -> String? {
        if let cached = await InterpreterCache.shared.cached() { return cached }

        for candidate in interpreterCandidates where FileManager.default.isExecutableFile(atPath: candidate) {
            if await hasMLXWhisper(candidate) {
                await InterpreterCache.shared.store(candidate)
                cachedInterpreter = candidate
                return candidate
            }
        }
        return nil
    }

    /// Probe one interpreter for mlx_whisper.
    static func hasMLXWhisper(_ path: String) async -> Bool {
        guard let python = try? await run(path: path,
                                         arguments: ["-c", "import mlx_whisper"],
                                         timeout: 20) else { return false }
        return python.code == 0
    }

    /// Whether the engine is usable at all (for the settings status line).
    static func isAvailable() async -> Bool {
        await interpreter() != nil
    }

    // MARK: - Work

    /// Transcribe a WAV file with the chosen model.
    static func transcribe(wav: URL,
                           model: AudioSettings.SttModel,
                           language: String,
                           timeout: TimeInterval? = nil) async throws -> Result {
        if AudioSettings.keepSttLoaded {
            do {
                let (text, lang) = try await STTDaemon.shared.transcribe(
                    wav: wav, model: model, language: language,
                    timeout: timeout ?? model.timeout)
                return Result(text: text, language: lang)
            } catch {
                AppLog.important("voice: daemon failed, falling back to one-shot: \(error.localizedDescription)")
            }
        }
        let payload = try await runHelper(
            arguments: [
                wav.path,
                "--model", model.repoID,
                "--language", language.isEmpty ? "auto" : language,
            ],
            timeout: timeout ?? model.timeout
        )
        let json = try decode(payload)
        guard json["ok"] as? Bool == true else {
            throw EngineError.helperFailed(json["error"] as? String ?? "The transcription failed.")
        }
        return Result(text: json["text"] as? String ?? "",
                      language: json["language"] as? String)
    }

    /// Download a model without transcribing. Returns the cache path.
    static func download(model: AudioSettings.SttModel) async throws -> String {
        let payload = try await runHelper(
            arguments: ["--model", model.repoID, "--download-only"],
            timeout: 1800
        )
        let json = try decode(payload)
        guard json["ok"] as? Bool == true else {
            throw EngineError.helperFailed(json["error"] as? String ?? "The download failed.")
        }
        return json["path"] as? String ?? ""
    }

    /// Whether the model is already on disk. Never touches the network.
    /// The check is done on the filesystem first; the helper is only used
    /// when the cache layout is ambiguous (custom HF_HOME etc.).
    static func isCached(model: AudioSettings.SttModel) async -> Bool {
        if let cached = modelOnDisk(model: model) { return cached }
        guard let payload = try? await runHelper(
            arguments: ["--model", model.repoID, "--check-only"],
            timeout: 60
        ) else { return false }
        return payload["cached"] as? Bool == true
    }

    /// Whether the model's snapshot folder exists on disk. Returns nil when
    /// the cache root cannot be determined (custom env / missing folder) so
    /// the caller falls back to the helper.
    static func modelOnDisk(model: AudioSettings.SttModel) -> Bool? {
        let env = ProcessInfo.processInfo.environment
        let custom = env["HUGGINGFACE_HUB_CACHE"] != nil
            || env["HUGGINGFACE_HUB"] != nil
            || env["HF_HOME"] != nil
        let root: URL
        if let hub = env["HUGGINGFACE_HUB_CACHE"] ?? env["HUGGINGFACE_HUB"] {
            root = URL(fileURLWithPath: hub)
        } else if let hfHome = env["HF_HOME"] {
            root = URL(fileURLWithPath: hfHome).appendingPathComponent("hub")
        } else {
            let candidate = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/huggingface/hub")
            guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
            root = candidate
        }
        let repoDir = "models--\(model.repoID.replacingOccurrences(of: "/", with: "--"))"
        let snapshots = root.appendingPathComponent(repoDir).appendingPathComponent("snapshots")
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: snapshots.path) else {
            return custom ? nil : false
        }
        return items.contains { !$0.hasPrefix(".") }
    }

    /// Run the helper and return the JSON payload it printed.
    private static func runHelper(arguments: [String], timeout: TimeInterval) async throws -> [String: Any] {
        guard let python = await interpreter() else { throw EngineError.noInterpreter }
        let script = try STTHelper.install()
        return try await runJSON(path: python, arguments: [script.path] + arguments, timeout: timeout)
    }

    /// Run a process, wait with a timeout, and return its JSON line.
    private static func runJSON(path: String,
                                arguments: [String],
                                timeout: TimeInterval) async throws -> [String: Any] {
        let output = try await run(path: path, arguments: arguments, timeout: timeout)
        guard output.code == 0 || !output.stdout.isEmpty else {
            throw EngineError.helperFailed(output.stderr.isEmpty ? "The helper exited with code \(output.code)." : output.stderr)
        }
        let line = output.stdout
            .split(separator: "\n")
            .last { $0.hasPrefix(STTHelper.jsonPrefix) }
        guard let line else {
            throw EngineError.badOutput(output.stdout.isEmpty ? output.stderr : output.stdout)
        }
        let json = line.dropFirst(STTHelper.jsonPrefix.count)
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EngineError.badOutput(String(line))
        }
        return parsed
    }

    private static func decode(_ payload: [String: Any]) throws -> [String: Any] { payload }

    // MARK: - Process plumbing

    struct ProcessOutput {
        let code: Int32
        let stdout: String
        let stderr: String
    }

    /// Run a process and collect its output, killing it if it overruns.
    static func run(path: String, arguments: [String], timeout: TimeInterval) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let waiter = TerminationWaiter()
        process.terminationHandler = { proc in waiter.complete(proc.terminationStatus) }

        do {
            try process.run()
        } catch {
            throw EngineError.helperFailed("Could not start \(path): \(error.localizedDescription)")
        }

        // Drain both pipes on background queues so a full pipe never stalls
        // the child.
        async let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        async let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

        let status: Int32
        do {
            status = try await withThrowingTaskGroup(of: Int32.self) { group in
                group.addTask { await waiter.wait() }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(max(0.1, timeout) * 1_000_000_000))
                    throw EngineError.timeout
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } catch {
            if process.isRunning { process.terminate() }
            _ = await outData
            _ = await errData
            throw error
        }

        let out = String(data: await outData, encoding: .utf8) ?? ""
        let err = String(data: await errData, encoding: .utf8) ?? ""
        return ProcessOutput(code: status, stdout: out, stderr: err)
    }
}

/// Resumes a continuation exactly once, from the process termination handler.
private final class TerminationWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int32, Never>?
    private var resolved: Int32?

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let resolved {
                lock.unlock()
                continuation.resume(returning: resolved)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func complete(_ status: Int32) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            resolved = status
            lock.unlock()
            continuation.resume(returning: status)
        } else {
            resolved = status
            lock.unlock()
        }
    }
}
