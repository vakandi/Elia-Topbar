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
    @State private var maxDrops: Int = UserDefaults.standard.object(forKey: "runPopupMaxConcurrent") as? Int ?? 5
    @State private var customEnabled: Bool = UserDefaults.standard.bool(forKey: "runPopupCustomEnabled")
    @State private var customDuration: Double = UserDefaults.standard.object(forKey: "runPopupCustomDuration") as? Double ?? 15

    private let defaults = UserDefaults.standard

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Topbar Settings")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
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
                        Text("Default (banner + count)").tag("default")
                        Text("Grok orbit").tag("grok")
                        Text("Grok orbit + icon").tag("grokIcon")
                        Text("Pulse behind icon").tag("pulseIcon")
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
                        Text(!runPopupEnabled || runPopupDuration == 0 ? "Off" : "\(Int(runPopupDuration))s")
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
                    Text("Photo + live bubble dropping from the icon when an agent starts. Hover to keep open — retracts 1.5s after mouse leaves. Click to dismiss.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(6)
            } label: {
                Text("Run animation").font(.caption).foregroundColor(.secondary)
            }

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
        .frame(width: 430)
        .frame(maxHeight: 600)
        .onReceive(previewTimer) { _ in previewPhase += 0.13 }
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
        ZStack {
            Circle().fill(color.opacity(0.9)).frame(width: 13, height: 13)
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
        let size = barHeight * 0.92
        let c = CGPoint(x: size/2, y: size/2)
        if style == "default" {
            guard let p = Bundle.main.path(forResource: "icon_running_topbar", ofType: "png"), let im = NSImage(contentsOfFile: p) else { return nil }
            im.isTemplate = false
            return im
        }
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            switch style {
            case "grok":
                let sq: CGFloat = size*0.82, half=sq/2, rad=sq*0.28
                let r = NSRect(x: c.x-half, y: c.y-half, width: sq, height: sq)
                let perim: CGFloat = 4*(sq-2*rad)+2*CGFloat.pi*rad
                NSColor.labelColor.withAlphaComponent(0.16).setStroke()
                let t = NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad); t.lineWidth=1.2; t.stroke()
                let visLen = perim*0.68, orbitPhase = -CGFloat(phase)*10
                let head = NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad); head.lineWidth=2; head.lineCapStyle = .round
                head.setLineDash([visLen, perim-visLen], count: 2, phase: orbitPhase); NSColor.labelColor.withAlphaComponent(0.95).setStroke(); head.stroke()
                let tail = NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad); tail.lineWidth=2; tail.lineCapStyle = .round
                tail.setLineDash([perim*0.22, perim*0.78], count: 2, phase: orbitPhase+visLen+perim*0.05); NSColor.labelColor.withAlphaComponent(0.35).setStroke(); tail.stroke()
                let pulse = 0.5-0.5*cos(phase*2.2); let cr: CGFloat = size*0.08+CGFloat(pulse)*size*0.04
                NSColor.labelColor.withAlphaComponent(0.95).setFill(); NSBezierPath(ovalIn: NSRect(x:c.x-cr,y:c.y-cr,width:cr*2,height:cr*2)).fill()
            case "grokIcon":
                let sq: CGFloat = size*0.92, half=sq/2, rad=sq*0.27
                let r = NSRect(x: c.x-half, y: c.y-half, width: sq, height: sq)
                let perim: CGFloat = 4*(sq-2*rad)+2*CGFloat.pi*rad
                NSColor.labelColor.withAlphaComponent(0.16).setStroke()
                let t = NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad); t.lineWidth=1.2; t.stroke()
                let visLen = perim*0.68, orbitPhase = -CGFloat(phase)*10
                let head = NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad); head.lineWidth=2; head.lineCapStyle = .round
                head.setLineDash([visLen, perim-visLen], count: 2, phase: orbitPhase); NSColor.labelColor.withAlphaComponent(0.95).setStroke(); head.stroke()
                let tail = NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad); tail.lineWidth=2; tail.lineCapStyle = .round
                tail.setLineDash([perim*0.22, perim*0.78], count: 2, phase: orbitPhase+visLen+perim*0.05); NSColor.labelColor.withAlphaComponent(0.35).setStroke(); tail.stroke()
                if let icon = Bundle.main.path(forResource: "icon_running_topbar", ofType: "png").flatMap({ NSImage(contentsOfFile: $0) }) { let s: CGFloat = size*0.78; let rr = NSRect(x:c.x-s/2,y:c.y-s/2,width:s,height:s); let inset=(sq-s)/2; let iconRad=max(0,rad-inset); NSGraphicsContext.saveGraphicsState(); NSBezierPath(roundedRect: rr, xRadius: iconRad, yRadius: iconRad).addClip(); icon.draw(in: rr, from: NSRect(origin:.zero,size:icon.size), operation:.sourceOver, fraction:1); NSGraphicsContext.restoreGraphicsState() }
            case "pulseIcon":
                let sc = 1+0.38*sin(phase); let rr: CGFloat = size*0.38*sc; let sq: CGFloat = size*0.92, rad: CGFloat = sq*0.27
                NSColor.systemGreen.withAlphaComponent(0.26).setFill(); NSBezierPath(roundedRect: NSRect(x:c.x-rr*1.45,y:c.y-rr*1.45,width:rr*2.9,height:rr*2.9), xRadius: rad, yRadius: rad).fill()
                NSColor.systemGreen.setFill(); NSBezierPath(roundedRect: NSRect(x:c.x-rr*0.95,y:c.y-rr*0.95,width:rr*1.9,height:rr*1.9), xRadius: rad*0.7, yRadius: rad*0.7).fill()
                if let icon = Bundle.main.path(forResource: "icon_running_topbar", ofType: "png").flatMap({ NSImage(contentsOfFile: $0) }) { let s: CGFloat = size*0.78; let rr2 = NSRect(x:c.x-s/2,y:c.y-s/2,width:s,height:s); let inset=(sq-s)/2; let iconRad=max(0,rad-inset); NSGraphicsContext.saveGraphicsState(); NSBezierPath(roundedRect: rr2, xRadius: iconRad, yRadius: iconRad).addClip(); icon.draw(in: rr2, from: NSRect(origin:.zero,size:icon.size), operation:.sourceOver, fraction:1); NSGraphicsContext.restoreGraphicsState() }
            default: break
            }
            return true
        }
        img.isTemplate = false
        return img
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
}
