import Foundation
import EliaTopBarKit

/// Routes agent triggers straight to the `devin` CLI.
///
/// Enabled whenever the CLI config carries a model (`agent.model` in
/// ~/.config/devin/config.json — what the Devin chooser's Apply writes).
/// When enabled, `SubworkerManager.triggerSubworker` never reaches the
/// BunControl bridge: the agent's PROMPT.md (or the voice-built prompt)
/// goes to `devin -p` in the agent's own subworker directory, on the
/// configured model, fire-and-forget like the bridge trigger.
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

    /// Fire-and-forget `devin -p` run for one agent.
    ///
    /// - `prompt`: when non-empty it replaces the agent's PROMPT.md, matching
    ///   the bridge contract (the voice router already sends a full prompt).
    /// - Otherwise the agent's `<repo>/subworkers/<agent>/PROMPT.md` is used
    ///   verbatim and the run's cwd is that same directory.
    func run(agent: String, prompt: String?) {
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
                return
            }
            promptText = text
        }

        // PROMPT.md files run to tens of KB — far past a comfortable argv,
        // so the prompt always travels via --prompt-file.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("devin-\(agent)-\(Int(Date().timeIntervalSince1970)).md")
        do {
            try promptText.write(to: tmp, atomically: true, encoding: .utf8)
        } catch {
            AppLog.d("DevinRunner: prompt write failed for \(agent): \(error.localizedDescription)")
            return
        }

        let cwd = FileManager.default.fileExists(atPath: agentDir.path)
            ? agentDir : URL(fileURLWithPath: repo, isDirectory: true)

        AppLog.d("DevinRunner: \(agent) -> devin --model \(model) (cwd \(cwd.lastPathComponent))")

        // One hour ceiling: devin -p exits when the turn ends, but a hung
        // session must not pin the task table forever.
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            defer {
                Task { @MainActor in self?.tasks[agent] = nil }
            }
            do {
                let result = try await DevinProcess.run(
                    devin,
                    [
                        "--model", model,
                        "--permission-mode", "dangerous",
                        "--respect-workspace-trust", "false",
                        "--prompt-file", tmp.path,
                        "-p",
                    ],
                    timeout: 3600,
                    currentDirectoryURL: cwd
                )
                try? FileManager.default.removeItem(at: tmp)
                let tail = result.stdout.suffix(400)
                AppLog.d("DevinRunner \(agent) exit=\(result.status) out=\(result.stdout.count)B")
                if result.status != 0 {
                    AppLog.d("DevinRunner \(agent) stderr tail: \(result.stderr.suffix(400))")
                } else if !tail.isEmpty {
                    AppLog.d("DevinRunner \(agent) out tail: \(tail)")
                }
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                AppLog.d("DevinRunner \(agent) error: \(error.localizedDescription)")
            }
        }
        tasks[agent] = task
    }
}
