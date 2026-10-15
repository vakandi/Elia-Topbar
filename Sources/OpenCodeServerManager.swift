import Foundation
import AppKit

/// Manages the OpenCode Rust server (a plain native process — no Docker).
///
/// The Docker path is handled by `ColimaManager`. This covers the Rust server
/// that replaced it: one process, one port, started and stopped directly.
///
/// Single-instance is enforced two ways, because a second server is the failure
/// mode that actually bites: a port that is already serving something, and a
/// second `opencode serve` process anywhere on the machine. Both are surfaced so
/// the menu can offer a full kill rather than silently fighting over the port.
@MainActor
final class OpenCodeServerManager: ObservableObject {
    enum Status: Equatable {
        case running
        case unhealthy
        case stopped
        case starting
        case stopping
        case missingBinary

        var label: String {
            switch self {
            case .running: return "Running"
            case .unhealthy: return "Running (not responding)"
            case .stopped: return "Stopped"
            case .starting: return "Starting…"
            case .stopping: return "Stopping…"
            case .missingBinary: return "Not installed"
            }
        }

        var isBusy: Bool { self == .starting || self == .stopping }
    }

    /// A process that looks like an opencode server, for the "other servers" list.
    struct DetectedServer: Identifiable, Equatable {
        let pid: pid_t
        let port: Int?
        let command: String

        var id: pid_t { pid }

        var displayPort: String {
            guard let port else { return "unknown port" }
            return "port \(port)"
        }
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var version: String?
    @Published private(set) var port: Int = OpenCodeServerManager.defaultPort
    @Published private(set) var otherServers: [DetectedServer] = []
    @Published private(set) var actionError: String?
    @Published private(set) var isCleaning = false
    @Published private(set) var lastCleanSummary: String?

    static let defaultPort = 5655
    private static let portDefaultsKey = "opencodeServerPort"
    private static let repoPathDefaultsKey = "opencodeServerRepoPath"

    /// Where the engine checkout lives: the `server/` directory inside the
    /// subworker repo, which vendors the Rust engine. Not a separate
    /// `~/Documents/opencode-rust` clone — nothing in the subworker system
    /// loads or needs that one. Overridable for a fork or second checkout.
    static var repoPath: String {
        get {
            if let stored = UserDefaults.standard.string(forKey: repoPathDefaultsKey),
               !stored.trimmingCharacters(in: .whitespaces).isEmpty {
                return (stored as NSString).expandingTildeInPath
            }
            return SubworkerServerManager.configuredRepoPath + "/server"
        }
        set { UserDefaults.standard.set(newValue, forKey: repoPathDefaultsKey) }
    }

    /// Instance access to the repo path. Setting it re-resolves the binary and
    /// status immediately, so changing the folder in the menu takes effect
    /// without a relaunch.
    var checkoutPath: String {
        get { Self.repoPath }
        set {
            Self.repoPath = newValue
            refresh()
        }
    }

    var configuredPort: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: Self.portDefaultsKey)
            return stored > 0 ? stored : Self.defaultPort
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.portDefaultsKey) }
    }

    /// Resolved binary, or nil when nothing runnable was found.
    ///
    /// `target/release/opencode` is only one of the ways this engine gets
    /// installed: `install.sh` also drops a standalone `opencoderust` on PATH,
    /// and the npm package ships its own. Looking only in target/ reported
    /// "Not built" on a machine where the engine was installed and working.
    var binaryPath: String? {
        let inRepo = "\(Self.repoPath)/target/release/opencode"
        if FileManager.default.isExecutableFile(atPath: inRepo) { return inRepo }
        if let override = UserDefaults.standard.string(forKey: Self.binaryPathKey),
           !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        return Self.discoverInstalledBinary()
    }

    /// Explicit binary path, bypassing the repo lookup.
    var binaryPathOverride: String? {
        get {
            let stored = UserDefaults.standard.string(forKey: Self.binaryPathKey) ?? ""
            return stored.isEmpty ? nil : stored
        }
        set {
            UserDefaults.standard.set(newValue ?? "", forKey: Self.binaryPathKey)
            refresh()
        }
    }

    /// Where the binary actually came from, for the menu.
    var binaryDescription: String {
        guard let path = binaryPath else { return "not found" }
        if path.hasPrefix(Self.repoPath) { return "repo build: \(path)" }
        return "installed: \(path)"
    }

    private static let binaryPathKey = "opencodeServerBinaryPath"

    /// Looks for the engine where an install would actually put it.
    static func discoverInstalledBinary() -> String? {
        var candidates: [String] = []
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in envPath.split(separator: ":").map(String.init) {
            for name in ["opencoderust", "opencode-rust"] {
                candidates.append("\(dir)/\(name)")
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        candidates.append("\(home)/.local/bin/opencoderust")
        candidates.append("\(home)/.local/bin/opr")
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private var statusTimer: Timer?
    private var managedProcess: Process?
    /// Bookmark for the repo folder. macOS only grants an app access to
    /// `~/Documents` when the user picks it, so the grant is stored and reused
    /// instead of re-prompting on every Start.
    private static let accessBookmarkKey = "opencodeRepoAccessBookmark"

    /// macOS grants Documents access only when the user picks the folder, and the
    /// grant has to be stored or every Start re-prompts. Without it, `start.sh`
    /// fails with exit 126 "Operation not permitted".
    @MainActor
    private func requestRepoAccess() async -> Bool {
        if let path = Self.resolveRepoAccess(expected: subworkerRoot) {
            AppLog.important("access: already granted for \(path)")
            return true
        }
        // The user picks, so this is a consent grant for that folder alone — the
        // panel never selects more than one directory and we never widen it.
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: subworkerRoot)
        panel.message = "EliaTopBar needs access to the subworker folder to start the bridge and engine."
        panel.prompt = "Grant Access"

        guard panel.runModal() == .OK, let chosen = panel.url else {
            AppLog.important("access: denied by user")
            return false
        }
        // Grant only the configured checkout. The panel can navigate anywhere, so the
        // choice is validated here rather than trusted — a stale stored path
        // must not silently re-grant access to a different folder later.
        let root = URL(fileURLWithPath: subworkerRoot).standardizedFileURL.path
        let picked = chosen.standardizedFileURL.path
        guard picked == root || picked.hasPrefix(root + "/") else {
            AppLog.important("access: rejected \(picked), outside \(root)")
            return false
        }
        guard let bookmark = try? chosen.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            AppLog.important("access: could not bookmark \(chosen.path)")
            return false
        }
        UserDefaults.standard.set(bookmark, forKey: Self.accessBookmarkKey)
        AppLog.important("access: granted for \(chosen.path)")
        return true
    }

    private static func resolveRepoAccess(expected: String) -> String? {
        guard let data = UserDefaults.standard.data(forKey: accessBookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        // A grant that no longer points at the configured checkout is discarded,
        // so changing the repo path in settings cannot reuse the old grant.
        let root = URL(fileURLWithPath: expected).standardizedFileURL.path
        guard url.standardizedFileURL.path == root else { return nil }
        if stale {
            UserDefaults.standard.removeObject(forKey: accessBookmarkKey)
            return nil
        }
        return url.startAccessingSecurityScopedResource() ? url.path : nil
    }

    /// Process scans (pgrep, ps, lsof) must never run on the main actor.
    /// They did, and every Start/Stop froze the menu for as long as the scan
    /// took — clicking Start was what made the app appear to hang.
    private static let scanQueue = DispatchQueue(label: "com.elia.topbar.ocs.scan", qos: .userInitiated)

    /// A health probe must not hang the menu; anything slower is not healthy.
    private let probeTimeout: TimeInterval = 2.0

    /// How long a freshly spawned server is given to answer /health before we
    /// stop showing "Starting…". Surfaces in the menu so the wait is legible.
    private let settleTimeout: TimeInterval = 15.0
    private let settleInterval: TimeInterval = 0.5

    var isHealthy: Bool { status == .running }
    var isBusy: Bool { status.isBusy }
    /// Elapsed seconds of the current start, for the loading row.
    private(set) var startElapsed: TimeInterval = 0
    private var startBeganAt: Date?

    enum Action { case start, stop }

    struct Outcome {
        let action: Action
        let ok: Bool
        /// The reason, already phrased for a human: on success what is now up,
        /// on failure the one line that explains why nothing is.
        let message: String
    }

    /// Fires once per Start/Stop, at the moment it settles. The menu bar popup
    /// needs a definitive success or failure to swap its spinner for an emoji —
    /// watching `status` instead means guessing whether a transition was caused by
    /// this action or by the background poll.
    var onOutcome: ((Outcome) -> Void)?
    private var pendingAction: Action?
    private var didReportOutcome = false

    /// Single exit point for every terminal start/stop state, so a success or a
    /// failure can never be reported by one path and swallowed by another.
    /// First report wins: several paths converge on a failure (the script exits
    /// non-zero, then the settle poll also gives up), and the popup should show
    /// the first real reason, not the last.
    private func reportOutcome(ok: Bool, _ message: String) {
        guard !didReportOutcome else { return }
        didReportOutcome = true
        let action = pendingAction ?? .start
        AppLog.important("outcome: \(action == .start ? "start" : "stop") ok=\(ok) \(message)")
        onOutcome?(Outcome(action: action, ok: ok, message: message))
    }

    init() {
        port = configuredPort
        refresh()
        scheduleTimer()
    }

    deinit {
        statusTimer?.invalidate()
    }

    // MARK: - Polling

    private func scheduleTimer() {
        statusTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshIfIdle()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
    }

    /// Never probe while a start/stop is in flight: the port is legitimately
    /// mid-transition and would flip the label to "not responding".
    private func refreshIfIdle() {
        guard !isBusy else { return }
        refresh()
    }

    /// Refreshes status off the main actor.
    ///
    /// `settling` must be true only while resolving a start/stop we initiated:
    /// the point of that path is to leave `.starting`/`.stopping`, which the
    /// ordinary isBusy guard exists to prevent. Without it the status could
    /// never leave "starting" — the only code able to move it refused to run
    /// for exactly as long as it was stuck.
    func refresh(settling: Bool = false) {
        port = configuredPort
        if startBeganAt != nil { startElapsed = Date().timeIntervalSince(startBeganAt!) }
        Task { [weak self] in
            guard let self else { return }
            let servers = await Self.detectServersOffMain()
            let probe = await self.probeHealth()
            await self.applyResults(servers: servers, probe: probe, settling: settling)
        }
    }

    private static func detectServersOffMain() async -> [DetectedServer] {
        // Read the subworker repo path on the main actor first: reading
        // UserDefaults off-actor is not safe, and this runs on a scan queue.
        let repo = await MainActor.run { SubworkerServerManager.shared.repoPath }
        return await withCheckedContinuation { continuation in
            scanQueue.async {
                continuation.resume(returning: findServerProcesses(
                    excluding: ProcessInfo.processInfo.processIdentifier,
                    subworkerRepo: repo
                ))
            }
        }
    }

    private static func portOccupiedOffMain(_ port: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            scanQueue.async {
                continuation.resume(returning: isPortOccupiedSync(port))
            }
        }
    }

    // MARK: - Health

    private struct HealthProbe {
        var isHealthy: Bool
        var version: String?
    }

    /// Set when `start.sh` brought the stack up. The bridge and the Rust engine
    /// child bind the ports in `control/config/server.json`, not the standalone
    /// port this menu stores, so health has to follow the repo or the probe
    /// answers for a server nobody started.
    private var bridgeHealthPort: Int?

    private var probePort: Int { bridgeHealthPort ?? port }

    private func probeHealth() async -> HealthProbe {
        guard let url = URL(string: "http://127.0.0.1:\(probePort)/health") else {
            return HealthProbe(isHealthy: false, version: nil)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = probeTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return HealthProbe(isHealthy: false, version: nil)
            }
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let version = json?["version"] as? String
            return HealthProbe(isHealthy: true, version: version)
        } catch {
            // Connection refused is the normal "not running" path.
            return HealthProbe(isHealthy: false, version: nil)
        }
    }

    /// Single place where status is decided, so the busy guard and the start
    /// settle can never disagree about who is allowed to move it.
    private func applyResults(servers: [DetectedServer], probe: HealthProbe, settling: Bool) {
        if !settling { guard !isBusy else { return } }
        otherServers = servers
        if binaryPath == nil && probe.isHealthy == false && servers.isEmpty {
            status = .missingBinary
            version = nil
            startBeganAt = nil
            return
        }
        if probe.isHealthy {
            status = .running
            version = probe.version
            startBeganAt = nil
        } else if servers.isEmpty {
            status = .stopped
            version = nil
            startBeganAt = nil
        } else {
            // Something is serving opencode but did not answer /health.
            status = .unhealthy
            version = nil
            startBeganAt = nil
        }
    }

    // MARK: - Process detection

    /// Find every `opencode ... serve` process, excluding this app.
    ///
    /// `pgrep -f` matches the full command line, which is what makes a server
    /// started from a shell or another tool visible here — those are exactly the
    /// duplicates the single-instance guard has to catch. Callers must be off
    /// the main actor: this shells out to pgrep and then ps once per match.
    static func findServerProcesses(excluding ownPID: pid_t, subworkerRepo: String? = nil) -> [DetectedServer] {
        guard let output = runSync("/usr/bin/pgrep", ["-f", "opencode.*serve"]),
              !output.isEmpty else { return [] }

        var found: [DetectedServer] = []
        for line in output.split(separator: "\n") {
            guard let pid = pid_t(line.trimmingCharacters(in: .whitespaces)) else { continue }
            if pid == ownPID { continue }
            guard let command = runSync("/bin/ps", ["-p", String(pid), "-o", "command="])?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !command.isEmpty else { continue }
            // The subworker server spawns its own Rust harness child, which is
            // also an `opencode serve`. It is not a competing agent engine, so
            // listing it as one sent the user to kill their own subworker
            // stack. stop.sh identifies it the same way: OPENCODE_PATHS_ROOT
            // pointing inside the repo.
            if let repo = subworkerRepo, isSubworkerChild(pid: pid, repo: repo) { continue }
            found.append(DetectedServer(pid: pid, port: portFromCommand(command), command: command))
        }
        return found.sorted { $0.pid < $1.pid }
    }

    /// True when the process's OPENCODE_PATHS_ROOT sits inside the subworker repo.
    private static func isSubworkerChild(pid: pid_t, repo: String) -> Bool {
        guard let env = runSync("/bin/ps", ["eww", "-p", String(pid)]),
              let line = env.split(separator: "\n").first(where: { $0.contains("OPENCODE_PATHS_ROOT=") })
        else { return false }
        guard let marker = line.split(separator: " ").first(where: { $0.hasPrefix("OPENCODE_PATHS_ROOT=") })
        else { return false }
        let value = String(marker.dropFirst("OPENCODE_PATHS_ROOT=".count))
        let normalisedRepo = repo.hasSuffix("/") ? String(repo.dropLast()) : repo
        return value == normalisedRepo || value.hasPrefix(normalisedRepo + "/")
    }

    /// Pull the `--port` value out of a command line, if present.
    static func portFromCommand(_ command: String) -> Int? {
        let tokens = command.split(separator: " ").map(String.init)
        for (index, token) in tokens.enumerated() where token == "--port" || token == "-p" {
            if index + 1 < tokens.count, let value = Int(tokens[index + 1]) { return value }
        }
        return nil
    }

    // MARK: - Start / stop

    // MARK: - Driving the repo's start.sh / stop.sh

    /// `repoPath` is the `server/` checkout; the bridge scripts sit one level up
    /// in the monorepo root, next to control/.
    private var subworkerRoot: String { SubworkerServerManager.configuredRepoPath }
    private var bridgeStartScript: String { subworkerRoot + "/start.sh" }
    private var bridgeStopScript: String { subworkerRoot + "/stop.sh" }
    private var bridgeScriptsExist: Bool {
        FileManager.default.isExecutableFile(atPath: bridgeStartScript)
            && FileManager.default.isExecutableFile(atPath: bridgeStopScript)
    }

    /// The port the bridge binds, read from the same file `start.sh` reads, so
    /// the health probe can never ask a different port than the one bound.
    private func bridgePortFromRepo() -> Int? {
        let path = subworkerRoot + "/control/config/server.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let p = json["port"] as? Int, p > 0 else { return nil }
        return p
    }

    struct ScriptResult {
        let exitCode: Int32
        let output: String
        /// The one line that says why it failed, when the script says so itself.
        /// Both repo scripts report through `[start] ERROR: …` / `[stop] ERROR: …`
        /// on stderr; the popup needs that line, not whatever happened to be last.
        var errorLine: String? {
            output.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.contains("ERROR:") }
                .map { String($0) }
        }
    }

    /// Environment for every child process this manager spawns.
    ///
    /// A `.app` launched by launchd inherits launchd's PATH
    /// (`/usr/bin:/bin:/usr/sbin:/sbin`), never the user's shell PATH. `start.sh`
    /// then dies at its very first gate — `command -v bun` — because bun lives in
    /// `~/.bun/bin`, and the failure reads as "run ./install.sh first" on a machine
    /// where bun is installed and working in a terminal.
    ///
    /// The same gap hides two more tools the script needs: `cargo` in
    /// `~/.cargo/bin` (same gate, plus it builds the engine) and `jq` in
    /// `/opt/homebrew/bin`, without which start.sh silently falls back to its
    /// default port instead of the one in `control/config/server.json`. So the
    /// toolchain dirs are restored explicitly rather than trusting the inherited
    /// environment, which is empty of them.
    ///
    /// Proxy vars are dropped because the desktop shell exports omp's residential
    /// proxy, which refuses outbound HTTPS from the server's context and fails
    /// every provider call while the same request works directly.
    static func launchEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy", "ALL_PROXY", "all_proxy"] {
            env.removeValue(forKey: key)
        }
        let home = NSHomeDirectory()
        let toolchainDirs = [
            home + "/.bun/bin",       // bun — start.sh refuses to start without it
            home + "/.cargo/bin",    // cargo — same gate, and it builds the engine
            home + "/.local/bin",
            "/opt/homebrew/bin",     // jq — start.sh reads the real port with it
            "/usr/local/bin",
        ]
        var seen = Set<String>()
        var pathParts: [String] = []
        for dir in toolchainDirs + (env["PATH"] ?? "").split(separator: ":").map(String.init) {
            let trimmed = dir.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            pathParts.append(trimmed)
        }
        env["PATH"] = pathParts.joined(separator: ":")
        return env
    }

    /// Runs a repo script off the main actor and keeps its output, which is where
    /// start.sh puts the reason it could not come up.
    ///
    /// Output goes to a temp file, never a `Pipe`. `start.sh` detaches the control
    /// plane with `nohup`, and a detached grandchild that inherits the capture pipe
    /// keeps its write end open long after start.sh itself exits — so
    /// `readDataToEndOfFile()` never returns EOF, the continuation never resumes,
    /// and the Start popup spins forever with no verdict. A file has no reader to
    /// starve, so the run always completes.
    ///
    /// The deadline is the second half of that guarantee: a script that hangs for
    /// any other reason is killed and reported as a failure rather than stalling
    /// the action indefinitely. `start.sh`'s own worst case is 30s of health wait
    /// plus a 60s gate; `stop.sh` is two 10s waits.
    private static func runShellScript(_ path: String, in dir: String) async -> ScriptResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let logURL = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("eliatopbar-script-\(UUID().uuidString).log")
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = [path]
                process.currentDirectoryURL = URL(fileURLWithPath: dir)
                process.environment = launchEnvironment()
                let capture = openAppendHandle(logURL.path)
                process.standardOutput = capture
                process.standardError = capture
                process.standardInput = FileHandle.nullDevice

                func finish(exitCode: Int32) {
                    let data = (try? Data(contentsOf: logURL)) ?? Data()
                    let text = String(data: data, encoding: .utf8) ?? ""
                    try? FileManager.default.removeItem(at: logURL)
                    continuation.resume(returning: ScriptResult(exitCode: exitCode, output: text))
                }

                do {
                    try process.run()
                } catch {
                    finish(exitCode: -1)
                    return
                }

                let deadline = Date().addingTimeInterval(scriptTimeout)
                while process.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.2)
                }
                if process.isRunning {
                    AppLog.important("script timed out after \(Int(scriptTimeout))s, killing: \(path)")
                    process.terminate()
                    Thread.sleep(forTimeInterval: 1)
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
                process.waitUntilExit()
                finish(exitCode: process.terminationStatus)
            }
        }
    }

    /// Spawns the executables directly, not the repo's `start.sh`: macOS refuses to
    /// let this app execute a script out of `~/Documents` (exit 126, "Operation
    /// not permitted"). Running bun needs no such grant. Returns false when this
    /// is not a subworker checkout, so the caller falls back to the bare binary.
    private func startViaBridgeScripts() async -> Bool {
        guard bridgeScriptsExist else { return false }
        AppLog.important("start: running \(bridgeStartScript)")

        let result = await Self.runShellScript(bridgeStartScript, in: subworkerRoot)
        AppLog.important("start: exit=\(result.exitCode) output=[\(result.output)]")
        guard result.exitCode == 0 else {
            await failStart(Self.reason(for: result, script: "start.sh"))
            return true
        }

        bridgeHealthPort = bridgePortFromRepo()
        AppLog.important("start: ok bridgePort=\(bridgeHealthPort.map(String.init) ?? "?")")
        settleAfterStart(pid: nil)
        return true
    }

    /// Hard ceiling on one repo script. start.sh's worst case is a 30s health wait
    /// plus a 60s gate; stop.sh is two 10s waits. Past this the script is stuck,
    /// not slow, and the action must still reach a verdict.
    private static let scriptTimeout: TimeInterval = 180

    /// The one line worth putting in front of the user. The script's own
    /// `ERROR:` line names the actual cause; the trailing chatter ("proxy pool=
    /// N entries") is the last thing printed and used to be what the menu showed.
    private static func reason(for result: ScriptResult, script: String) -> String {
        if let line = result.errorLine { return line }
        let tail = result.output.split(separator: "\n").suffix(2)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return tail.isEmpty ? "\(script) exited \(result.exitCode)" : tail
    }

    private func startViaBridge() async -> Bool {
        let bun = Self.findBun()
        let bridgeEntry = subworkerRoot + "/control/server.ts"
        let childScript = subworkerRoot + "/control/data/serve-rust.sh"
        guard let bun,
              FileManager.default.fileExists(atPath: bridgeEntry),
              binaryPath != nil else {
            AppLog.important("start: bridge incomplete (bun=\(bun ?? "nil") engine=\(binaryPath ?? "nil"))")
            return false
        }

        AppLog.important("start: spawning bridge \(bun) \(bridgeEntry)")

        // Detached on purpose: the bridge and its engine child must outlive this
        // app, and a Process we hold a handle on dies with it.
        let bridge = Process()
        bridge.executableURL = URL(fileURLWithPath: bun)
        bridge.arguments = [bridgeEntry]
        bridge.currentDirectoryURL = URL(fileURLWithPath: subworkerRoot)
        var env = Self.launchEnvironment()
        let repoEnv = subworkerRoot + "/.env"
        if let token = readToken(from: repoEnv) { env["ELIA_AUTH_TOKEN"] = token }
        bridge.environment = env
        let bridgeLog = Self.openAppendHandle(subworkerRoot + "/control/data/server.log")
        bridge.standardOutput = bridgeLog
        bridge.standardError = bridgeLog
        bridge.standardInput = FileHandle.nullDevice

        do {
            try bridge.run()
        } catch {
            await failStart("Failed to start bridge: \(error.localizedDescription)")
            return true
        }
        AppLog.important("start: bridge pid=\(bridge.processIdentifier)")

        // The bridge owns the engine child through its watchdog, so starting the
        // bridge is what brings up both ports. spawn the child only if the
        // watchdog has not done it within a moment.
        bridgeHealthPort = bridgePortFromRepo()
        if FileManager.default.isExecutableFile(atPath: childScript) {
            AppLog.important("start: bridge watchdog owns the engine child; \(childScript) is its launcher")
        }
        AppLog.important("start: ok bridgePort=\(bridgeHealthPort.map(String.init) ?? "?")")
        settleAfterStart(pid: nil)
        return true
    }

    private static func findBun() -> String? {
        let candidates = [
            "/Users/vakandi/.bun/bin/bun",
            "/opt/homebrew/bin/bun",
            "/usr/local/bin/bun",
            "/usr/bin/env",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            if path.hasSuffix("/bun") { return path }
        }
        return Self.runSync("/usr/bin/which", ["bun"])?
            .split(separator: "\n").first.map(String.init)
    }

    private func readToken(from path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("ELIA_AUTH_TOKEN=") else { continue }
            var value = String(trimmed.dropFirst("ELIA_AUTH_TOKEN=".count))
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// stdout/stderr appended, so the bridge's own log stays where an operator
    /// running start.sh by hand would leave it.
    private static func openAppendHandle(_ path: String) -> FileHandle {
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return FileHandle.nullDevice }
        handle.seekToEndOfFile()
        return handle
    }

    func start() {
        guard !isBusy else {
            reportOutcome(ok: false, "Busy (\(status.label)) — try again in a moment")
            return
        }

        pendingAction = .start
        didReportOutcome = false
        status = .starting
        actionError = nil
        startElapsed = 0
        startBeganAt = Date()

        Task { [weak self] in
            guard let self else { return }
            // Ask macOS first: the repo lives in ~/Documents, so the launch fails with
            // exit 126 until the user grants access. A stored grant skips the panel.
            let granted = await self.requestRepoAccess()
            guard granted else {
                await self.failStart("Access to \(self.subworkerRoot) was not granted — start.sh cannot be run without it.")
                return
            }
            if await self.startViaBridgeScripts() { return }
            AppLog.important("start: falling back to bare binary at \(Self.repoPath)")
            await self.startStandalone()
        }
    }

    /// The pre-existing path: launch the raw engine as a child of this app. Kept
    /// for checkouts with no bridge scripts, where the binary genuinely is the
    /// whole product.
    private func startStandalone() async {
        guard let binary = binaryPath else {
            let message = "opencode binary not built. Run ./install.sh in \(Self.repoPath)"
            actionError = message
            status = .stopped
            startBeganAt = nil
            reportOutcome(ok: false, message)
            return
        }

        // Refuse rather than fight: a second server on the same port fails in a
        // way that is far harder to diagnose than an explicit refusal.
        let existing = await Self.detectServersOffMain()
        if !existing.isEmpty {
            // A healthy server already on our port is not a conflict, it is
            // the desired end state. Reporting an error here made Start look
            // broken whenever the app was already doing its job.
            let probe = await self.probeHealth()
            if probe.isHealthy, existing.count == 1 {
                self.adoptRunningServer()
                return
            }
            let pids = existing.map { String($0.pid) }.joined(separator: ", ")
            let plural = existing.count == 1 ? "" : "s"
            await self.failStart("\(existing.count) opencode server\(plural) already running (pid \(pids)) — stop them first")
            return
        }
        if await Self.portOccupiedOffMain(self.port) {
            await self.failStart("Port \(self.port) is already in use by another program")
            return
        }
        self.spawn(binary: binary)
    }

    private func adoptRunningServer() {
        status = .running
        actionError = nil
        startElapsed = 0
        startBeganAt = nil
        reportOutcome(ok: true, "Already running on :\(probePort)")
        refresh()
    }

    private func failStart(_ message: String) {
        status = .stopped
        actionError = message
        startBeganAt = nil
        reportOutcome(ok: false, message)
        refresh()
    }

    private func spawn(binary: String) {
        let baseURL = configuredPort
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["serve", "--port", String(baseURL), "--hostname", "127.0.0.1"]
        // Run from the repo so it finds crates/, docs and its own config.
        process.currentDirectoryURL = URL(fileURLWithPath: Self.repoPath)

        var environment = Self.launchEnvironment()
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" + ":" + (environment["PATH"] ?? "")
        process.environment = environment

        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            managedProcess = process
            AppLog.d("opencode server started pid=\(process.processIdentifier) port=\(baseURL)")
            settleAfterStart(pid: process.processIdentifier)
        } catch {
            status = .stopped
            actionError = "Failed to start: \(error.localizedDescription)"
            startBeganAt = nil
            reportOutcome(ok: false, actionError ?? "Failed to start")
        }
    }

    /// Polls /health until the new server answers, then settles the label.
    /// The old code waited a fixed 1.5s and asked `applyHealth`, which refused
    /// to run while the status was still `.starting` — so the menu sat on
    /// "Starting…" indefinitely whether or not the server came up.
    ///
    /// `pid` is nil when `start.sh` drove the launch: the stack is detached behind
    /// the repo's own pidfile, so there is no child of this app to watch.
    private func settleAfterStart(pid: pid_t?) {
        Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(self.settleTimeout)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: UInt64(self.settleInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                if let pid, kill(pid, 0) != 0 {
                    self.status = .stopped
                    self.actionError = "Server exited immediately after starting — see ~/Library/Logs/EliaTopBar/debug.log"
                    self.startBeganAt = nil
                    self.reportOutcome(ok: false, self.actionError ?? "Server exited immediately")
                    self.refresh(settling: true)
                    return
                }
                let probe = await self.probeHealth()
                if probe.isHealthy {
                    self.status = .running
                    self.version = probe.version
                    self.actionError = nil
                    self.startBeganAt = nil
                    self.reportOutcome(ok: true, "Rust server up on :\(self.probePort)")
                    self.refresh(settling: true)
                    await self.ensureTunnelIfConfigured()
                    return
                }
                if let began = self.startBeganAt { self.startElapsed = Date().timeIntervalSince(began) }
            }
            self.status = .stopped
            self.actionError = "Server did not answer /health within \(Int(self.settleTimeout))s"
            self.startBeganAt = nil
            self.reportOutcome(ok: false, self.actionError ?? "Start timed out")
            self.refresh(settling: true)
        }
    }

    // MARK: - Tunnel

    /// The app keeps its own copy so Cloudflare config lives in Application Support
    /// with the rest of the app state, instead of depending on a token sitting in
    /// some checkout's tree. Seeded once from the wrapper's tunnel state.
    private var localTunnelDir: String {
        NSHomeDirectory() + "/Library/Application Support/EliaTopBar/tunnel"
    }

    private var localTunnelTokenPath: String { localTunnelDir + "/token" }

    private func resolveTunnelTokenPath() -> String? {
        let statePath = subworkerRoot + "/control/config/tunnel.json"
        let wrapperToken = (try? Data(contentsOf: URL(fileURLWithPath: statePath)))
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            .flatMap { $0["tunnel_token"] as? String }
        guard let token = wrapperToken, !token.isEmpty else {
            return FileManager.default.fileExists(atPath: localTunnelTokenPath) ? localTunnelTokenPath : nil
        }
        let existing = try? String(contentsOfFile: localTunnelTokenPath, encoding: .utf8)
        guard existing != token else { return localTunnelTokenPath }
        try? FileManager.default.createDirectory(atPath: localTunnelDir, withIntermediateDirectories: true)
        guard (try? token.write(toFile: localTunnelTokenPath, atomically: true, encoding: .utf8)) != nil else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: localTunnelTokenPath)
        AppLog.important("tunnel: synced own config from \(statePath)")
        return localTunnelTokenPath
    }

    /// Start already brings up the bridge and the engine, but the tunnel is a
    /// separate process the bridge never spawns — `control/tunnelWatch.sh` and the
    /// compose `cloudflared` profile own it, and neither runs under the app. So a
    /// configured tunnel had nothing listening on its public hostname after Start.
    private func ensureTunnelIfConfigured() async {
        guard let tokenPath = resolveTunnelTokenPath() else {
            AppLog.important("tunnel: no tunnel token available, nothing to start")
            return
        }
        if await Self.isCloudflaredRunning() {
            AppLog.important("tunnel: cloudflared already running")
            return
        }
        if await Self.startCloudflaredService() {
            AppLog.important("tunnel: started via systemctl --user \(Self.cloudflaredServiceName)")
            return
        }
        guard let binary = Self.findCloudflared() else {
            AppLog.important("tunnel: token present at \(tokenPath) but cloudflared binary not found")
            return
        }
        AppLog.important("tunnel: spawning \(binary) tunnel run with \(tokenPath)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["tunnel", "run", "--token-file", tokenPath]
        process.currentDirectoryURL = URL(fileURLWithPath: subworkerRoot + "/control")
        let log = Self.openAppendHandle(subworkerRoot + "/control/data/cloudflared.log")
        process.standardOutput = log
        process.standardError = log
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            AppLog.important("tunnel: cloudflared pid=\(process.processIdentifier)")
        } catch {
            AppLog.important("tunnel: failed to spawn cloudflared — \(error.localizedDescription)")
        }
    }

    private static let cloudflaredServiceName = "cloudflared-omp"

    private static func isCloudflaredRunning() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
                process.arguments = ["-f", "cloudflared.*tunnel.*run"]
                process.standardOutput = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private static func startCloudflaredService() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = ["-lc", "systemctl --user start \(cloudflaredServiceName) 2>/dev/null"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private static func findCloudflared() -> String? {
        for candidate in ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared"] where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    func stop() {
        guard !isBusy else {
            reportOutcome(ok: false, "Busy (\(status.label)) — try again in a moment")
            return
        }
        pendingAction = .stop
        didReportOutcome = false

        if bridgeScriptsExist {
            Task { await stopViaBridgeScripts() }
            return
        }

        var pids: [pid_t] = []
        if let managed = managedProcess {
            pids.append(managed.processIdentifier)
        } else {
            pids = otherServers.map(\.pid)
        }

        guard !pids.isEmpty else {
            actionError = "No running server to stop"
            reportOutcome(ok: false, actionError ?? "No running server to stop")
            return
        }

        status = .stopping
        signal(pids, signal: SIGTERM)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            let survivors = pids.filter { kill($0, 0) == 0 }
            if !survivors.isEmpty {
                signal(survivors, signal: SIGKILL)
            }
            self.managedProcess = nil
            self.startBeganAt = nil
            self.reportOutcome(ok: survivors.isEmpty, survivors.isEmpty
                ? "Rust server stopped"
                : "\(survivors.count) process(es) survived SIGTERM and were killed")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                // settling: nothing else will move .stopping to .stopped.
                self?.refresh(settling: true)
            }
        }
    }

    /// Symmetric with `startViaBridgeScripts`. The pgrep path below only ever
    /// matched `opencode … serve`, so it killed the Rust engine and left the Bun
    /// bridge holding :5656 — the menu then read "Stopped" against a live server.
    /// `stop.sh` owns the pidfile and only kills an engine child whose
    /// `OPENCODE_PATHS_ROOT` is inside this repo, so it leaves foreign ones alone.
    private func stopViaBridgeScripts() async {
        status = .stopping
        actionError = nil
        let port = bridgePortFromRepo()
        AppLog.important("stop: running \(bridgeStopScript)")

        let result = await Self.runShellScript(bridgeStopScript, in: subworkerRoot)
        AppLog.important("stop: exit=\(result.exitCode) output=[\(result.output)]")

        // stop.sh relies on the repo pidfile, and start.sh writes the pid of the
        // forked subshell rather than bun's, so the script refuses to kill
        // ("does not match `bun.*server.ts`") and leaves the bridge on :5656 while
        // the engine child is gone. Stop has to end with the port free, so verify
        // it instead of trusting the script's exit code.
        var stragglers: [pid_t] = []
        if let port {
            stragglers = await Self.freeBridgePortOffMain(port)
        }

        managedProcess = nil
        bridgeHealthPort = nil
        startBeganAt = nil

        if result.exitCode == 0, stragglers.isEmpty {
            reportOutcome(ok: true, "Rust server stopped")
        } else if !stragglers.isEmpty {
            let message = ":5656 still held by pid \(stragglers.map(String.init).joined(separator: ", ")) after stop.sh — check the repo pidfile"
            actionError = message
            reportOutcome(ok: false, message)
        } else {
            actionError = Self.reason(for: result, script: "stop.sh")
            reportOutcome(ok: false, actionError ?? "Stop failed")
        }
        refresh(settling: true)
    }

    /// Terminates whatever still listens on the bridge port, so Stop ends with the
    /// port free. Returns the pids it had to kill. Scoped to the port `start.sh`
    /// was told to bind, never to a process name, so a foreign server cannot be
    /// reached by this path — only one this app just started on that port.
    private static func freeBridgePortOffMain(_ port: Int) async -> [pid_t] {
        await withCheckedContinuation { continuation in
            scanQueue.async {
                guard let output = runSync("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]),
                      !output.isEmpty else {
                    continuation.resume(returning: [])
                    return
                }
                let pids = output.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
                for pid in pids where pid != ProcessInfo.processInfo.processIdentifier {
                    kill(pid, SIGTERM)
                }
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline {
                    let alive = pids.filter { $0 != ProcessInfo.processInfo.processIdentifier && kill($0, 0) == 0 }
                    if alive.isEmpty { break }
                    Thread.sleep(forTimeInterval: 0.2)
                }
                for pid in pids where pid != ProcessInfo.processInfo.processIdentifier && kill(pid, 0) == 0 {
                    kill(pid, SIGKILL)
                }
                continuation.resume(returning: pids)
            }
        }
    }

    /// Kill every detected server, ours or not.
    func stopAllDetected() {
        let targets = otherServers
        guard !targets.isEmpty else {
            actionError = "No opencode servers detected"
            return
        }
        status = .stopping
        signal(targets.map(\.pid), signal: SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            signal(targets.map(\.pid), signal: SIGKILL)
            self.managedProcess = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.refresh()
            }
        }
    }

    // MARK: - Clean

    /// Port of the repo's `clean.sh`: refuse to clean while a server we started is
    /// still up, warn about servers that are not ours, then clear build residue
    /// and MCP servers our own sessions spawned.
    func clean(completion: @escaping (Result<String, Error>) -> Void) {
        guard !isCleaning else { return }
        isCleaning = true
        actionError = nil

        Task {
            let report = await Self.performClean(repoPath: Self.repoPath)
            await MainActor.run {
                self.isCleaning = false
                switch report {
                case .success(let summary):
                    self.lastCleanSummary = summary
                    completion(.success(summary))
                case .failure(let error):
                    self.actionError = error.localizedDescription
                    completion(.failure(error))
                }
            }
        }
    }

    private struct CleanReport: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func performClean(repoPath: String) async -> Result<String, Error> {
        // Kill MCP servers our sessions left behind. These are not opencode
        // servers, so they are matched narrowly and never reported as "other".
        var killedMCP = 0
        if let pids = runSync("/usr/bin/pgrep", ["-f", "mcp_server|modelcontextprotocol"]) {
            for line in pids.split(separator: "\n") {
                guard let pid = pid_t(line.trimmingCharacters(in: .whitespaces)) else { continue }
                if kill(pid, SIGTERM) == 0 { killedMCP += 1 }
            }
        }

        let target = "\(repoPath)/target"
        var removedTarget = false
        if FileManager.default.fileExists(atPath: target) {
            do {
                try FileManager.default.removeItem(atPath: target)
                removedTarget = true
            } catch {
                return .failure(CleanReport(message: "Could not remove target/: \(error.localizedDescription)"))
            }
        }

        var parts: [String] = []
        parts.append(removedTarget ? "Removed target/" : "No build artefacts to remove")
        if killedMCP > 0 {
            parts.append("Stopped \(killedMCP) leftover MCP server\(killedMCP == 1 ? "" : "s")")
        }
        parts.append("Your config and sessions were left untouched")
        return .success(parts.joined(separator: " · "))
    }

    // MARK: - Process helpers

    private func signal(_ pids: [pid_t], signal: Int32) {
        for pid in pids {
            guard pid > 1 else { continue }
            kill(pid, signal)
        }
    }

    @discardableResult
    private static func runSync(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    /// True when something already holds the port, healthy or not.
    private static func isPortOccupiedSync(_ port: Int) -> Bool {
        guard let output = runSync("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]),
              output.contains("LISTEN") else { return false }
        return true
    }
}