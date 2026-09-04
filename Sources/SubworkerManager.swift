import Foundation
import Combine
import Network

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
    /// Weekday filter 0=Sun..6=Sat; nil = every day.
    var scheduleDays: [Int]?
    var scheduleExpression: String?
    var scheduleEvery: Int?
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
    /// Fleet icon ordering mode (see sortedRunningNames).
    @Published var fleetOrderMode: String = UserDefaults.standard.string(forKey: "fleetOrderMode") ?? "default"
    /// Last streaming activity per agent — drives "latest_msg" ordering.
    @Published var lastActivity: [String: Date] = [:]
    /// Completed-run counters this app session — drives "runs" ordering.
    @Published var runCounts: [String: Int] = [:]
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

    // Network path monitor — fires within ~1s of a Wi-Fi roam.
    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "com.elia.topbar.pathMonitor")

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
        startPathMonitor()
        connectWebSocket()
        startServerHealthPolling()
    }

    func stop() {
        AppLog.d("Stopping SubworkerManager")
        stopPathMonitor()
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

    func forceReconnect() {
        AppLog.d("forceReconnect — tearing down WS + timers, fresh connect")
        wsReconnectDelay = 1.0
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        wsConnected = false
        pingTimer?.invalidate()
        pingTimer = nil
        clearPongState()
        wsReconnectTimer?.invalidate()
        wsReconnectTimer = nil
        connectWebSocket()
        Task { await fetchStatus() }
        Task { await fetchServerHealth() }
    }

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                NotificationCenter.default.post(name: Self.networkPathChangedNotification, object: nil)
                if path.status == .satisfied {
                    if !self.wsConnected {
                        AppLog.d("Network path satisfied — reconnecting WS")
                        self.forceReconnect()
                    }
                } else {
                    AppLog.d("Network path unsatisfied")
                }
            }
        }
        m.start(queue: pathMonitorQueue)
        pathMonitor = m
    }

    private func stopPathMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    private func scheduleTimer(interval: TimeInterval, repeats: Bool, block: @escaping (Timer) -> Void) -> Timer {
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: repeats, block: block)
        RunLoop.main.add(t, forMode: .common)
        return t
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

        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil

        AppLog.d("Connecting WS to \(wsURL)")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "token", value: EliaAuth.token)]
        components.queryItems = queryItems
        let task = session.webSocketTask(with: components.url!)
        wsTask = task
        task.resume()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            if self.wsConnected {
                AppLog.d("WS connected successfully")
                return
            }
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
                lastActivity[name] = Date()
                NotificationCenter.default.post(
                    name: SubworkerManager.runLogNotification,
                    object: nil,
                    userInfo: ["name": name, "text": delta, "field": json["field"] as? String ?? "text"]
                )
            }
        case "run_banner":
            if let name = json["name"] as? String,
               let banner = json["banner"] as? [String: Any] {
                lastActivity[name] = Date()
                NotificationCenter.default.post(
                    name: SubworkerManager.runBannerNotification,
                    object: nil,
                    userInfo: ["name": name, "banner": banner]
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
    static let runBannerNotification = Notification.Name("SubworkerRunBanner")
    static let subworkerStartedNotification = Notification.Name("SubworkerStarted")
    static let subworkerCompletedNotification = Notification.Name("SubworkerCompleted")
    static let subworkerToggleNotification = Notification.Name("SubworkerToggleCompleted")
    static let networkPathChangedNotification = Notification.Name("EliaNetworkPathChanged")

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
            let sched = dict["schedule"] as? [String: Any]
            let sType = dict["schedule_type"] as? String ?? sched?["type"] as? String ?? old?.scheduleType
            let info = SubworkerInfo(
                id: name,
                name: name,
                enabled: dict["enabled"] as? Bool ?? false,
                running: running,
                nextRun: dict["next_run"] as? String ?? old?.nextRun,
                scheduleType: sType,
                scheduleHours: sched?["hours"] as? [Int] ?? old?.scheduleHours,
                scheduleMinute: sched?["minute"] as? Int ?? old?.scheduleMinute,
                scheduleDays: sched?["days"] as? [Int] ?? old?.scheduleDays,
                scheduleExpression: sched?["expression"] as? String ?? old?.scheduleExpression,
                scheduleEvery: sched?["every"] as? Int ?? old?.scheduleEvery,
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
            let schedule = dict["schedule"] as? [String: Any]
            let sType = dict["schedule_type"] as? String ?? schedule?["type"] as? String
            let info = SubworkerInfo(
                id: name,
                name: name,
                enabled: dict["enabled"] as? Bool ?? false,
                running: dict["running"] as? Bool ?? false,
                nextRun: dict["next_run"] as? String,
                scheduleType: sType,
                scheduleHours: schedule?["hours"] as? [Int],
                scheduleMinute: schedule?["minute"] as? Int,
                scheduleDays: schedule?["days"] as? [Int],
                scheduleExpression: schedule?["expression"] as? String,
                scheduleEvery: schedule?["every"] as? Int,
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
        NotificationCenter.default.post(name: Self.subworkerStartedNotification, object: nil, userInfo: ["name": name])
    }

    private func handleSubworkerCompleted(_ json: [String: Any]) {
        guard let name = json["name"] as? String else { return }
        AppLog.d("Subworker completed: \(name)")

        runCounts[name, default: 0] += 1
        if let idx = subworkers.firstIndex(where: { $0.name == name }) {
            subworkers[idx].running = false
            subworkers[idx].lastError = nil
            subworkers[idx].lastCompleted = Date()
        }
        recalculateCounts()
        NotificationCenter.default.post(name: Self.subworkerCompletedNotification, object: nil, userInfo: ["name": name])
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
        NotificationCenter.default.post(name: Self.subworkerCompletedNotification, object: nil, userInfo: ["name": name, "error": errorMsg])
    }

    private func handleDisconnect() {
        AppLog.d("WS disconnected")
        clearPongState()
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
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
        wsReconnectTimer = scheduleTimer(interval: wsReconnectDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.connectWebSocket()
            }
        }
        wsReconnectDelay = min(wsReconnectDelay * 2, 30.0)
    }

    private func startPingTimer() {
        pingTimer?.invalidate()
        pingTimer = scheduleTimer(interval: 30.0, repeats: true) { [weak self] _ in
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
        pongWatchdog = scheduleTimer(interval: 10.0, repeats: false) { [weak self] _ in
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
        pollTimer = scheduleTimer(interval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.fetchStatus()
            }
        }
        Task { await fetchStatus() }
    }

    private func stopHTTPPolling() {
        AppLog.d("Stopping HTTP status polling")
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func setSlowPolling() {
        guard pollTimer == nil || pollInterval != 15.0 else { return }
        AppLog.d("HTTP status polling every 15s (WS backup)")
        pollInterval = 15.0
        pollTimer?.invalidate()
        pollTimer = scheduleTimer(interval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.fetchStatus()
            }
        }
    }

    private func startServerHealthPolling() {
        serverHealthTimer?.invalidate()
        serverHealthTimer = scheduleTimer(interval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.fetchServerHealth()
                if self?.availableModels.isEmpty == true {
                    self?.fetchModels()
                }
                self?.fetchMainAgent()
            }
        }
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
                let sType = dict["schedule_type"] as? String ?? schedule?["type"] as? String
                let info = SubworkerInfo(
                    id: name,
                    name: name,
                    enabled: dict["enabled"] as? Bool ?? false,
                    running: dict["running"] as? Bool ?? false,
                    nextRun: dict["next_run"] as? String,
                    scheduleType: sType,
                    scheduleHours: schedule?["hours"] as? [Int],
                    scheduleMinute: schedule?["minute"] as? Int,
                    scheduleDays: schedule?["days"] as? [Int],
                    scheduleExpression: schedule?["expression"] as? String,
                    scheduleEvery: schedule?["every"] as? Int
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
        // Optimistic: flip immediately so UI moves agent to Active list without waiting for round-trip.
        if let idx = subworkers.firstIndex(where: { $0.name == name }) {
            subworkers[idx].enabled = true
            recalculateCounts()
        }
        var request = EliaAuth.authorize(url)
        request.httpMethod = "POST"

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    AppLog.d("Enable error: \(error.localizedDescription)")
                    self.lastError = "Enable failed: \(error.localizedDescription)"
                    if let idx = self.subworkers.firstIndex(where: { $0.name == name }) {
                        self.subworkers[idx].enabled = false
                        self.recalculateCounts()
                    }
                    NotificationCenter.default.post(name: Self.subworkerToggleNotification, object: nil)
                    return
                }
                if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                    AppLog.d("Enable HTTP \(http.statusCode)")
                    self.lastError = "Enable failed: HTTP \(http.statusCode)"
                    if let idx = self.subworkers.firstIndex(where: { $0.name == name }) {
                        self.subworkers[idx].enabled = false
                        self.recalculateCounts()
                    }
                    NotificationCenter.default.post(name: Self.subworkerToggleNotification, object: nil)
                    return
                }
                if let idx = self.subworkers.firstIndex(where: { $0.name == name }) {
                    self.subworkers[idx].enabled = true
                    self.recalculateCounts()
                }
                self.lastError = nil
                NotificationCenter.default.post(name: Self.subworkerToggleNotification, object: nil)
                Task { await self.fetchStatus() }
            }
        }.resume()
    }

    func disableSubworker(_ name: String) {
        guard let url = URL(string: "\(baseURL)/disable/\(name)") else { return }
        AppLog.d("Disabling subworker: \(name)")
        // Optimistic: flip immediately so UI moves agent to Inactive list without waiting.
        if let idx = subworkers.firstIndex(where: { $0.name == name }) {
            subworkers[idx].enabled = false
            recalculateCounts()
        }
        var request = EliaAuth.authorize(url)
        request.httpMethod = "POST"

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    AppLog.d("Disable error: \(error.localizedDescription)")
                    self.lastError = "Disable failed: \(error.localizedDescription)"
                    if let idx = self.subworkers.firstIndex(where: { $0.name == name }) {
                        self.subworkers[idx].enabled = true
                        self.recalculateCounts()
                    }
                    NotificationCenter.default.post(name: Self.subworkerToggleNotification, object: nil)
                    return
                }
                if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                    AppLog.d("Disable HTTP \(http.statusCode)")
                    self.lastError = "Disable failed: HTTP \(http.statusCode)"
                    if let idx = self.subworkers.firstIndex(where: { $0.name == name }) {
                        self.subworkers[idx].enabled = true
                        self.recalculateCounts()
                    }
                    NotificationCenter.default.post(name: Self.subworkerToggleNotification, object: nil)
                    return
                }
                if let idx = self.subworkers.firstIndex(where: { $0.name == name }) {
                    self.subworkers[idx].enabled = false
                    self.recalculateCounts()
                }
                NotificationCenter.default.post(name: Self.subworkerToggleNotification, object: nil)
                self.lastError = nil
                Task { await self.fetchStatus() }
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
                let favoriteProvider = "opencode"
                let favorites = options.filter { $0.provider == favoriteProvider }
                let rest = options.filter { $0.provider != favoriteProvider }
                self.availableModels = favorites + rest
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

    func nextRunDate(for sw: SubworkerInfo, now: Date = Date()) -> Date? {
        if let date = Self.parseNextRun(sw.nextRun), date > now { return date }
        guard sw.enabled else { return nil }
        let calendar = Calendar.current
        if sw.scheduleType == "interval", let hours = sw.scheduleHours, !hours.isEmpty {
            let minute = sw.scheduleMinute ?? 0
            for hour in hours.sorted() {
                if let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now), candidate > now {
                    if let days = sw.scheduleDays, !days.isEmpty {
                        let w = calendar.component(.weekday, from: candidate) - 1
                        if !days.contains(w) { continue }
                    }
                    return candidate
                }
            }
            var dayOffset = 1
            while dayOffset < 8 {
                guard let day = calendar.date(byAdding: .day, value: dayOffset, to: now) else { break }
                if let days = sw.scheduleDays, !days.isEmpty {
                    let w = calendar.component(.weekday, from: day) - 1
                    if !days.contains(w) { dayOffset += 1; continue }
                }
                if let h = hours.sorted().first, let cand = calendar.date(bySettingHour: h, minute: minute, second: 0, of: day) { return cand }
                dayOffset += 1
            }
            return nil
        }
        if sw.scheduleType == "every", let every = sw.scheduleEvery, every > 0 {
            let hours = sw.scheduleHours
            let minuteCandidates: [Int] = {
                if every >= 60 && every % 60 == 0 { return [0] }
                if 60 % every == 0 {
                    return stride(from: 0, to: 60, by: every).map { Int($0) }
                }
                var r: [Int] = []; var m = 0; while m < 60 { r.append(m); m += every }; return r
            }()
            var cursor = now.addingTimeInterval(60)
            for _ in 0..<(48*60) {
                let comps = calendar.dateComponents([.hour, .minute], from: cursor)
                guard let h = comps.hour, let m = comps.minute else { break }
                let minuteMatch = minuteCandidates.contains(m)
                let hourMatch = hours == nil || hours!.isEmpty || hours!.contains(h)
                let dayMatch: Bool = {
                    guard let days = sw.scheduleDays, !days.isEmpty else { return true }
                    let w = calendar.component(.weekday, from: cursor) - 1
                    return days.contains(w)
                }()
                if minuteMatch && hourMatch && dayMatch {
                    if let cand = calendar.date(bySettingHour: h, minute: m, second: 0, of: cursor), cand > now { return cand }
                }
                cursor = cursor.addingTimeInterval(60)
            }
            return nil
        }
        return nil
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

    /// Running agents ordered by the user's fleetOrderMode:
    /// default (most recent session first) · runs_desc/runs_asc · latest_msg · alpha
    func sortedRunningNames() -> [String] {
        let running = subworkers.filter(\.running)
        switch fleetOrderMode {
        case "runs_desc":
            return running.sorted { runCounts[$0.name, default: 0] > runCounts[$1.name, default: 0] }.map(\.name)
        case "runs_asc":
            return running.sorted { runCounts[$0.name, default: 0] < runCounts[$1.name, default: 0] }.map(\.name)
        case "latest_msg":
            return running.sorted { (lastActivity[$0.name] ?? .distantPast) > (lastActivity[$1.name] ?? .distantPast) }.map(\.name)
        case "alpha":
            return running.map(\.name).sorted()
        default:
            return running.sorted { recency($0.name) > recency($1.name) }.map(\.name)
        }
    }

    /// Most recent known session moment: live streaming activity or last completion.
    func recency(_ name: String) -> Date {
        let stream = lastActivity[name] ?? .distantPast
        let completed = subworkers.first(where: { $0.name == name })?.lastCompleted ?? .distantPast
        return max(stream, completed)
    }
}
