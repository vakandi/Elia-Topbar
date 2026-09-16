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

private struct CleanupLoadingView: View {
    var body: some View {
        HStack(spacing:8){
            ProgressView().controlSize(.small)
            Text("Cleaning RAM + Idle Cleaner…").font(.system(size:11, weight:.medium)).foregroundColor(.secondary)
        }.padding(.horizontal,14).padding(.vertical,10).background(RoundedRectangle(cornerRadius:10).fill(.regularMaterial)).overlay(RoundedRectangle(cornerRadius:10).stroke(Color.primary.opacity(0.12))).shadow(color:.black.opacity(0.15), radius:8, x:0, y:2)
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
    // X of the primary base inside the composed icon (0 when fleet is right
    // of / absent; fleetWidth when fleet photos sit left). The animated ring
    // overlay must be drawn here, not at x=0.
    private var iconBaseStartX: CGFloat = 0
    private var iconCellWidth: CGFloat = 0
    private var iconPhotoCount: Int = 0
    private var iconPhotoNames: [String] = []
    private var subworkerLogPopover: NSPopover?
    private var subworkerLogPopoverName: String?
    private var tunnelProgressController: TunnelProgressPanelController?
    private var tunnelStatusCache: [String: Any]?
    private var tunnelStatusInFlight = false
    private var tunnelPollTimer: Timer?
    private var previousRunningNames: Set<String> = []
    private var seenFirstSubworkerSnapshot = false
    private var menuRebuildThrottleWorkItem: DispatchWorkItem?
    private var statusItemWatchdog: Timer?
    private var statusItemDispatchWatchdog: DispatchSourceTimer?
    private var countdownRefreshTimer: Timer?
    private var lastMenuHash: Int = 0
    private var isMenuOpen = false
    private weak var openModelMenu: NSMenu?
    private var openModelAgent: String?
    private var cleanupLoadingPanel: NSPanel?

    private func logDrop(_ msg: String) {
        let line = "[\(Date())] \(msg)\n"
        if let data = line.data(using: .utf8) {
            let url = URL(fileURLWithPath: "/tmp/EliaTopBar.log")
            if FileManager.default.fileExists(atPath: url.path) {
                if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
            } else {
                try? data.write(to: url)
            }
        }
        print("[EliaDrop] \(msg)")
    }

    private func detectNewlyRunningAgents() {
        let running = Set(subworkerManager.subworkers.filter(\.running).map(\.name))
        logDrop("detect running=\(running) prev=\(previousRunningNames) isFirst=\(!seenFirstSubworkerSnapshot) duration=\(effectiveRunPopupDuration) max=\(maxConcurrentDrops) windowNil=\(statusItem.button?.window==nil) panels=\(RunPopupController.shared.panelCount)")
        defer {
            previousRunningNames = running
            seenFirstSubworkerSnapshot = true
        }
        let isFirst = !seenFirstSubworkerSnapshot
        if isFirst {
            return
        }
        let duration = effectiveRunPopupDuration
        guard duration > 0 else { return }
        let newly = running.subtracting(previousRunningNames).filter { !RunPopupController.shared.hasPanel(for: $0) }
        guard !newly.isEmpty else { return }
        let dropX = menuBarAnchorX()
        let limited = Array(newly.sorted().prefix(maxConcurrentDrops - RunPopupController.shared.panelCount))
         guard !limited.isEmpty else { return }
         for name in limited {
             RunPopupController.shared.show(for: name, dropX: dropX, duration: duration, baseURL: subworkerManager.currentBaseURL)
         }
     }
     @objc private func handleRunPopupEnabledChanged() {
         let running = Set(subworkerManager.subworkers.filter(\.running).map(\.name))
        guard !running.isEmpty else { return }
        let duration = effectiveRunPopupDuration
        guard duration > 0 else { return }
        let dropX = menuBarAnchorX()
        let available = maxConcurrentDrops - RunPopupController.shared.panelCount
        guard available > 0 else { return }
        let limited = Array(running.filter { !RunPopupController.shared.hasPanel(for: $0) }.sorted().prefix(available))
         for name in limited {
             RunPopupController.shared.show(for: name, dropX: dropX, duration: duration, baseURL: subworkerManager.currentBaseURL)
         }
     }
     @objc private func handleShowMiniBubble(_ note: Notification) {
        guard let name = note.userInfo?["name"] as? String else { return }
        let dropX = menuBarAnchorX()
         let dur = effectiveRunPopupDuration == 0 ? 10 : effectiveRunPopupDuration
         RunPopupController.shared.show(for: name, dropX: dropX, duration: dur, baseURL: subworkerManager.currentBaseURL, disableAutoClose: true)
     }
     @objc private func handleCloseLogViewer() { closeAllLogPopovers() }
    @objc private func handleOpenTopbarSettings() {
        if let w = topbarSettingsWindow { w.close() }
        DispatchQueue.main.async { [weak self] in self?.openTopbarSettings(NSMenuItem()) }
    }

    /// Keeps App Nap from throttling our timers — status-bar apps are background by definition.
    private var appNapActivity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent App Nap from freezing timers when the app is backgrounded for hours.
        appNapActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "EliaTopBar status-bar live updates")

        colimaManager = ColimaManager()
        subworkerManager = SubworkerManager()

        // Restore persisted server URL
        if let savedURL = UserDefaults.standard.string(forKey: "subworkerServerURL") {
            subworkerManager.updateBaseURL(savedURL)
        }
        subworkerManager.start()
        NotificationCenter.default.addObserver(self, selector: #selector(handleRunPopupEnabledChanged), name: .eliaRunPopupEnabledChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleShowMiniBubble(_:)), name: .eliaShowMiniBubble, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleCloseLogViewer), name: .eliaCloseLogViewer, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleOpenTopbarSettings), name: .eliaOpenTopbarSettings, object: nil)

        setupStatusItem()
        setupMenu()
        installWakeObservers()

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
            self.throttledSetupMenu()
            self.reconcileSubworkerStatusItems()
            // Drop was never firing: defined but never called. Real agent runs
            // arrive here via $subworkers/$runningCount — Test button bypasses this.
            self.detectNewlyRunningAgents()
        }
        .store(in: &cancellables)

        NotificationCenter.default.addObserver(forName: SubworkerManager.subworkerToggleNotification, object: nil, queue: .main) { [weak self] _ in
            self?.resetMenuHashAndRebuild()
        }
        NotificationCenter.default.addObserver(forName: SubworkerManager.modelsLoadedNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let menu = self.openModelMenu, let agent = self.openModelAgent else { return }
            self.populateModelMenu(menu, agentName: agent)
        }

        // Cloudflare tunnel status — keep the menu line fresh (30s cadence).
        refreshTunnelStatus()
        let t = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.refreshTunnelStatus()
        }
        RunLoop.main.add(t, forMode: .common)
        tunnelPollTimer = t
        startStatusItemWatchdog()
        startCountdownRefresh()
    }

    // MARK: - Wake / Display / Network heal

    private func installWakeObservers() {
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(handleSystemWake(_:)), name: NSWorkspace.screensDidWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(handleSystemWake(_:)), name: NSWorkspace.screensDidSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(handleSystemWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleBecomeActive(_:)), name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleDisplayChange(_:)), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(handleSystemWake(_:)), name: .init("com.apple.system.clockChanged"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleNetworkPathChange(_:)), name: SubworkerManager.networkPathChangedNotification, object: nil)
    }

    @objc private func handleDisplayChange(_ note: Notification) {
        AppLog.d("Display change: \(note.name.rawValue) — re-asserting statusItem")
        ensureStatusItemAlive()
        throttledSetupMenu()
        updateStatusIcon()
    }

    @objc private func handleSystemWake(_ note: Notification) {
        AppLog.d("System wake/sleep event: \(note.name.rawValue) — healing status item + WS")
        healAfterWake()
    }

    @objc private func handleBecomeActive(_ note: Notification) {
        ensureStatusItemAlive()
        watchdogCheck()
    }

    @objc private func handleNetworkPathChange(_ note: Notification) {
        AppLog.d("Network path changed — healing statusItem")
        ensureStatusItemAlive()
        watchdogCheck()
        throttledSetupMenu()
    }

    private func healAfterWake() {
        ensureStatusItemAlive()
        rescheduleTunnelPoll()
        startCountdownRefresh()
        subworkerManager.forceReconnect()
        refreshTunnelStatus()
        colimaManager.refreshInstances()
        setupMenu()
        updateStatusIcon()
    }

    private func rescheduleTunnelPoll() {
        tunnelPollTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.refreshTunnelStatus()
        }
        RunLoop.main.add(t, forMode: .common)
        tunnelPollTimer = t
    }

    private func throttledSetupMenu() {
        if isMenuOpen || logPopover?.isShown == true || subworkerLogPopover?.isShown == true { return }
        // nextRun is a live countdown that changes every poll — including it here
        // rebuilt the whole 40-item menu every 5s (AppKit layout storm, 55% CPU).
        // Countdown labels already refresh on the 30s countdown timer.
        let currentHash = subworkerManager.subworkers.map { "\($0.name):\($0.enabled):\($0.running):\(subworkerManager.wsConnected):\(subworkerManager.hasError):\(subworkerManager.statusError ?? ""):\(subworkerManager.serverHealth?.healthStatus ?? "")" }.joined().hashValue ^ colimaManager.instances.count
        if currentHash == lastMenuHash && mainMenu != nil && (mainMenu?.numberOfItems ?? 0) > 0 { return }
        lastMenuHash = currentHash
        menuRebuildThrottleWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.setupMenu() }
        menuRebuildThrottleWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func resetMenuHashAndRebuild() {
        lastMenuHash = 0
        menuRebuildThrottleWorkItem?.cancel()
        setupMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        if openModelMenu === menu {
            openModelMenu = nil
            openModelAgent = nil
        }
        // Release the menu so the next click routes through mainItemClicked
        // again (a lingering statusItem.menu bypasses the button action,
        // which left log popovers stuck open).
        if statusItem.menu === menu { statusItem.menu = nil }
        throttledSetupMenu()
    }

    private func startCountdownRefresh() {
        countdownRefreshTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self, !self.isMenuOpen, self.logPopover?.isShown != true, self.subworkerLogPopover?.isShown != true else { return }
            self.lastMenuHash = 0
            self.setupMenu()
        }
        RunLoop.main.add(t, forMode: .common)
        countdownRefreshTimer = t
    }

    private func startStatusItemWatchdog() {
        // Keep RunLoop timer as secondary, but primary is DispatchSource (not coalesced by App Nap).
        statusItemWatchdog?.invalidate()
        statusItemWatchdog = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in self?.watchdogCheck() }
        RunLoop.main.add(statusItemWatchdog!, forMode: .common)

        statusItemDispatchWatchdog?.cancel()
        let src = DispatchSource.makeTimerSource(queue: .main)
        src.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(2))
        src.setEventHandler { [weak self] in self?.watchdogCheck() }
        src.resume()
        statusItemDispatchWatchdog = src

        // Enable health.log by default for this hardening build — user can still opt-out via defaults write.
        if UserDefaults.standard.object(forKey: "topbarHealthLog") == nil {
            UserDefaults.standard.set(true, forKey: "topbarHealthLog")
        }
    }

    private func watchdogCheck() {
        let buttonNil = statusItem.button == nil
        let windowNil = statusItem.button?.window == nil
        let superviewNil = statusItem.button?.superview == nil
        let menuEmpty = mainMenu == nil || (mainMenu?.numberOfItems ?? 0) == 0
        let targetWrong = statusItem.button?.target !== self
        let actionWrong = statusItem.button?.action != #selector(mainItemClicked(_:))
        let shouldHeal = buttonNil || windowNil || superviewNil || menuEmpty || targetWrong || actionWrong
        if shouldHeal {
            AppLog.d("watchdog: heal buttonNil=\(buttonNil) windowNil=\(windowNil) superviewNil=\(superviewNil) menuEmpty=\(menuEmpty) targetWrong=\(targetWrong) actionWrong=\(actionWrong)")
            // Always write health.log when topbarHealthLog is true (now default true). Also log via AppLog.d for unified stream.
            if UserDefaults.standard.bool(forKey: "topbarHealthLog") {
                let path = NSString(string: "~/Library/Logs/EliaTopBar/health.log").expandingTildeInPath
                try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                let line = "\(Date()): watchdog heal buttonNil=\(buttonNil) windowNil=\(windowNil) superviewNil=\(superviewNil) menuEmpty=\(menuEmpty) targetWrong=\(targetWrong) actionWrong=\(actionWrong) ws=\(subworkerManager.wsConnected) subs=\(subworkerManager.subworkers.count) running=\(subworkerManager.runningCount) hasError=\(subworkerManager.hasError) statusError=\(subworkerManager.statusError ?? "-") lastError=\(subworkerManager.lastError ?? "-")\n"
                if let handle = FileHandle(forWritingAtPath: path) {
                    handle.seekToEndOfFile()
                    handle.write(Data(line.utf8))
                    handle.closeFile()
                } else {
                    try? line.write(toFile: path, atomically: true, encoding: .utf8)
                }
            }
            ensureStatusItemAlive()
            setupMenu()
        }
    }

    /// Re-assert the NSStatusItem button target/action. macOS can invalidate the
    /// button's window/action after display reconfiguration, sleep/wake, or a
    /// status-bar rebuild — when that happens clicks are silently swallowed.
    private func ensureStatusItemAlive() {
        let buttonWasNil = statusItem.button == nil
        let windowWasNil = statusItem.button?.window == nil
        if buttonWasNil || windowWasNil {
            AppLog.d("statusItem invalid — button nil=\(buttonWasNil) window nil=\(windowWasNil) — recreating")
            NSStatusBar.system.removeStatusItem(statusItem)
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        }
        guard let button = statusItem.button else { return }
        let needsReinstall = button.target !== self || button.action != #selector(mainItemClicked(_:))
        if needsReinstall {
            AppLog.d("Reinstalling statusItem button target/action (was target=\(String(describing: button.target)) action=\(String(describing: button.action)))")
        }
        button.target = self
        button.action = #selector(mainItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .leftMouseDown])
        // Re-apply icon in case the backing store was purged.
        updateStatusIcon()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(mainItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .leftMouseDown])
        }
        startIconPulseObserver()
        updateStatusIcon()
    }

    private var runningIconTimer: Timer?
    private var runningPhase: Double = 0
    // Skips redundant menu-bar repaints: composing the icon runs CoreText +
    // fleet-photo blending, so identical states reuse the current NSImage.
    private var lastIconKey = ""
    // Static layer cache for the animated primary icon: banner + badge text +
    // fleet photos composited once per content change; each frame only blits
    // the ring overlay on top instead of re-running CoreText and photo decode.
    private var lastStaticKey = ""
    private var cachedStaticIcon: NSImage?
    private var primaryStyle: String { UserDefaults.standard.string(forKey: "primaryIconStyle") ?? "default" }
    private var effectiveRunPopupDuration: TimeInterval {
        let base = UserDefaults.standard.object(forKey: "runPopupDuration") as? Double ?? 10
        if base == 0 { return 0 }
        if UserDefaults.standard.bool(forKey: "runPopupCustomEnabled") {
            return UserDefaults.standard.object(forKey: "runPopupCustomDuration") as? Double ?? 15
        }
        return base
    }
    private var maxConcurrentDrops: Int { UserDefaults.standard.object(forKey: "runPopupMaxConcurrent") as? Int ?? 5 }
    private func menuBarAnchorX() -> CGFloat {
        if let screen = NSScreen.main {
            if let midX = statusItem.button?.window?.frame.midX, midX > screen.frame.minX + 200 {
                return midX
            }
            return screen.frame.maxX - 140
        }
        return statusItem.button?.window?.frame.midX ?? 900
    }

    private func ensureRunningAnimation() {
        let shouldAnimate = (subworkerManager.runningCount > 0 && primaryStyle != "default")
        if shouldAnimate && runningIconTimer == nil {
            // Frames are cheap now (cached static + one ring blit), so 15fps
            // stays smooth without the old full-recompose cost per tick.
            runningIconTimer = Timer.scheduledTimer(withTimeInterval: 1.0/15.0, repeats: true) { [weak self] _ in
                self?.runningPhase += 0.173
                self?.updateStatusIcon()
            }
            RunLoop.main.add(runningIconTimer!, forMode: .common)
        } else if !shouldAnimate {
            runningIconTimer?.invalidate(); runningIconTimer = nil
        }
    }

    private func grokRingOverlay(style: String, barHeight: CGFloat, phase: Double) -> NSImage {
        let size = barHeight * 0.92
        let c = CGPoint(x: size/2, y: size/2)
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            switch style {
            case "grok", "grokIcon":
                let sq: CGFloat = style == "grok" ? size * 0.82 : size * 0.92
                let half = sq/2, rad: CGFloat = sq*0.28
                let r = NSRect(x: c.x-half, y: c.y-half, width: sq, height: sq)
                let perim: CGFloat = 4*(sq-2*rad)+2*CGFloat.pi*rad
                NSColor.labelColor.withAlphaComponent(0.16).setStroke()
                let t = NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad); t.lineWidth=1.2; t.stroke()
                let visLen = perim*0.68, orbitPhase = -CGFloat(phase)*10
                let head = NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad); head.lineWidth=2; head.lineCapStyle = .round
                head.setLineDash([visLen, perim-visLen], count: 2, phase: orbitPhase); NSColor.labelColor.withAlphaComponent(0.95).setStroke(); head.stroke()
                let tail = NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad); tail.lineWidth=2; tail.lineCapStyle = .round
                tail.setLineDash([perim*0.22, perim*0.78], count: 2, phase: orbitPhase+visLen+perim*0.05); NSColor.labelColor.withAlphaComponent(0.35).setStroke(); tail.stroke()
                if style == "grok" {
                    let pulse = 0.5-0.5*cos(phase*2.2); let cr: CGFloat = size*0.08+CGFloat(pulse)*size*0.04
                    NSColor.labelColor.withAlphaComponent(0.95).setFill(); NSBezierPath(ovalIn: NSRect(x:c.x-cr,y:c.y-cr,width:cr*2,height:cr*2)).fill()
                }
            case "pulseIcon":
                let sc = 1+0.38*sin(phase); let rr: CGFloat = size*0.38*sc; let sq: CGFloat = size*0.92, rad: CGFloat = sq*0.27
                NSColor.systemGreen.withAlphaComponent(0.26).setFill(); NSBezierPath(roundedRect: NSRect(x:c.x-rr*1.45,y:c.y-rr*1.45,width:rr*2.9,height:rr*2.9), xRadius: rad, yRadius: rad).fill()
                NSColor.systemGreen.setFill(); NSBezierPath(roundedRect: NSRect(x:c.x-rr*0.95,y:c.y-rr*0.95,width:rr*1.9,height:rr*1.9), xRadius: rad*0.7, yRadius: rad*0.7).fill()
            default: break
            }
            return true
        }
    }

    // Static square behind the animated ring (banner png, or transparent).
    // Cached per content key so per-frame work is only the ring blit.
    private func grokBannerBase(style: String, barHeight: CGFloat) -> NSImage {
        let size = barHeight * 0.92
        if style == "grok" {
            return NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in true }
        }
        let base = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in true }
        if let icon = Self.runningBannerIcon {
            let s: CGFloat = size*0.78
            let sq: CGFloat = size*0.92, rad: CGFloat = sq*0.27
            let rr = NSRect(x: size/2-s/2, y: size/2-s/2, width: s, height: s)
            base.lockFocus()
            let inset=(sq-s)/2; let iconRad=max(0,rad-inset)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rr, xRadius: iconRad, yRadius: iconRad).addClip()
            icon.draw(in: rr, from: NSRect(origin:.zero,size:icon.size), operation:.sourceOver, fraction:1)
            NSGraphicsContext.restoreGraphicsState()
            base.unlockFocus()
        }
        return base
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
        ensureRunningAnimation()

        let barHeight = max(NSStatusBar.system.thickness, 20)
        var runningNames = subworkerManager.sortedRunningNames()
        for sw in subworkerManager.subworkers where sw.lastError != nil && !runningNames.contains(sw.name) {
            runningNames.append(sw.name)
        }
        // Content key for the paint cache: quantized phase keeps animating while
        // duplicate fires inside one bucket skip the full CoreText/fleet compose.
        let defs = UserDefaults.standard
        let iconKey = "\(subworkerManager.wsConnected)|\(subworkerManager.runningCount)|\(subworkerManager.serverHealth?.healthStatus ?? "-")|\(primaryStyle)|\(Int((runningPhase * 10).rounded()))|\(runningNames.joined(separator: ","))|\(colimaManager.hasRunningInstance)|\(colimaManager.instances.contains { $0.status.isTransitioning })|\(barHeight)|\(defs.string(forKey: "fleetPhotosSide") ?? "left")|\(defs.object(forKey: "fleetLeftPad") as? Double ?? 3)|\(defs.string(forKey: "dropPhotoShape") ?? "round")"
        if iconKey == lastIconKey { return }
        lastIconKey = iconKey

        iconPhotoCount = 0
        iconPhotoNames = []

        let hasRunning = colimaManager.hasRunningInstance
        let hasTransitioning = colimaManager.instances.contains { $0.status.isTransitioning }

        let swDisconnected = !subworkerManager.wsConnected
        let swRunning = subworkerManager.runningCount

        if swDisconnected {
            AppLog.d("icon fallback disconnected ws=\(subworkerManager.wsConnected) lastError=\(subworkerManager.lastError ?? "-") statusError=\(subworkerManager.statusError ?? "-") running=\(swRunning) fleet=\(runningNames.count) photosBefore=\(iconPhotoCount)")
            let symbolName = "circle.slash"
            let config = NSImage.SymbolConfiguration(pointSize: barHeight * 0.58, weight: .medium)
            guard let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return }
            button.image = tintedSymbol(baseImage, color: .systemRed)
            iconPhotoCount = 0
            iconPhotoNames = []
            return
        }

        // Elia system healthy → custom brain banner or animated primary when running
        if subworkerManager.serverHealth?.healthStatus == "healthy" {
            let style = primaryStyle
            if swRunning > 0 && style != "default" {
                let staticKey = "\(swDisconnected)|\(swRunning)|\(subworkerManager.serverHealth?.healthStatus ?? "-")|\(style)|\(runningNames.joined(separator: ","))|\(hasRunning)|\(hasTransitioning)|\(barHeight)|\(defs.string(forKey: "fleetPhotosSide") ?? "left")|\(defs.object(forKey: "fleetLeftPad") as? Double ?? 3)|\(defs.string(forKey: "dropPhotoShape") ?? "round")"
                if staticKey != lastStaticKey || cachedStaticIcon == nil {
                    iconBaseStartX = 0
                    var base = badgeImage(base: grokBannerBase(style: style, barHeight: barHeight), count: swRunning, barHeight: barHeight)
                    if !runningNames.isEmpty {
                        base = appendFleetPhotos(to: base, names: runningNames, barHeight: barHeight)
                    }
                    cachedStaticIcon = base
                    lastStaticKey = staticKey
                }
                guard let stat = cachedStaticIcon else { return }
                let size = barHeight * 0.92
                let frame = stat.copy() as! NSImage
                frame.lockFocus()
                grokRingOverlay(style: style, barHeight: barHeight, phase: runningPhase).draw(
                    in: NSRect(x: iconBaseStartX, y: (frame.size.height - size) / 2, width: size, height: size),
                    from: NSRect(origin: .zero, size: NSSize(width: size, height: size)),
                    operation: .sourceOver, fraction: 1.0)
                frame.unlockFocus()
                button.image = frame
                return
            }
            if let banner = Self.runningBannerIcon?.copy() as? NSImage {
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
        }

        // Docker up but OpenCode server unreachable → red X banner.
        if hasRunning, let xBanner = Self.serverDownBannerIcon?.copy() as? NSImage {
            xBanner.size = NSSize(width: barHeight * 0.92, height: barHeight * 0.92)
            button.image = xBanner
            iconPhotoCount = 0
            iconPhotoNames = []
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
            iconPhotoNames = []
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
        AppLog.d("setupMenu: button nil=\(statusItem.button == nil) window nil=\(statusItem.button?.window == nil) menuItems=\(mainMenu?.numberOfItems ?? -1) ws=\(subworkerManager.wsConnected) subs=\(subworkerManager.subworkers.count)")
        ensureStatusItemAlive()
        statusItem.menu = nil
        let menu = NSMenu()
        menu.delegate = self

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

        // ── Server Connection Settings (submenu — keeps the main dropdown clean)
        addServerConnectionSubmenu(to: menu)

        menu.addItem(NSMenuItem.separator())

        // Topbar settings
        let settingsItem = NSMenuItem(title: "⚙️ Topbar Settings…", action: #selector(openTopbarSettings(_:)), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = launchAtLoginEnabled ? .on : .off
        menu.addItem(launchItem)

        // Quit
        let quitItem = NSMenuItem(title: "Quit EliaTopBar", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        mainMenu = menu
    }

    // MARK: - Server Connection Submenu

    private func addServerConnectionSubmenu(to menu: NSMenu) {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        // Refresh
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshStatus), keyEquivalent: "r")
        refreshItem.target = self
        submenu.addItem(refreshItem)

        submenu.addItem(NSMenuItem.separator())

        // Server URL preference
        addServerURLMenuItems(to: submenu)

        submenu.addItem(NSMenuItem.separator())

        // Remote domain via Cloudflare Tunnel — requires local network
        addTunnelMenuItems(to: submenu)

        let parentItem = NSMenuItem(title: "🔌 Server Connection Settings", action: nil, keyEquivalent: "")
        parentItem.submenu = submenu
        menu.addItem(parentItem)
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
            if subworkerManager.subworkers.isEmpty { return }
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
        // Stable server list order in both lists: no reshuffling.
        let active = subworkerManager.subworkers
            .filter { $0.enabled }
        let inactive = subworkerManager.subworkers
            .filter { !$0.enabled }

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

    private func clampPopoverInsideScreen(_ popover: NSPopover) {
        DispatchQueue.main.async { [weak popover] in
            guard let popover, popover.isShown,
                  let win = popover.contentViewController?.view.window,
                  let screen = win.screen ?? NSScreen.main else { return }
            let margin: CGFloat = 8
            var frame = win.frame
            let maxRight = screen.visibleFrame.maxX - margin
            let minLeft = screen.visibleFrame.minX + margin
            if frame.maxX > maxRight { frame.origin.x = maxRight - frame.width }
            if frame.minX < minLeft { frame.origin.x = minLeft }
            if frame != win.frame { win.setFrame(frame, display: true) }
        }
    }

    private func closeAllLogPopovers() {
        if let popover = logPopover, popover.isShown { popover.performClose(nil) }
        logPopover = nil
        if let popover = subworkerLogPopover, popover.isShown { popover.performClose(nil) }
        subworkerLogPopover = nil
        subworkerLogPopoverName = nil
    }

    private var viewerPreferredUI: String { UserDefaults.standard.string(forKey: "viewerPreferredUI") ?? "logViewer" }
    @objc private func showLogs(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        if viewerPreferredUI == "miniBubble" {
             closeAllLogPopovers(); let dropX = menuBarAnchorX(); RunPopupController.shared.show(for: name, dropX: dropX, duration: effectiveRunPopupDuration, baseURL: subworkerManager.currentBaseURL, showSessionSelector: true, disableAutoClose: true); return
        }
        closeAllLogPopovers()

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 500, height: 400)
        popover.behavior = .semitransient

        let logView = LogPopoverView(subworkerName: name, baseURL: subworkerManager.currentBaseURL)
        popover.contentViewController = NSHostingController(rootView: logView)

        logPopover = popover
        if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            clampPopoverInsideScreen(popover)
        }
    }

    @objc private func mainItemClicked(_ sender: NSStatusBarButton) {
        AppLog.d("mainItemClicked — button click received buttonNil=\(statusItem.button == nil) windowNil=\(statusItem.button?.window == nil) menuItems=\(mainMenu?.numberOfItems ?? -1)")
        if NSApp.currentEvent?.type == .leftMouseDown { return }
        let wasOpenName = subworkerLogPopoverName
        closeAllLogPopovers()
        watchdogCheck()
        ensureStatusItemAlive()
        if mainMenu == nil || (mainMenu?.numberOfItems ?? 0) == 0 {
            AppLog.d("mainMenu was nil/empty at click — rebuilding synchronously")
            setupMenu()
            lastMenuHash = subworkerManager.subworkers.map { "\($0.name):\($0.enabled):\($0.running):\(subworkerManager.wsConnected):\(subworkerManager.hasError):\(subworkerManager.statusError ?? "")" }.joined().hashValue ^ colimaManager.instances.count
            menuRebuildThrottleWorkItem?.cancel()
        }
        let mouse = NSApp.currentEvent?.locationInWindow ?? sender.bounds.origin
        let point = sender.convert(mouse, from: nil)

        if iconPhotoCount > 0, point.x >= iconPhotosStartX,
           point.x < iconPhotosStartX + CGFloat(iconPhotoCount) * iconCellWidth {
            let idx = min(max(Int((point.x - iconPhotosStartX) / iconCellWidth), 0), iconPhotoCount - 1)
            if idx < iconPhotoNames.count {
                let name = iconPhotoNames[idx]
                if RunPopupController.shared.hasPanel(for: name) {
                    RunPopupController.shared.retract(for: name)
                    return
                }
                if wasOpenName == name {
                    return
                }
                 if viewerPreferredUI == "miniBubble" {
                     let dropX = menuBarAnchorX(); RunPopupController.shared.show(for: name, dropX: dropX, duration: effectiveRunPopupDuration, baseURL: subworkerManager.currentBaseURL, showSessionSelector: true, disableAutoClose: true); return
                 }
                showSubworkerLogPopover(for: name, button: sender)
                return
            }
        }
        let shouldCloseDrops = UserDefaults.standard.object(forKey: "closeDropsOnPrimaryClick") as? Bool ?? true
        if shouldCloseDrops && RunPopupController.shared.panelCount > 0 {
            AppLog.d("primaryClick closeAll Drops count=\(RunPopupController.shared.panelCount)")
            RunPopupController.shared.closeAll()
        }
        if let menu = mainMenu {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
        } else {
            AppLog.d("mainMenu still nil — nothing to show")
            statusItem.menu = mainMenu
            statusItem.button?.performClick(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.statusItem.menu = nil }
        }
    }

    private func reconcileSubworkerStatusItems() {
        if let shown = subworkerLogPopoverName,
           !subworkerManager.subworkers.contains(where: { $0.name == shown }) {
            subworkerLogPopover?.performClose(nil)
            subworkerLogPopover = nil
            subworkerLogPopoverName = nil
        }
        // Never mutate @Published state synchronously inside its own Combine sink:
        // that re-publishes on the same runloop turn and recursed until stack-guard
        // overflow (EXC_BAD_ACCESS, 50k-frame cycle via Published.withMutation).
        // Collect here, clear on the next turn — each pass then terminates.
        let now = Date()
        let stale = subworkerManager.subworkers.indices.filter { i in
            !subworkerManager.subworkers[i].running
                && subworkerManager.subworkers[i].lastErrorAt.map({ now.timeIntervalSince($0) > 600 }) == true
        }
        if !stale.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for i in stale where i < self.subworkerManager.subworkers.indices.count {
                    self.subworkerManager.subworkers[i].lastError = nil
                    self.subworkerManager.subworkers[i].lastErrorAt = nil
                }
            }
        }
        updateStatusIcon()
    }

    /// Draw running-agent photos flush against the banner; stuck together.
    private func appendFleetPhotos(to base: NSImage, names: [String], barHeight: CGFloat) -> NSImage {
        let cell = barHeight - 2
        let gap: CGFloat = 1
        let badges: [(photo: NSImage?, monogram: String, color: NSColor, hasError: Bool)] = names.map { name in
            let sw = subworkerManager.subworkers.first(where: { $0.name == name })
            let color = sw.map { subworkerColor(for: $0) } ?? .systemGreen
            return (ProfilePhotos.shared.circularPhoto(for: name, size: 24),
                    monogram(for: name),
                    color,
                    sw?.lastError != nil)
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
        iconPhotoNames = names

        let total: CGFloat = side == "right"
            ? iconPhotosStartX + CGFloat(names.count) * cell
            : fleetWidth + base.size.width
        let isSquare = (UserDefaults.standard.string(forKey: "dropPhotoShape") ?? "round") == "square"
        let composed = NSImage(size: NSSize(width: total, height: max(base.size.height, barHeight)))
        composed.lockFocus()
        for (i, badge) in badges.enumerated() {
            let rect = NSRect(x: iconPhotosStartX + CGFloat(i) * cell, y: 0, width: cell, height: barHeight)
            let diameter = rect.height * 0.86
            let dotRect = NSRect(x: rect.midX - diameter / 2,
                                 y: (rect.height - diameter) / 2,
                                 width: diameter,
                                 height: diameter)
            let dotRadius: CGFloat = isSquare ? diameter * 0.27 : diameter / 2
            let dotPath = NSBezierPath(roundedRect: dotRect, xRadius: dotRadius, yRadius: dotRadius)
            badge.color.setFill()
            dotPath.fill()

            NSGraphicsContext.saveGraphicsState()
            let photoRect = dotRect.insetBy(dx: 1, dy: 1)
            let photoRadius: CGFloat = photoRect.width / 2
            NSBezierPath(roundedRect: photoRect, xRadius: photoRadius, yRadius: photoRadius).addClip()
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
            if badge.hasError {
                let badgeR = diameter * 0.30
                let badgeRect = NSRect(
                    x: dotRect.maxX - badgeR * 1.9,
                    y: dotRect.maxY - badgeR * 1.9,
                    width: badgeR * 2,
                    height: badgeR * 2
                )
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: badgeRect).fill()
                NSColor.white.setStroke()
                NSBezierPath(ovalIn: badgeRect).stroke()
                let font = NSFont.systemFont(ofSize: badgeR * 1.1, weight: .black)
                let str = NSAttributedString(string: "!", attributes: [.font: font, .foregroundColor: NSColor.white])
                let tsz = str.size()
                str.draw(at: NSPoint(x: badgeRect.midX - tsz.width / 2, y: badgeRect.midY - tsz.height / 2))
            }
        }
        let baseX: CGFloat = side == "right" ? 0 : fleetWidth
        iconBaseStartX = baseX
        base.draw(at: NSPoint(x: baseX, y: (barHeight - base.size.height) / 2),
                  from: .zero, operation: .sourceOver, fraction: 1.0)
        composed.unlockFocus()
        return composed
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
        if viewerPreferredUI == "miniBubble" {
             let dropX = menuBarAnchorX(); RunPopupController.shared.show(for: name, dropX: dropX, duration: effectiveRunPopupDuration, baseURL: subworkerManager.currentBaseURL, showSessionSelector: true); return
         }
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
        popover.behavior = .semitransient
        popover.contentViewController = NSHostingController(
            rootView: LogPopoverView(subworkerName: name, baseURL: subworkerManager.currentBaseURL)
        )
        subworkerLogPopover = popover
        subworkerLogPopoverName = name
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        clampPopoverInsideScreen(popover)
    }

    // MARK: - Subworker Actions

    @objc private func triggerSubworker(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        subworkerManager.triggerSubworker(name)
    }

    @objc private func enableSubworker(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        subworkerManager.enableSubworker(name)
        updateStatusIcon()
        forceMenuRebuild()
    }

    @objc private func disableSubworker(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        subworkerManager.disableSubworker(name)
        updateStatusIcon()
        forceMenuRebuild()
    }

    private func forceMenuRebuild() {
        menuRebuildThrottleWorkItem?.cancel()
        menuRebuildThrottleWorkItem = nil
        lastMenuHash = subworkerManager.subworkers.map { "\($0.name):\($0.enabled):\($0.running)" }.joined().hashValue ^ colimaManager.instances.count
        setupMenu()
        updateStatusIcon()
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

    @objc private func cleanRamAndIdle(_ sender: NSMenuItem) {
        sender.isEnabled = false
        let original = sender.attributedTitle
        sender.attributedTitle = emojiAwareTitle("🧹 Cleaning…", color: .secondaryLabelColor)
        AppLog.d("Manual RAM cleanup triggered")
        showCleanupLoadingPanel()
        Task { @MainActor [weak self] in
            defer {
                sender.isEnabled = true
                sender.attributedTitle = original
                self?.hideCleanupLoadingPanel()
            }
            guard let self else { return }
            guard let url = URL(string: "\(self.subworkerManager.currentBaseURL)/server/cleanup") else { return }
            var request = EliaAuth.authorize(url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["restart_opencode": true, "run_idle_cleaner": true])
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (json["ok"] as? Bool) == true else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    self.showCleanupAlert(title: "Cleanup failed", message: "HTTP \(code). See logs for details.")
                    return
                }
                let message: String
                var detail = ""
                if let freed = json["freed_mb"] as? Int,
                   let before = json["rss_before_mb"] as? Int,
                   let after = json["rss_after_mb"] as? Int {
                    message = "Freed \(freed) MB (RSS \(before)→\(after)) + idle cleaned."
                } else {
                    message = "Cleanup done (RSS unreadable) + idle cleaned."
                }
                if let oldPid = json["old_pid"] as? Int, let newPid = json["new_pid"] as? Int {
                    detail += "opencode pid \(oldPid) → \(newPid)\n"
                }
                if let steps = json["steps"] as? [[String: Any]] {
                    for step in steps {
                        let name = step["name"] as? String ?? "?"
                        let ok = (step["ok"] as? Bool) ?? false
                        let info = step["detail"] as? String ?? ""
                        let ms = step["duration_ms"] as? Int ?? 0
                        detail += "\(ok ? "✅" : "❌") \(name) — \(info) (\(ms)ms)\n"
                    }
                }
                if let procs = json["processes"] as? [[String: Any]], !procs.isEmpty {
                    detail += "\nCleaned processes:\n"
                    for proc in procs.prefix(20) {
                        let pid = proc["pid"] as? Int ?? 0
                        let label = proc["label"] as? String ?? "?"
                        detail += "  • pid \(pid) [\(label)]\n"
                    }
                    if procs.count > 20 {
                        detail += "  … +\(procs.count - 20) more\n"
                    }
                } else {
                    detail += "\nNo stale processes found — nothing to kill."
                }
                if let ms = json["duration_ms"] as? Int {
                    detail += "\nTotal: \(ms)ms"
                }
                AppLog.d("cleanup done: \(message)")
                self.showCleanupDetailAlert(title: "RAM Cleanup Done", message: message, detail: detail)
                await self.subworkerManager.fetchServerHealth()
                await self.subworkerManager.fetchStatus()
            } catch {
                self.showCleanupAlert(title: "Cleanup failed", message: error.localizedDescription)
            }
        }
    }

    private func showCleanupDetailAlert(title: String, message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 200))
        scroll.hasVerticalScroller = true
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 200))
        textView.string = detail
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.isEditable = false
        textView.backgroundColor = .clear
        scroll.documentView = textView
        alert.accessoryView = scroll
        alert.runModal()
    }

    private func showCleanupAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showCleanupLoadingPanel() {
        if cleanupLoadingPanel != nil { return }
        guard let screen = NSScreen.main else { return }
        let width: CGFloat = 260, height: CGFloat = 44
        let x = menuBarAnchorX() - width/2
        let y = screen.frame.maxY - NSStatusBar.system.thickness - height - 8
        let frame = NSRect(x: max(screen.frame.minX+8, min(x, screen.frame.maxX-width-8)), y: y, width: width, height: height)
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar; p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true; p.isMovableByWindowBackground = false
        p.contentView = NSHostingView(rootView: CleanupLoadingView())
        p.orderFrontRegardless()
        p.alphaValue = 0
        NSAnimationContext.runAnimationGroup({ ctx in ctx.duration=0.22; ctx.timingFunction=CAMediaTimingFunction(name:.easeInEaseOut); p.animator().alphaValue=1 })
        cleanupLoadingPanel = p
    }

    private func hideCleanupLoadingPanel() {
        guard let p = cleanupLoadingPanel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in ctx.duration=0.18; p.animator().alphaValue=0 }, completionHandler: { p.orderOut(nil); self.cleanupLoadingPanel=nil })
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
            lastIconKey = ""
            lastStaticKey = ""
            cachedStaticIcon = nil
            updateStatusIcon()
            reconcileSubworkerStatusItems()
            setupMenu()
        }
    }

    @objc private func removeProfilePhoto(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        ProfilePhotos.shared.removePhoto(for: name)
        lastIconKey = ""
        lastStaticKey = ""
        cachedStaticIcon = nil
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 404, height: 640),
                              styleMask: [.titled, .closable, .resizable],
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
                let dropX = self.menuBarAnchorX()
                let name = self.subworkerManager.subworkers.first?.name ?? "test-agent"
                 let dur = self.effectiveRunPopupDuration
                  RunPopupController.shared.show(for: name, dropX: dropX, duration: dur == 0 ? 10 : dur, baseURL: subworkerManager.currentBaseURL, disableAutoClose: true)
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
        alert.informativeText = "Enter your domain (e.g. your-domain.com) and your Cloudflare API Token (Zone:DNS Edit + Account:Tunnel Edit). The server will create the tunnel on your Mac (local network required)."
        alert.addButton(withTitle: "Setup Tunnel")
        alert.addButton(withTitle: "Cancel")
        let domainField = NSTextField(string: UserDefaults.standard.string(forKey: "tunnelDomain") ?? "")
        domainField.placeholderString = "your-domain.com"
        domainField.frame = NSRect(x: 0, y: 48, width: 320, height: 24)
        let tokenField = NSTextField(string: UserDefaults.standard.string(forKey: "cfApiToken") ?? "")
        tokenField.placeholderString = "Cloudflare API Token (or Global API Key cfk_...)"
        tokenField.frame = NSRect(x: 0, y: 24, width: 320, height: 24)
        let emailField = NSTextField(string: UserDefaults.standard.string(forKey: "cfEmail") ?? "wael.bousfira@gmail.com")
        emailField.placeholderString = "Cloudflare Email (only for Global API Key)"
        emailField.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        container.addSubview(domainField)
        container.addSubview(tokenField)
        container.addSubview(emailField)
        alert.accessoryView = container
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let domain = domainField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let token = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = emailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !domain.isEmpty, !token.isEmpty else { return }
        UserDefaults.standard.set(domain, forKey: "tunnelDomain")
        UserDefaults.standard.set(token, forKey: "cfApiToken")
        if !email.isEmpty { UserDefaults.standard.set(email, forKey: "cfEmail") }
        let baseURL = UserDefaults.standard.string(forKey: "subworkerServerURL") ?? "http://localhost:5656"
        guard let url = URL(string: "\(baseURL)/tunnel/setup") else { return }
        var req = EliaAuth.authorize(url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Auto-detect Global API Key (cfk_ or 37 hex) vs Bearer token
        let isGlobal = token.hasPrefix("cfk_") || token.count == 37
        if isGlobal && !email.isEmpty {
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["domain": domain, "global_key": token, "email": email])
        } else {
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["domain": domain, "api_token": token])
        }
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
            for (index, instance) in colimaManager.instances.enumerated() {
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

                if index == 0 {
                    instanceMenu.addItem(NSMenuItem.separator())
                    let cleanupItem = NSMenuItem(title: "", action: #selector(cleanRamAndIdle(_:)), keyEquivalent: "")
                    cleanupItem.attributedTitle = emojiAwareTitle("🧹 Clean RAM + Idle Cleaner", color: .labelColor)
                    cleanupItem.target = self
                    instanceMenu.addItem(cleanupItem)
                }

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
        openModelMenu = menu
        openModelAgent = agentName
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
        let email = UserDefaults.standard.string(forKey: "cfEmail") ?? ""
        let isGlobal = token.hasPrefix("cfk_") || token.count == 37
        if isGlobal && !email.isEmpty {
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["domain": domain, "global_key": token, "email": email])
        } else {
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["domain": domain, "api_token": token])
        }
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
