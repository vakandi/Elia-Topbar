import SwiftUI

struct RunBanner: Identifiable, Equatable {
    let id: String
    let type: String
    let attempt: Int
    let maxAttempts: Int
    let delaySeconds: Double
    let error: String
    let timestamp: Date?
    let sessionId: String?
}

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

/// Reports the bottom edge (maxY) of the scroll content's true-end marker,
/// in the scroll view's own coordinate space, so we can tell whether the
/// user is currently at/near the bottom without any macOS 14+ scroll APIs.
private struct BottomAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

enum DisplayItem: Identifiable {
    case message(SessionLogEntry)
    case banner(RunBanner)
    var id: String {
        switch self {
        case .message(let m): return m.id
        case .banner(let b): return b.id
        }
    }
    var timestamp: Date? {
        switch self {
        case .message(let m): return m.timestamp
        case .banner(let b): return b.timestamp
        }
    }
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
    // Keyed by sessionId so two sessions returning identical JSON (e.g. both
    // empty) can't dedupe-block each other's legitimate updates.
    @State private var lastMessagesFingerprint: [String: Int] = [:]
    // Prevents overlapping /list requests (onAppear can fire more than once
    // inside an NSHostingController-hosted NSPopover) from racing each other.
    @State private var sessionsFetchInFlight = false
    // Pin-to-bottom scroll state — true unless the user has manually scrolled up.
    @State private var isPinnedToBottom = true
    @State private var pendingScrollWork: DispatchWorkItem?
    private let maxMessages = 200

    @State private var banners: [RunBanner] = []
    @State private var bannerObserver: NSObjectProtocol?
    @State private var liveRunning = false
    @State private var liveStartedAt: Date?
    @State private var liveStartedObserver: NSObjectProtocol?
    @State private var liveCompletedObserver: NSObjectProtocol?
    @State private var liveTick = 0
    @State private var verticalTodos: [TodoItem] = []
    @State private var isHoveringTodoModule = false
    @State private var messageFetchLimit = 20
    @State private var hasMoreMessages = true
    @State private var isLoadingMoreMessages = false
    @State private var continuingIds: Set<String> = []

    private var displayItems: [DisplayItem] {
        var items: [DisplayItem] = messages.map { .message($0) }
        let relevant = banners.filter { $0.sessionId == nil || $0.sessionId == selectedSessionId || selectedSessionId == nil }
        items.append(contentsOf: relevant.map { .banner($0) })
        return items.sorted { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
    }

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
            observeRunBanners()
            observeLiveLifecycle()
            startLiveTick()
            checkInitialRunningState()
        }
        .onDisappear {
            stopObservingRunLogs()
            stopObservingRunBanners()
            stopObservingLiveLifecycle()
        }
    }

    // MARK: - Session Sidebar (batch loading)

    private var sessionSidebar: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                if let photo = ProfilePhotos.shared.circularPhoto(for: subworkerName, size: 72) {
                    Image(nsImage: photo)
                        .resizable()
                        .frame(width: 72, height: 72)
                } else {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.22))
                        Text(agentMonogram)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.accentColor)
                    }
                    .frame(width: 72, height: 72)
                }
                Text(subworkerName)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .help(subworkerName)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)

            Divider()

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
        let isContinuing = continuingIds.contains(session.id)
        return Button(action: {
            guard session.id != selectedSessionId else {
                fetchMessages(sessionId: session.id)
                return
            }
            selectedSessionId = session.id
            selectedSessionChanged = true
            isPinnedToBottom = true
            messages = []
            messagesError = nil
            verticalTodos = []
            messageFetchLimit = 20
            hasMoreMessages = true
            isLoadingMoreMessages = false
            resetLiveBuffer(for: subworkerName)
            fetchMessages(sessionId: session.id)
        }) {
            VStack(alignment: .leading, spacing: 2) {
                Text(sessionTitle(session))
                    .font(.caption)
                    .foregroundColor(isSelected ? .white : .primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let ts = session.timeCreated {
                        Text(sessionDate(ts))
                            .font(.caption2)
                            .foregroundColor(isSelected ? .white.opacity(0.7) : .secondary)
                    } else {
                        Text(String(session.id.prefix(8)) + "…")
                            .font(.caption2)
                            .foregroundColor(isSelected ? .white.opacity(0.7) : .secondary)
                    }
                    Spacer()
                    Button(action: {
                        continueSession(sessionId: session.id)
                    }) {
                        HStack(spacing: 3) {
                            if isContinuing {
                                ProgressView().controlSize(.mini).scaleEffect(0.6)
                            }
                            Text(isContinuing ? "Sending…" : "Continue")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundColor(isSelected ? .white : .accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(isSelected ? Color.white.opacity(0.2) : Color.accentColor.opacity(0.14))
                        .cornerRadius(4)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(isSelected ? Color.white.opacity(0.3) : Color.accentColor.opacity(0.3), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(isContinuing)
                    .help("Send 'continue the tasks' to this session")
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

    private func continueSession(sessionId: String) {
        guard let url = URL(string: "\(baseURL)/sessions/\(subworkerName)/\(sessionId)/continue") else { return }
        continuingIds.insert(sessionId)
        var request = EliaAuth.authorize(url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["message": "continue the tasks"])
        URLSession.shared.dataTask(with: request) { _, response, _ in
            DispatchQueue.main.async {
                continuingIds.remove(sessionId)
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    selectedSessionId = sessionId
                    fetchMessages(sessionId: sessionId, showSpinner: false)
                    fetchSessions()
                }
            }
        }.resume()
    }

    // MARK: - Messages Panel (auto-scroll + tool banners)

    private var messagesPanel: some View {
        GeometryReader { outerGeo in
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
                        } else {
                            if !displayItems.isEmpty {
                                if hasMoreMessages && !isLoadingMoreMessages {
                                    HStack(spacing: 6) {
                                        ProgressView().controlSize(.mini)
                                        Text("Older messages — scroll up to load").font(.caption2).foregroundColor(.secondary)
                                    }.frame(maxWidth: .infinity).padding(.vertical, 4).onAppear { loadMoreMessages() }
                                    Divider()
                                }
                                ForEach(displayItems) { item in
                                    switch item {
                                    case .message(let msg):
                                        messageRow(msg)
                                    case .banner(let b):
                                        systemBanner(b)
                                    }
                                    Divider()
                                }
                            }
                            if hasLiveContent(for: subworkerName) {
                                liveStreamPanel
                            } else if liveRunning {
                                liveWaitingView
                            } else if displayItems.isEmpty {
                                if selectedSessionId == nil {
                                    Text("Select a session")
                                        .foregroundColor(.secondary)
                                        .padding()
                                } else {
                                    VStack(spacing: 8) {
                                        Text("No messages in this session")
                                            .foregroundColor(.secondary)
                                        Text("Trigger the agent or wait for it to write its first message.")
                                            .font(.caption2).foregroundColor(.secondary.opacity(0.7))
                                    }
                                    .padding()
                                }
                            }
                        }

                        // Single unambiguous "end of everything" marker — historical
                        // messages, banners, AND the live stream/waiting view all sit
                        // above this, so scrolling here always means scrolling to the
                        // true tail regardless of which branch above is active.
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchorId)
                            .background(
                                GeometryReader { anchorGeo in
                                    Color.clear.preference(
                                        key: BottomAnchorPreferenceKey.self,
                                        value: anchorGeo.frame(in: .named(Self.scrollCoordinateSpace)).maxY
                                    )
                                }
                            )
                    }
                    .padding(8)
                }
                .coordinateSpace(name: Self.scrollCoordinateSpace)
                .onPreferenceChange(BottomAnchorPreferenceKey.self) { anchorMaxY in
                    // Anchor's maxY relative to the scroll container: near/inside the
                    // visible height means we're at the bottom; far past it means the
                    // user has scrolled up to read history.
                    let atBottom = anchorMaxY <= outerGeo.size.height + 48
                    if atBottom != isPinnedToBottom {
                        isPinnedToBottom = atBottom
                    }
                }
                .onChange(of: messages.count) { _ in
                    requestScroll(proxy: proxy)
                }
                .onChange(of: banners) { _ in
                    requestScroll(proxy: proxy)
                }
                .onChange(of: liveEntries) { _ in
                    requestScroll(proxy: proxy)
                }
                .onChange(of: selectedSessionChanged) { changed in
                    guard changed else { return }
                    selectedSessionChanged = false
                    isPinnedToBottom = true
                    for delay in [0.05, 0.2, 0.45, 0.8, 1.2] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(Self.bottomAnchorId, anchor: .bottom)
                            }
                        }
                    }
                }
                .onChange(of: messagesLoading) { isLoading in
                    if !isLoading && !messages.isEmpty {
                        isPinnedToBottom = true
                        for delay in [0.05, 0.2, 0.45, 0.8, 1.2] {
                            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    proxy.scrollTo(Self.bottomAnchorId, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
            }
            .overlay(alignment: .leading) {
                HStack(spacing: 0) {
                    verticalTodoStrip
                    Spacer()
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .padding(.leading, 3)
                .allowsHitTesting(!verticalTodos.isEmpty)
            }
        }
    }

    private static let bottomAnchorId = "log-scroll-bottom-anchor"
    private static let scrollCoordinateSpace = "log-scroll-area"

    /// Coalesces rapid-fire updates (WS delta bursts can arrive many times a
    /// second) into a single throttled scroll, and only auto-scrolls while the
    /// user hasn't deliberately scrolled away from the bottom — unless `force`
    /// is set (session switch / explicit jump-to-latest).
    private func requestScroll(proxy: ScrollViewProxy, force: Bool = false, delay: TimeInterval = 0.05) {
        guard force || isPinnedToBottom else { return }
        pendingScrollWork?.cancel()
        let work = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(Self.bottomAnchorId, anchor: .bottom)
            }
        }
        pendingScrollWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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
            HStack(alignment: .top, spacing: 6) {
                Rectangle()
                    .fill(Color.gray.opacity(0.35))
                    .frame(width: 2)
                MarkdownView(text: r, baseColor: .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .tool(let name, let input, let output):
            if name.lowercased() == "todowrite", let todos = parseTodoWritePayload(input, output: output) {
                todoWriteBanner(todos: todos)
            } else if name.lowercased() == "edit", let input, !input.isEmpty,
               let diff = parseEditPayload(input) {
                editDiffBanner(filePath: diff.path, oldString: diff.old, newString: diff.new)
            } else if name.lowercased() == "write", let input, !input.isEmpty,
                      let wp = parseWritePayload(input) {
                writeFileBanner(filePath: wp.path, contentPreview: wp.preview, output: output)
            } else {
                toolBanner(
                    icon: toolIcon(name),
                    title: toolDisplayName(name),
                    color: toolColor(name),
                    content: formatToolContent(name: name, input: input, output: output)
                )
            }
        }
    }

    private func hostPath(_ path: String) -> String {
        if path.hasPrefix("/data/") {
            return path.replacingOccurrences(of: "/data/", with: "/Users/vakandi/EliaAI/", options: .anchored)
        }
        if path == "/data" { return "/Users/vakandi/EliaAI" }
        return path
    }

    private struct EditPayload { let path: String; let old: String; let new: String }
    private struct WritePayload { let path: String; let preview: String }

    private func parseEditPayload(_ raw: String) -> EditPayload? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let path = (obj["filePath"] as? String ?? obj["file_path"] as? String ?? obj["path"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        let old = obj["oldString"] as? String ?? obj["old_string"] as? String ?? obj["oldText"] as? String ?? ""
        let new = obj["newString"] as? String ?? obj["new_string"] as? String ?? obj["newText"] as? String ?? ""
        if old.isEmpty && new.isEmpty { return nil }
        return EditPayload(path: hostPath(path), old: old, new: new)
    }

    private func parseWritePayload(_ raw: String) -> WritePayload? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let path = (obj["filePath"] as? String ?? obj["file_path"] as? String ?? obj["path"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        let content = obj["content"] as? String ?? ""
        return WritePayload(path: hostPath(path), preview: String(content.prefix(500)))
    }

    private struct TodoItem { let content: String; let status: String; let priority: String }
    private func parseTodoWritePayload(_ input: String?, output: String?) -> [TodoItem]? {
        let raw = (input?.isEmpty == false ? input : output) ?? ""
        guard !raw.isEmpty, let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["todos"] as? [[String: Any]], !arr.isEmpty else { return nil }
        return arr.compactMap { d in
            guard let c = d["content"] as? String, !c.isEmpty else { return nil }
            return TodoItem(content: c, status: (d["status"] as? String ?? "pending").lowercased(), priority: (d["priority"] as? String ?? "medium").lowercased())
        }
    }
    private func todoDotColor(_ status: String) -> Color {
        switch status {
        case "completed": return .green
        case "in_progress": return .blue
        case "cancelled": return .red
        default: return .gray
        }
    }
    private func todoPriorityColor(_ p: String) -> Color {
        switch p {
        case "high": return .red.opacity(0.7)
        case "medium": return .orange.opacity(0.7)
        default: return .secondary
        }
    }
    private func todoWriteBanner(todos: [TodoItem]) -> some View {
        let completed = todos.filter { $0.status == "completed" }.count
        let inProgress = todos.filter { $0.status == "in_progress" }.count
        let pending = todos.filter { $0.status == "pending" }.count
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "checklist").font(.caption2).foregroundColor(.purple)
                Text("Todo List").font(.system(.caption, design: .monospaced)).fontWeight(.semibold).foregroundColor(.purple)
                Text("\(completed)/\(todos.count)").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundColor(.secondary).padding(.horizontal, 6).padding(.vertical, 2).background(Color.purple.opacity(0.12)).cornerRadius(4)
                if inProgress > 0 { Text("\(inProgress) running").font(.caption2).foregroundColor(.blue) }
                if pending > 0 { Text("\(pending) pending").font(.caption2).foregroundColor(.secondary) }
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 6).background(Color.purple.opacity(0.08)).clipShape(RoundedCorner(radius: 6, corners: [.topLeft, .topRight]))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(todos.prefix(10).enumerated()), id: \.offset) { _, t in
                    HStack(spacing: 8) {
                        todoDotView(status: t.status)
                        Text(t.content).font(.system(size: 11)).foregroundColor(t.status == "completed" ? .secondary : .primary).lineLimit(2).truncationMode(.tail)
                        Spacer()
                        Text(t.priority).font(.system(size: 9, weight: .medium)).foregroundColor(todoPriorityColor(t.priority)).padding(.horizontal, 4).padding(.vertical, 1).background(Color.secondary.opacity(0.08)).cornerRadius(3)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5).background(todoRowBackground(status: t.status))
                    if t.content != todos.prefix(10).last?.content { Divider().opacity(0.3) }
                }
                if todos.count > 10 { Text("… \(todos.count - 10) more").font(.caption2).foregroundColor(.secondary).padding(6) }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .frame(maxHeight: todos.count > 6 ? 220 : nil)
            .clipShape(RoundedCorner(radius: 6, corners: [.bottomLeft, .bottomRight]))
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.purple.opacity(0.25), lineWidth: 1))
    }
    private func todoDotView(status: String) -> some View {
        let color = todoDotColor(status)
        return ZStack {
            Circle().fill(color).frame(width: 8, height: 8)
            if status == "in_progress" { Circle().stroke(Color.blue.opacity(0.4), lineWidth: 2).frame(width: 11, height: 11) }
        }.frame(width: 11, height: 11)
    }
    private func todoRowBackground(status: String) -> Color {
        switch status {
        case "in_progress": return Color.blue.opacity(0.06)
        case "completed": return Color.green.opacity(0.04)
        default: return Color.clear
        }
    }
    private var verticalTodoStrip: some View {
        Group {
            if !verticalTodos.isEmpty {
                VStack(spacing: 7) {
                    ForEach(Array(verticalTodos.prefix(10).enumerated()), id: \.offset) { _, t in
                        HStack(spacing: 6) {
                            todoDotView(status: t.status)
                            if isHoveringTodoModule {
                                Text(t.content).font(.system(size: 10)).foregroundColor(t.status == "completed" ? .secondary : .primary).lineLimit(1).truncationMode(.tail)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    if verticalTodos.count > 10 {
                        Text("…\(verticalTodos.count - 10)").font(.caption2).foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 8).padding(.horizontal, isHoveringTodoModule ? 8 : 4)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.96))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.purple.opacity(0.28), lineWidth: 1))
                .shadow(color: .black.opacity(0.08), radius: 4, x: 1, y: 2)
                .frame(width: isHoveringTodoModule ? min(260, 520) : 18)
                .onHover { hovering in withAnimation(.easeOut(duration: 0.2)) { isHoveringTodoModule = hovering } }
            }
        }
    }

    private func systemBanner(_ b: RunBanner) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                Text("ELIA SYSTEM")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundColor(.orange)
                if b.attempt > 0 {
                    Text("Reinjection \(b.attempt)/\(b.maxAttempts)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15))
                        .cornerRadius(4)
                } else {
                    Text("Reinjection")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15))
                        .cornerRadius(4)
                }
                Spacer()
                if let ts = b.timestamp {
                    Text(ts, style: .time)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Text("Agent didn't finish — provider returned an error. System re-injected \"\(b.error.isEmpty ? "continue the tasks" : b.error)\" \(b.delaySeconds > 0 ? "after \(String(format: "%.0f", b.delaySeconds))s" : "to keep the run alive").")
                .font(.caption)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if !b.error.isEmpty && b.error != "Agent didn't finish — system reinjected" {
                Text(b.error)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.3), lineWidth: 1))
        .cornerRadius(8)
        .id(b.id)
    }

    @ViewBuilder
    private var liveStreamPanel: some View {
        let entries = liveEntries[subworkerName] ?? []
        VStack(alignment: .leading, spacing: 6) {
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
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                switch entry {
                case .liveReasoning(let text):
                    VStack(alignment: .leading, spacing: 2) {
                        Text("THINKING")
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.7))
                            .tracking(0.6)
                        HStack(alignment: .top, spacing: 6) {
                            Rectangle()
                                .fill(Color.gray.opacity(0.35))
                                .frame(width: 2)
                            MarkdownView(text: text, baseColor: .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                case .liveText(let text):
                    MarkdownView(text: streamingSafeMarkdown(text), baseColor: .primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                case .liveTool(let name, let input, let output):
                    let lname = name.lowercased()
                    if lname == "todowrite", let todos = parseTodoWritePayload(input, output: output) {
                        todoWriteBanner(todos: todos)
                    } else if lname == "edit", let input, let diff = parseEditLivePayload(input, output: output) {
                        editDiffBanner(filePath: diff.path, oldString: diff.old, newString: diff.new)
                    } else if lname == "write", let input, let wp = parseWriteLivePayload(input) {
                        writeFileBanner(filePath: wp.path, contentPreview: wp.preview, output: output)
                    } else {
                        toolBanner(
                            icon: toolIcon(name),
                            title: toolDisplayName(name),
                            color: toolColor(name),
                            content: formatToolContent(name: name, input: input, output: output)
                        )
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .id("live-stream")
        Divider()
    }

    private var liveWaitingView: some View {
        let elapsed: String = {
            guard let start = liveStartedAt else { return "" }
            let s = Int(Date().timeIntervalSince(start))
            if s < 60 { return "\(s)s" }
            return "\(s/60)m \(s%60)s"
        }()
        let dots = String(repeating: ".", count: (liveTick % 3) + 1)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("LIVE").font(.system(.caption, design: .monospaced)).foregroundColor(.white).padding(.horizontal, 6).padding(.vertical, 2).background(Color.orange).cornerRadius(4)
                Text(subworkerName).font(.caption).foregroundColor(.secondary)
                Spacer()
                ProgressView().controlSize(.mini).scaleEffect(0.7)
                if !elapsed.isEmpty {
                    Text(elapsed).font(.caption2).foregroundColor(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Agent running\(dots)")
                        .font(.caption).foregroundColor(.primary)
                    Spacer()
                }
                Text("Connecting to opencode • waiting for first token")
                    .font(.caption2).foregroundColor(.secondary)
                HStack(spacing: 4) {
                    Circle().fill(Color.green).frame(width: 6, height: 6).opacity(0.9)
                    Text("WS: streaming").font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                    Spacer()
                    Text("Session will appear when opencode creates it").font(.system(size: 9)).foregroundColor(.secondary.opacity(0.7))
                }
            }
            .padding(10)
            .background(Color.orange.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.2), lineWidth: 1))
            .cornerRadius(8)
        }
        .padding(.vertical, 4)
        .id("live-waiting")
    }

    private func observeLiveLifecycle() {
        liveStartedObserver = NotificationCenter.default.addObserver(forName: SubworkerManager.subworkerStartedNotification, object: nil, queue: .main) { note in
            guard let name = note.userInfo?["name"] as? String, name == self.subworkerName else { return }
            self.liveRunning = true
            self.liveStartedAt = Date()
            self.liveTick = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.fetchSessions() }
        }
        liveCompletedObserver = NotificationCenter.default.addObserver(forName: SubworkerManager.subworkerCompletedNotification, object: nil, queue: .main) { note in
            guard let name = note.userInfo?["name"] as? String, name == self.subworkerName else { return }
            self.liveRunning = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.fetchSessions() }
        }
    }

    private func stopObservingLiveLifecycle() {
        if let o = liveStartedObserver { NotificationCenter.default.removeObserver(o); liveStartedObserver = nil }
        if let o = liveCompletedObserver { NotificationCenter.default.removeObserver(o); liveCompletedObserver = nil }
    }

    private func startLiveTick() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
            if self.liveRunning { self.liveTick += 1 }
        }
        // Timer.scheduledTimer defaults to .default run loop mode, which is
        // suspended while AppKit is in event-tracking (e.g. this popover's
        // own show/scroll interactions) — same class of stall SubworkerManager
        // already works around via its scheduleTimer(..., forMode: .common).
        RunLoop.main.add(timer, forMode: .common)
    }

    private func checkInitialRunningState() {
        guard let url = URL(string: "\(baseURL)/status") else { return }
        URLSession.shared.dataTask(with: EliaAuth.authorize(url)) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = json["subworkers"] as? [[String: Any]] else { return }
            DispatchQueue.main.async {
                if let sw = arr.first(where: { ($0["name"] as? String) == self.subworkerName }),
                   (sw["running"] as? Bool) == true {
                    self.liveRunning = true
                    if self.liveStartedAt == nil { self.liveStartedAt = Date() }
                }
            }
        }.resume()
    }

    private func streamingSafeMarkdown(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return text }
        let fenceCount = text.components(separatedBy: "```").count - 1
        if fenceCount % 2 == 1 {
            return text + "\n```"
        }
        return text
    }

    // MARK: - Tool Banner Rendering

    private func toolBanner(icon: String, title: String, color: Color, content: String) -> some View {
        let safeContent = content.isEmpty ? "—" : content
        return VStack(alignment: .leading, spacing: 0) {
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
                Text(safeContent)
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

    private func writeFileBanner(filePath: String, contentPreview: String, output: String?) -> some View {
        let name = (filePath as NSString).lastPathComponent
        let dir = (filePath as NSString).deletingLastPathComponent
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "doc.badge.plus").font(.caption2).foregroundColor(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(.caption, design: .monospaced)).fontWeight(.semibold).foregroundColor(.green)
                    Text(dir).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if let out = output, !out.isEmpty {
                    Text(out).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color.green.opacity(0.1))
            .clipShape(RoundedCorner(radius: 6, corners: [.topLeft, .topRight]))
            if !contentPreview.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(contentPreview)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.primary.opacity(0.7))
                        .textSelection(.enabled)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .frame(maxHeight: 120)
                .clipShape(RoundedCorner(radius: 6, corners: [.bottomLeft, .bottomRight]))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.green.opacity(0.25), lineWidth: 1))
    }

    private func editDiffBanner(filePath: String, oldString: String, newString: String) -> some View {
        let oldLines = oldString.components(separatedBy: "\n")
        let newLines = newString.components(separatedBy: "\n")
        let diff = lineDiff(old: oldLines, new: newLines)
        let name = (filePath as NSString).lastPathComponent
        let dir = (filePath as NSString).deletingLastPathComponent
        let added = diff.filter { $0.kind == .added }.count
        let removed = diff.filter { $0.kind == .removed }.count
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "pencil.and.scribble").font(.caption2).foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(.caption, design: .monospaced)).fontWeight(.semibold).foregroundColor(.orange)
                    Text(dir).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text("+\(added) −\(removed)").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundColor(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Color.secondary.opacity(0.12)).cornerRadius(4)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color.orange.opacity(0.1))
            .clipShape(RoundedCorner(radius: 6, corners: [.topLeft, .topRight]))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.prefix(80).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 6) {
                        Text(row.kind.prefix).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundColor(row.kind.color).frame(width: 14, alignment: .center)
                        Text(row.text).font(.system(size: 10, design: .monospaced)).foregroundColor(row.kind == .added ? .green : row.kind == .removed ? .red : .primary.opacity(0.85)).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(row.kind.bg)
                }
                if diff.count > 80 {
                    Text("… \(diff.count - 80) more lines").font(.caption2).foregroundColor(.secondary).padding(6)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .frame(maxHeight: 220)
            .clipShape(RoundedCorner(radius: 6, corners: [.bottomLeft, .bottomRight]))
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.orange.opacity(0.25), lineWidth: 1))
    }

    private enum DiffKind { case added, removed, unchanged
        var prefix: String { switch self { case .added: return "+"; case .removed: return "−"; case .unchanged: return " " } }
        var color: Color { switch self { case .added: return .green; case .removed: return .red; case .unchanged: return .secondary } }
        var bg: Color { switch self { case .added: return Color.green.opacity(0.08); case .removed: return Color.red.opacity(0.08); case .unchanged: return .clear } }
    }
    private struct DiffRow { let kind: DiffKind; let text: String }
    private func lineDiff(old: [String], new: [String]) -> [DiffRow] {
        if old.isEmpty { return new.map { DiffRow(kind: .added, text: $0) } }
        if new.isEmpty { return old.map { DiffRow(kind: .removed, text: $0) } }
        var i = 0, j = 0
        var out: [DiffRow] = []
        while i < old.count || j < new.count {
            if i < old.count && j < new.count && old[i] == new[j] {
                out.append(DiffRow(kind: .unchanged, text: old[i])); i+=1; j+=1
            } else if j < new.count && (i >= old.count || !old[i...].contains(new[j])) {
                out.append(DiffRow(kind: .added, text: new[j])); j+=1
            } else if i < old.count {
                out.append(DiffRow(kind: .removed, text: old[i])); i+=1
            } else {
                out.append(DiffRow(kind: .added, text: new[j])); j+=1
            }
        }
        return out
    }

    private func parseEditLivePayload(_ raw: String, output: String?) -> EditPayload? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if raw.contains("oldString") || raw.contains("old_string") { return nil }
            return nil
        }
        let path = (obj["filePath"] as? String ?? obj["file_path"] as? String ?? obj["path"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if path.isEmpty { return nil }
        let old = obj["oldString"] as? String ?? obj["old_string"] as? String ?? ""
        let new = obj["newString"] as? String ?? obj["new_string"] as? String ?? ""
        if old.isEmpty && new.isEmpty { return nil }
        return EditPayload(path: hostPath(path), old: old, new: new)
    }
    private func parseWriteLivePayload(_ raw: String) -> WritePayload? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let path = (obj["filePath"] as? String ?? obj["file_path"] as? String ?? obj["path"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if path.isEmpty { return nil }
        let content = obj["content"] as? String ?? obj["input"] as? String ?? ""
        return WritePayload(path: hostPath(path), preview: String(content.prefix(500)))
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
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "{}" || trimmed == "()" || trimmed.isEmpty { return "" }
            return String(raw.prefix(500))
        }
        if obj.isEmpty { return "" }

        func fp(_ o: [String: Any]) -> String? {
            (o["filePath"] as? String ?? o["file_path"] as? String ?? o["path"] as? String ?? o["filepath"] as? String)
        }

        switch name.lowercased() {
        case "bash", "shell", "interactive_bash":
            if let cmd = obj["command"] as? String { return "$ \(cmd)" }

        case "read":
            if let path = fp(obj) { return hostPath(path) }

        case "write":
            if let path = fp(obj) {
                let hp = hostPath(path)
                if let content = obj["content"] as? String, !content.isEmpty {
                    return "\(hp)\n\(content.prefix(200))"
                }
                return hp
            }

        case "edit":
            if let path = fp(obj) { return hostPath(path) }

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

    private var agentMonogram: String {
        let parts = subworkerName.split(separator: "-").map(String.init)
        let initials = parts.prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
        if initials.count == 2 { return initials }
        let firstWord = parts.first ?? subworkerName
        return String(firstWord.prefix(2)).uppercased()
    }

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
        // onAppear can fire more than once for a SwiftUI view hosted inside an
        // NSHostingController-backed NSPopover; without this guard two
        // concurrent /list requests race and stomp each other's state.
        guard !sessionsFetchInFlight else { return }
        sessionsFetchInFlight = true
        sessionsLoading = true
        sessionsError = nil

        URLSession.shared.dataTask(with: EliaAuth.authorize(url)) { data, _, _ in
            DispatchQueue.main.async {
                defer { sessionsFetchInFlight = false }
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
            isPinnedToBottom = true
            messageFetchLimit = 20
            hasMoreMessages = true
            isLoadingMoreMessages = false
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

    enum LiveEntry: Equatable {
        case liveReasoning(String)
        case liveText(String)
        case liveTool(name: String, input: String?, output: String?)
    }

    @State private var liveEntries: [String: [LiveEntry]] = [:]
    @State private var liveAgent: String?
    @State private var runLogObserver: NSObjectProtocol?

    private func hasLiveContent(for name: String) -> Bool {
        guard let entries = liveEntries[name] else { return false }
        return !entries.isEmpty
    }

    private func liveCoalescedText(for name: String) -> String {
        (liveEntries[name] ?? []).compactMap { if case .liveText(let t) = $0 { return t } else { return nil } }.joined()
    }

    private func liveCoalescedReasoning(for name: String) -> String {
        (liveEntries[name] ?? []).compactMap { if case .liveReasoning(let t) = $0 { return t } else { return nil } }.joined()
    }

    private func appendLiveDelta(for name: String, field: String, delta: String) {
        if name == subworkerName && !liveRunning {
            liveRunning = true
            if liveStartedAt == nil { liveStartedAt = Date() }
        }
        if liveEntries[name] == nil { liveEntries[name] = [] }
        switch field {
        case "reasoning":
            if let last = liveEntries[name]?.last, case .liveReasoning(let cur) = last {
                if delta == cur || cur.hasSuffix(delta) || (cur.contains(delta) && delta.count < 40) {
                    return
                }
                var next: String
                if delta.hasPrefix(cur) { next = delta }
                else if cur.isEmpty { next = delta }
                else if delta.count > 1 && cur.hasSuffix(String(delta.prefix(1))) {
                    next = cur + delta
                } else {
                    if delta.count < cur.count && cur.contains(delta) { return }
                    next = cur + delta
                }
                if next.count > 12000 { next = String(next.suffix(8000)) }
                liveEntries[name]?[liveEntries[name]!.count - 1] = .liveReasoning(next)
            } else {
                let capped = delta.count > 12000 ? String(delta.suffix(8000)) : delta
                liveEntries[name]?.append(.liveReasoning(capped))
            }
        case "tool":
            let parsed: (String, String?, String?) = {
                if let data = delta.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let tool = obj["tool"] as? String ?? "tool"
                    if obj["filePath"] != nil || obj["oldString"] != nil || obj["content"] != nil {
                        return (tool, delta, obj["output"] as? String)
                    }
                    return (tool, obj["input"] as? String, obj["output"] as? String)
                }
                return (delta.isEmpty ? "tool" : delta, nil, nil)
            }()
            if let last = liveEntries[name]?.last, case .liveTool(let ln, let li, let lo) = last,
               ln == parsed.0 && li == parsed.1 && lo == parsed.2 {
                return
            }
            liveEntries[name]?.append(.liveTool(name: parsed.0, input: parsed.1, output: parsed.2))
            if (liveEntries[name]?.count ?? 0) > 40 {
                liveEntries[name] = Array(liveEntries[name]!.suffix(40))
            }
            if parsed.0.lowercased() == "todowrite", name == subworkerName, let todos = parseTodoWritePayload(parsed.1, output: parsed.2) {
                verticalTodos = todos
            }
        default:
            if let last = liveEntries[name]?.last, case .liveText(let cur) = last {
                if delta == cur { return }
                if delta.count < 80 && cur.contains(delta) { return }
                var next: String
                if delta.hasPrefix(cur) { next = delta }
                else if cur.hasSuffix(delta) { return }
                else { next = cur + delta }
                if next.count > 12000 { next = String(next.suffix(8000)) }
                liveEntries[name]?[liveEntries[name]!.count - 1] = .liveText(next)
            } else {
                let capped = delta.count > 12000 ? String(delta.suffix(8000)) : delta
                liveEntries[name]?.append(.liveText(capped))
            }
        }
        if name != liveAgent { liveAgent = name }
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
            self.appendLiveDelta(for: name, field: field, delta: delta)
        }
    }

    private func resetLiveBuffer(for name: String) {
        liveEntries[name] = nil
    }

    private func stopObservingRunLogs() {
        if let obs = runLogObserver {
            NotificationCenter.default.removeObserver(obs)
            runLogObserver = nil
        }
    }

    private func observeRunBanners() {
        bannerObserver = NotificationCenter.default.addObserver(
            forName: SubworkerManager.runBannerNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let name = note.userInfo?["name"] as? String,
                  name == self.subworkerName,
                  let dict = note.userInfo?["banner"] as? [String: Any] else { return }
            let b = RunBanner(
                id: UUID().uuidString,
                type: dict["type"] as? String ?? "reinjection",
                attempt: dict["attempt"] as? Int ?? 1,
                maxAttempts: dict["max_attempts"] as? Int ?? 3,
                delaySeconds: dict["delay_seconds"] as? Double ?? 0,
                error: dict["error"] as? String ?? "",
                timestamp: (dict["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0/1000) } ?? Date(),
                sessionId: dict["session_id"] as? String
            )
            self.banners.append(b)
            if self.banners.count > 20 { self.banners = Array(self.banners.suffix(20)) }
        }
    }

    private func stopObservingRunBanners() {
        if let obs = bannerObserver {
            NotificationCenter.default.removeObserver(obs)
            bannerObserver = nil
        }
    }

    private func bannerFromContinueMessage(id: String, ts: Date?) -> RunBanner {
        RunBanner(id: id, type: "reinjection", attempt: 0, maxAttempts: 3, delaySeconds: 0, error: "Agent didn't finish — system reinjected", timestamp: ts, sessionId: nil)
    }

    // MARK: - Fetch Messages

    private func fetchMessages(sessionId: String, showSpinner: Bool = true) {
        guard let url = URL(string: "\(baseURL)/sessions/\(subworkerName)?session_id=\(sessionId)&limit=\(messageFetchLimit)") else { return }
        if showSpinner { messagesLoading = true }

        URLSession.shared.dataTask(with: EliaAuth.authorize(url)) { data, _, _ in
            DispatchQueue.main.async {
                defer { messagesLoading = false; isLoadingMoreMessages = false }
                // The user may have already navigated to a different session
                // by the time this response lands — applying it now would
                // silently overwrite the correct session's content with a
                // stale one. This was the main cause of the "empty panel /
                // must click 2-3x" symptom: whichever of two in-flight
                // requests happened to finish last used to win unconditionally.
                guard sessionId == self.selectedSessionId else { return }

                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let rawMessages = json["messages"] as? [[String: Any]] else {
                    if messages.isEmpty { messagesError = "Could not load messages" }
                    return
                }

                // Identical payload → keep current views untouched (5s polling).
                // Keyed per-session: two different sessions can legitimately
                // return byte-identical JSON (e.g. both "no messages yet"),
                // and a global fingerprint would wrongly swallow that update,
                // leaving stale content on screen until the fingerprint
                // happened to change via some other session.
                let fingerprint = String(data: data, encoding: .utf8)?.hashValue ?? 0
                if fingerprint == lastMessagesFingerprint[sessionId] && !messages.isEmpty {
                    return
                }
                lastMessagesFingerprint[sessionId] = fingerprint

                var derivedBanners: [RunBanner] = []
                var filtered: [SessionLogEntry] = []
                for (idx, raw) in rawMessages.enumerated() {
                    if let info = raw["info"] as? [String: Any],
                       let parts = raw["parts"] as? [[String: Any]],
                       parts.count == 1, let t = parts.first?["text"] as? String, t == "continue the tasks",
                       (info["role"] as? String) == "user" {
                        let ts: Date? = (info["time"] as? [String: Any])?["created"] as? Double == nil ? nil : {
                            if let c = (info["time"] as? [String: Any])?["created"] as? Double { return Date(timeIntervalSince1970: c/1000) } ; return nil
                        }()
                        let errFromPrev: String = {
                            if idx > 0, let prev = rawMessages[idx-1]["info"] as? [String: Any], let err = prev["error"] as? [String: Any], let d = err["data"] as? [String: Any], let m = d["message"] as? String { return m }
                            return "Agent didn't finish — system reinjected"
                        }()
                        derivedBanners.append(RunBanner(id: "\(sessionId)-banner-\(idx)", type: "reinjection", attempt: 0, maxAttempts: 3, delaySeconds: 0, error: errFromPrev, timestamp: ts, sessionId: sessionId))
                        continue
                    }
                    if let entry = parseMessage(raw, id: "\(sessionId)-\(idx)") {
                        filtered.append(entry)
                    }
                }
                let allParsed = filtered
                messages = allParsed.count > maxMessages ? Array(allParsed.suffix(maxMessages)) : allParsed
                var merged = derivedBanners
                let liveForSession = self.banners.filter { $0.sessionId == sessionId || $0.sessionId == nil }
                for b in liveForSession where !merged.contains(where: { $0.id == b.id }) {
                    merged.append(b)
                }
                for b in self.banners where b.sessionId != nil && b.sessionId != sessionId {
                    if !merged.contains(where: { $0.id == b.id }) { merged.append(b) }
                }
                banners = merged.sorted { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
                messagesError = nil
                var latestTodos: [TodoItem]? = nil
                for raw in rawMessages.reversed() {
                    for part in (raw["parts"] as? [[String: Any]] ?? []) {
                        if (part["tool"] as? String)?.lowercased() == "todowrite" {
                            var todos: [TodoItem]? = nil
                            if let inputDict = part["input"] as? [String: Any], let arr = inputDict["todos"] as? [[String: Any]] {
                                todos = arr.compactMap { d in guard let c = d["content"] as? String, !c.isEmpty else { return nil }; return TodoItem(content: c, status: (d["status"] as? String ?? "pending").lowercased(), priority: (d["priority"] as? String ?? "medium").lowercased()) }
                            } else {
                                let inputStr: String? = {
                                    if let s = part["input"] as? String { return s }
                                    if let obj = part["input"] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: obj) { return String(data: data, encoding: .utf8) }
                                    return nil
                                }()
                                todos = parseTodoWritePayload(inputStr, output: part["output"] as? String)
                            }
                            if let t = todos, !t.isEmpty { latestTodos = t; break }
                        }
                    }
                    if latestTodos != nil { break }
                }
                verticalTodos = latestTodos ?? []
                hasMoreMessages = rawMessages.count >= messageFetchLimit
                isLoadingMoreMessages = false

                selectedSessionChanged = true
            }
        }.resume()
    }

    private func loadMoreMessages() {
        guard !isLoadingMoreMessages, hasMoreMessages, let sid = selectedSessionId else { return }
        isLoadingMoreMessages = true
        messageFetchLimit += 20
        fetchMessages(sessionId: sid, showSpinner: false)
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
