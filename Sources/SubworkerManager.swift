import Foundation
import Combine

// MARK: - Debug Logging

enum AppLog {
    static let debug = true

    static func d(_ msg: String, file: String = #file, line: Int = #line) {
        guard debug else { return }
        let fn = (file as NSString).lastPathComponent
        FileHandle.standardError.write(Data("[DEBUG \(fn):\(line)] \(msg)\n".utf8))
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
    /// Interval-schedule hours (server sends them in /status `schedule.hours`).
    var scheduleHours: [Int]?
    var scheduleMinute: Int?
    var lastError: String?
    var lastCompleted: Date?
    var model: String?
    var variant: String?
}

struct ServerHealth: Equatable {
    let state: String
    let healthStatus: String
    let pid: Int?
    let restartCount: Int
}

// MARK: - Model Selection

enum SubworkerModels {
    /// Shared with ui_electron — trigger_template.js reads this file to pick `--model`.
    static let selectionsPath = "/Users/vakandi/EliaAI/ui_electron/model-selections.json"
    static let defaultModel = "opencode/big-pickle"

    static func displayName(for id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }
}

struct ModelOption: Identifiable {
    let id: String        // "provider/model-id"
    let name: String
    let provider: String
    let variants: [String] // reasoning effort levels (low/medium/high/max…)
}

enum EliaAuth {
    static let defaultToken = "70c0bb6a44c6cb1f45f07ee25ddb9038c042b82ddb1f7b15d9e5417b1b3bd039"

    static var token: String {
        let stored = UserDefaults.standard.string(forKey: "eliaAuthToken") ?? ""
        return stored.isEmpty ? defaultToken : stored
    }

    static func authorize(_ request: URLRequest) -> URLRequest {
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(token, forHTTPHeaderField: "X-Elia-Token")
        return request
    }

    static func authorize(_ url: URL) -> URLRequest {
        authorize(URLRequest(url: url))
    }
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
    @Published var modelSelections: [String: String] = [:]
    @Published var modelVariants: [String: String] = [:]
    @Published var availableModels: [ModelOption] = []
    @Published var mainAgentName = "elia"

    var hasError: Bool { wsError != nil || lastError != nil }
    var allIdle: Bool { runningCount == 0 && !hasError }
    var currentBaseURL: String { baseURL }

    // WebSocket
    private var wsTask: URLSessionWebSocketTask?
    private var wsReconnectDelay: TimeInterval = 1.0
    private var pingTimer: Timer?
    private var wsReconnectTimer: Timer?
    private var pongWatchdog: Timer?
    private var awaitingPong = false

    // HTTP polling
    private var pollTimer: Timer?
    private var pollInterval: TimeInterval = 5.0
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
        loadModelSelections()
        fetchMainAgent()
        fetchModels()
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
        clearPongState()
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
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "token", value: EliaAuth.token)]
        components.queryItems = queryItems
        let task = session.webSocketTask(with: components.url!)
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
            applyServerHealth(from: json)
        case "status_update":
            handleStatusUpdate(json)
            applyServerHealth(from: json)
        case "subworker_started":
            handleSubworkerStarted(json)
        case "subworker_completed":
            handleSubworkerCompleted(json)
        case "subworker_error":
            handleSubworkerError(json)
        case "run_log":
            if let name = json["name"] as? String,
               let delta = json["text"] as? String {
                NotificationCenter.default.post(
                    name: SubworkerManager.runLogNotification,
                    object: nil,
                    userInfo: ["name": name, "text": delta, "field": json["field"] as? String ?? "text"]
                )
            }
        case "pong":
            AppLog.d("Received pong")
            clearPongState()
            if !wsConnected {
                wsConnected = true
                wsError = nil
                statusError = nil
                wsReconnectDelay = 1.0
                setSlowPolling()
            }
        default:
            // Check if this is a connection success without explicit event
            if json["subworkers"] != nil && !wsConnected {
                handleInitialStatus(json)
            }
            AppLog.d("Unknown WS event: \(event)")
        }
    }

    static let runLogNotification = Notification.Name("SubworkerRunLog")

    /// Single source of truth for server state — WS events carry it so the
    /// icon and the menu can never disagree.
    private func applyServerHealth(from json: [String: Any]) {
        guard let status = json["opencode_health"] as? String else { return }
        let mapped = ServerHealth(
            state: status == "healthy" ? "running" : "stopped",
            healthStatus: status,
            pid: nil,
            restartCount: 0
        )
        if mapped != serverHealth {
            serverHealth = mapped
        }
    }

    /// Full snapshot pushed by the server on every state change — replaces HTTP polling.
    private func handleStatusUpdate(_ json: [String: Any]) {
        guard let swArray = json["subworkers"] as? [[String: Any]] else { return }

        let previous = subworkers
        var parsed: [SubworkerInfo] = []
        for dict in swArray {
            guard let name = dict["name"] as? String else { continue }
            let old = previous.first(where: { $0.name == name })
            let running = dict["running"] as? Bool ?? false
            let info = SubworkerInfo(
                id: name,
                name: name,
                enabled: dict["enabled"] as? Bool ?? false,
                running: running,
                nextRun: dict["next_run"] as? String ?? old?.nextRun,
                scheduleType: dict["schedule_type"] as? String ?? old?.scheduleType,
                scheduleHours: old?.scheduleHours,
                scheduleMinute: old?.scheduleMinute,
                lastError: running ? nil : old?.lastError,
                lastCompleted: running ? nil : old?.lastCompleted,
                model: dict["model"] as? String ?? old?.model,
                variant: dict["variant"] as? String ?? old?.variant
            )
            parsed.append(info)
            if let m = info.model, !m.isEmpty { modelSelections[name] = m }
            if let v = info.variant { modelVariants[name] = v }
        }

        subworkers = parsed
        recalculateCounts()
    }

    private func handleInitialStatus(_ json: [String: Any]) {
        guard let swArray = json["subworkers"] as? [[String: Any]] else {
            AppLog.d("No subworkers in initial_status")
            return
        }

        AppLog.d("Received initial_status: \(swArray.count) subworkers")
        loadModelSelections()

        var parsed: [SubworkerInfo] = []
        for dict in swArray {
            guard let name = dict["name"] as? String else { continue }
            let info = SubworkerInfo(
                id: name,
                name: name,
                enabled: dict["enabled"] as? Bool ?? false,
                running: dict["running"] as? Bool ?? false,
                nextRun: dict["next_run"] as? String,
                scheduleType: dict["schedule_type"] as? String,
                model: dict["model"] as? String,
                variant: dict["variant"] as? String
            )
            parsed.append(info)
        }

        subworkers = parsed
        for sw in parsed {
            if let m = sw.model, !m.isEmpty { modelSelections[sw.name] = m }
            if let v = sw.variant { modelVariants[sw.name] = v }
        }
        recalculateCounts()
        isLoading = false
        statusError = nil
        lastError = nil

        if !wsConnected {
            wsConnected = true
            wsError = nil
            wsReconnectDelay = 1.0
            stopHTTPPolling()
            setSlowPolling()
        }
    }

    private func handleSubworkerStarted(_ json: [String: Any]) {
        guard let name = json["name"] as? String else { return }
        AppLog.d("Subworker started: \(name)")

        if let idx = subworkers.firstIndex(where: { $0.name == name }) {
            subworkers[idx].running = true
            subworkers[idx].lastError = nil
            recalculateCounts()
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
        clearPongState()
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
                if self.awaitingPong {
                    AppLog.d("Previous ping never answered — treating WS as dead")
                    self.handleDisconnect()
                    return
                }
                let ping = URLSessionWebSocketTask.Message.string("{\"type\":\"ping\"}")
                task.send(ping) { [weak self] error in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if let error {
                            AppLog.d("Ping error: \(error.localizedDescription)")
                            self.handleDisconnect()
                        } else {
                            self.awaitingPong = true
                            self.startPongWatchdog()
                        }
                    }
                }
            }
        }
    }

    private func startPongWatchdog() {
        pongWatchdog?.invalidate()
        pongWatchdog = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.awaitingPong else { return }
                AppLog.d("No pong within 10s — reconnecting WS")
                self.handleDisconnect()
            }
        }
    }

    private func clearPongState() {
        awaitingPong = false
        pongWatchdog?.invalidate()
        pongWatchdog = nil
    }

    // MARK: - HTTP Polling

    private func startHTTPPolling() {
        guard pollTimer == nil else { return }
        AppLog.d("Starting HTTP status polling (5s)")
        pollInterval = 5.0
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

    /// Slow safety-net polling while WS is connected — catches missed events.
    private func setSlowPolling() {
        guard pollTimer == nil || pollInterval != 15.0 else { return }
        AppLog.d("HTTP status polling every 15s (WS backup)")
        pollInterval = 15.0
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.fetchStatus()
            }
        }
    }

    private func startServerHealthPolling() {
        serverHealthTimer?.invalidate()
        serverHealthTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.fetchServerHealth()
                // Retry until the catalog lands (first attempt may hit a
                // restarting container).
                if self?.availableModels.isEmpty == true {
                    self?.fetchModels()
                }
                self?.fetchMainAgent()
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
            let (data, response) = try await session.data(for: EliaAuth.authorize(url))
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
                let schedule = dict["schedule"] as? [String: Any]
                let info = SubworkerInfo(
                    id: name,
                    name: name,
                    enabled: dict["enabled"] as? Bool ?? false,
                    running: dict["running"] as? Bool ?? false,
                    nextRun: dict["next_run"] as? String,
                    scheduleType: dict["schedule_type"] as? String,
                    scheduleHours: schedule?["hours"] as? [Int],
                    scheduleMinute: schedule?["minute"] as? Int
                )
                parsed.append(info)
            }
            subworkers = parsed
            loadModelSelections()
            for sw in parsed {
                if let m = sw.model, !m.isEmpty { modelSelections[sw.name] = m }
                if let v = sw.variant { modelVariants[sw.name] = v }
            }
            recalculateCounts()
            isLoading = false
            statusError = nil
            lastError = nil
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
            let (data, _) = try await session.data(for: EliaAuth.authorize(url))
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            serverHealth = ServerHealth(
                state: json["state"] as? String ?? "unknown",
                healthStatus: json["health_status"] as? String ?? "unknown",
                pid: json["pid"] as? Int,
                restartCount: json["restart_count"] as? Int ?? 0
            )
            fetchMainAgent()
            AppLog.d("Server health: \(json["state"] as? String ?? "?")")
        } catch {
            AppLog.d("Server health fetch error: \(error.localizedDescription)")
        }
    }

    func triggerSubworker(_ name: String) {
        guard let url = URL(string: "\(baseURL)/trigger/\(name)") else { return }
        AppLog.d("Triggering subworker: \(name)")
        var request = EliaAuth.authorize(url)
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
        var request = EliaAuth.authorize(url)
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
        var request = EliaAuth.authorize(url)
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
            let (data, _) = try await session.data(for: EliaAuth.authorize(url))
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let logLines = json["lines"] as? [String] else { return [] }
            AppLog.d("Got \(logLines.count) log lines for \(name)")
            return logLines
        } catch {
            AppLog.d("Log fetch error: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Model Selection

    func loadModelSelections() {
        guard let data = FileManager.default.contents(atPath: SubworkerModels.selectionsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            modelSelections = [:]
            return
        }
        modelSelections = json
    }

    func fetchModels() {
        guard let url = URL(string: "\(baseURL)/models") else { return }
        URLSession.shared.dataTask(with: EliaAuth.authorize(url)) { [weak self] data, _, _ in
            Task { @MainActor [weak self] in
                guard let self, let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let raw = json["models"] as? [[String: Any]] else { return }
                let options: [ModelOption] = raw.compactMap { m in
                    guard let id = m["id"] as? String else { return nil }
                    return ModelOption(
                        id: id,
                        name: m["name"] as? String ?? id,
                        provider: m["provider"] as? String ?? "",
                        variants: m["variants"] as? [String] ?? []
                    )
                }
                self.availableModels = options
                AppLog.d("Loaded \(options.count) models")
            }
        }.resume()
    }

    func currentModel(for name: String) -> String {
        if let m = modelSelections[name], !m.isEmpty { return m }
        return subworkers.first(where: { $0.name == name })?.model ?? SubworkerModels.defaultModel
    }

    func currentVariant(for name: String) -> String {
        if let v = modelVariants[name], !v.isEmpty { return v }
        return subworkers.first(where: { $0.name == name })?.variant ?? ""
    }

    func setModel(_ modelID: String, variant: String, for name: String) {
        var updated = modelSelections
        updated[name] = modelID
        modelSelections = updated

        var updatedVariants = modelVariants
        updatedVariants[name] = variant
        modelVariants = updatedVariants

        if let idx = subworkers.firstIndex(where: { $0.name == name }) {
            subworkers[idx].model = modelID
            subworkers[idx].variant = variant.isEmpty ? nil : variant
        }

        guard let data = try? JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys]) else {
            lastError = "Model selection: invalid payload"
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: SubworkerModels.selectionsPath), options: .atomic)
            AppLog.d("Model for \(name) set to \(modelID) (\(variant))")
        } catch {
            AppLog.d("Model save error: \(error.localizedDescription)")
            lastError = "Model save failed: \(error.localizedDescription)"
        }
        pushModelToServer(modelID, variant: variant, for: name)
    }

    private func pushModelToServer(_ modelID: String, variant: String, for name: String) {
        guard let url = URL(string: "\(baseURL)/status/\(name)") else { return }
        var request = EliaAuth.authorize(url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["model": modelID]
        if !variant.isEmpty { payload["variant"] = variant }
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            Task { @MainActor [weak self] in
                if let error {
                    self?.lastError = "Model sync failed: \(error.localizedDescription)"
                } else if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                    self?.lastError = "Model sync failed: HTTP \(http.statusCode)"
                } else {
                    self?.lastError = nil
                }
            }
        }.resume()
    }

    // MARK: - Main Agent

    func fetchMainAgent() {
        guard let url = URL(string: "\(baseURL)/main-agent") else { return }
        URLSession.shared.dataTask(with: EliaAuth.authorize(url)) { [weak self] data, _, _ in
            Task { @MainActor [weak self] in
                guard let self, let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let name = json["name"] as? String, !name.isEmpty else { return }
                if name != self.mainAgentName {
                    self.mainAgentName = name
                }
            }
        }.resume()
    }

    func setMainAgent(_ name: String) {
        guard let url = URL(string: "\(baseURL)/main-agent") else { return }
        var request = EliaAuth.authorize(url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name])

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            Task { @MainActor [weak self] in
                if let error {
                    self?.lastError = "Main agent set failed: \(error.localizedDescription)"
                } else if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                    self?.lastError = "Main agent set failed: HTTP \(http.statusCode)"
                } else {
                    self?.mainAgentName = name
                }
            }
        }.resume()
    }

    // MARK: - Next Run Helpers

    private static let isoParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parseNextRun(_ string: String?) -> Date? {
        guard let string else { return nil }
        return isoParser.date(from: string)
    }

    /// Server-provided next run, or computed from the interval schedule
    /// (next slot among `scheduleHours` at `scheduleMinute`, rolling to tomorrow).
    func nextRunDate(for sw: SubworkerInfo, now: Date = Date()) -> Date? {
        // Server snapshots can lag behind a fired/running job — only trust future dates.
        if let date = Self.parseNextRun(sw.nextRun), date > now { return date }
        guard sw.enabled,
              sw.scheduleType == "interval",
              let hours = sw.scheduleHours, !hours.isEmpty else { return nil }
        let minute = sw.scheduleMinute ?? 0
        let calendar = Calendar.current
        for hour in hours.sorted() {
            if let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now),
               candidate > now {
                return candidate
            }
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        return calendar.date(bySettingHour: hours.min()!, minute: minute, second: 0, of: tomorrow)
    }

    /// Minutes under 2h ("45m"), hours beyond ("3h"), "due" when overdue.
    static func countdownLabel(until date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return "due" }
        if seconds < 60 { return "<1m" }
        let minutes = seconds / 60
        if minutes < 120 { return "\(minutes)m" }
        return "\(minutes / 60)h"
    }

    // MARK: - Helpers

    private func recalculateCounts() {
        runningCount = subworkers.filter(\.running).count
        totalEnabled = subworkers.filter(\.enabled).count
        AppLog.d("Counts: \(runningCount) running / \(totalEnabled) enabled")
    }
}
