import Foundation
import EliaTopBarKit

/// Routes agent triggers straight to the `devin` CLI over ACP.
///
/// Enabled whenever the CLI config carries a model (`agent.model` in
/// ~/.config/devin/config.json — what the Devin chooser's Apply writes).
/// When enabled, `SubworkerManager.triggerSubworker` never reaches the
/// BunControl bridge: the agent's PROMPT.md (or the voice-built prompt)
/// goes to a `devin acp` session in the agent's own subworker directory.
///
/// Live output is translated from ACP `session/update` notifications into
/// the exact `LivestreamStore.appendDelta` contract the OpenCode `run_log`
/// WebSocket events feed, so LogPopoverView / RunPopupController render a
/// Devin run with zero changes. Raw ACP lines are NEVER logged: the CLI
/// emits `_cognition.ai/output` notifications that can contain MCP command
/// lines with secrets.
@MainActor
final class DevinRunner {
    static let shared = DevinRunner()

    /// agent name -> in-flight run. A second trigger for the same agent is
    /// dropped rather than queued — same semantics as a busy subworker.
    private var tasks: [String: Task<Void, Never>] = [:]

    /// True when agent runs should go to `devin` instead of BunControl:
    /// a model is configured AND the binary resolves.
    var isEnabled: Bool {
        guard let uid = DevinConfig.currentModel(), !uid.isEmpty else { return false }
        return DevinPaths.locate("devin") != nil
    }

    /// Agents with a devin run in flight.
    var activeAgents: [String] { tasks.keys.sorted() }

    /// Fire-and-forget ACP run for one agent.
    ///
    /// - `prompt`: when non-empty it replaces the agent's PROMPT.md, matching
    ///   the bridge contract (the voice router already sends a full prompt).
    /// - Otherwise the agent's `<repo>/subworkers/<agent>/PROMPT.md` is used
    ///   verbatim and the session cwd is that same directory.
    /// - `onFinish`: called on the main actor when the run ends, with an
    ///   optional error string. The caller flips `subworkers[].running`,
    ///   which is what lights up the topbar icon, menu status and run popup.
    func run(agent: String, prompt: String?,
             onFinish: ((String, String?) -> Void)? = nil) {
        guard isEnabled,
              tasks[agent] == nil,
              let devin = DevinPaths.locate("devin"),
              let model = DevinConfig.currentModel() else { return }

        let repo = SubworkerServerManager.configuredRepoPath
        let agentDir = URL(fileURLWithPath: repo)
            .appendingPathComponent("subworkers", isDirectory: true)
            .appendingPathComponent(agent, isDirectory: true)

        let promptText: String
        if let prompt, !prompt.isEmpty {
            promptText = prompt
        } else {
            let url = agentDir.appendingPathComponent("PROMPT.md")
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                AppLog.d("DevinRunner: no PROMPT.md for \(agent) at \(url.path)")
                onFinish?(agent, "no PROMPT.md for \(agent)")
                return
            }
            promptText = text
        }

        let cwd = FileManager.default.fileExists(atPath: agentDir.path)
            ? agentDir : URL(fileURLWithPath: repo, isDirectory: true)

        AppLog.d("DevinRunner: \(agent) -> devin acp --model \(model) (cwd \(cwd.lastPathComponent))")

        // Run boundary: clears the previous run's live entries/todos exactly
        // like subworker_started does for bridge runs.
        LivestreamStore.shared.noteRunStarted(agent: agent)

        let finish: @Sendable (String?) -> Void = { [weak self] error in
            Task { @MainActor in
                self?.tasks[agent] = nil
                onFinish?(agent, error)
            }
        }

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let client = DevinACPClient(
                executable: devin,
                arguments: ["acp", "--model", model],
                currentDirectoryURL: cwd,
                agent: agent
            ) { agent, sessionId, update in
                // session/update notifications -> the shared live feed.
                Task { @MainActor in
                    if let sessionId {
                        LivestreamStore.shared.observeLive(agent: agent, sessionId: sessionId)
                    }
                    DevinRunner.translate(update: update, agent: agent)
                }
            }
            do {
                let sessionId = try await client.run(prompt: promptText,
                                                     timeout: 3600)
                AppLog.d("DevinRunner \(agent) done session=\(sessionId ?? "?")")
                finish(nil)
            } catch {
                AppLog.d("DevinRunner \(agent) error: \(error.localizedDescription)")
                finish(error.localizedDescription)
            }
        }
        tasks[agent] = task
    }

    /// ACP `session/update` kinds -> LivestreamStore delta fields. Only the
    /// kinds the UI understands are translated; everything else
    /// (usage_update, available_commands_update, session_info_update, …)
    /// is dropped here, before it can reach a log.
    private static func translate(update: [String: Any], agent: String) {
        guard let kind = update["sessionUpdate"] as? String else { return }
        switch kind {
        case "agent_message_chunk":
            if let text = chunkText(update) {
                LivestreamStore.shared.appendDelta(agent: agent, field: "text", delta: text)
            }
        case "agent_thought_chunk":
            if let text = chunkText(update) {
                LivestreamStore.shared.appendDelta(agent: agent, field: "reasoning", delta: text)
            }
        case "tool_call":
            emitToolCall(update, agent: agent, final: false)
        case "tool_call_update":
            emitToolCall(update, agent: agent, final: true)
        default:
            break
        }
    }

    private static func chunkText(_ update: [String: Any]) -> String? {
        guard let content = update["content"] as? [String: Any],
              content["type"] as? String == "text",
              let text = content["text"] as? String, !text.isEmpty
        else { return nil }
        return text
    }

    /// tool_call / tool_call_update -> a `field:"tool"` delta carrying the
    /// same JSON shape the OpenCode bridge emits ({"tool","input","output"}).
    /// Updates only emit once the call settles so one tool does not become
    /// a dozen rows.
    private static func emitToolCall(_ update: [String: Any], agent: String, final: Bool) {
        if !final {
            let name = (update["kind"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (update["title"] as? String) ?? "tool"
            var payload: [String: Any] = ["tool": name]
            if let raw = update["rawInput"] {
                payload["input"] = stringify(raw)
            } else if let title = update["title"] as? String {
                payload["input"] = title
            }
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let json = String(data: data, encoding: .utf8) {
                LivestreamStore.shared.appendDelta(agent: agent, field: "tool", delta: json)
            }
            return
        }
        let status = (update["status"] as? String) ?? ""
        guard status == "completed" || status == "failed" else { return }
        var payload: [String: Any] = ["tool": "tool"]
        payload["output"] = toolOutputText(update)
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: data, encoding: .utf8) {
            LivestreamStore.shared.appendDelta(agent: agent, field: "tool", delta: json)
        }
    }

    private static func toolOutputText(_ update: [String: Any]) -> String {
        if let raw = update["rawOutput"], !(raw is NSNull) {
            return stringify(raw)
        }
        if let content = update["content"] as? [[String: Any]] {
            var parts: [String] = []
            for item in content {
                if let inner = item["content"] as? [String: Any],
                   inner["type"] as? String == "text",
                   let t = inner["text"] as? String { parts.append(t) }
                else if let t = item["text"] as? String { parts.append(t) }
            }
            if !parts.isEmpty { return parts.joined(separator: "\n") }
        }
        if let status = update["status"] as? String { return status }
        return ""
    }

    private static func stringify(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let data = try? JSONSerialization.data(withJSONObject: value),
           let s = String(data: data, encoding: .utf8) { return s }
        return "\(value)"
    }
}

// MARK: - ACP client (background, one JSON-RPC message per line)

/// Minimal ACP client: initialize → session/new → session/prompt, streaming
/// `session/update` notifications through `onUpdate`. Agent→client requests
/// (permission prompts) are auto-allowed; everything else gets a JSON-RPC
/// error so the agent never waits on us.
private final class DevinACPClient {
    private let process: Process
    private let stdin: FileHandle
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var pendingLock = NSLock()
    private var lineBuffer = Data()
    private var bufferLock = NSLock()
    private var finished = false
    private let finishLock = NSLock()
    private let agent: String
    private let onUpdate: @Sendable (String, String?, [String: Any]) -> Void

    init(executable: URL, arguments: [String], currentDirectoryURL: URL,
         agent: String,
         onUpdate: @escaping @Sendable (String, String?, [String: Any]) -> Void) {
        self.agent = agent
        self.onUpdate = onUpdate
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [
            "/opt/homebrew/bin", "/usr/local/bin",
            NSHomeDirectory() + "/.local/bin",
            env["PATH"] ?? "/usr/bin:/bin",
        ].joined(separator: ":")
        process.environment = env

        let input = Pipe()
        let out = Pipe()
        // stderr to null: tracing can be verbose and is never needed here.
        process.standardInput = input
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        self.process = process
        self.stdin = input.fileHandleForWriting
        _ = input // keep the read end referenced by the process

        process.terminationHandler = { [weak self] _ in
            self?.terminateAll(DevinError.message("devin acp exited"))
        }

        let readHandle = out.fileHandleForReading
        readHandle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self?.terminateAll(DevinError.message("devin acp closed stdout"))
                return
            }
            self?.consume(chunk)
        }
    }

    /// Runs the full handshake + prompt. Returns the ACP session id.
    /// Throws DevinError on spawn failure, JSON-RPC error, or timeout.
    func run(prompt: String, timeout: TimeInterval) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: DevinError.message("client deallocated"))
                    return
                }
                do {
                    try self.process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let killer = DispatchWorkItem { [weak self] in
                    self?.terminateAll(DevinError.message("devin acp timed out"))
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

                Task { [weak self] in
                    guard let self else { return }
                    do {
                        _ = try await self.request("initialize", params: [
                            "protocolVersion": 1,
                            "clientCapabilities": [String: Any](),
                        ])
                        // ACP has no `initialized` notification (that is LSP);
                        // sending one just earns a -32601 warning on the server.
                        let session = try await self.request("session/new", params: [
                            "cwd": self.process.currentDirectoryURL?.path ?? NSHomeDirectory(),
                            "mcpServers": [[String: Any]](),
                        ])
                        guard let sid = session["sessionId"] as? String else {
                            throw DevinError.message("session/new returned no sessionId")
                        }
                        // The prompt response IS the end of the turn.
                        _ = try await self.request("session/prompt", params: [
                            "sessionId": sid,
                            "prompt": [["type": "text", "text": prompt]],
                        ])
                        killer.cancel()
                        self.shutdown()
                        continuation.resume(returning: sid)
                    } catch {
                        killer.cancel()
                        self.shutdown()
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    // MARK: JSON-RPC plumbing

    private func nextRequestID() -> Int {
        pendingLock.lock(); defer { pendingLock.unlock() }
        defer { nextID += 1 }
        return nextID
    }

    private func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        // write(contentsOf:) throws on EPIPE; the plain write(_:) would
        // raise an ObjC exception and take the whole app down.
        try? stdin.write(contentsOf: Data(line.utf8))
    }

    private func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = nextRequestID()
        return try await withCheckedThrowingContinuation { continuation in
            pendingLock.lock()
            pending[id] = continuation
            pendingLock.unlock()
            send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        }
    }

    private func respond(id: Any, result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func respondError(id: Any, code: Int, message: String) {
        send(["jsonrpc": "2.0", "id": id,
              "error": ["code": code, "message": message]])
    }

    /// One NDJSON frame. Messages with BOTH id and method are agent→client
    /// requests (permission prompts); id+result/error are responses to us;
    /// method-only are notifications.
    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        bufferLock.lock()
        lineBuffer.append(data)
        var lines: [Data] = []
        while let nl = lineBuffer.firstIndex(of: 0x0A) {
            lines.append(lineBuffer[..<nl])
            lineBuffer.removeSubrange(...nl)
        }
        bufferLock.unlock()

        for line in lines where !line.isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { continue }
            handle(obj)
        }
    }

    private func handle(_ msg: [String: Any]) {
        let method = msg["method"] as? String
        let id = msg["id"]

        // Agent → client request: must be answered or the agent stalls.
        if let method, let rid = id {
            if method == "session/request_permission" {
                respondPermission(id: rid, params: msg["params"] as? [String: Any] ?? [:])
            } else {
                respondError(id: rid, code: -32601, message: "method not found")
            }
            return
        }

        // Response to one of our requests.
        if let idNum = id as? Int {
            pendingLock.lock()
            let cont = pending.removeValue(forKey: idNum)
            pendingLock.unlock()
            guard let cont else { return }
            if let error = msg["error"] as? [String: Any] {
                let text = (error["message"] as? String) ?? "json-rpc error"
                cont.resume(throwing: DevinError.message(text))
            } else if let result = msg["result"] as? [String: Any] {
                cont.resume(returning: result)
            } else {
                cont.resume(returning: [:])
            }
            return
        }

        // Notification. Only session/update carries streamable content.
        guard method == "session/update",
              let params = msg["params"] as? [String: Any],
              let update = params["update"] as? [String: Any] else { return }
        onUpdate(agent, params["sessionId"] as? String, update)
    }

    /// ACP permission prompt → pick the most permissive allow option,
    /// matching --permission-mode dangerous semantics.
    private func respondPermission(id: Any, params: [String: Any]) {
        let options = params["options"] as? [[String: Any]] ?? []
        let pick = options.first { ($0["kind"] as? String) == "allow_always" }
            ?? options.first { ($0["kind"] as? String) == "allow" }
            ?? options.first
        let optionId = pick?["optionId"] as? String ?? ""
        respond(id: id, result: [
            "outcome": ["outcome": "selected", "optionId": optionId]
        ])
    }

    private func terminateAll(_ error: DevinError) {
        finishLock.lock()
        guard !finished else { finishLock.unlock(); return }
        finished = true
        finishLock.unlock()
        pendingLock.lock()
        let conts = pending
        pending.removeAll()
        pendingLock.unlock()
        for (_, cont) in conts { cont.resume(throwing: error) }
        if process.isRunning { process.terminate() }
    }

    private func shutdown() {
        finishLock.lock()
        finished = true
        finishLock.unlock()
        process.terminationHandler = nil
        if process.isRunning { process.terminate() }
    }
}
