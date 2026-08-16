import Foundation
import Combine

// MARK: - Debug Logging

enum AppLog {
    static let debug = false

    static func d(_ msg: String, file: String = #file, line: Int = #line) {
        guard debug else { return }
        let fn = (file as NSString).lastPathComponent
        print("[DEBUG \(fn):\(line)] \(msg)")
    }
}

// MARK: - Models

struct SubworkerInfo: Identifiable, Equatable {
    let id: String
    let name: String
    var enabled: Bool
    var running: Bool
    var nextRun: String?
    var scheduleType: String?
    var lastError: String?
    var lastCompleted: Date?
}

struct ServerHealth: Equatable {
    let state: String
    let healthStatus: String
    let pid: Int?
    let restartCount: Int
}

// MARK: - SubworkerManager

@MainActor
final class SubworkerManager: ObservableObject {
    // Published state
    @Published var wsConnected = false
    @Published var wsError: String?
    @Published var subworkers: [SubworkerInfo] = []
    @Published var serverHealth: ServerHealth?
    @Published var lastError: String?
    @Published var runningCount = 0
    @Published var totalEnabled = 0
    @Published var isLoading = true
    @Published var statusError: String?

    var hasError: Bool { wsError != nil || lastError != nil }
    var allIdle: Bool { runningCount == 0 && !hasError }
    var currentBaseURL: String { baseURL }

    // WebSocket
    private var wsTask: URLSessionWebSocketTask?
    private var wsReconnectDelay: TimeInterval = 1.0
    private var pingTimer: Timer?
    private var wsReconnectTimer: Timer?

    // HTTP polling
    private var pollTimer: Timer?
    private var serverHealthTimer: Timer?

    // Session
    private let session = URLSession(configuration: .default)
    private var baseURL = "http://localhost:5656"
    private var wsURL = "ws://localhost:5656/ws"

    // MARK: - Start / Stop

    func start() {
        AppLog.d("Starting SubworkerManager")
        isLoading = true
        statusError = nil
        connectWebSocket()
        startServerHealthPolling()
    }

    func stop() {
        AppLog.d("Stopping SubworkerManager")
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        wsConnected = false
        pingTimer?.invalidate()
        pingTimer = nil
        wsReconnectTimer?.invalidate()
        wsReconnectTimer = nil
        stopHTTPPolling()
        serverHealthTimer?.invalidate()
        serverHealthTimer = nil
        isLoading = true
        statusError = nil
    }

    func updateBaseURL(_ url: String) {
        AppLog.d("Updating base URL: \(url)")
        baseURL = url
        wsURL = url.replacingOccurrences(of: "http://", with: "ws://")
            .replacingOccurrences(of: "https://", with: "wss://")
        if !wsURL.hasSuffix("/ws") {
            wsURL = wsURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/ws"
        }
        stop()
        start()
    }

    // MARK: - WebSocket

    private func connectWebSocket() {
        guard let url = URL(string: wsURL) else {
            AppLog.d("Invalid WS URL: \(wsURL)")
            wsError = "Invalid server URL"
            startHTTPPolling()
            return
        }

        AppLog.d("Connecting WS to \(wsURL)")
        let task = session.webSocketTask(with: url)
        wsTask = task
        task.resume()

        // Check connection after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            if self.wsConnected {
                AppLog.d("WS connected successfully")
                return
            }
            // If still not connected after 1s, treat as failure
            AppLog.d("WS connection timeout")
            self.handleDisconnect()
        }

        receiveMessages()
        startPingTimer()
    }

    private func receiveMessages() {
        wsTask?.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handleWSMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleWSMessage(text)
                        }
                    @unknown default:
                        break
                    }
                    self.receiveMessages()
                case .failure(let error):
                    AppLog.d("WS receive error: \(error.localizedDescription)")
                    self.handleDisconnect()
                }
            }
        }
    }

    private func handleWSMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            AppLog.d("Failed to parse WS message")
            return
        }

        let event = json["event"] as? String ?? ""

        switch event {
        case "initial_status":
            handleInitialStatus(json)
        case "subworker_completed":
            handleSubworkerCompleted(json)
        case "subworker_error":
            handleSubworkerError(json)
        case "pong":
            AppLog.d("Received pong")
            if !wsConnected {
                wsConnected = true
                wsError = nil
                statusError = nil
                wsReconnectDelay = 1.0
                stopHTTPPolling()
            }
        default:
            // Check if this is a connection success without explicit event
            if json["subworkers"] != nil && !wsConnected {
                handleInitialStatus(json)
            }
            AppLog.d("Unknown WS event: \(event)")
        }
    }

    private func handleInitialStatus(_ json: [String: Any]) {
        guard let swArray = json["subworkers"] as? [[String: Any]] else {
            AppLog.d("No subworkers in initial_status")
            return
        }

        AppLog.d("Received initial_status: \(swArray.count) subworkers")

        var parsed: [SubworkerInfo] = []
        for dict in swArray {
            guard let name = dict["name"] as? String else { continue }
            let info = SubworkerInfo(
                id: name,
                name: name,
                enabled: dict["enabled"] as? Bool ?? false,
                running: dict["running"] as? Bool ?? false,
                nextRun: dict["next_run"] as? String,
                scheduleType: dict["schedule_type"] as? String
            )
            parsed.append(info)
        }

        subworkers = parsed
        recalculateCounts()
        isLoading = false
        statusError = nil

        if !wsConnected {
            wsConnected = true
            wsError = nil
            wsReconnectDelay = 1.0
            stopHTTPPolling()
        }
    }

    private func handleSubworkerCompleted(_ json: [String: Any]) {
        guard let name = json["name"] as? String else { return }
        AppLog.d("Subworker completed: \(name)")

        if let idx = subworkers.firstIndex(where: { $0.name == name }) {
            subworkers[idx].running = false
            subworkers[idx].lastError = nil
            subworkers[idx].lastCompleted = Date()
        }
        recalculateCounts()
    }

    private func handleSubworkerError(_ json: [String: Any]) {
        guard let name = json["name"] as? String else { return }
        let errorMsg = json["error"] as? String ?? "Unknown error"
        AppLog.d("Subworker error: \(name) - \(errorMsg)")

        if let idx = subworkers.firstIndex(where: { $0.name == name }) {
            subworkers[idx].running = false
            subworkers[idx].lastError = errorMsg
        }
        lastError = "\(name): \(errorMsg)"
        recalculateCounts()
    }

    private func handleDisconnect() {
        AppLog.d("WS disconnected")
        wsConnected = false
        statusError = "WebSocket disconnected"
        if subworkers.isEmpty {
            isLoading = false
        }
        startHTTPPolling()
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        AppLog.d("Scheduling reconnect in \(wsReconnectDelay)s")
        wsReconnectTimer?.invalidate()
        wsReconnectTimer = Timer.scheduledTimer(withTimeInterval: wsReconnectDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.connectWebSocket()
            }
        }
        wsReconnectDelay = min(wsReconnectDelay * 2, 30.0)
    }

    private func startPingTimer() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let task = self.wsTask else { return }
                let ping = URLSessionWebSocketTask.Message.string("{\"type\":\"ping\"}")
                task.send(ping) { error in
                    if let error {
                        AppLog.d("Ping error: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    // MARK: - HTTP Polling

    private func startHTTPPolling() {
        guard pollTimer == nil else { return }
        AppLog.d("Starting HTTP status polling (5s)")
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.fetchStatus()
            }
        }
        // Immediate first fetch
        Task { await fetchStatus() }
    }

    private func stopHTTPPolling() {
        AppLog.d("Stopping HTTP status polling")
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func startServerHealthPolling() {
        serverHealthTimer?.invalidate()
        serverHealthTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.fetchServerHealth()
            }
        }
        // Immediate first fetch
        Task { await fetchServerHealth() }
    }

    // MARK: - HTTP Requests

    func fetchStatus() async {
        guard let url = URL(string: "\(baseURL)/status") else { return }
        AppLog.d("Fetching /status")

        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                statusError = "Status: HTTP \(http.statusCode)"
                isLoading = false
                return
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let swArray = json["subworkers"] as? [[String: Any]] else {
                statusError = "Invalid /status response"
                isLoading = false
                return
            }

            var parsed: [SubworkerInfo] = []
            for dict in swArray {
                guard let name = dict["name"] as? String else { continue }
                let info = SubworkerInfo(
                    id: name,
                    name: name,
                    enabled: dict["enabled"] as? Bool ?? false,
                    running: dict["running"] as? Bool ?? false,
                    nextRun: dict["next_run"] as? String,
                    scheduleType: dict["schedule_type"] as? String
                )
                parsed.append(info)
            }
            subworkers = parsed
            recalculateCounts()
            isLoading = false
            statusError = nil
            AppLog.d("Status updated: \(parsed.count) subworkers")
        } catch {
            statusError = error.localizedDescription
            isLoading = false
            AppLog.d("Status fetch error: \(error.localizedDescription)")
        }
    }

    func fetchServerHealth() async {
        guard let url = URL(string: "\(baseURL)/server/health") else { return }
        AppLog.d("Fetching /server/health")

        do {
            let (data, _) = try await session.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            serverHealth = ServerHealth(
                state: json["state"] as? String ?? "unknown",
                healthStatus: json["health_status"] as? String ?? "unknown",
                pid: json["pid"] as? Int,
                restartCount: json["restart_count"] as? Int ?? 0
            )
            AppLog.d("Server health: \(json["state"] as? String ?? "?")")
        } catch {
            AppLog.d("Server health fetch error: \(error.localizedDescription)")
        }
    }

    func triggerSubworker(_ name: String) {
        guard let url = URL(string: "\(baseURL)/trigger/\(name)") else { return }
        AppLog.d("Triggering subworker: \(name)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            Task { @MainActor [weak self] in
                if let error {
                    AppLog.d("Trigger error: \(error.localizedDescription)")
                    self?.lastError = "Trigger failed: \(error.localizedDescription)"
                } else if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    AppLog.d("Triggered \(name) successfully")
                    if let idx = self?.subworkers.firstIndex(where: { $0.name == name }) {
                        self?.subworkers[idx].running = true
                        self?.subworkers[idx].lastError = nil
                    }
                    self?.recalculateCounts()
                }
            }
        }.resume()
    }

    func enableSubworker(_ name: String) {
        guard let url = URL(string: "\(baseURL)/enable/\(name)") else { return }
        AppLog.d("Enabling subworker: \(name)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        URLSession.shared.dataTask(with: request) { [weak self] _, _, error in
            Task { @MainActor [weak self] in
                if let error {
                    AppLog.d("Enable error: \(error.localizedDescription)")
                } else if let idx = self?.subworkers.firstIndex(where: { $0.name == name }) {
                    self?.subworkers[idx].enabled = true
                    self?.recalculateCounts()
                }
            }
        }.resume()
    }

    func disableSubworker(_ name: String) {
        guard let url = URL(string: "\(baseURL)/disable/\(name)") else { return }
        AppLog.d("Disabling subworker: \(name)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        URLSession.shared.dataTask(with: request) { [weak self] _, _, error in
            Task { @MainActor [weak self] in
                if let error {
                    AppLog.d("Disable error: \(error.localizedDescription)")
                } else if let idx = self?.subworkers.firstIndex(where: { $0.name == name }) {
                    self?.subworkers[idx].enabled = false
                    self?.recalculateCounts()
                }
            }
        }.resume()
    }

    func fetchLogs(for name: String, lines: Int = 50) async -> [String] {
        guard let url = URL(string: "\(baseURL)/logs/\(name)?lines=\(lines)") else { return [] }
        AppLog.d("Fetching logs for \(name)")

        do {
            let (data, _) = try await session.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let logLines = json["lines"] as? [String] else { return [] }
            AppLog.d("Got \(logLines.count) log lines for \(name)")
            return logLines
        } catch {
            AppLog.d("Log fetch error: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Helpers

    private func recalculateCounts() {
        runningCount = subworkers.filter(\.running).count
        totalEnabled = subworkers.filter(\.enabled).count
        AppLog.d("Counts: \(runningCount) running / \(totalEnabled) enabled")
    }
}
