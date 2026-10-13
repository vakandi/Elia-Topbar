import AppKit
import Combine
import EliaTopBarKit

/// Starts and stops the **subworker server** by driving its own `start.sh` /
/// `stop.sh`, and reads the repo for the port and auth token it needs.
///
/// The app used to only *connect* to this server. It had no way to start it,
/// and its port and token were hardcoded, so the two drifted apart silently:
/// changing the port in `control/config/server.json` or rotating the token in
/// `.env` left the menu talking to nothing.
///
/// `start.sh` detaches its own control plane with nohup and writes a pidfile,
/// so this never spawns the server itself — it calls the repo's own script and
/// then health-gates the result, exactly as a human running `./start.sh` would.
@MainActor
final class SubworkerServerManager: ObservableObject {

    enum Status: Equatable {
        case missingRepo
        case stopped
        case starting
        case stopping
        case running
        case unhealthy

        var label: String {
            switch self {
            case .missingRepo: return "Repo not found"
            case .stopped:     return "Stopped"
            case .starting:    return "Starting"
            case .stopping:    return "Stopping"
            case .running:     return "Running"
            case .unhealthy:   return "Not responding"
            }
        }

        var isBusy: Bool { self == .starting || self == .stopping }
    }

    static let shared = SubworkerServerManager()

    @Published private(set) var status: Status = .stopped
    @Published private(set) var port: Int = 0
    @Published private(set) var actionError: String?
    /// Elapsed seconds of the current start/stop, so the menu can show progress
    /// instead of looking frozen.
    @Published private(set) var elapsed: TimeInterval = 0

    private static let repoPathKey = "subworkerServerRepoPath"
    private static let settleTimeout: TimeInterval = 90
    private static let settleInterval: TimeInterval = 1.0

    /// Scripts shell out and wait; they must never run on the main actor.
    private static let scriptQueue = DispatchQueue(label: "com.elia.topbar.subsrv", qos: .userInitiated)

    private var timer: Timer?
    private var startedAt: Date?

    private init() {
        applyRepoSettings()
        refresh()
        let t = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshIfIdle() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit { timer?.invalidate() }

    // MARK: - Repo location

    /// Overridable so a fork or a second clone needs no code change.
    var repoPath: String {
        get { UserDefaults.standard.string(forKey: Self.repoPathKey) ?? Self.defaultRepoPath }
        set { UserDefaults.standard.set(newValue, forKey: Self.repoPathKey); applyRepoSettings(); refresh() }
    }

    static var defaultRepoPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/subworker-opencode-rust").path
    }

    var startScript: String { repoPath + "/start.sh" }
    var stopScript: String { repoPath + "/stop.sh" }
    var serverConfigPath: String { repoPath + "/control/config/server.json" }
    var dotEnvPath: String { repoPath + "/.env" }

    var repoExists: Bool { FileManager.default.fileExists(atPath: repoPath) }
    var scriptsExist: Bool {
        FileManager.default.isExecutableFile(atPath: startScript)
            && FileManager.default.isExecutableFile(atPath: stopScript)
    }

    // MARK: - Reading the repo

    /// Port comes from `control/config/server.json` — the same file `start.sh`
    /// reads, so the app can never probe a different port than the server binds.
    func portFromRepo() -> Int? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: serverConfigPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let p = json["port"] as? Int, p > 0 else { return nil }
        return p
    }

    /// `ELIA_AUTH_TOKEN` from the repo's `.env`. The app had a hardcoded copy;
    /// rotating the token in the repo left every request 401ing.
    func tokenFromRepo() -> String? {
        guard let text = try? String(contentsOfFile: dotEnvPath, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("ELIA_AUTH_TOKEN=") else { continue }
            var value = String(trimmed.dropFirst("ELIA_AUTH_TOKEN=".count))
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Adopts the repo's port and token. Called before anything talks to it.
    @discardableResult
    func applyRepoSettings() -> Bool {
        var changed = false
        if let p = portFromRepo(), p != port { port = p; changed = true }
        if let t = tokenFromRepo(), t != EliaAuth.token, !t.isEmpty {
            UserDefaults.standard.set(t, forKey: "eliaAuthToken")
            changed = true
        }
        return changed
    }

    var baseURL: String { port > 0 ? "http://127.0.0.1:\(port)" : "http://127.0.0.1:5656" }

    // MARK: - Health

    private func probeHealth() async -> Bool {
        guard let url = URL(string: "\(baseURL)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let result = try? await URLSession.shared.data(for: request)
        return (result?.1 as? HTTPURLResponse)?.statusCode == 200
    }

    func refreshIfIdle() {
        guard !status.isBusy else { return }
        refresh()
    }

    func refresh() {
        guard repoExists else { status = .missingRepo; return }
        applyRepoSettings()
        Task { [weak self] in
            guard let self else { return }
            let healthy = await self.probeHealth()
            guard !self.status.isBusy else { return }
            self.status = healthy ? .running : .stopped
        }
    }

    // MARK: - Start / stop

    func start() {
        guard !status.isBusy else { return }
        guard repoExists else {
            actionError = "Repo not found at \(repoPath). Set the path in Topbar Settings."
            status = .missingRepo
            return
        }
        guard scriptsExist else {
            actionError = "start.sh / stop.sh not found or not executable in \(repoPath)"
            return
        }
        applyRepoSettings()
        status = .starting
        actionError = nil
        startedAt = Date()
        elapsed = 0

        Task { [weak self] in
            guard let self else { return }
            let result = await Self.runScript(self.startScript, in: self.repoPath)
            await self.settleAfter(result: result)
        }
    }

    func stop() {
        guard !status.isBusy else { return }
        guard scriptsExist else {
            actionError = "stop.sh not found or not executable in \(repoPath)"
            return
        }
        status = .stopping
        actionError = nil
        startedAt = Date()

        Task { [weak self] in
            guard let self else { return }
            let result = await Self.runScript(self.stopScript, in: self.repoPath)
            self.status = .stopped
            self.startedAt = nil
            if result.exitCode != 0 {
                self.actionError = result.lastLines.isEmpty
                    ? "stop.sh exited \(result.exitCode)"
                    : result.lastLines
            }
            self.refresh()
        }
    }

    struct ScriptResult { let exitCode: Int32; let lastLines: String }

    /// Runs the repo's script off the main actor and captures its tail, which is
    /// where start.sh puts the reason it could not come up.
    private static func runScript(_ path: String, in dir: String) async -> ScriptResult {
        await withCheckedContinuation { continuation in
            scriptQueue.async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = [path]
                process.currentDirectoryURL = URL(fileURLWithPath: dir)
                var env = ProcessInfo.processInfo.environment
                for key in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy", "ALL_PROXY", "all_proxy"] {
                    env.removeValue(forKey: key)
                }
                process.environment = env
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let text = String(data: data, encoding: .utf8) ?? ""
                    let tail = text.split(separator: "\n").suffix(4)
                        .map { $0.hasPrefix("[start]") || $0.hasPrefix("[stop]") ? String($0) : "" }
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n")
                    continuation.resume(returning: ScriptResult(exitCode: process.terminationStatus, lastLines: tail))
                } catch {
                    continuation.resume(returning: ScriptResult(exitCode: -1,
                                                                  lastLines: error.localizedDescription))
                }
            }
        }
    }

    /// `start.sh` already health-gates internally, so by the time it returns the
    /// server is either up or it explained why it is not. This loop covers the
    /// case where the script exited 0 but the port is still binding.
    private func settleAfter(result: ScriptResult) async {
        let deadline = Date().addingTimeInterval(Self.settleTimeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(Self.settleInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if await probeHealth() {
                status = .running
                startedAt = nil
                actionError = nil
                AppLog.d("subworker server up on :\(port)")
                refresh()
                return
            }
            if let began = startedAt { elapsed = Date().timeIntervalSince(began) }
            // The script has returned and the server is not there: nothing left
            // to wait for, so stop showing "Starting…".
            if result.exitCode != 0 { break }
        }
        status = .stopped
        startedAt = nil
        actionError = result.lastLines.isEmpty
            ? "start.sh finished but :\(port) never answered"
            : result.lastLines
        refresh()
    }
}