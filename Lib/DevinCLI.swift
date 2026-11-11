import Foundation

// DevinPaths — where the Devin CLI keeps its state. XDG_DATA_HOME wins,
// ~/.local/share is the fallback; nothing is ever hardcoded to a user.
public enum DevinPaths {
    public static var dataHome: URL {
        if let raw = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !raw.isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share", isDirectory: true)
    }

    public static var stateFile: URL {
        dataHome.appendingPathComponent("devin/reset_state.json")
    }

    /// UserDefaults overrides set by the popup's Locate… button. Empty means
    /// auto-detect through the usual prefixes.
    public static func overridePath(for name: String) -> String? {
        let key: String
        switch name {
        case "devin": key = "devin.binaryPath"
        case "devin-reset": key = "devin.helperPath"
        default: return nil
        }
        let value = UserDefaults.standard.string(forKey: key) ?? ""
        return value.isEmpty ? nil : value
    }

    /// `devin` and `devin-reset` live in ~/.local/bin on this machine; the
    /// other two entries are the usual Homebrew prefixes. PATH alone is not
    /// trusted because a launchd-started app inherits a minimal environment.
    public static func locate(_ name: String) -> URL? {
        if let override = overridePath(for: name),
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        let dirs = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            NSHomeDirectory() + "/.local/bin",
        ]
        for dir in dirs {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        // Last resort: ask the login shell, which is where a manual install lands.
        let result = try? DevinProcess.runSync(
            URL(fileURLWithPath: "/bin/zsh"),
            ["-lc", "command -v \(name)"],
            timeout: 5
        )
        let path = result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }
}

public struct DevinProcessResult {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

// DevinProcess — runs a child with BOTH pipes drained concurrently. A naive
// waitUntilExit()-then-read hangs forever once output passes the 64 KB pipe
// buffer, and `devin models list --format json` returns ~472 KB today.
public enum DevinProcess {
    public static func run(_ executable: URL, _ args: [String],
                    timeout: TimeInterval) async throws -> DevinProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = args
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = [
                    "/opt/homebrew/bin", "/usr/local/bin",
                    NSHomeDirectory() + "/.local/bin",
                    env["PATH"] ?? "/usr/bin:/bin",
                ].joined(separator: ":")
                process.environment = env

                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err

                do { try process.run() } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let group = DispatchGroup()
                var outData = Data(), errData = Data()
                group.enter()
                DispatchQueue.global().async {
                    outData = out.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                let killer = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

                process.waitUntilExit()
                killer.cancel()
                group.wait()

                continuation.resume(returning: DevinProcessResult(
                    status: process.terminationStatus,
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? ""
                ))
            }
        }
    }

    /// Synchronous variant for path probing at launch. Never call on the main thread.
    public static func runSync(_ executable: URL, _ args: [String],
                        timeout: TimeInterval) throws -> DevinProcessResult {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<DevinProcessResult, Error>!
        Task.detached {
            do { result = .success(try await run(executable, args, timeout: timeout)) }
            catch { result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }
}

public enum DevinError: LocalizedError {
    case binaryMissing
    case helperMissing
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .binaryMissing: return "devin not found. Install it, or use Locate…"
        case .helperMissing: return "devin-reset not found. Account switching is disabled."
        case .message(let text): return text
        }
    }
}
