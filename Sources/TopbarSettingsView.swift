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
                        Text("""
                        1. Hold ⌘ (Command)
                        2. Drag the brain icon in the REAL menu bar
                        3. Drop it right of Wi-Fi / battery — done
                        The agent photos follow automatically.
                        """)
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
        .onAppear(perform: captureMenuBar)
    }

    // MARK: - Preview

    private var menuBarPreview: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let bar = capturedBar {
                    Image(nsImage: bar)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
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
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let entry = list.first(where: { ($0[kCGWindowLayer as String] as? Int) == 24 }),
              let windowID = entry[kCGWindowNumber as String] as? CGWindowID,
              let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.bestResolution])
        else {
            captureDenied = true
            return
        }
        let cgImage = cg
        let scale = CGFloat(cgImage.width) / max(CGFloat(cgImage.height), 1)
        capturedBar = NSImage(cgImage: cgImage, size: NSSize(width: scale * barHeight, height: barHeight))
    }
}

extension Notification.Name {
    static let eliaPulseMainIcon = Notification.Name("eliaPulseMainIcon")
}
