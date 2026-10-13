import Foundation

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

    static let defaultPort = 3000
    private static let portDefaultsKey = "opencodeServerPort"
    private static let repoPathDefaultsKey = "opencodeServerRepoPath"

    /// Where the Rust checkout lives. Overridable so a fork or a second clone
    /// does not have to be patched into the app.
    static var repoPath: String {
        get {
            if let stored = UserDefaults.standard.string(forKey: repoPathDefaultsKey),
               !stored.trimmingCharacters(in: .whitespaces).isEmpty {
                return stored
            }
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/opencode-rust").path
        }
        set { UserDefaults.standard.set(newValue, forKey: repoPathDefaultsKey) }
    }

    var configuredPort: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: Self.portDefaultsKey)
            return stored > 0 ? stored : Self.defaultPort
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.portDefaultsKey) }
    }

    /// Resolved binary, or nil when the repo has not been built.
    var binaryPath: String? {
        let path = "\(Self.repoPath)/target/release/opencode"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    private var statusTimer: Timer?
    private var managedProcess: Process?

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

    private func probeHealth() async -> HealthProbe {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else {
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

    /// Pull `--port 3000` out of a command line, if present.
    static func portFromCommand(_ command: String) -> Int? {
        let tokens = command.split(separator: " ").map(String.init)
        for (index, token) in tokens.enumerated() where token == "--port" || token == "-p" {
            if index + 1 < tokens.count, let value = Int(tokens[index + 1]) { return value }
        }
        return nil
    }

    // MARK: - Start / stop

    func start() {
        guard !isBusy else { return }

        guard let binary = binaryPath else {
            actionError = "opencode binary not built. Run ./install.sh in \(Self.repoPath)"
            return
        }

        status = .starting
        actionError = nil
        startElapsed = 0
        startBeganAt = Date()

        Task { [weak self] in
            guard let self else { return }
            // Refuse rather than fight: a second server on the same port fails in a
            // way that is far harder to diagnose than an explicit refusal.
            let existing = await Self.detectServersOffMain()
            if !existing.isEmpty {
                let pids = existing.map { String($0.pid) }.joined(separator: ", ")
                let plural = existing.count == 1 ? "" : "s"
                await self.failStart("\(existing.count) opencode server\(plural) already running (pid \(pids)) — stop them first")
                return
            }
            if await Self.portOccupiedOffMain(self.port) {
                await self.failStart("Port \(self.port) is already in use by another program")
                return
            }
            await self.spawn(binary: binary)
        }
    }

    private func failStart(_ message: String) {
        status = .stopped
        actionError = message
        startBeganAt = nil
        refresh()
    }

    private func spawn(binary: String) {
        let baseURL = configuredPort
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["serve", "--port", String(baseURL), "--hostname", "127.0.0.1"]
        // Run from the repo so it finds crates/, docs and its own config.
        process.currentDirectoryURL = URL(fileURLWithPath: Self.repoPath)

        var environment = ProcessInfo.processInfo.environment
        // A proxy in the environment would break the server's own localhost
        // calls the same way it broke a git push.
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy", "ALL_PROXY", "all_proxy"] {
            environment.removeValue(forKey: key)
        }
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
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
        }
    }

    /// Polls /health until the new server answers, then settles the label.
    /// The old code waited a fixed 1.5s and asked `applyHealth`, which refused
    /// to run while the status was still `.starting` — so the menu sat on
    /// "Starting…" indefinitely whether or not the server came up.
    private func settleAfterStart(pid: pid_t) {
        Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(self.settleTimeout)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: UInt64(self.settleInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                if kill(pid, 0) != 0 {
                    self.status = .stopped
                    self.actionError = "Server exited immediately after starting — see ~/Library/Logs/EliaTopBar/debug.log"
                    self.startBeganAt = nil
                    self.refresh(settling: true)
                    return
                }
                let probe = await self.probeHealth()
                if probe.isHealthy {
                    self.status = .running
                    self.version = probe.version
                    self.actionError = nil
                    self.startBeganAt = nil
                    self.refresh(settling: true)
                    return
                }
                if let began = self.startBeganAt { self.startElapsed = Date().timeIntervalSince(began) }
            }
            self.status = .stopped
            self.actionError = "Server did not answer /health within \(Int(self.settleTimeout))s"
            self.startBeganAt = nil
            self.refresh(settling: true)
        }
    }

    func stop() {
        guard !isBusy else { return }

        var pids: [pid_t] = []
        if let managed = managedProcess {
            pids.append(managed.processIdentifier)
        } else {
            pids = otherServers.map(\.pid)
        }

        guard !pids.isEmpty else {
            actionError = "No running server to stop"
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                // settling: nothing else will move .stopping to .stopped.
                self?.refresh(settling: true)
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