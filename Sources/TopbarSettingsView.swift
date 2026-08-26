import SwiftUI
import AppKit

/// Topbar placement planner: live capture of the real menu bar, draggable ghost
/// of our icon, plus the settings that genuinely apply (photo side, padding).
///
/// macOS exposes no API to place an NSStatusItem next to Wi-Fi/battery — the only
/// supported mechanism is native ⌘-drag reordering, which this UI teaches.
struct TopbarSettingsView: View {
    var iconProvider: () -> NSImage?
    var onRefresh: () -> Void
    var onTestRunPopup: () -> Void = {}
    var onOrderChange: (String) -> Void

    @State private var previewIcon: NSImage?
    @State private var capturedBar: NSImage?
    @State private var captureDenied = false

    private let staticBarImage: NSImage? = {
        guard let path = Bundle.main.path(forResource: "menubar-preview", ofType: "png") else { return nil }
        return NSImage(contentsOfFile: path)
    }()
    @State private var ghostX: CGFloat = 0
    @State private var photosSide: String = UserDefaults.standard.string(forKey: "fleetPhotosSide") ?? "left"
    @State private var leftPad: Double = UserDefaults.standard.object(forKey: "fleetLeftPad") as? Double ?? 3
    @State private var runPopupDuration: Double = UserDefaults.standard.object(forKey: "runPopupDuration") as? Double ?? 10
    @State private var showGuide = false
    @State private var orderMode: String = UserDefaults.standard.string(forKey: "fleetOrderMode") ?? "default"

    private let barHeight: CGFloat = 20
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
                        previewIcon = iconProvider()
                    }

                    HStack {
                        Text(photosSide == "right" ? "Right padding" : "Left padding")
                        Slider(value: $leftPad, in: 0...10, step: 1)
                            .onChange(of: leftPad) { _ in
                                defaults.set(leftPad, forKey: "fleetLeftPad")
                                onRefresh()
                                previewIcon = iconProvider()
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
                        previewIcon = iconProvider()
                    }
                }
                .padding(6)
            } label: {
                Text("Layout").font(.caption).foregroundColor(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Duration")
                        Slider(value: $runPopupDuration, in: 0...30, step: 1)
                            .onChange(of: runPopupDuration) { _ in
                                defaults.set(runPopupDuration, forKey: "runPopupDuration")
                            }
                        Text(runPopupDuration == 0 ? "Off" : "\(Int(runPopupDuration))s")
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                            .frame(width: 34, alignment: .trailing)
                        Button("Test") { onTestRunPopup() }
                            .controlSize(.small)
                    }
                    Text("Photo + live bubble dropping from the icon when an agent starts. Click it to dismiss.")
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
        .frame(maxHeight: 560)
        .onAppear {
            previewIcon = iconProvider()
        }
    }

    // MARK: - Preview

    private var menuBarPreview: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let bar = staticBarImage {
                    Image(nsImage: bar)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(Color(nsColor: .windowBackgroundColor))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: barHeight + 8)
            .clipped()

            if let icon = previewIcon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(height: barHeight - 5)
                    .shadow(radius: 2)
                    .offset(x: ghostX, y: 4)
                    .gesture(
                        DragGesture()
                            .onChanged { v in
                                ghostX = max(0, min(v.location.x, 380))
                            }
                    )
                    .animation(.interactiveSpring(), value: ghostX)
            }
        }
        .cornerRadius(5)
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.4)))
    }
}

extension Notification.Name {
    static let eliaPulseMainIcon = Notification.Name("eliaPulseMainIcon")
}
