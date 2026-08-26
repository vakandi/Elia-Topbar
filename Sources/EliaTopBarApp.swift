import SwiftUI
import AppKit
import Combine
import ServiceManagement

@main
struct EliaTopBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class SubworkerHoverHandler: NSObject {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    func mouseEntered(with event: NSEvent) {
        onEnter?()
    }

    func mouseExited(with event: NSEvent) {
        onExit?()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var scheduleWindow: NSWindow?
    private var colimaManager: ColimaManager!
    private var subworkerManager: SubworkerManager!
    private var cancellables = Set<AnyCancellable>()
    private var logPopover: NSPopover?
    private var mainMenu: NSMenu?
    private var topbarSettingsWindow: NSWindow?
    /// Hit-test geometry for the merged icon: photos zone + banner zone.
    private var iconPhotosStartX: CGFloat = 0
    private var iconCellWidth: CGFloat = 0
    private var iconPhotoCount: Int = 0
    private var subworkerLogPopover: NSPopover?
    private var subworkerLogPopoverName: String?
    private var tunnelProgressController: TunnelProgressPanelController?
    private var tunnelStatusCache: [String: Any]?
    private var tunnelStatusInFlight = false
    private var tunnelPollTimer: Timer?
    private var previousRunningNames: Set<String> = []
    private var seenFirstSubworkerSnapshot = false

    private func detectNewlyRunningAgents() {
        let running = Set(subworkerManager.subworkers.filter(\.running).map(\.name))
        defer {
            previousRunningNames = running
            seenFirstSubworkerSnapshot = true
        }
        guard seenFirstSubworkerSnapshot else { return }
        let newly = running.subtracting(previousRunningNames)
        guard !newly.isEmpty, let buttonWindow = statusItem.button?.window else { return }
        let dropX = buttonWindow.frame.midX
        let duration = UserDefaults.standard.object(forKey: "runPopupDuration") as? Double ?? 10
        for name in newly.sorted() {
            RunPopupController.shared.show(for: name, dropX: dropX, duration: duration)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        colimaManager = ColimaManager()
        subworkerManager = SubworkerManager()

        // Restore persisted server URL
        if let savedURL = UserDefaults.standard.string(forKey: "subworkerServerURL") {
            subworkerManager.updateBaseURL(savedURL)
        }
        subworkerManager.start()

        setupStatusItem()
        setupMenu()

        Publishers.MergeMany(
            colimaManager.$instances.map { _ in () }.eraseToAnyPublisher(),
            colimaManager.$loadState.map { _ in () }.eraseToAnyPublisher(),
            colimaManager.$actionError.map { _ in () }.eraseToAnyPublisher(),
            subworkerManager.$wsConnected.map { _ in () }.eraseToAnyPublisher(),
            subworkerManager.$runningCount.map { _ in () }.eraseToAnyPublisher(),
            subworkerManager.$wsError.map { _ in () }.eraseToAnyPublisher(),
            subworkerManager.$lastError.map { _ in () }.eraseToAnyPublisher(),
            subworkerManager.$subworkers.map { _ in () }.eraseToAnyPublisher(),
            subworkerManager.$serverHealth.map { _ in () }.eraseToAnyPublisher(),
            subworkerManager.$isLoading.map { _ in () }.eraseToAnyPublisher(),
            subworkerManager.$statusError.map { _ in () }.eraseToAnyPublisher()
        )
        .sink { [weak self] _ in
            guard let self else { return }
            self.updateStatusIcon()
            self.setupMenu()
            self.reconcileSubworkerStatusItems()
        }
        .store(in: &cancellables)

        // Cloudflare tunnel status — keep the menu line fresh (30s cadence).
        refreshTunnelStatus()
        tunnelPollTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.refreshTunnelStatus()
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(mainItemClicked(_:))
            button.sendAction(on: [.leftMouseUp])
        }
        startIconPulseObserver()
        updateStatusIcon()
    }

    // MARK: - Dynamic Icon

    private static let runningBannerIcon: NSImage? = {
        guard let path = Bundle.main.path(forResource: "icon_running_topbar", ofType: "png"),
              let image = NSImage(contentsOfFile: path) else { return nil }
        image.isTemplate = false
        return image
    }()

    private static let serverDownBannerIcon: NSImage? = {
        guard let path = Bundle.main.path(forResource: "icon_not_running_server", ofType: "png"),
              let image = NSImage(contentsOfFile: path) else { return nil }
        image.isTemplate = false
        return image
    }()

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }

        let hasRunning = colimaManager.hasRunningInstance
        let hasTransitioning = colimaManager.instances.contains { $0.status.isTransitioning }

        let swDisconnected = !subworkerManager.wsConnected
        let swHasError = subworkerManager.hasError
        let swRunning = subworkerManager.runningCount

        let barHeight = max(NSStatusBar.system.thickness, 20)
        let runningNames = subworkerManager.sortedRunningNames()

        if swDisconnected || swHasError {
            let symbolName = swDisconnected ? "circle.slash" : "exclamationmark.circle"
            let config = NSImage.SymbolConfiguration(pointSize: barHeight * 0.58, weight: .medium)
            guard let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return }
            button.image = tintedSymbol(baseImage, color: .systemRed)
            iconPhotoCount = 0
            return
        }

        // Elia system healthy → custom brain banner instead of the docker box.
        if subworkerManager.serverHealth?.healthStatus == "healthy",
           let banner = Self.runningBannerIcon?.copy() as? NSImage {
            banner.size = NSSize(width: barHeight * 0.92, height: barHeight * 0.92)
            var base: NSImage
            if swRunning > 0 {
                base = badgeImage(base: banner, count: swRunning, barHeight: barHeight)
            } else {
                base = banner
            }
            if !runningNames.isEmpty {
                base = appendFleetPhotos(to: base, names: runningNames, barHeight: barHeight)
            }
            button.image = base
            return
        }

        // Docker up but OpenCode server unreachable → red X banner.
        if hasRunning, let xBanner = Self.serverDownBannerIcon?.copy() as? NSImage {
            xBanner.size = NSSize(width: barHeight * 0.92, height: barHeight * 0.92)
            button.image = xBanner
            iconPhotoCount = 0
            return
        }

        let symbolName: String
        let tintColor: NSColor
        var badgeCount: Int?

        if swRunning > 0 {
            symbolName = "circle.fill"
            tintColor = .systemGreen
            badgeCount = swRunning
        } else if hasTransitioning {
            symbolName = "shippingbox.and.arrow.backward.fill"
            tintColor = .labelColor
        } else if hasRunning {
            symbolName = "shippingbox.fill"
            tintColor = .labelColor
        } else {
            symbolName = "circle"
            tintColor = .systemGray
        }

        let glyphSize = barHeight * 0.58
        let config = NSImage.SymbolConfiguration(pointSize: glyphSize, weight: .medium)
        guard let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }

        let tinted = tintedSymbol(baseImage, color: tintColor)

        if let count = badgeCount {
            var composed = badgeImage(base: tinted, count: count, barHeight: barHeight)
            if !runningNames.isEmpty {
                composed = appendFleetPhotos(to: composed, names: runningNames, barHeight: barHeight)
            }
            button.image = composed
        } else {
            tinted.isTemplate = (tintColor == .labelColor)
            button.image = tinted
            iconPhotoCount = 0
        }
    }

    private func tintedSymbol(_ image: NSImage, color: NSColor) -> NSImage {
        let tinted = image.copy() as! NSImage
        tinted.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.isTemplate = false
        return tinted
    }

    private func badgeImage(base: NSImage, count: Int, barHeight: CGFloat) -> NSImage {
        let badgeFont = NSFont.systemFont(ofSize: barHeight * 0.40, weight: .bold)
        let text = "\(count)"
        let textSize = text.size(withAttributes: [.font: badgeFont])
        let width = base.size.width + 3 + textSize.width
        let image = NSImage(size: NSSize(width: width, height: barHeight), flipped: false) { rect in
            let baseRect = NSRect(
                x: 0,
                y: (rect.height - base.size.height) / 2,
                width: base.size.width,
                height: base.size.height
            )
            base.draw(in: baseRect)
            let textRect = NSRect(
                x: base.size.width + 3,
                y: (rect.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            text.draw(at: textRect.origin, withAttributes: [.font: badgeFont, .foregroundColor: NSColor.labelColor])
            return true
        }
        return image
    }

    // MARK: - Menu Construction

    private func setupMenu() {
        let menu = NSMenu()

        if let actionError = colimaManager.actionError {
            let errorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            errorItem.attributedTitle = emojiAwareTitle("⚠ \(actionError)", color: .secondaryLabelColor)
            errorItem.isEnabled = false
            menu.addItem(errorItem)
            menu.addItem(NSMenuItem.separator())
        }

        switch colimaManager.loadState {
        case .loading where colimaManager.instances.isEmpty:
            let loadingItem = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
            loadingItem.isEnabled = false
            menu.addItem(loadingItem)
        case .error(let message):
            let errorItem = NSMenuItem(title: message, action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        case .loaded, .loading:
            addInstanceItems(to: menu)
        }

        addManualRunSubworkerItem(to: menu)

        // ── Subworker Server ──
        addSubworkerServerSection(to: menu)

        // ── Active Agents ──
        addSubworkerItems(to: menu)

        menu.addItem(NSMenuItem.separator())

        // Refresh
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshStatus), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        // Server URL preference
        addServerURLMenuItems(to: menu)

        // Remote domain via Cloudflare Tunnel — requires local network
        addTunnelMenuItems(to: menu)

        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = launchAtLoginEnabled ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(NSMenuItem.separator())

        // Topbar settings
        let settingsItem = NSMenuItem(title: "⚙️ Topbar Settings…", action: #selector(openTopbarSettings(_:)), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Quit
        let quitItem = NSMenuItem(title: "Quit EliaTopBar", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        mainMenu = menu
    }

    // MARK: - Subworker Server Section

    private func addSubworkerServerSection(to menu: NSMenu) {
        menu.addItem(NSMenuItem.separator())

        let headerEmoji: String
        if subworkerManager.wsConnected && subworkerManager.runningCount > 0 && !subworkerManager.hasError {
            headerEmoji = "🚀"
        } else if subworkerManager.wsConnected {
            headerEmoji = "●"
        } else {
            headerEmoji = "🔴"
        }
        let headerItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        headerItem.attributedTitle = emojiAwareTitle("\(headerEmoji) Subworker Server", color: .secondaryLabelColor)
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        let statusText: String
        if subworkerManager.isLoading {
            statusText = "  Connecting…"
        } else if subworkerManager.wsConnected {
            statusText = "  Connected │ \(subworkerManager.runningCount) running / \(subworkerManager.totalEnabled)"
        } else {
            statusText = "  Disconnected"
        }
        let statusItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        if subworkerManager.isLoading {
            menu.addItem(loadingMenuItem(text: "Loading status…"))
        } else if let statusError = subworkerManager.statusError {
            menu.addItem(errorMenuItem(text: "Error: \(statusError)"))
        }

        if let health = subworkerManager.serverHealth {
            let stateEmoji = health.healthStatus == "healthy" ? "✅" : "❌"
            var healthText = "  \(stateEmoji) Server: \(health.healthStatus)"
            if let pid = health.pid {
                healthText += " (PID \(pid))"
            }
            let healthItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            healthItem.attributedTitle = emojiAwareTitle(healthText, color: .secondaryLabelColor)
            healthItem.isEnabled = false
            menu.addItem(healthItem)
        } else if !subworkerManager.isLoading {
            let noHealthItem = NSMenuItem(title: "  Server health unavailable", action: nil, keyEquivalent: "")
            noHealthItem.isEnabled = false
            menu.addItem(noHealthItem)
        }

        if let error = subworkerManager.lastError {
            let errorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            errorItem.attributedTitle = emojiAwareTitle("  ⚠ Last: \(error)", color: .secondaryLabelColor)
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        }

        if !subworkerManager.wsConnected {
            let reconnectItem = NSMenuItem(title: "", action: #selector(reconnectServer), keyEquivalent: "")
            reconnectItem.attributedTitle = emojiAwareTitle("🔄 Reconnect", color: .labelColor)
            reconnectItem.target = self
            menu.addItem(reconnectItem)
        }
    }

    // MARK: - Subworker List

    private func addSubworkerItems(to menu: NSMenu) {
        menu.addItem(NSMenuItem.separator())

        if subworkerManager.isLoading {
            let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            header.attributedTitle = emojiAwareTitle("🤖 Active Agents", color: .secondaryLabelColor)
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(loadingMenuItem(text: "Loading subworkers…"))
            return
        }
        if let statusError = subworkerManager.statusError {
            let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            header.attributedTitle = emojiAwareTitle("🤖 Active Agents", color: .secondaryLabelColor)
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(errorMenuItem(text: "Error: \(statusError)"))
            return
        }
        guard !subworkerManager.subworkers.isEmpty else {
            let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            header.attributedTitle = emojiAwareTitle("🤖 Active Agents", color: .secondaryLabelColor)
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(disabledItem("No subworkers"))
            return
        }

        let now = Date()
        // Most recent session first, in both lists.
        let active = subworkerManager.subworkers
            .filter { $0.enabled }
            .sorted { subworkerManager.recency($0.name) > subworkerManager.recency($1.name) }
        let inactive = subworkerManager.subworkers
            .filter { !$0.enabled }
            .sorted { subworkerManager.recency($0.name) > subworkerManager.recency($1.name) }

        if !active.isEmpty {
            let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            header.attributedTitle = emojiAwareTitle("🤖 Active Agents (\(active.count))", color: .secondaryLabelColor)
            header.isEnabled = false
            menu.addItem(header)

            for sw in active {
                menu.addItem(buildSubworkerMenuItem(for: sw, now: now))
            }
        }

        if !inactive.isEmpty {
            menu.addItem(NSMenuItem.separator())
            let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            header.attributedTitle = emojiAwareTitle("💤 Inactive Agents (\(inactive.count))", color: .secondaryLabelColor)
            header.isEnabled = false
            menu.addItem(header)

            for sw in inactive {
                menu.addItem(buildSubworkerMenuItem(for: sw, now: now))
            }
        }
    }

    private func buildSubworkerMenuItem(for sw: SubworkerInfo, now: Date) -> NSMenuItem {
        let instanceMenu = buildSubworkerSubmenu(for: sw)

        let dot: String
        let color: NSColor
        if sw.lastError != nil {
            dot = "💥"; color = .systemRed
        } else if sw.running {
            dot = "⚡"; color = .systemGreen
        } else if sw.enabled {
            dot = "●"; color = .systemGreen.withAlphaComponent(0.5)
        } else {
            dot = "○"; color = .systemGray
        }

        let justCompletedDocs = sw.name.lowercased().contains("doc")
            && sw.lastCompleted != nil
            && now.timeIntervalSince(sw.lastCompleted!) < 120
        let justCompletedAny = sw.lastCompleted != nil
            && now.timeIntervalSince(sw.lastCompleted!) < 120

        let isMain = sw.name == subworkerManager.mainAgentName

        let statusText: String
        if sw.lastError != nil {
            statusText = "Error"
        } else if justCompletedDocs {
            statusText = "📝 Done"
        } else if sw.running {
            statusText = "Running"
        } else if justCompletedAny {
            statusText = "✅ Done"
        } else if sw.enabled {
            statusText = "Idle"
        } else {
            statusText = "Disabled"
        }

        let displayName = isMain ? "\(sw.name) ★" : sw.name
        let nextCountdown = sw.enabled
            ? SubworkerManager.countdownLabel(until: subworkerManager.nextRunDate(for: sw, now: now), now: now)
            : nil
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = buildAttributedItem(
            dot: dot,
            name: displayName,
            status: statusText,
            color: color,
            badge: nextCountdown.map { "⏱ \($0)" }
        )
        item.submenu = instanceMenu

        if let photo = ProfilePhotos.shared.circularPhoto(for: sw.name, size: 16) {
            item.image = photo
        }

        return item
    }

    private func buildSubworkerSubmenu(for sw: SubworkerInfo) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        if let photo = ProfilePhotos.shared.circularPhoto(for: sw.name, size: 120) {
            let containerWidth: CGFloat = 240
            let container = NSView(frame: NSRect(x: 0, y: 0, width: containerWidth, height: 120))
            let photoView = NSImageView(image: photo)
            photoView.frame = NSRect(x: (containerWidth - 120) / 2, y: 0, width: 120, height: 120)
            photoView.imageScaling = .scaleProportionallyUpOrDown
            photoView.autoresizingMask = [.minXMargin, .maxXMargin]
            container.addSubview(photoView)
            let photoItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            photoItem.view = container
            submenu.addItem(photoItem)
            submenu.addItem(NSMenuItem.separator())
        }

        let statusEmoji = sw.running ? "⚡" : (sw.enabled ? "⏸️" : "⛔")
        let statusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusItem.attributedTitle = emojiAwareTitle("Status: \(statusEmoji) \(sw.running ? "Running" : (sw.enabled ? "Idle" : "Disabled"))", color: .secondaryLabelColor)
        statusItem.isEnabled = false
        submenu.addItem(statusItem)

        // ── Main Agent ──
        if sw.name == subworkerManager.mainAgentName {
            let mainItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            mainItem.attributedTitle = emojiAwareTitle("★ MAIN AGENT — workspace: ~/EliaAI", color: .systemYellow)
            mainItem.isEnabled = false
            submenu.addItem(mainItem)

            let unsetItem = NSMenuItem(title: "", action: #selector(toggleMainAgent(_:)), keyEquivalent: "")
            unsetItem.attributedTitle = emojiAwareTitle("✕ Unset as Main Agent (fallback: elia)", color: .labelColor)
            unsetItem.target = self
            unsetItem.representedObject = ["name": sw.name, "action": "unset"]
            submenu.addItem(unsetItem)
        } else {
            let setItem = NSMenuItem(title: "", action: #selector(toggleMainAgent(_:)), keyEquivalent: "")
            setItem.attributedTitle = emojiAwareTitle("★ Set as Main Agent (workspace: ~/EliaAI)", color: .labelColor)
            setItem.target = self
            setItem.representedObject = ["name": sw.name, "action": "set"]
            submenu.addItem(setItem)
        }

        if let nextDate = subworkerManager.nextRunDate(for: sw) {
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "EEE HH:mm"
            let countdown = SubworkerManager.countdownLabel(until: nextDate)
            let when = countdown == "due" ? "due now" : "in \(countdown ?? "?")"
            let nextItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            nextItem.attributedTitle = emojiAwareTitle("🕐 Next Run: \(timeFormatter.string(from: nextDate)) (\(when))", color: .secondaryLabelColor)
            nextItem.isEnabled = false
            submenu.addItem(nextItem)
        }

        if let schedule = sw.scheduleType {
            let schedItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            schedItem.attributedTitle = emojiAwareTitle("📅 Schedule: \(schedule)", color: .secondaryLabelColor)
            schedItem.isEnabled = false
            submenu.addItem(schedItem)
        }

        let editSchedItem = NSMenuItem(title: "", action: #selector(openScheduleEditor(_:)), keyEquivalent: "")
        editSchedItem.attributedTitle = emojiAwareTitle("🗓 Edit Schedule…", color: .labelColor)
        editSchedItem.target = self
        editSchedItem.representedObject = sw.name
        submenu.addItem(editSchedItem)

        if let error = sw.lastError {
            let errItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            errItem.attributedTitle = emojiAwareTitle("❌ Error: \(error)", color: .secondaryLabelColor)
            errItem.isEnabled = false
            submenu.addItem(errItem)
        }

        if let completed = sw.lastCompleted {
            let elapsed = Date().timeIntervalSince(completed)
            let timeAgo = elapsed < 60 ? "\(Int(elapsed))s ago" : "\(Int(elapsed / 60))m ago"
            let completedItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            completedItem.attributedTitle = emojiAwareTitle("✅ Last Run: \(timeAgo)", color: .secondaryLabelColor)
            completedItem.isEnabled = false
            submenu.addItem(completedItem)
        }

        submenu.addItem(NSMenuItem.separator())

        let logItem = NSMenuItem(title: "", action: #selector(showLogs(_:)), keyEquivalent: "")
        logItem.attributedTitle = emojiAwareTitle("📋 View Logs…", color: .labelColor)
        logItem.target = self
        logItem.representedObject = sw.name
        submenu.addItem(logItem)

        let triggerItem = NSMenuItem(title: "", action: #selector(triggerSubworker(_:)), keyEquivalent: "")
        triggerItem.attributedTitle = emojiAwareTitle("⚡ Trigger Now", color: .labelColor)
        triggerItem.target = self
        triggerItem.representedObject = sw.name
        submenu.addItem(triggerItem)

        submenu.addItem(NSMenuItem.separator())

        if sw.enabled {
            let disableItem = NSMenuItem(title: "", action: #selector(disableSubworker(_:)), keyEquivalent: "")
            disableItem.attributedTitle = emojiAwareTitle("⏸️ Disable", color: .labelColor)
            disableItem.target = self
            disableItem.representedObject = sw.name
            submenu.addItem(disableItem)
        } else {
            let enableItem = NSMenuItem(title: "", action: #selector(enableSubworker(_:)), keyEquivalent: "")
            enableItem.attributedTitle = emojiAwareTitle("▶️ Enable", color: .labelColor)
            enableItem.target = self
            enableItem.representedObject = sw.name
            submenu.addItem(enableItem)
        }

        // ── Model ──
        submenu.addItem(NSMenuItem.separator())

        let currentModel = subworkerManager.currentModel(for: sw.name)
        let currentVariant = subworkerManager.currentVariant(for: sw.name)
        var modelLabel = SubworkerModels.displayName(for: currentModel)
        if !currentVariant.isEmpty { modelLabel += " (\(currentVariant))" }
        let modelHeader = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        modelHeader.attributedTitle = emojiAwareTitle("🧠 Model: \(modelLabel)", color: .secondaryLabelColor)
        modelHeader.isEnabled = false
        submenu.addItem(modelHeader)

        // Options populate lazily via NSMenuDelegate (catalog has 500+ entries).
        let modelSubmenu = NSMenu()
        modelSubmenu.autoenablesItems = false
        modelSubmenu.delegate = self
        modelSubmenu.identifier = NSUserInterfaceItemIdentifier(sw.name)
        let modelItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        modelItem.attributedTitle = emojiAwareTitle("🧠 Change Model…", color: .labelColor)
        modelItem.submenu = modelSubmenu
        submenu.addItem(modelItem)

        // ── Profile Photo ──
        submenu.addItem(NSMenuItem.separator())

        let hasPhoto = ProfilePhotos.shared.hasPhoto(for: sw.name)
        if hasPhoto {
            let removePhotoItem = NSMenuItem(title: "", action: #selector(removeProfilePhoto(_:)), keyEquivalent: "")
            removePhotoItem.attributedTitle = emojiAwareTitle("🗑 Remove Profile Photo", color: .systemRed)
            removePhotoItem.target = self
            removePhotoItem.representedObject = sw.name
            submenu.addItem(removePhotoItem)
        }

        let setPhotoItem = NSMenuItem(title: "", action: #selector(setProfilePhoto(_:)), keyEquivalent: "")
        setPhotoItem.attributedTitle = emojiAwareTitle(hasPhoto ? "📷 Change Profile Photo…" : "📷 Set Profile Photo…", color: .labelColor)
        setPhotoItem.target = self
        setPhotoItem.representedObject = sw.name
        submenu.addItem(setPhotoItem)

        return submenu
    }

    private func buildAttributedItem(dot: String, name: String, status: String, color: NSColor, badge: String? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let dotIsEmoji = !(dot == "●" || dot == "○")
        result.append(NSAttributedString(string: "\(dot) ", attributes: [
            .foregroundColor: color,
            .font: dotIsEmoji ? NSFont.systemFont(ofSize: 10) : NSFont.menuFont(ofSize: 0)
        ]))

        // Name (truncated)
        let displayName = name.count > 22 ? String(name.prefix(20)) + "…" : name
        result.append(NSAttributedString(string: displayName, attributes: [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.menuFont(ofSize: 0)
        ]))

        // Right-aligned status with tab
        let statusAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.menuFont(ofSize: 0)
        ]
        let padding = String(repeating: " ", count: max(1, 24 - displayName.count))
        result.append(NSAttributedString(string: "\(padding)\(status)", attributes: statusAttrs))

        if let badge {
            let badgePad = String(repeating: " ", count: max(1, 10 - status.count))
            result.append(NSAttributedString(string: "\(badgePad)\(badge)", attributes: [
                .foregroundColor: NSColor.systemTeal,
                .font: NSFont.menuFont(ofSize: 0)
            ]))
        }

        return result
    }

    private func emojiAwareTitle(_ text: String, emojiSize: CGFloat = 10, color: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let plainFont = NSFont.menuFont(ofSize: 0)
        let emojiFont = NSFont.systemFont(ofSize: emojiSize)

        for character in text {
            let isEmoji = character.unicodeScalars.first?.properties.isEmoji ?? false
            result.append(NSAttributedString(string: String(character), attributes: [
                .foregroundColor: color,
                .font: isEmoji ? emojiFont : plainFont
            ]))
        }
        return result
    }

    // MARK: - Log Popover

    @objc private func showLogs(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 500, height: 400)
        popover.behavior = .transient

        let logView = LogPopoverView(subworkerName: name, baseURL: subworkerManager.currentBaseURL)
        popover.contentViewController = NSHostingController(rootView: logView)

        logPopover = popover
        if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    /// Draw running-agent photos flush against the LEFT edge; banner sits right.
    private func appendFleetPhotos(to base: NSImage, names: [String], barHeight: CGFloat) -> NSImage {
        let cell = barHeight - 2
        let gap: CGFloat = 1
        let badges: [(photo: NSImage?, monogram: String, color: NSColor)] = names.map { name in
            let sw = subworkerManager.subworkers.first(where: { $0.name == name })
            let color = sw.map { subworkerColor(for: $0) } ?? .systemGreen
            return (ProfilePhotos.shared.circularPhoto(for: name, size: 24),
                    monogram(for: name),
                    color)
        }
        iconCellWidth = cell
        let side = UserDefaults.standard.string(forKey: "fleetPhotosSide") ?? "left"
        let storedPad = UserDefaults.standard.object(forKey: "fleetLeftPad") as? Double
        let pad: CGFloat = CGFloat(storedPad ?? 3)
        let fleetWidth = pad + CGFloat(names.count) * cell + gap
        if side == "right" {
            iconPhotosStartX = base.size.width + pad
        } else {
            iconPhotosStartX = pad
        }
        iconPhotoCount = names.count

        let total: CGFloat = side == "right"
            ? iconPhotosStartX + CGFloat(names.count) * cell
            : fleetWidth + base.size.width
        let composed = NSImage(size: NSSize(width: total, height: max(base.size.height, barHeight)))
        composed.lockFocus()
        for (i, badge) in badges.enumerated() {
            let rect = NSRect(x: iconPhotosStartX + CGFloat(i) * cell, y: 0, width: cell, height: barHeight)
            let diameter = rect.height * 0.86
            let dotRect = NSRect(x: rect.midX - diameter / 2,
                                 y: (rect.height - diameter) / 2,
                                 width: diameter,
                                 height: diameter)
            badge.color.setFill()
            NSBezierPath(ovalIn: dotRect).fill()

            NSGraphicsContext.saveGraphicsState()
            let photoRect = dotRect.insetBy(dx: 1, dy: 1)
            NSBezierPath(ovalIn: photoRect).addClip()
            if let photo = badge.photo {
                let scale = max(photoRect.width / photo.size.width, photoRect.height / photo.size.height)
                photo.draw(in: NSRect(
                    x: photoRect.midX - photo.size.width * scale / 2,
                    y: photoRect.midY - photo.size.height * scale / 2,
                    width: photo.size.width * scale,
                    height: photo.size.height * scale
                ), from: .zero, operation: .sourceOver, fraction: 1.0)
            } else {
                let font = NSFont.systemFont(ofSize: diameter * 0.4, weight: .bold)
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
                let str = NSAttributedString(string: badge.monogram, attributes: attrs)
                let tsz = str.size()
                str.draw(at: NSPoint(x: dotRect.midX - tsz.width / 2, y: dotRect.midY - tsz.height / 2))
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        let baseX: CGFloat = side == "right" ? 0 : fleetWidth
        base.draw(at: NSPoint(x: baseX, y: (barHeight - base.size.height) / 2),
                  from: .zero, operation: .sourceOver, fraction: 1.0)
        composed.unlockFocus()
        return composed
    }

    /// Click zones: agent photo (left) → that agent's live log; banner (right) → main menu.
    @objc private func mainItemClicked(_ sender: NSStatusBarButton) {
        let mouse = NSApp.currentEvent?.locationInWindow ?? sender.bounds.origin
        let point = sender.convert(mouse, from: nil)

        if iconPhotoCount > 0, point.x >= iconPhotosStartX,
           point.x < iconPhotosStartX + CGFloat(iconPhotoCount) * iconCellWidth {
            let idx = min(max(Int((point.x - iconPhotosStartX) / iconCellWidth), 0), iconPhotoCount - 1)
            let names = subworkerManager.sortedRunningNames()
            guard idx < names.count else { return }
            let name = names[idx]

            if let popover = subworkerLogPopover,
               subworkerLogPopoverName == name,
               popover.isShown {
                popover.performClose(nil)
                subworkerLogPopover = nil
                subworkerLogPopoverName = nil
                return
            }
            showSubworkerLogPopover(for: name, button: sender)
            return
        }

        if let menu = mainMenu {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: sender)
        }
    }

    private func reconcileSubworkerStatusItems() {
        let names = subworkerManager.subworkers.filter(\.running).map(\.name)

        if let shown = subworkerLogPopoverName, !names.contains(shown) {
            subworkerLogPopover?.performClose(nil)
            subworkerLogPopover = nil
            subworkerLogPopoverName = nil
        }
        updateStatusIcon()
    }

    private func subworkerIconWithBorder(photo: NSImage, color: NSColor) -> NSImage {
        let barHeight = max(NSStatusBar.system.thickness, 20)
        let size = NSSize(width: barHeight, height: barHeight)
        let diameter = barHeight * 0.98
        return NSImage(size: size, flipped: false) { rect in
            let dotRect = NSRect(
                x: (rect.width - diameter) / 2,
                y: (rect.height - diameter) / 2,
                width: diameter,
                height: diameter
            )
            color.setFill()
            NSBezierPath(ovalIn: dotRect).fill()

            let photoInset: CGFloat = 1
            let photoRect = dotRect.insetBy(dx: photoInset, dy: photoInset)
            let clipPath = NSBezierPath(ovalIn: photoRect)
            clipPath.addClip()

            let imageSize = photo.size
            let scaleW = photoRect.width / imageSize.width
            let scaleH = photoRect.height / imageSize.height
            let scale = max(scaleW, scaleH)
            let drawW = imageSize.width * scale
            let drawH = imageSize.height * scale
            let drawRect = NSRect(
                x: photoRect.midX - drawW / 2,
                y: photoRect.midY - drawH / 2,
                width: drawW,
                height: drawH
            )
            photo.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            return true
        }
    }

    private func subworkerColor(for sw: SubworkerInfo) -> NSColor {
        sw.lastError != nil ? .systemRed : .systemGreen
    }

    private func monogram(for name: String) -> String {
        let parts = name.split(separator: "-").map(String.init)
        let initials = parts.prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
        if initials.count == 2 { return initials }
        let firstWord = parts.first ?? name
        return String(firstWord.prefix(2)).uppercased()
    }

    private func subworkerIcon(monogram: String, color: NSColor) -> NSImage {
        let barHeight = max(NSStatusBar.system.thickness, 20)
        let size = NSSize(width: barHeight, height: barHeight)
        return NSImage(size: size, flipped: false) { rect in
            let diameter = rect.height * 0.98
            let dotRect = NSRect(
                x: (rect.width - diameter) / 2,
                y: (rect.height - diameter) / 2,
                width: diameter,
                height: diameter
            )
            color.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            let font = NSFont.systemFont(ofSize: diameter * 0.44, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white
            ]
            let textSize = monogram.size(withAttributes: attrs)
            monogram.draw(
                at: NSPoint(x: dotRect.midX - textSize.width / 2, y: dotRect.midY - textSize.height / 2),
                withAttributes: attrs
            )
            return true
        }
    }

    private func showSubworkerLogPopover(for name: String, button: NSButton?) {
        guard let button else { return }
        if let popover = subworkerLogPopover {
            if subworkerLogPopoverName == name && popover.isShown {
                return
            }
            popover.performClose(nil)
            subworkerLogPopover = nil
            subworkerLogPopoverName = nil
        }
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 520, height: 400)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: LogPopoverView(subworkerName: name, baseURL: subworkerManager.currentBaseURL)
        )
        subworkerLogPopover = popover
        subworkerLogPopoverName = name
        // A transient popover shown while another app is frontmost closes
        // immediately — activate our app first.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // NSPopover does not clamp itself — icon next to Wi-Fi overflows the screen.
        if let win = popover.contentViewController?.view.window,
           let screen = win.screen ?? NSScreen.main {
            let margin: CGFloat = 8
            var frame = win.frame
            if frame.maxX > screen.visibleFrame.maxX - margin {
                frame.origin.x = screen.visibleFrame.maxX - margin - frame.width
            }
            if frame.minX < screen.visibleFrame.minX + margin {
                frame.origin.x = screen.visibleFrame.minX + margin
            }
            if frame != win.frame {
                win.setFrame(frame, display: true)
            }
        }
    }

    // MARK: - Subworker Actions

    @objc private func triggerSubworker(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        subworkerManager.triggerSubworker(name)
    }

    @objc private func enableSubworker(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        subworkerManager.enableSubworker(name)
    }

    @objc private func disableSubworker(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        subworkerManager.disableSubworker(name)
    }

    @objc private func setSubworkerModel(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let name = info["name"],
              let modelID = info["model"] else { return }
        let variant = info["variant"] ?? ""
        subworkerManager.setModel(modelID, variant: variant, for: name)
        setupMenu()
    }

    @objc private func toggleMainAgent(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let name = info["name"],
              let action = info["action"] else { return }
        if action == "set" {
            subworkerManager.setMainAgent(name)
        } else {
            subworkerManager.setMainAgent("elia")
        }
        setupMenu()
    }

    @objc private func reconnectServer() {
        subworkerManager.start()
    }

    @objc private func setProfilePhoto(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }

        let panel = NSOpenPanel()
        panel.title = "Profile Photo for \(name)"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        if ProfilePhotos.shared.setPhoto(for: name, sourceURL: url) {
            updateStatusIcon()
            reconcileSubworkerStatusItems()
            setupMenu()
        }
    }

    @objc private func removeProfilePhoto(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        ProfilePhotos.shared.removePhoto(for: name)
        updateStatusIcon()
        reconcileSubworkerStatusItems()
        setupMenu()
    }

    @objc private func openScheduleEditor(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let rootView = SchedulePopoverView(
            agentName: name,
            manager: subworkerManager,
            onClose: { [weak self] in self?.scheduleWindow?.close() }
        )
        if let window = scheduleWindow {
            window.title = "Schedule — \(name)"
            window.contentView = NSHostingView(rootView: rootView)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 348, height: 520),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Schedule — \(name)"
        window.contentView = NSHostingView(rootView: rootView)
        window.center()
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        scheduleWindow = window
    }

    @objc private func openTopbarSettings(_ sender: NSMenuItem) {
        if let w = topbarSettingsWindow { w.close() }
        let contentView = NSHostingView(rootView: TopbarSettingsView(
            iconProvider: { [weak self] in self?.statusItem.button?.image },
            onRefresh: { [weak self] in
                self?.updateStatusIcon()
                self?.setupMenu()
            },
            onTestRunPopup: { [weak self] in
                guard let self else { return }
                let dropX = self.statusItem.button?.window?.frame.midX
                    ?? (NSScreen.main?.frame.midX ?? 400)
                let name = self.subworkerManager.subworkers.first?.name ?? "test-agent"
                let stored = UserDefaults.standard.object(forKey: "runPopupDuration") as? Double ?? 10
                RunPopupController.shared.show(for: name, dropX: dropX, duration: stored == 0 ? 10 : stored)
            },
            onOrderChange: { [weak self] mode in
                self?.subworkerManager.fleetOrderMode = mode
                self?.updateStatusIcon()
            }
        ))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 460, height: 380)
        window.isReleasedWhenClosed = false
        window.title = "Topbar Settings"
        window.contentView = contentView
        window.center()
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        topbarSettingsWindow = window
    }

    private func startIconPulseObserver() {
        NotificationCenter.default.addObserver(forName: .eliaPulseMainIcon, object: nil, queue: .main) { [weak self] _ in
            guard let button = self?.statusItem.button else { return }
            var delay = 0.0
            for _ in 0..<4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { button.alphaValue = 0.15 }
                delay += 0.25
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { button.alphaValue = 1.0 }
                delay += 0.25
            }
        }
    }

    // MARK: - Server URL Preference

    private func addServerURLMenuItems(to menu: NSMenu) {
        let currentURL = UserDefaults.standard.string(forKey: "subworkerServerURL") ?? "http://localhost:5656"
        let urlDisplayItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        urlDisplayItem.attributedTitle = emojiAwareTitle("🔗 Server: \(currentURL)", color: .secondaryLabelColor)
        urlDisplayItem.isEnabled = false
        menu.addItem(urlDisplayItem)

        let urlItem = NSMenuItem(title: "", action: #selector(changeServerURL), keyEquivalent: "")
        urlItem.attributedTitle = emojiAwareTitle("🔗 Change Server URL…", color: .labelColor)
        urlItem.target = self
        menu.addItem(urlItem)

        let authItem = NSMenuItem(title: "", action: #selector(setAuthToken), keyEquivalent: "")
        let hasCustomToken = !(UserDefaults.standard.string(forKey: "eliaAuthToken") ?? "").isEmpty
        authItem.attributedTitle = emojiAwareTitle(hasCustomToken ? "🔑 Auth Token: custom" : "🔑 Auth Token: default", color: .secondaryLabelColor)
        authItem.target = self
        menu.addItem(authItem)
    }

    @objc private func setAuthToken() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Auth Token"
        alert.informativeText = "Leave empty to use the built-in default token."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: UserDefaults.standard.string(forKey: "eliaAuthToken") ?? "")
        field.placeholderString = "ELIA_AUTH_TOKEN"
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        UserDefaults.standard.set(field.stringValue.trimmingCharacters(in: .whitespaces), forKey: "eliaAuthToken")
        subworkerManager.updateBaseURL(subworkerManager.currentBaseURL)
    }

    @objc private func changeServerURL() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Subworker Server URL"
        alert.informativeText = "Enter the FastAPI server base URL."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(string: UserDefaults.standard.string(forKey: "subworkerServerURL") ?? "http://localhost:5656")
        field.placeholderString = "http://localhost:5656"
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let url = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }

        UserDefaults.standard.set(url, forKey: "subworkerServerURL")
        subworkerManager.updateBaseURL(url)
    }

    private func addTunnelMenuItems(to menu: NSMenu) {
        let current = UserDefaults.standard.string(forKey: "tunnelDomain") ?? ""
        let title = current.isEmpty ? "🌐 Setup Remote Domain…" : "🌐 Remote Domain: \(current)"
        let domainItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        domainItem.attributedTitle = emojiAwareTitle(title, color: .secondaryLabelColor)
        domainItem.isEnabled = false
        menu.addItem(domainItem)
        if !current.isEmpty {
            menu.addItem(tunnelStatusMenuItem())
        }
        let setupItem = NSMenuItem(title: "", action: #selector(setupTunnel), keyEquivalent: "")
        let label = current.isEmpty ? "🌐 Setup Remote Domain…" : "🌐 Change Remote Domain…"
        setupItem.attributedTitle = emojiAwareTitle(label, color: .labelColor)
        setupItem.target = self
        menu.addItem(setupItem)
        if !current.isEmpty {
            let resetItem = NSMenuItem(title: "", action: #selector(resetTunnel), keyEquivalent: "")
            resetItem.attributedTitle = emojiAwareTitle("🌐 Reset Remote Domain…", color: .systemRed)
            resetItem.target = self
            menu.addItem(resetItem)
        }
    }

    private func tunnelStatusMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false

        guard let cache = tunnelStatusCache else {
            item.attributedTitle = emojiAwareTitle("🌐 Tunnel: checking…", color: .secondaryLabelColor)
            return item
        }

        let running = cache["cloudflared_running"] as? Bool ?? false
        let publicOk = cache["public_ok"] as? Bool ?? false
        let step = cache["step"] as? String ?? ""
        let lastError = cache["last_error"] as? String

        if step == "error", let lastError, !lastError.isEmpty {
            item.attributedTitle = emojiAwareTitle("🔴 Tunnel error — \(lastError)", color: .systemRed)
            item.toolTip = lastError
        } else if publicOk {
            item.attributedTitle = emojiAwareTitle("🟢 Tunnel live — reachable everywhere", color: .systemGreen)
        } else if running {
            item.attributedTitle = emojiAwareTitle("🟠 Connector up — verifying access…", color: .systemOrange)
        } else {
            item.attributedTitle = emojiAwareTitle("🔴 Connector stopped", color: .systemRed)
        }
        return item
    }

    private func refreshTunnelStatus() {
        guard UserDefaults.standard.string(forKey: "tunnelDomain") != nil,
              !tunnelStatusInFlight else { return }
        tunnelStatusInFlight = true
        let baseURL = UserDefaults.standard.string(forKey: "subworkerServerURL") ?? "http://localhost:5656"
        guard let url = URL(string: "\(baseURL)/tunnel/status") else {
            tunnelStatusInFlight = false
            return
        }
        var req = EliaAuth.authorize(url)
        req.httpMethod = "GET"
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.tunnelStatusInFlight = false
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                let changed = self.tunnelStatusCache.map { prev in
                    prev["step"] as? String != json["step"] as? String
                        || prev["cloudflared_running"] as? Bool != json["cloudflared_running"] as? Bool
                        || prev["public_ok"] as? Bool != json["public_ok"] as? Bool
                        || (prev["last_error"] as? String ?? "") != (json["last_error"] as? String ?? "")
                } ?? true
                guard changed else { return }
                self.tunnelStatusCache = json
                self.setupMenu()
            }
        }.resume()
    }

    @objc private func resetTunnel() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Reset Cloudflare?"
        alert.informativeText = "This permanently deletes the DNS record and the tunnel on Cloudflare and stops the connector. The server goes back to LAN-only until setup runs again."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let baseURL = UserDefaults.standard.string(forKey: "subworkerServerURL") ?? "http://localhost:5656"
        guard let url = URL(string: "\(baseURL)/tunnel/remove") else { return }
        var req = EliaAuth.authorize(url)
        req.httpMethod = "POST"
        URLSession.shared.dataTask(with: req) { [weak self] _, _, _ in
            DispatchQueue.main.async {
                UserDefaults.standard.removeObject(forKey: "tunnelDomain")
                self?.setupMenu()
                let done = NSAlert()
                done.messageText = "Cloudflare reset"
                done.informativeText = "The domain was removed from Cloudflare and the connector stopped."
                done.runModal()
            }
        }.resume()
    }

    @objc private func setupTunnel() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Remote Domain (Cloudflare Tunnel)"
        alert.informativeText = "Enter your domain (e.g. elia.surfai.tech) and your Cloudflare API Token (Zone:DNS Edit + Account:Tunnel Edit). The server will create the tunnel on your Mac (local network required)."
        alert.addButton(withTitle: "Setup Tunnel")
        alert.addButton(withTitle: "Cancel")
        let domainField = NSTextField(string: UserDefaults.standard.string(forKey: "tunnelDomain") ?? "")
        domainField.placeholderString = "elia.surfai.tech"
        domainField.frame = NSRect(x: 0, y: 24, width: 320, height: 24)
        let tokenField = NSTextField(string: UserDefaults.standard.string(forKey: "cfApiToken") ?? "")
        tokenField.placeholderString = "Cloudflare API Token"
        tokenField.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))
        container.addSubview(domainField)
        container.addSubview(tokenField)
        alert.accessoryView = container
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let domain = domainField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let token = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !domain.isEmpty, !token.isEmpty else { return }
        UserDefaults.standard.set(domain, forKey: "tunnelDomain")
        UserDefaults.standard.set(token, forKey: "cfApiToken")
        let baseURL = UserDefaults.standard.string(forKey: "subworkerServerURL") ?? "http://localhost:5656"
        guard let url = URL(string: "\(baseURL)/tunnel/setup") else { return }
        var req = EliaAuth.authorize(url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["domain": domain, "api_token": token])
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    let err = NSAlert()
                    err.messageText = "Tunnel Setup Failed"
                    err.informativeText = "Could not reach the server: \(error.localizedDescription)"
                    err.runModal()
                    return
                }
                var status: String?
                var message: String?
                if let data,
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    status = obj["status"] as? String
                    message = (obj["message"] as? String)
                        ?? (obj["detail"] as? String)
                        ?? (obj["last_error"] as? String)
                }
                if status == "error" {
                    let err = NSAlert()
                    err.messageText = "Tunnel Setup Failed"
                    err.informativeText = message ?? "The server reported an error while starting tunnel setup."
                    err.runModal()
                    return
                }
                let controller = TunnelProgressPanelController(domain: domain)
                controller.onClose = { [weak self] in self?.tunnelProgressController = nil }
                controller.show()
                self.tunnelProgressController = controller
            }
        }.resume()
    }

    // MARK: - Existing Colima Methods

    private func addManualRunSubworkerItem(to menu: NSMenu) {
        menu.addItem(NSMenuItem.separator())

        let submenu = NSMenu()
        submenu.autoenablesItems = false

        if subworkerManager.isLoading {
            submenu.addItem(loadingMenuItem(text: "Loading subworkers…"))
        } else if let statusError = subworkerManager.statusError {
            submenu.addItem(errorMenuItem(text: "Error: \(statusError)"))
        } else if subworkerManager.subworkers.isEmpty {
            submenu.addItem(disabledItem("No subworkers"))
        } else {
            for sw in subworkerManager.subworkers {
                let item = NSMenuItem(title: "", action: #selector(triggerSubworker(_:)), keyEquivalent: "")
                item.attributedTitle = emojiAwareTitle("⚡ \(sw.name)", color: .labelColor)
                item.target = self
                item.representedObject = sw.name
                submenu.addItem(item)
            }
        }

        let manualItem = NSMenuItem(title: "Manual Run Subworker", action: nil, keyEquivalent: "")
        manualItem.submenu = submenu
        menu.addItem(manualItem)
    }

    private func loadingMenuItem(text: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        let spinner = NSProgressIndicator(frame: NSRect(x: 10, y: 4, width: 16, height: 16))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        container.addSubview(spinner)
        let label = NSTextField(labelWithString: text)
        label.frame = NSRect(x: 34, y: 2, width: 180, height: 20)
        label.font = NSFont.menuFont(ofSize: 0)
        label.textColor = .secondaryLabelColor
        label.drawsBackground = false
        label.isBezeled = false
        container.addSubview(label)
        item.view = container
        return item
    }

    private func errorMenuItem(text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.toolTip = text
        return item
    }

    private func disabledItem(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func addInstanceItems(to menu: NSMenu) {
        if colimaManager.instances.isEmpty {
            let noInstancesItem = NSMenuItem(title: "No instances found", action: nil, keyEquivalent: "")
            noInstancesItem.isEnabled = false
            menu.addItem(noInstancesItem)
        } else {
            // Add each instance
            for instance in colimaManager.instances {
                let instanceMenu = NSMenu()
                instanceMenu.autoenablesItems = false

                // Info items
                let statusInfo = NSMenuItem(title: "Status: \(instance.status.rawValue)", action: nil, keyEquivalent: "")
                statusInfo.isEnabled = false
                instanceMenu.addItem(statusInfo)

                let archInfo = NSMenuItem(title: "Arch: \(instance.arch)", action: nil, keyEquivalent: "")
                archInfo.isEnabled = false
                instanceMenu.addItem(archInfo)

                let cpuInfo = NSMenuItem(title: "CPUs: \(instance.cpus)", action: nil, keyEquivalent: "")
                cpuInfo.isEnabled = false
                instanceMenu.addItem(cpuInfo)

                let memInfo = NSMenuItem(title: "Memory: \(instance.memoryFormatted)", action: nil, keyEquivalent: "")
                memInfo.isEnabled = false
                instanceMenu.addItem(memInfo)

                let diskInfo = NSMenuItem(title: "Disk: \(instance.diskFormatted)", action: nil, keyEquivalent: "")
                diskInfo.isEnabled = false
                instanceMenu.addItem(diskInfo)

                instanceMenu.addItem(NSMenuItem.separator())

                // Start/Stop actions
                if instance.status.isStopped {
                    let startItem = NSMenuItem(title: "Start", action: #selector(startInstance(_:)), keyEquivalent: "")
                    startItem.target = self
                    startItem.representedObject = instance.name
                    instanceMenu.addItem(startItem)
                } else if instance.status.isRunning {
                    let stopItem = NSMenuItem(title: "Stop", action: #selector(stopInstance(_:)), keyEquivalent: "")
                    stopItem.target = self
                    stopItem.representedObject = instance.name
                    instanceMenu.addItem(stopItem)

                    let restartItem = NSMenuItem(title: "Restart", action: #selector(restartInstance(_:)), keyEquivalent: "")
                    restartItem.target = self
                    restartItem.representedObject = instance.name
                    instanceMenu.addItem(restartItem)

                    let shellItem = NSMenuItem(title: "Open Shell", action: #selector(sshInstance(_:)), keyEquivalent: "")
                    shellItem.target = self
                    shellItem.representedObject = instance.name
                    instanceMenu.addItem(shellItem)
                } else {
                    let transitionItem = NSMenuItem(title: instance.status.rawValue, action: nil, keyEquivalent: "")
                    transitionItem.isEnabled = false
                    instanceMenu.addItem(transitionItem)
                }

                instanceMenu.addItem(NSMenuItem.separator())
                let deleteItem = NSMenuItem(title: "Delete…", action: #selector(deleteInstance(_:)), keyEquivalent: "")
                deleteItem.target = self
                deleteItem.representedObject = instance.name
                deleteItem.isEnabled = !instance.status.isTransitioning
                instanceMenu.addItem(deleteItem)

                let headerTitle: String
                if instance.name == "default" && instance.status.isRunning {
                    let serverHealthy = subworkerManager.serverHealth?.healthStatus == "healthy"
                    headerTitle = serverHealthy
                        ? "✅ ELIA SYSTEM RUNNING"
                        : "⚠️ Docker Running — Server Down"
                } else if instance.name == "default" {
                    headerTitle = "○ Docker Engine"
                } else {
                    let statusIcon = instance.status.isRunning ? "●" : "○"
                    headerTitle = "\(statusIcon) \(instance.name)"
                }
                let instanceItem = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
                instanceItem.submenu = instanceMenu
                menu.addItem(instanceItem)
            }
        }
    }

    @objc private func startInstance(_ sender: NSMenuItem) {
        guard let profile = sender.representedObject as? String else { return }
        colimaManager.start(profile: profile)
    }

    @objc private func stopInstance(_ sender: NSMenuItem) {
        guard let profile = sender.representedObject as? String else { return }
        colimaManager.stop(profile: profile)
    }

    @objc private func restartInstance(_ sender: NSMenuItem) {
        guard let profile = sender.representedObject as? String else { return }
        colimaManager.restart(profile: profile)
    }

    @objc private func deleteInstance(_ sender: NSMenuItem) {
        guard let profile = sender.representedObject as? String else { return }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Delete \"\(profile)\"?"
        alert.informativeText = "This permanently deletes the instance and all its data. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            colimaManager.delete(profile: profile)
        }
    }

    @objc private func sshInstance(_ sender: NSMenuItem) {
        guard let profile = sender.representedObject as? String else { return }
        openShell(profile: profile)
    }

    /// Open the user's Terminal and run `colima ssh` for the profile.
    private func openShell(profile: String) {
        let command = "\(colimaManager.executablePath) ssh -p '\(profile)'"
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """

        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error = error {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Could not open a shell for \"\(profile)\""
            alert.informativeText = error[NSAppleScript.errorMessage] as? String
                ?? "Terminal could not be controlled. Grant automation access in System Settings › Privacy & Security › Automation."
            alert.runModal()
        }
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Could not update Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        setupMenu()
    }

    @objc private func refreshStatus() {
        colimaManager.refreshInstances()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Lazy Model Menu Population

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let agentName = menu.identifier?.rawValue else { return }
        populateModelMenu(menu, agentName: agentName)
    }

    private func populateModelMenu(_ menu: NSMenu, agentName: String) {
        menu.removeAllItems()

        let models = subworkerManager.availableModels
        guard !models.isEmpty else {
            // Kick a refresh so the next hover shows the catalog.
            subworkerManager.fetchModels()
            let item = NSMenuItem(title: "Loading models…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        let currentModel = subworkerManager.currentModel(for: agentName)
        let currentVariant = subworkerManager.currentVariant(for: agentName)

        for m in models {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            let star = m.provider == "opencode" ? "⭐ " : ""
            item.attributedTitle = emojiAwareTitle("\(star)\(m.name)  (\(m.provider))", color: .labelColor)
            item.state = m.id == currentModel ? .on : .off
            item.target = self
            item.representedObject = ["name": agentName, "model": m.id]

            if m.variants.isEmpty {
                item.action = #selector(setSubworkerModel(_:))
            } else {
                // Thinking levels — selection happens in the nested menu.
                let thinkMenu = NSMenu()
                thinkMenu.autoenablesItems = false

                let noneItem = NSMenuItem(title: "no extra thinking", action: #selector(setSubworkerModel(_:)), keyEquivalent: "")
                noneItem.state = (m.id == currentModel && currentVariant.isEmpty) ? .on : .off
                noneItem.target = self
                noneItem.representedObject = ["name": agentName, "model": m.id, "variant": ""]
                thinkMenu.addItem(noneItem)

                for v in m.variants {
                    let vi = NSMenuItem(title: "thinking: \(v)", action: #selector(setSubworkerModel(_:)), keyEquivalent: "")
                    vi.state = (m.id == currentModel && currentVariant == v) ? .on : .off
                    vi.target = self
                    vi.representedObject = ["name": agentName, "model": m.id, "variant": v]
                    thinkMenu.addItem(vi)
                }

                item.submenu = thinkMenu
            }
            menu.addItem(item)
        }
    }
}

final class TunnelProgressPanelController: NSObject, NSWindowDelegate {
    private struct StepDefinition {
        let key: String
        let title: String
    }

    private enum StepVisual {
        case pending
        case active
        case completed
        case error
    }

    private static let steps: [StepDefinition] = [
        StepDefinition(key: "verifying_token", title: "Verifying API token"),
        StepDefinition(key: "checking_zone", title: "Checking the domain zone"),
        StepDefinition(key: "creating_tunnel", title: "Creating the tunnel"),
        StepDefinition(key: "routing_dns", title: "Routing DNS"),
        StepDefinition(key: "starting_cloudflared", title: "Starting the connector"),
        StepDefinition(key: "verifying_public", title: "Verifying public access"),
    ]

    var onClose: (() -> Void)?

    private let domain: String
    private var panel: NSPanel?
    private var pollTimer: Timer?
    private let pollSession = URLSession(configuration: .ephemeral)
    private var lastActiveStepIndex: Int?
    private var consecutiveFailures = 0

    private var headlineLabel: NSTextField!
    private var bannerLabel: NSTextField!
    private var noteLabel: NSTextField!
    private var retryButton: NSButton!
    private var indicatorContainers: [NSView] = []
    private var rowLabels: [NSTextField] = []

    init(domain: String) {
        self.domain = domain
        super.init()
    }

    func show() {
        guard panel == nil else { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Cloudflare Tunnel Setup"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let content = buildContentView()
        panel.contentView = content
        let fitting = content.fittingSize
        panel.setContentSize(NSSize(width: max(420, fitting.width), height: fitting.height))
        panel.center()
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        render(states: Array(repeating: .pending, count: Self.steps.count),
               headline: "Setting up Cloudflare Tunnel…",
               errorText: nil,
               terminal: false)
        startPolling()
    }

    private func buildContentView() -> NSView {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))

        headlineLabel = NSTextField(labelWithString: "Setting up Cloudflare Tunnel…")
        headlineLabel.font = .boldSystemFont(ofSize: 14)
        headlineLabel.alignment = .center
        headlineLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let rowsStack = NSStackView(views: [])
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 8

        for step in Self.steps {
            let container = NSView()
            container.translatesAutoresizingMaskIntoConstraints = false
            container.widthAnchor.constraint(equalToConstant: 22).isActive = true
            container.heightAnchor.constraint(equalToConstant: 22).isActive = true

            let label = NSTextField(labelWithString: step.title)
            label.font = .systemFont(ofSize: 13)

            let row = NSStackView(views: [container, label])
            row.orientation = .horizontal
            row.spacing = 10
            row.alignment = .centerY

            indicatorContainers.append(container)
            rowLabels.append(label)
            rowsStack.addArrangedSubview(row)
        }

        bannerLabel = NSTextField(wrappingLabelWithString: "")
        bannerLabel.font = .systemFont(ofSize: 12)
        bannerLabel.textColor = .systemRed
        bannerLabel.maximumNumberOfLines = 0
        bannerLabel.alphaValue = 0
        bannerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bannerLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bannerLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 380).isActive = true

        noteLabel = NSTextField(labelWithString: "")
        noteLabel.font = .systemFont(ofSize: 11)
        noteLabel.textColor = .secondaryLabelColor

        retryButton = NSButton(title: "Retry", target: self, action: #selector(retryClicked))
        retryButton.bezelStyle = .rounded
        retryButton.isHidden = true
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonsRow = NSStackView(views: [spacer, retryButton, closeButton])
        buttonsRow.orientation = .horizontal
        buttonsRow.spacing = 8
        buttonsRow.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let outer = NSStackView(views: [headlineLabel, rowsStack, bannerLabel, noteLabel, buttonsRow])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 12
        outer.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        outer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: content.topAnchor),
            outer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            outer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        return content
    }

    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollOnce()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        pollOnce()
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollOnce() {
        let baseURL = UserDefaults.standard.string(forKey: "subworkerServerURL") ?? "http://localhost:5656"
        guard let url = URL(string: "\(baseURL)/tunnel/status") else { return }
        let request = EliaAuth.authorize(url)
        pollSession.dataTask(with: request) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.consecutiveFailures += 1
                    self.noteLabel.stringValue = "Waiting for server… (\(self.consecutiveFailures))"
                    return
                }
                self.apply(statusJSON: obj)
            }
        }.resume()
    }

    private func apply(statusJSON obj: [String: Any]) {
        consecutiveFailures = 0
        noteLabel.stringValue = ""
        let step = obj["step"] as? String ?? "idle"

        if step == "done" {
            stopPolling()
            let liveDomain = (obj["domain"] as? String) ?? domain
            render(states: Array(repeating: .completed, count: Self.steps.count),
                   headline: "Tunnel is live — https://\(liveDomain)",
                   errorText: nil,
                   terminal: true)
            return
        }

        if step == "error" {
            stopPolling()
            let message = obj["last_error"] as? String ?? "The tunnel setup failed."
            render(states: statesThroughFailure(at: failureIndex()),
                   headline: "Tunnel Setup Failed",
                   errorText: message,
                   terminal: true)
            return
        }

        if let index = Self.steps.firstIndex(where: { $0.key == step }) {
            lastActiveStepIndex = index
            var states = Array(repeating: StepVisual.pending, count: Self.steps.count)
            for i in 0..<Self.steps.count {
                states[i] = i < index ? .completed : (i == index ? .active : .pending)
            }
            render(states: states,
                   headline: "Setting up Cloudflare Tunnel…",
                   errorText: nil,
                   terminal: false)
        } else {
            render(states: Array(repeating: .pending, count: Self.steps.count),
                   headline: "Setting up Cloudflare Tunnel…",
                   errorText: nil,
                   terminal: false)
        }
    }

    private func failureIndex() -> Int {
        lastActiveStepIndex ?? 0
    }

    private func statesThroughFailure(at index: Int) -> [StepVisual] {
        var states = Array(repeating: StepVisual.pending, count: Self.steps.count)
        for i in 0..<Self.steps.count {
            states[i] = i < index ? .completed : (i == index ? .error : .pending)
        }
        return states
    }

    private func render(states: [StepVisual], headline: String, errorText: String?, terminal: Bool) {
        headlineLabel.stringValue = headline
        for (index, container) in indicatorContainers.enumerated() where index < states.count {
            applyIndicator(to: container, state: states[index])
            rowLabels[index].textColor = textColor(for: states[index])
        }
        if let errorText {
            bannerLabel.stringValue = errorText
            bannerLabel.alphaValue = 1
        } else {
            bannerLabel.stringValue = ""
            bannerLabel.alphaValue = 0
        }
        retryButton.isHidden = !(terminal && errorText != nil)
    }

    private func textColor(for state: StepVisual) -> NSColor {
        switch state {
        case .pending: return .secondaryLabelColor
        case .active: return .labelColor
        case .completed: return .labelColor
        case .error: return .systemRed
        }
    }

    private func applyIndicator(to container: NSView, state: StepVisual) {
        container.subviews.forEach { $0.removeFromSuperview() }
        switch state {
        case .active:
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            spinner.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
            spinner.startAnimation(nil)
        case .pending:
            addSymbol("○", color: .secondaryLabelColor, to: container)
        case .completed:
            addSymbol("✓", color: .systemGreen, to: container)
        case .error:
            addSymbol("✗", color: .systemRed, to: container)
        }
    }

    private func addSymbol(_ symbol: String, color: NSColor, to container: NSView) {
        let label = NSTextField(labelWithString: symbol)
        label.font = .systemFont(ofSize: 13, weight: .bold)
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
    }

    @objc private func retryClicked() {
        guard let savedDomain = UserDefaults.standard.string(forKey: "tunnelDomain"),
              let savedToken = UserDefaults.standard.string(forKey: "cfApiToken") else { return }
        lastActiveStepIndex = nil
        consecutiveFailures = 0
        render(states: Array(repeating: .pending, count: Self.steps.count),
               headline: "Setting up Cloudflare Tunnel…",
               errorText: nil,
               terminal: false)
        postSetup(domain: savedDomain, token: savedToken) { [weak self] in
            self?.startPolling()
        }
    }

    private func postSetup(domain: String, token: String, onSuccess: @escaping () -> Void) {
        let baseURL = UserDefaults.standard.string(forKey: "subworkerServerURL") ?? "http://localhost:5656"
        guard let url = URL(string: "\(baseURL)/tunnel/setup") else { return }
        var request = EliaAuth.authorize(url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["domain": domain, "api_token": token])
        pollSession.dataTask(with: request) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if let data,
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   obj["status"] as? String == "error" {
                    self.stopPolling()
                    let message = (obj["message"] as? String)
                        ?? (obj["detail"] as? String)
                        ?? (obj["last_error"] as? String)
                        ?? "The tunnel setup failed."
                    self.render(states: self.statesThroughFailure(at: self.failureIndex()),
                                headline: "Tunnel Setup Failed",
                                errorText: message,
                                terminal: true)
                    return
                }
                onSuccess()
            }
        }.resume()
    }

    @objc private func closeClicked() {
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        stopPolling()
        panel?.delegate = nil
        panel = nil
        onClose?()
    }
}
