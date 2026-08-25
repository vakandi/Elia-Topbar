import SwiftUI

struct SessionLogEntry: Identifiable {
    let id: String
    let role: String
    let agent: String?
    let model: String?
    let variant: String?
    let timestamp: Date?
    let entries: [LogEntry]

    enum LogEntry {
        case text(String)
        case reasoning(String)
        case tool(name: String, input: String?, output: String?)

        var displayText: String {
            switch self {
            case .text(let t): return t
            case .reasoning(let r): return "[thinking] \(r)"
            case .tool(let name, let input, let output):
                var s = "[tool: \(name)]"
                if let input, !input.isEmpty { s += " \(input.prefix(120))" }
                if let output, !output.isEmpty { s += " → \(output.prefix(120))" }
                return s
            }
        }

        var color: Color {
            switch self {
            case .text: return .primary
            case .reasoning: return .purple
            case .tool: return .blue
            }
        }
    }
}

struct SessionItem: Identifiable {
    let id: String
    let title: String?
    let agent: String?
    let timeCreated: TimeInterval?
}

struct LogPopoverView: View {
    let subworkerName: String
    let baseURL: String

    @State private var sessions: [SessionItem] = []
    @State private var sessionsLoading = true
    @State private var sessionsError: String?
    @State private var selectedSessionId: String?
    @State private var messages: [SessionLogEntry] = []
    @State private var messagesLoading = false
    @State private var messagesError: String?

    // Batch loading state
    @State private var allSessionIds: [String] = []
    @State private var loadedBatchCount = 0
    @State private var isLoadingMore = false
    @State private var hasMoreSessions = true
    private let batchSize = 5

    // Auto-scroll trigger
    @State private var scrollTarget: UUID?
    @State private var selectedSessionChanged = false
    @State private var lastMessagesFingerprint = 0
    private let maxMessages = 200

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Logs: \(subworkerName)")
                    .font(.headline)
                Spacer()
                if isLoadingMore {
                    ProgressView().controlSize(.mini)
                }
                Button("Refresh") {
                    loadedBatchCount = 0
                    hasMoreSessions = true
                    fetchSessions()
                    if let sid = selectedSessionId {
                        fetchMessages(sessionId: sid, showSpinner: false)
                    }
                }
            }
            .padding()

            Divider()

            HStack(spacing: 0) {
                sessionSidebar
                Divider()
                messagesPanel
            }
        }
        .frame(width: 760, height: 560)
        .onAppear {
            fetchSessions()
            observeRunLogs()
        }
        .onDisappear {
            stopObservingRunLogs()
        }
    }

    // MARK: - Session Sidebar (batch loading)

    private var sessionSidebar: some View {
        VStack(spacing: 0) {
            Text("Sessions")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

            Divider()

            if sessionsLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Loading…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = sessionsError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sessions.isEmpty {
                Text("No sessions")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sessions) { session in
                            sessionRow(session)
                        }

                        if hasMoreSessions && !sessionsLoading {
                            ProgressView()
                                .controlSize(.mini)
                                .padding(8)
                                .onAppear {
                                    loadNextBatch()
                                }
                        }
                    }
                }
            }
        }
        .frame(width: 210)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func sessionRow(_ session: SessionItem) -> some View {
        let isSelected = session.id == selectedSessionId
        return Button(action: {
            selectedSessionId = session.id
            selectedSessionChanged = true
            resetLiveBuffer(for: subworkerName)
            fetchMessages(sessionId: session.id)
        }) {
            VStack(alignment: .leading, spacing: 2) {
                Text(sessionTitle(session))
                    .font(.caption)
                    .foregroundColor(isSelected ? .white : .primary)
                    .lineLimit(1)
                if let ts = session.timeCreated {
                    Text(sessionDate(ts))
                        .font(.caption2)
                        .foregroundColor(isSelected ? .white.opacity(0.7) : .secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor : Color.clear)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Messages Panel (auto-scroll + tool banners)

    private var messagesPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if messagesLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading messages…")
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                    } else if let err = messagesError {
                        Text(err)
                            .foregroundColor(.red)
                            .padding()
                    } else if messages.isEmpty {
                        Text(selectedSessionId == nil ? "Select a session" : "No messages in this session")
                            .foregroundColor(.secondary)
                            .padding()
                    } else {
                        ForEach(messages) { msg in
                            messageRow(msg)
                            Divider()
                        }

                        // Live stream from WS run_log events (running agent).
                        if !liveText(for: subworkerName, field: "text").isEmpty || !liveText(for: subworkerName, field: "reasoning").isEmpty {
                            liveStreamPanel
                        }
                    }
                }
                .padding(8)
            }
            .onChange(of: messages.count) { _ in
                if let last = messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: liveBuffers) { _ in
                proxy.scrollTo("live-stream", anchor: .bottom)
            }
            .onChange(of: selectedSessionChanged) { changed in
                guard changed else { return }
                selectedSessionChanged = false
                // Single delayed scroll — enough for LazyVStack to materialize
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if let last = messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func messageRow(_ msg: SessionLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text((msg.agent ?? msg.role).uppercased())
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(msg.role == "assistant" ? Color.blue : Color.green)
                    .cornerRadius(4)
                if let model = msg.model {
                    Text(msg.variant.flatMap { $0.isEmpty ? nil : "\(model) (\($0))" } ?? model)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let ts = msg.timestamp {
                    Text(ts, style: .time)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            ForEach(Array(msg.entries.enumerated()), id: \.offset) { _, entry in
                messageEntry(entry)
            }
        }
        .padding(.vertical, 4)
        .id(msg.id)
    }

    @ViewBuilder
    private func messageEntry(_ entry: SessionLogEntry.LogEntry) -> some View {
        switch entry {
        case .text(let t):
            MarkdownView(text: t, baseColor: .primary)
                .fixedSize(horizontal: false, vertical: true)
        case .reasoning(let r):
            // Grey plain text with a thin grey bar —
            // visually distinct from the reply without a banner.
            HStack(alignment: .top, spacing: 6) {
                Rectangle()
                    .fill(Color.gray.opacity(0.35))
                    .frame(width: 2)
                MarkdownView(text: r, baseColor: .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .tool(let name, let input, let output):
            toolBanner(
                icon: toolIcon(name),
                title: toolDisplayName(name),
                color: toolColor(name),
                content: formatToolContent(name: name, input: input, output: output)
            )
        }
    }

    @ViewBuilder
    private var liveStreamPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("LIVE")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange)
                    .cornerRadius(4)
                Text(liveAgent ?? subworkerName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
            }
            let reasoning = liveText(for: subworkerName, field: "reasoning")
            if !reasoning.isEmpty {
                MarkdownView(text: reasoning, baseColor: .secondary)
                    .font(.system(.caption2, design: .monospaced))
            }
            let text = liveText(for: subworkerName, field: "text")
            if !text.isEmpty {
                MarkdownView(text: text, baseColor: .primary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
        .id("live-stream")
        Divider()
    }

    // MARK: - Tool Banner Rendering

    private func toolBanner(icon: String, title: String, color: Color, content: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundColor(color)
                Text(title)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.semibold)
                    .foregroundColor(color)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.1))
            .clipShape(RoundedCorner(radius: 6, corners: [.topLeft, .topRight]))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(content)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.primary.opacity(0.8))
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .frame(maxHeight: 200)
            .clipShape(RoundedCorner(radius: 6, corners: [.bottomLeft, .bottomRight]))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(color.opacity(0.2), lineWidth: 1)
        )
    }

    private func toolIcon(_ name: String) -> String {
        switch name.lowercased() {
        case "bash", "shell", "interactive_bash": return "terminal"
        case "read", "view": return "doc.text"
        case "write", "edit": return "pencil.and.document"
        case "grep", "search": return "magnifyingglass"
        case "glob", "find": return "folder"
        case "task", "agent", "call_omo_agent": return "person.2"
        case "skill": return "wand.and.stars"
        case "background_output", "background_cancel": return "arrow.triangle.2.circlepath"
        case "codegraph_explore": return "point.3.connected.trianglepath.dotted"
        case "websearch", "web_search_exa", "webfetch": return "globe"
        default: return "wrench.and.screwdriver"
        }
    }

    private func toolDisplayName(_ name: String) -> String {
        switch name.lowercased() {
        case "bash": return "Terminal"
        case "interactive_bash": return "Shell"
        case "read": return "Read File"
        case "write": return "Write File"
        case "edit": return "Edit File"
        case "grep": return "Search"
        case "glob": return "Find Files"
        case "task": return "Subtask"
        case "call_omo_agent": return "Agent Call"
        case "skill": return "Skill"
        case "background_output": return "BG Output"
        case "background_cancel": return "BG Cancel"
        case "codegraph_explore": return "CodeGraph"
        case "websearch", "web_search_exa": return "Web Search"
        case "webfetch": return "Fetch URL"
        default: return name
        }
    }

    private func toolColor(_ name: String) -> Color {
        switch name.lowercased() {
        case "bash", "shell", "interactive_bash": return .orange
        case "read", "view": return .cyan
        case "write": return .green
        case "edit": return .yellow
        case "grep", "search", "glob", "find": return .purple
        case "task", "agent", "call_omo_agent": return .pink
        case "skill": return .indigo
        case "background_output", "background_cancel": return .teal
        case "codegraph_explore": return .mint
        case "websearch", "web_search_exa", "webfetch": return .blue
        default: return .blue
        }
    }

    private func formatToolContent(name: String, input: String?, output: String?) -> String {
        var parts: [String] = []

        if let input, !input.isEmpty {
            let formatted = formatToolInput(name: name, raw: input)
            if !formatted.isEmpty { parts.append(formatted) }
        }

        if let output, !output.isEmpty {
            let display = output.count > 600 ? String(output.prefix(600)) + "…" : output
            parts.append(display)
        }

        return parts.joined(separator: "\n")
    }

    private func formatToolInput(name: String, raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(raw.prefix(500))
        }

        switch name.lowercased() {
        case "bash", "shell", "interactive_bash":
            if let cmd = obj["command"] as? String { return "$ \(cmd)" }

        case "read":
            if let path = obj["filePath"] as? String { return path }

        case "write":
            if let path = obj["filePath"] as? String {
                let preview = (obj["content"] as? String ?? "").prefix(120)
                return "\(path)\n\(preview)"
            }

        case "edit":
            if let path = obj["filePath"] as? String { return path }

        case "grep":
            if let pattern = obj["pattern"] as? String { return pattern }

        case "glob":
            if let pattern = obj["pattern"] as? String { return pattern }

        case "task":
            if let prompt = obj["prompt"] as? String { return String(prompt.prefix(300)) }
            if let desc = obj["description"] as? String { return desc }

        case "websearch", "web_search_exa":
            if let query = obj["query"] as? String { return query }

        case "webfetch":
            if let url = obj["url"] as? String { return url }

        case "codegraph_explore":
            if let query = obj["query"] as? String { return query }

        default:
            break
        }

        let fallbackKeys = ["command", "query", "pattern", "filePath", "content", "url", "prompt", "description", "script", "selector"]
        for key in fallbackKeys {
            if let val = obj[key] as? String, !val.isEmpty {
                return "\(key): \(val.prefix(300))"
            }
        }

        return String(raw.prefix(500))
    }

    // MARK: - Session Helpers

    private func sessionTitle(_ session: SessionItem) -> String {
        if let t = session.title, !t.isEmpty { return t }
        return String(session.id.prefix(16)) + "…"
    }

    private static let sessionDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter
    }()

    private func sessionDate(_ ts: TimeInterval) -> String {
        Self.sessionDateFormatter.string(from: Date(timeIntervalSince1970: ts / 1000))
    }

    // MARK: - Batch Loading

    private func fetchSessions() {
        guard let url = URL(string: "\(baseURL)/sessions/\(subworkerName)/list") else { return }
        sessionsLoading = true
        sessionsError = nil

        URLSession.shared.dataTask(with: EliaAuth.authorize(url)) { data, _, _ in
            DispatchQueue.main.async {
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let rawSessions = json["sessions"] as? [[String: Any]] else {
                    sessionsLoading = false
                    if sessions.isEmpty { sessionsError = "Could not load sessions" }
                    return
                }

                let allParsed = rawSessions.compactMap { s -> SessionItem? in
                    guard let sid = s["session_id"] as? String, !sid.isEmpty else { return nil }
                    return SessionItem(
                        id: sid,
                        title: s["title"] as? String,
                        agent: s["agent"] as? String,
                        timeCreated: s["time_created"] as? TimeInterval
                    )
                }

                allSessionIds = allParsed.map(\.id)
                loadedBatchCount = 0
                sessions = []
                hasMoreSessions = !allParsed.isEmpty

                loadBatchFrom(allParsed)
                sessionsLoading = false
                sessionsError = nil
            }
        }.resume()
    }

    private func loadBatchFrom(_ allParsed: [SessionItem]) {
        let start = loadedBatchCount * batchSize
        let end = min(start + batchSize, allParsed.count)
        guard start < allParsed.count else {
            hasMoreSessions = false
            return
        }

        let batch = Array(allParsed[start..<end])
        sessions.append(contentsOf: batch)
        loadedBatchCount += 1
        hasMoreSessions = end < allParsed.count

        if selectedSessionId == nil, let first = sessions.first {
            selectedSessionId = first.id
            fetchMessages(sessionId: first.id)
        }
    }

    private func loadNextBatch() {
        guard !isLoadingMore, hasMoreSessions else { return }
        isLoadingMore = true

        guard let url = URL(string: "\(baseURL)/sessions/\(subworkerName)/list") else {
            isLoadingMore = false
            return
        }

        URLSession.shared.dataTask(with: EliaAuth.authorize(url)) { data, _, _ in
            DispatchQueue.main.async {
                defer { isLoadingMore = false }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let rawSessions = json["sessions"] as? [[String: Any]] else { return }

                let allParsed = rawSessions.compactMap { s -> SessionItem? in
                    guard let sid = s["session_id"] as? String, !sid.isEmpty else { return nil }
                    return SessionItem(
                        id: sid,
                        title: s["title"] as? String,
                        agent: s["agent"] as? String,
                        timeCreated: s["time_created"] as? TimeInterval
                    )
                }

                let start = loadedBatchCount * batchSize
                let end = min(start + batchSize, allParsed.count)
                guard start < allParsed.count else {
                    hasMoreSessions = false
                    return
                }

                let batch = Array(allParsed[start..<end])
                sessions.append(contentsOf: batch)
                loadedBatchCount += 1
                hasMoreSessions = end < allParsed.count
            }
        }.resume()
    }

    // MARK: - Live log streaming (WS run_log events)

    /// Per-agent buffers — keyed by agent so concurrent runs never wipe each other.
    @State private var liveBuffers: [String: [String: String]] = [:]
    @State private var liveAgent: String?
    @State private var runLogObserver: NSObjectProtocol?

    private func liveText(for name: String, field: String) -> String {
        liveBuffers[name]?[field] ?? ""
    }

    private func observeRunLogs() {
        runLogObserver = NotificationCenter.default.addObserver(
            forName: SubworkerManager.runLogNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let name = note.userInfo?["name"] as? String,
                  let delta = note.userInfo?["text"] as? String else { return }
            let field = note.userInfo?["field"] as? String ?? "text"
            if liveBuffers[name] == nil { liveBuffers[name] = [:] }
            liveBuffers[name]?[field, default: ""] += delta
            for (k, v) in liveBuffers[name] ?? [:] where liveBuffers[name]?[k]?.count ?? 0 > 12000 {
                liveBuffers[name]?[k] = String(v.suffix(8000))
            }
            if name != liveAgent { liveAgent = name }
        }
    }

    private func resetLiveBuffer(for name: String) {
        liveBuffers[name] = nil
    }

    private func stopObservingRunLogs() {
        if let obs = runLogObserver {
            NotificationCenter.default.removeObserver(obs)
            runLogObserver = nil
        }
    }

    // MARK: - Fetch Messages

    private func fetchMessages(sessionId: String, showSpinner: Bool = true) {
        guard let url = URL(string: "\(baseURL)/sessions/\(subworkerName)?session_id=\(sessionId)&limit=50") else { return }
        if showSpinner { messagesLoading = true }

        URLSession.shared.dataTask(with: EliaAuth.authorize(url)) { data, _, _ in
            DispatchQueue.main.async {
                defer { messagesLoading = false }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let rawMessages = json["messages"] as? [[String: Any]] else {
                    if messages.isEmpty { messagesError = "Could not load messages" }
                    return
                }

                // Identical payload → keep current views untouched (5s polling).
                let fingerprint = String(data: data, encoding: .utf8)?.hashValue ?? 0
                if fingerprint == lastMessagesFingerprint && !messages.isEmpty {
                    return
                }
                lastMessagesFingerprint = fingerprint

                let allParsed = rawMessages.enumerated().compactMap { idx, raw in
                    parseMessage(raw, id: "\(sessionId)-\(idx)")
                }
                messages = allParsed.count > maxMessages ? Array(allParsed.suffix(maxMessages)) : allParsed
                messagesError = nil

                selectedSessionChanged = true
            }
        }.resume()
    }

    private func parseMessage(_ raw: [String: Any], id: String) -> SessionLogEntry? {
        guard let info = raw["info"] as? [String: Any],
              let parts = raw["parts"] as? [[String: Any]] else { return nil }

        let role = info["role"] as? String ?? "unknown"
        let agent = info["agent"] as? String

        var timestamp: Date?
        if let timeObj = info["time"] as? [String: Any],
           let created = timeObj["created"] as? TimeInterval {
            timestamp = Date(timeIntervalSince1970: created / 1000)
        }

        let entries: [SessionLogEntry.LogEntry] = parts.compactMap { part -> SessionLogEntry.LogEntry? in
            guard let type = part["type"] as? String else { return nil }
            switch type {
            case "text":
                if let text = part["text"] as? String, !text.isEmpty {
                    return .text(text)
                }
                return nil
            case "reasoning":
                if let text = part["text"] as? String, !text.isEmpty {
                    return .reasoning(text)
                }
                return nil
            case "tool":
                let toolName = part["tool"] as? String ?? "?"
                let input: String? = {
                    if let obj = part["input"] as? [String: Any] {
                        guard JSONSerialization.isValidJSONObject(obj),
                              let data = try? JSONSerialization.data(withJSONObject: obj) else {
                            return String(describing: obj)
                        }
                        return String(data: data, encoding: .utf8)
                    }
                    if let str = part["input"] as? String { return str }
                    if let scalar = part["input"] as? NSNumber { return scalar.stringValue }
                    return nil
                }()
                let output: String? = {
                    if let str = part["output"] as? String { return str }
                    if let num = part["output"] as? NSNumber { return num.stringValue }
                    if let arr = part["output"] as? [Any] {
                        guard JSONSerialization.isValidJSONObject(arr),
                              let data = try? JSONSerialization.data(withJSONObject: arr) else {
                            return String(describing: arr)
                        }
                        return String(data: data, encoding: .utf8)
                    }
                    if let dict = part["output"] as? [String: Any] {
                        guard JSONSerialization.isValidJSONObject(dict),
                              let data = try? JSONSerialization.data(withJSONObject: dict) else {
                            return String(describing: dict)
                        }
                        return String(data: data, encoding: .utf8)
                    }
                    return nil
                }()
                return .tool(name: toolName, input: input, output: output)
            default:
                return nil
            }
        }

        guard !entries.isEmpty else { return nil }
        let model = info["model"] as? String
        let variant = info["variant"] as? String
        return SessionLogEntry(id: id, role: role, agent: agent, model: model, variant: variant, timestamp: timestamp, entries: entries)
    }
}

// MARK: - RoundedCorner Extension

struct RoundedCorner: Shape {
    var radius: CGFloat
    var corners: CornerSet

    struct CornerSet: OptionSet {
        let rawValue: Int
        static let topLeft = CornerSet(rawValue: 1 << 0)
        static let topRight = CornerSet(rawValue: 1 << 1)
        static let bottomLeft = CornerSet(rawValue: 1 << 2)
        static let bottomRight = CornerSet(rawValue: 1 << 3)
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(radius, min(rect.width, rect.height) / 2)

        let tl = corners.contains(.topLeft) ? r : 0
        let tr = corners.contains(.topRight) ? r : 0
        let bl = corners.contains(.bottomLeft) ? r : 0
        let br = corners.contains(.bottomRight) ? r : 0

        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        if tr > 0 { path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + tr), radius: tr) }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        if br > 0 { path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - br, y: rect.maxY), radius: br) }
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        if bl > 0 { path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bl), radius: bl) }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        if tl > 0 { path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + tl, y: rect.minY), radius: tl) }
        path.closeSubpath()
        return path
    }
}
