import SwiftUI
import AppKit

/// Topbar placement planner: live capture of the real menu bar, draggable ghost
/// of our icon, plus the settings that genuinely apply (photo side, padding).
///
/// macOS exposes no API to place an NSStatusItem next to Wi-Fi/battery — the only
/// supported mechanism is native ⌘-drag reordering, which this UI teaches.
struct TopbarSettingsView: View {
    var currentIcon: NSImage?
    var onRefresh: () -> Void

    @State private var capturedBar: NSImage?
    @State private var captureDenied = false
    @State private var ghostX: CGFloat = 0
    @State private var photosSide: String = UserDefaults.standard.string(forKey: "fleetPhotosSide") ?? "left"
    @State private var leftPad: Double = {
        let v = UserDefaults.standard.double(forKey: "fleetLeftPad")
        return v == 0 ? 3 : v
    }()
    @State private var showGuide = false

    private let barHeight: CGFloat = 26
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
                        Text("Left padding")
                        Slider(value: $leftPad, in: 0...10, step: 1) { _ in
                            defaults.set(leftPad, forKey: "fleetLeftPad")
                            onRefresh()
                        }
                        Text("\(Int(leftPad))pt").monospacedDigit().foregroundColor(.secondary)
                    }
                }
                .padding(6)
            } label: {
                Text("Layout").font(.caption).foregroundColor(.secondary)
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
        .onAppear(perform: captureMenuBar)
    }

    // MARK: - Preview

    private var menuBarPreview: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let bar = capturedBar {
                    Image(nsImage: bar)
                        .resizable()
                        .scaledToFit()
                } else {
                    Rectangle()
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .overlay(
                            VStack(spacing: 6) {
                                Text(captureDenied
                                     ? "Live preview needs Screen Recording permission"
                                     : "Capturing menu bar…")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if captureDenied {
                                    Button("Grant permission…") {
                                        _ = CGRequestScreenCaptureAccess()
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                            captureMenuBar()
                                        }
                                    }
                                    .controlSize(.small)
                                    .buttonStyle(.borderedProminent)
                                    Text("After approving, click again if the preview stays empty.")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        )
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: barHeight + 8)
            .clipped()

            if let icon = currentIcon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(height: barHeight - 4)
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

    private func captureMenuBar() {
        guard CGPreflightScreenCaptureAccess() else {
            captureDenied = true
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let screenW = Int(NSScreen.main?.frame.width ?? 1600)
            let halfW = screenW / 2
            let cropH = Int(self.barHeight * 2)
            let tmp = URL(fileURLWithPath: "/tmp/elia_menubar.png")
            try? FileManager.default.removeItem(at: tmp)

            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", "-R\(halfW),0,\(halfW),\(cropH)", tmp.path]
            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                DispatchQueue.main.async { self.captureDenied = true }
                return
            }
            DispatchQueue.main.async {
                guard task.terminationStatus == 0, let img = NSImage(contentsOf: tmp) else {
                    self.captureDenied = true
                    return
                }
                self.capturedBar = img
                try? FileManager.default.removeItem(at: tmp)
            }
        }
    }
}

extension Notification.Name {
    static let eliaPulseMainIcon = Notification.Name("eliaPulseMainIcon")
}
