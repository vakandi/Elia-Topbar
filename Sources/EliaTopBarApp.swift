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
    private var colimaManager: ColimaManager!
    private var subworkerManager: SubworkerManager!
    private var cancellables = Set<AnyCancellable>()
    private var logPopover: NSPopover?
    private var subworkerStatusItems: [String: NSStatusItem] = [:]
    private var subworkerHoverHandlers: [String: SubworkerHoverHandler] = [:]
    private var subworkerLogPopover: NSPopover?
    private var subworkerLogPopoverName: String?

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
            self?.updateStatusIcon()
            self?.setupMenu()
            self?.reconcileSubworkerStatusItems()
        }
        .store(in: &cancellables)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
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

        if swDisconnected || swHasError {
            let symbolName = swDisconnected ? "circle.slash" : "exclamationmark.circle"
            let config = NSImage.SymbolConfiguration(pointSize: barHeight * 0.58, weight: .medium)
            guard let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return }
            button.image = tintedSymbol(baseImage, color: .systemRed)
            return
        }

        // Elia system healthy → custom brain banner instead of the docker box.
        if subworkerManager.serverHealth?.healthStatus == "healthy",
           let banner = Self.runningBannerIcon?.copy() as? NSImage {
            banner.size = NSSize(width: barHeight * 0.92, height: barHeight * 0.92)
            if swRunning > 0 {
                button.image = badgeImage(base: banner, count: swRunning, barHeight: barHeight)
            } else {
                button.image = banner
            }
            return
        }

        // Docker up but OpenCode server unreachable → red X banner.
        if hasRunning, let xBanner = Self.serverDownBannerIcon?.copy() as? NSImage {
            xBanner.size = NSSize(width: barHeight * 0.92, height: barHeight * 0.92)
            button.image = xBanner
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
            button.image = badgeImage(base: tinted, count: count, barHeight: barHeight)
        } else {
            tinted.isTemplate = (tintColor == .labelColor)
            button.image = tinted
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

        menu.addItem(refreshIntervalMenuItem())

        // Server URL preference
        addServerURLMenuItems(to: menu)

        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = launchAtLoginEnabled ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit EliaTopBar", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
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
        let active = subworkerManager.subworkers.filter { $0.enabled }
        let inactive = subworkerManager.subworkers.filter { !$0.enabled }

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
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = buildAttributedItem(dot: dot, name: displayName, status: statusText, color: color)
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
            let photoItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            let photoView = NSImageView(image: photo)
            photoView.frame = NSRect(x: 0, y: 0, width: 120, height: 120)
            photoView.imageScaling = .scaleProportionallyUpOrDown
            photoItem.view = photoView
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

        if let nextRun = sw.nextRun {
            let nextItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            nextItem.attributedTitle = emojiAwareTitle("🕐 Next Run: \(nextRun)", color: .secondaryLabelColor)
            nextItem.isEnabled = false
            submenu.addItem(nextItem)
        }

        if let schedule = sw.scheduleType {
            let schedItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            schedItem.attributedTitle = emojiAwareTitle("📅 Schedule: \(schedule)", color: .secondaryLabelColor)
            schedItem.isEnabled = false
            submenu.addItem(schedItem)
        }

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

    private func buildAttributedItem(dot: String, name: String, status: String, color: NSColor) -> NSAttributedString {
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

    private func reconcileSubworkerStatusItems() {
        let running = subworkerManager.subworkers.filter(\.running)
        let runningNames = Set(running.map(\.name))

        let staleNames = subworkerStatusItems.keys.filter { !runningNames.contains($0) }
        for name in staleNames {
            if let item = subworkerStatusItems.removeValue(forKey: name) {
                NSStatusBar.system.removeStatusItem(item)
            }
            subworkerHoverHandlers.removeValue(forKey: name)
            if subworkerLogPopoverName == name {
                subworkerLogPopover?.performClose(nil)
                subworkerLogPopover = nil
                subworkerLogPopoverName = nil
            }
        }

        for sw in running where subworkerStatusItems[sw.name] == nil {
            addSubworkerStatusItem(for: sw)
        }

        for sw in running {
            updateSubworkerStatusIcon(for: sw)
        }
    }

    private func addSubworkerStatusItem(for sw: SubworkerInfo) {
        let item = NSStatusBar.system.statusItem(withLength: 24)
        subworkerStatusItems[sw.name] = item

        guard let button = item.button else { return }
        button.image = subworkerStatusIcon(for: sw)
        button.toolTip = sw.name

        let handler = SubworkerHoverHandler()
        handler.onEnter = { [weak self] in
            self?.showSubworkerLogPopover(for: sw.name, button: button)
        }
        button.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: handler,
            userInfo: nil
        ))
        subworkerHoverHandlers[sw.name] = handler
    }

    private func updateSubworkerStatusIcon(for sw: SubworkerInfo) {
        guard let item = subworkerStatusItems[sw.name] else { return }
        item.button?.image = subworkerStatusIcon(for: sw)
    }

    private func subworkerStatusIcon(for sw: SubworkerInfo) -> NSImage {
        if let photo = ProfilePhotos.shared.circularPhoto(for: sw.name, size: 20) {
            let color = subworkerColor(for: sw)
            return subworkerIconWithBorder(photo: photo, color: color)
        }
        return subworkerIcon(monogram: monogram(for: sw.name), color: subworkerColor(for: sw))
    }

    private func subworkerIconWithBorder(photo: NSImage, color: NSColor) -> NSImage {
        let barHeight = max(NSStatusBar.system.thickness, 20)
        let size = NSSize(width: 22, height: barHeight)
        let diameter = barHeight * 0.92
        return NSImage(size: size, flipped: false) { rect in
            let dotRect = NSRect(
                x: (rect.width - diameter) / 2,
                y: (rect.height - diameter) / 2,
                width: diameter,
                height: diameter
            )
            color.setFill()
            NSBezierPath(ovalIn: dotRect).fill()

            let photoInset: CGFloat = 2
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
        let size = NSSize(width: 22, height: barHeight)
        return NSImage(size: size, flipped: false) { rect in
            let diameter = rect.height * 0.92
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
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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

    private func refreshIntervalMenuItem() -> NSMenuItem {
        let submenu = NSMenu()
        let current = colimaManager.refreshInterval
        for seconds in [5.0, 10.0, 30.0, 60.0] {
            let item = NSMenuItem(title: "\(Int(seconds)) seconds", action: #selector(setInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = seconds
            item.state = seconds == current ? .on : .off
            submenu.addItem(item)
        }
        let intervalItem = NSMenuItem(title: "Refresh Interval", action: nil, keyEquivalent: "")
        intervalItem.submenu = submenu
        return intervalItem
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

    @objc private func setInterval(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else { return }
        colimaManager.setRefreshInterval(seconds)
        setupMenu()
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
            item.attributedTitle = emojiAwareTitle("\(m.name)  (\(m.provider))", color: .labelColor)
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
