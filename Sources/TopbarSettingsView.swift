import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Topbar placement planner: live realistic menu bar preview with a draggable
/// primary icon, plus the settings that genuinely apply (photo side, padding).
///
/// macOS exposes no API to place an NSStatusItem next to Wi-Fi/battery — the only
/// supported mechanism is native ⌘-drag reordering, which this UI teaches.
/// The preview below simulates that: drag the 🧠 icon between the system icons
/// to preview real placement. Order persists in `previewBarOrder`.
struct TopbarSettingsView: View {
    var iconProvider: () -> NSImage?
    var onRefresh: () -> Void
    var onTestRunPopup: () -> Void = {}
    var onOrderChange: (String) -> Void

    @State private var barOrder: [BarSlot] = BarSlot.storedOrDefault
    @State private var photosSide: String = UserDefaults.standard.string(forKey: "fleetPhotosSide") ?? "left"
    @State private var leftPad: Double = UserDefaults.standard.object(forKey: "fleetLeftPad") as? Double ?? 3
    @State private var runPopupDuration: Double = UserDefaults.standard.object(forKey: "runPopupDuration") as? Double ?? 10
    @State private var showGuide = false
    @State private var orderMode: String = UserDefaults.standard.string(forKey: "fleetOrderMode") ?? "default"
    @State private var primaryStyle: String = UserDefaults.standard.string(forKey: "primaryIconStyle") ?? "default"
    @State private var previewPhase: Double = 0
    private let previewTimer = Timer.publish(every: 1.0/20.0, on: .main, in: .common).autoconnect()
    @State private var runPopupEnabled: Bool = (UserDefaults.standard.object(forKey: "runPopupDuration") as? Double ?? 10) > 0
    @State private var maxDrops: Int = UserDefaults.standard.object(forKey: "runPopupMaxConcurrent") as? Int ?? 10
    @State private var customEnabled: Bool = UserDefaults.standard.bool(forKey: "runPopupCustomEnabled")
    @State private var customDuration: Double = UserDefaults.standard.object(forKey: "runPopupCustomDuration") as? Double ?? 15
    @State private var dropPhotoShape: String = UserDefaults.standard.string(forKey: "dropPhotoShape") ?? "round"
    @State private var dropIconPosition: String = UserDefaults.standard.string(forKey: "dropIconPosition") ?? "above"
    @State private var subagentPosition: String = UserDefaults.standard.string(forKey: "subagentPosition") ?? "right"
    @State private var teamTasksPosition: String = UserDefaults.standard.string(forKey: "teamTasksPosition") ?? "side"
    @State private var dropDraggableEnabled: Bool = UserDefaults.standard.bool(forKey: "dropDraggableEnabled")
    @State private var closeDropsOnPrimaryClick: Bool = (UserDefaults.standard.object(forKey: "closeDropsOnPrimaryClick") as? Bool ?? true)
    @State private var viewerChoice: String = UserDefaults.standard.string(forKey: "viewerPreferredUI") ?? "logViewer"
    @State private var profile: String = UserDefaults.standard.string(forKey: "eliaProfile") ?? "developer"
    @State private var showSticker: Bool = (UserDefaults.standard.object(forKey: "dropShowSticker") as? Bool ?? true)
    @State private var showTodo: Bool = (UserDefaults.standard.object(forKey: "dropShowTodo") as? Bool ?? true)
    @State private var showSubagents: Bool = (UserDefaults.standard.object(forKey: "dropShowSubagents") as? Bool ?? true)

    private let defaults = UserDefaults.standard

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    if let logo = BrandAssets.sherlock {
                        Image(nsImage: logo)
                            .resizable().scaledToFill()
                            .frame(width: 24, height: 24)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    Text("EliaTopBar for OpenCode/EliaAgent")
                        .font(.system(size: 13, weight: .semibold))
                    Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")")
                        .font(.caption2).foregroundColor(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12)).cornerRadius(5)
                    Spacer()
                    Link(destination: URL(string: "https://github.com/vakandi/Elia-Topbar")!) {
                        HStack(spacing: 4) {
                            if let mark = BrandAssets.githubMark {
                                Image(nsImage: mark)
                                    .resizable().scaledToFit()
                                    .frame(width: 14, height: 14)
                            }
                            Text("by @vakandi").font(.caption2)
                        }
                    }
                    Button(action: { onRefresh() }) {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                menuBarPreview

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Agent photos", selection: $photosSide) {
                        Text("Left of banner").tag("left")
                        Text("Right of banner").tag("right")
                    }
                    .onChange(of: photosSide) { side in
                        defaults.set(side, forKey: "fleetPhotosSide")
                        onRefresh()
                    }

                    HStack {
                        Text(photosSide == "right" ? "Right padding" : "Left padding")
                        Slider(value: $leftPad, in: 0...10, step: 1)
                            .onChange(of: leftPad) { _ in
                                defaults.set(leftPad, forKey: "fleetLeftPad")
                                onRefresh()
                            }
                        Text("\(Int(leftPad))pt").monospacedDigit().foregroundColor(.secondary)
                    }

                    Picker("Icon order", selection: $orderMode) {
                        Text("Default (server)").tag("default")
                        Text("Most runs first").tag("runs_desc")
                        Text("Fewest runs first").tag("runs_asc")
                        Text("Latest message (live)").tag("latest_msg")
                        Text("Alphabetical A→Z").tag("alpha")
                    }
                    .onChange(of: orderMode) { mode in
                        defaults.set(mode, forKey: "fleetOrderMode")
                        onOrderChange(mode)
                        onRefresh()
                    }

                    Picker("Primary when running", selection: $primaryStyle) {
                        ForEach(GrokStyles.all, id: \.id) { s in
                            Text(s.label).tag(s.id)
                        }
                    }
                    .onChange(of: primaryStyle) { v in
                        defaults.set(v, forKey: "primaryIconStyle")
                        onRefresh()
                    }
                }
                .padding(6)
            } label: {
                Text("Layout").font(.caption).foregroundColor(.secondary)
            }

            GroupBox {
                HStack {
                    Text("Preview")
                    Spacer()
                    if let img = previewNSImage(for: primaryStyle, phase: previewPhase) {
                        Image(nsImage: img)
                            .frame(width: 32, height: 20)
                    }
                    Text(primaryStyle == "default" ? "Default" : primaryStyle).font(.caption2).foregroundColor(.secondary)
                }
            } label: {
                Text("Primary preview (when agent running)").font(.caption).foregroundColor(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Profile", selection: $profile) {
                        Text("Developer").tag("developer")
                        Text("Calm").tag("calm")
                        Text("Minimal").tag("minimal")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: profile) { v in applyProfile(v) }
                    Text(profileCaption)
                        .font(.caption2).foregroundColor(.secondary)
                }
                .padding(6)
            } label: {
                Text("Profile — one tap setup").font(.caption).foregroundColor(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Live stats header (traffic, tools, msgs)", isOn: $showSticker)
                        .onChange(of: showSticker) { v in defaults.set(v, forKey: "dropShowSticker"); onRefresh() }
                    Toggle("Todo strip (fused card + side panel)", isOn: $showTodo)
                        .onChange(of: showTodo) { v in defaults.set(v, forKey: "dropShowTodo"); onRefresh() }
                    Toggle("Subagent strip (groks + bubbles)", isOn: $showSubagents)
                        .onChange(of: showSubagents) { v in defaults.set(v, forKey: "dropShowSubagents"); onRefresh() }
                    Picker("Subagents", selection: $subagentPosition) {
                        Text("Left of bubble").tag("left")
                        Text("Right of bubble").tag("right")
                    }
                    .onChange(of: subagentPosition) { v in
                        defaults.set(v, forKey: "subagentPosition")
                        onRefresh()
                    }
                    .disabled(!showSubagents)
                    Picker("Team tasks", selection: $teamTasksPosition) {
                        Text("Above RunPopup").tag("above")
                        Text("Right side bar").tag("side")
                    }
                    .onChange(of: teamTasksPosition) { v in
                        defaults.set(v, forKey: "teamTasksPosition")
                        onRefresh()
                    }
                    .disabled(!showSubagents)
                }
                .padding(6)
            } label: {
                Text("Drop panels").font(.caption).foregroundColor(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Enable drop livestream on agent start", isOn: $runPopupEnabled)
                        .onChange(of: runPopupEnabled) { enabled in
                            if enabled {
                                if runPopupDuration == 0 { runPopupDuration = 10 }
                                defaults.set(runPopupDuration, forKey: "runPopupDuration")
                                NotificationCenter.default.post(name: .eliaRunPopupEnabledChanged, object: nil)
                            } else {
                                defaults.set(0, forKey: "runPopupDuration")
                                runPopupDuration = 0
                            }
                        }
                    HStack {
                        Text("Duration")
                        Slider(value: $runPopupDuration, in: 0...30, step: 1)
                            .disabled(!runPopupEnabled || customEnabled)
                            .onChange(of: runPopupDuration) { v in
                                defaults.set(v, forKey: "runPopupDuration")
                                runPopupEnabled = v > 0
                            }
                        Text(!runPopupEnabled || runPopupDuration == 0 ? "Off" : "\(Int(customEnabled ? customDuration : runPopupDuration))s")
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                            .frame(width: 34, alignment: .trailing)
                        Button("Test") { onTestRunPopup() }
                            .controlSize(.small)
                            .disabled(!runPopupEnabled)
                    }
                    HStack {
                        Text("Max drops at once")
                        Spacer()
                        Picker("", selection: $maxDrops) {
                            ForEach(1...10, id: \.self) { n in Text("\(n)").tag(n) }
                        }
                        .frame(width: 80)
                        .labelsHidden()
                        .disabled(!runPopupEnabled)
                        .onChange(of: maxDrops) { v in defaults.set(v, forKey: "runPopupMaxConcurrent") }
                    }
                    HStack {
                        Toggle("Custom duration", isOn: $customEnabled)
                            .onChange(of: customEnabled) { on in
                                defaults.set(on, forKey: "runPopupCustomEnabled")
                                if on && customDuration == 0 { customDuration = 15; defaults.set(15, forKey: "runPopupCustomDuration") }
                            }
                        TextField("sec", value: $customDuration, format: .number)
                            .frame(width: 60)
                            .textFieldStyle(.roundedBorder)
                            .disabled(!customEnabled || !runPopupEnabled)
                            .onChange(of: customDuration) { v in defaults.set(v, forKey: "runPopupCustomDuration") }
                        Text("s").foregroundColor(.secondary)
                        Spacer()
                    }
                    .opacity(customEnabled ? 1 : 0.5)
                    Picker("Agent icon", selection: $dropPhotoShape) {
                        Text("Round").tag("round")
                        Text("Square (primary radius)").tag("square")
                    }
                    .onChange(of: dropPhotoShape) { v in
                        defaults.set(v, forKey: "dropPhotoShape")
                        onRefresh()
                    }
                    Picker("Icon position", selection: $dropIconPosition) {
                        Text("Above bubble").tag("above")
                        Text("Left of bubble").tag("left")
                        Text("Right of bubble").tag("right")
                        Text("Tiny in header").tag("inlineTiny")
                    }
                    .onChange(of: dropIconPosition) { v in
                        defaults.set(v, forKey: "dropIconPosition")
                        onRefresh()
                    }
                    Toggle("Enable draggable Drops", isOn: $dropDraggableEnabled)
                        .onChange(of: dropDraggableEnabled) { v in
                            defaults.set(v, forKey: "dropDraggableEnabled")
                            NotificationCenter.default.post(name: .eliaRunPopupDraggableChanged, object: nil)
                            Task{ @MainActor in RunPopupController.shared.refreshAllDraggable() }
                            onRefresh()
                        }
                    if dropDraggableEnabled {
                        Text("Drag any Drop anywhere — it stays where you drop it. Lock button appears in the Drop header.")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    Toggle("Close all Drops when opening menu", isOn: $closeDropsOnPrimaryClick)
                        .onChange(of: closeDropsOnPrimaryClick) { v in
                            defaults.set(v, forKey: "closeDropsOnPrimaryClick")
                            onRefresh()
                        }
                    Text("Photo + live bubble dropping from the icon when an agent starts. Hover to keep open — retracts 1.5s after mouse leaves. Click to dismiss.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(6)
            } label: {
                Text("Run animation").font(.caption).foregroundColor(.secondary)
            }

            GroupBox {
                VStack(alignment:.leading, spacing:8){
                    Picker("When clicking agent / View logs", selection: $viewerChoice){
                        Text("Log Viewer (full)").tag("logViewer")
                        Text("Mini bubble (Drop)").tag("miniBubble")
                    }
                    .onChange(of: viewerChoice){ v in defaults.set(v, forKey:"viewerPreferredUI"); onRefresh() }
                    HStack(spacing:8){
                        Button("Reset") { viewerChoice="logViewer"; defaults.set("logViewer", forKey:"viewerPreferredUI"); defaults.removeObject(forKey:"viewerRememberMini"); onRefresh() }.controlSize(.small)
                        Text("Remember from LogViewer checkbox").font(.caption2).foregroundColor(.secondary)
                    }
                }.padding(6)
            } label: { Text("Viewer & icons").font(.caption).foregroundColor(.secondary) }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Label("macOS decides icon order — no app can self-place next to Wi-Fi.", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Find my icon (pulse it)") {
                        NotificationCenter.default.post(name: .eliaPulseMainIcon, object: nil)
                    }
                    .controlSize(.small)
                    Button(showGuide ? "Hide reorder steps" : "How to move it next to Wi-Fi / battery") { showGuide.toggle() }
                        .controlSize(.small)
                    if showGuide {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Move the icon next to Wi-Fi / battery:")
                                .font(.caption).fontWeight(.semibold)
                            Text("1. Close this window")
                            Text("2. Hold the ⌘ Command key on your keyboard")
                            Text("3. While holding ⌘, click and HOLD the brain icon in the real menu bar (top-right of your screen)")
                            Text("4. Keep ⌘ held and drag it left/right — you will see it slide between Wi-Fi, battery, clock…")
                            Text("5. Drop it where you want (e.g. right of the Wi-Fi symbol)")
                            Text("6. Release, then release ⌘")
                            Text("The agent photos are part of the same icon — they move with it.")
                                .foregroundColor(.secondary)
                        }
                        .font(.caption)
                        .textSelection(.enabled)
                    }
                }
                .padding(6)
            } label: {
                Text("Placement (system-managed)").font(.caption).foregroundColor(.secondary)
            }
            }
            .padding(14)
        }
        .frame(width: 430)
        .frame(maxHeight: 600)
        .onReceive(previewTimer) { _ in previewPhase += 0.13 }
    }

    private var profileCaption: String {
        switch profile {
        case "calm": return "Calm — drops stay, stats header off. For following runs without the numbers."
        case "minimal": return "Minimal — no drops, dots + LogViewer only. For non-dev daily use."
        default: return "Developer — full livestream: stats, todos, subagents. For active building."
        }
    }
    private func applyProfile(_ v: String) {
        defaults.set(v, forKey: "eliaProfile")
        if v == "developer" {
            runPopupEnabled = true; if runPopupDuration == 0 { runPopupDuration = 10; defaults.set(10, forKey: "runPopupDuration") }
            showSticker = true; showTodo = true; showSubagents = true
        } else if v == "calm" {
            runPopupEnabled = true; if runPopupDuration == 0 { runPopupDuration = 10; defaults.set(10, forKey: "runPopupDuration") }
            showSticker = false; showTodo = true; showSubagents = true
        } else {
            runPopupEnabled = false; runPopupDuration = 0; defaults.set(0, forKey: "runPopupDuration")
            showSticker = false; showTodo = false; showSubagents = false
        }
        defaults.set(showSticker, forKey: "dropShowSticker")
        defaults.set(showTodo, forKey: "dropShowTodo")
        defaults.set(showSubagents, forKey: "dropShowSubagents")
        NotificationCenter.default.post(name: .eliaRunPopupEnabledChanged, object: nil)
        onRefresh()
    }

    // MARK: - Live menu bar preview

    private var menuBarPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Live menu bar preview")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Reset order") { resetBarOrder() }
                    .controlSize(.small)
                    .buttonStyle(.link)
            }
            HStack(spacing: 2) {
                ForEach(barOrder) { slot in
                    slotView(slot)
                        .onDrop(of: [.text], delegate: PrimaryDropDelegate(target: slot, order: $barOrder))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.35)))
            Text("Drag the 🧠 icon between Wi-Fi, battery, clock… to preview real placement. (Real move: hold ⌘ and drag the live icon.)")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func slotView(_ slot: BarSlot) -> some View {
        switch slot {
        case .wifi: sysIcon("wifi")
        case .bluetooth: sysIcon("bluetooth")
        case .battery: sysIcon("battery.50")
        case .search: sysIcon("magnifyingglass")
        case .control: sysIcon("switch.2")
        case .date: dateCell
        case .primary: primaryCell
        }
    }

    private func sysIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.primary)
            .frame(minWidth: 26, minHeight: 26)
    }

    private var dateCell: some View {
        Text(dateString)
            .font(.system(size: 13))
            .foregroundColor(.primary)
            .padding(.horizontal, 6)
            .frame(minHeight: 26)
            .lineLimit(1)
            .fixedSize()
    }

    private var dateString: String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("EEdMMMHm")
        return f.string(from: Date())
    }

    /// The draggable primary icon: current style animating at 20fps + fleet
    /// photo dots positioned per settings, so side/padding/style all preview live.
    private var primaryCell: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: max(1, CGFloat(leftPad) * 0.6 + 1)) {
                if photosSide == "left" { fleetDots }
                primaryImage
                if photosSide == "right" { fleetDots }
            }
            .padding(.horizontal, 5)
            .frame(minHeight: 26)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.14)))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            )
            if primaryStyle == "default" {
                Text("2")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 0.5)
                    .background(Capsule().fill(Color.red))
                    .offset(x: 4, y: -6)
            }
        }
        .help("Drag me between Wi-Fi / battery / clock to preview placement")
        .onDrag {
            NSItemProvider(object: NSString(string: "elia-primary"))
        }
    }

    @ViewBuilder
    private var primaryImage: some View {
        if let img = previewNSImage(for: primaryStyle, phase: previewPhase) {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 19)
        } else if let live = iconProvider() {
            Image(nsImage: live)
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 19)
        } else {
            Image(systemName: "brain")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.primary)
                .frame(width: 30, height: 19)
        }
    }

    private var fleetDots: some View {
        HStack(spacing: 1.5) {
            agentDot(letter: "G", color: .green)
            agentDot(letter: "E", color: .purple)
        }
    }

    private func agentDot(letter: String, color: Color) -> some View {
        let isSquare = (UserDefaults.standard.string(forKey: "dropPhotoShape") ?? "round") == "square"
        return ZStack {
            Group {
                if isSquare { RoundedRectangle(cornerRadius: 3.5).fill(color.opacity(0.9)) }
                else { Circle().fill(color.opacity(0.9)) }
            }.frame(width: 13, height: 13)
            Text(letter)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.white)
        }
    }

    private func resetBarOrder() {
        withAnimation(.easeInOut(duration: 0.2)) {
            barOrder = BarSlot.defaultOrder
        }
        UserDefaults.standard.set(barOrder.map(\.rawValue), forKey: "previewBarOrder")
    }

    private func previewNSImage(for style: String, phase: Double) -> NSImage? {
        let barHeight: CGFloat = 20
        if style == "default" {
            guard let p = Bundle.main.path(forResource: "icon_running_topbar", ofType: "png"), let im = NSImage(contentsOfFile: p) else { return nil }
            im.isTemplate = false
            return im
        }
        // Same renderer as the live menu-bar icon: banner base + ring overlay.
        let size = barHeight * 0.92
        let frame = GrokStyles.bannerBase(style: style, barHeight: barHeight).copy() as! NSImage
        frame.lockFocus()
        GrokStyles.ringOverlay(style: style, barHeight: barHeight, phase: phase).draw(
            in: NSRect(x: 0, y: (frame.size.height - size) / 2, width: size, height: size),
            from: NSRect(origin: .zero, size: NSSize(width: size, height: size)),
            operation: .sourceOver, fraction: 1.0)
        frame.unlockFocus()
        frame.isTemplate = false
        return frame
    }
}

// MARK: - Preview bar model

enum BarSlot: String, CaseIterable, Identifiable {
    case wifi, bluetooth, battery, search, primary, control, date
    var id: String { rawValue }

    static var defaultOrder: [BarSlot] {
        [.wifi, .bluetooth, .battery, .primary, .search, .control, .date]
    }

    static var storedOrDefault: [BarSlot] {
        guard let saved = UserDefaults.standard.stringArray(forKey: "previewBarOrder") else {
            return defaultOrder
        }
        let slots = saved.compactMap(BarSlot.init(rawValue:))
        guard Set(slots.map(\.rawValue)) == Set(BarSlot.allCases.map(\.rawValue)) else {
            return defaultOrder
        }
        return slots
    }
}

/// Reorders the primary icon live as it hovers over other slots, so dropping
/// between Wi-Fi / battery / clock previews real ⌘-drag placement.
struct PrimaryDropDelegate: DropDelegate {
    let target: BarSlot
    var order: Binding<[BarSlot]>

    init(target: BarSlot, order: Binding<[BarSlot]>) {
        self.target = target
        self.order = order
    }

    func dropEntered(info: DropInfo) {
        var current = order.wrappedValue
        guard let from = current.firstIndex(of: .primary),
              let to = current.firstIndex(of: target),
              from != to else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            current.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            order.wrappedValue = current
        }
        UserDefaults.standard.set(current.map(\.rawValue), forKey: "previewBarOrder")
    }

    func performDrop(info: DropInfo) -> Bool { true }
}

extension Notification.Name {
    static let eliaPulseMainIcon = Notification.Name("eliaPulseMainIcon")
    static let eliaRunPopupEnabledChanged = Notification.Name("eliaRunPopupEnabledChanged")
    static let eliaShowMiniBubble = Notification.Name("eliaShowMiniBubble")
    static let eliaCloseLogViewer = Notification.Name("eliaCloseLogViewer")
    static let eliaOpenTopbarSettings = Notification.Name("eliaOpenTopbarSettings")
    static let eliaRunPopupDraggableChanged = Notification.Name("eliaRunPopupDraggableChanged")
}
