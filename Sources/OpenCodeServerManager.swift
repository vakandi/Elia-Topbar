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

    /// A health probe must not hang the menu; anything slower is not healthy.
    private let probeTimeout: TimeInterval = 2.0

    var isHealthy: Bool { status == .running }
    var isBusy: Bool { status.isBusy }

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

    func refresh() {
        port = configuredPort
        detectServers()

        Task { [weak self] in
            guard let self else { return }
            let response = await self.probeHealth()
            await self.applyHealth(response)
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

    private func applyHealth(_ probe: HealthProbe) {
        guard !isBusy else { return }
        if binaryPath == nil && probe.isHealthy == false && otherServers.isEmpty {
            status = .missingBinary
            version = nil
            return
        }
        if probe.isHealthy {
            status = .running
            version = probe.version
        } else if otherServers.isEmpty {
            status = .stopped
            version = nil
        } else {
            // Something is serving opencode but did not answer /health.
            status = .unhealthy
            version = nil
        }
    }

    // MARK: - Process detection

    /// Find every `opencode ... serve` process, excluding this app.
    ///
    /// `pgrep -f` matches the full command line, which is what makes a server
    /// started from a shell or another tool visible here — those are exactly the
    /// duplicates the single-instance guard has to catch.
    private func detectServers() {
        otherServers = Self.findServerProcesses(excluding: ProcessInfo.processInfo.processIdentifier)
    }

    static func findServerProcesses(excluding ownPID: pid_t) -> [DetectedServer] {
        guard let output = runSync("/usr/bin/pgrep", ["-f", "opencode.*serve"]),
              !output.isEmpty else { return [] }

        var found: [DetectedServer] = []
        for line in output.split(separator: "\n") {
            guard let pid = pid_t(line.trimmingCharacters(in: .whitespaces)) else { continue }
            if pid == ownPID { continue }
            guard let command = runSync("/bin/ps", ["-p", String(pid), "-o", "command="])?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !command.isEmpty else { continue }
            found.append(DetectedServer(pid: pid, port: portFromCommand(command), command: command))
        }
        return found.sorted { $0.pid < $1.pid }
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

        // Refuse rather than fight: a second server on the same port fails in a
        // way that is far harder to diagnose than an explicit refusal.
        if !otherServers.isEmpty {
            actionError = "\(otherServers.count) opencode server(s) already running — stop them first"
            refresh()
            return
        }
        if isPortOccupied() {
            actionError = "Port \(port) is already in use by another program"
            return
        }

        status = .starting
        actionError = nil

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["serve", "--port", String(port), "--hostname", "127.0.0.1"]
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
            AppLog.d("opencode server started pid=\(process.processIdentifier) port=\(port)")
            // Give it a moment to bind, then let the poller settle the label.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.refresh()
            }
        } catch {
            status = .stopped
            actionError = "Failed to start: \(error.localizedDescription)"
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.refresh()
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
    private func isPortOccupied() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return false }
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.contains("LISTEN")
        } catch {
            return false
        }
    }
}