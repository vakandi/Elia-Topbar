import AppKit
import SwiftUI

/// Drop-down agent photo + live chat bubble shown when a subworker starts.
/// NSPanel at .statusBar level with canJoinAllSpaces + fullScreenAuxiliary so it
/// stays visible above fullscreen video — same trick notch apps use.
@MainActor
final class RunPopupController {
    static let shared = RunPopupController()

    private var panel: NSPanel?
    private var retractTimer: Timer?
    private var currentAgent: String?

    func show(for agentName: String, dropX: CGFloat, duration: TimeInterval) {
        guard duration > 0 else { return }
        guard let screen = NSScreen.main else { return }

        let width: CGFloat = 280
        let height: CGFloat = 250
        let barBottom = screen.frame.maxY - NSStatusBar.system.thickness
        var x = dropX - width / 2
        x = max(screen.frame.minX + 8, min(x, screen.frame.maxX - width - 8))
        let finalFrame = NSRect(x: x, y: barBottom - height, width: width, height: height)
        let hiddenFrame = NSRect(x: x, y: screen.frame.maxY, width: width, height: height)

        let isNewAgent = currentAgent != agentName
        currentAgent = agentName

        if let p = panel, !isNewAgent {
            scheduleRetract(after: duration)
            return
        }

        let p = panel ?? makePanel(hiddenFrame: hiddenFrame)
        p.contentView = NSHostingView(
            rootView: RunPopupView(agentName: agentName) { [weak self] in self?.retract() }
        )
        if panel == nil {
            panel = p
            p.orderFrontRegardless()
            drop(panel: p, to: finalFrame)
        }
        scheduleRetract(after: duration)
    }

    private func makePanel(hiddenFrame: NSRect) -> NSPanel {
        let p = NSPanel(contentRect: hiddenFrame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovableByWindowBackground = false
        p.worksWhenModal = true
        return p
    }

    private func drop(panel: NSPanel, to frame: NSRect) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.55
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.2, 0.3, 1)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        })
    }

    func retract() {
        retractTimer?.invalidate()
        retractTimer = nil
        guard let panel else { return }
        guard let screen = NSScreen.main else {
            close(panel: panel)
            return
        }
        let target = NSRect(x: panel.frame.origin.x,
                            y: screen.frame.maxY,
                            width: panel.frame.width,
                            height: panel.frame.height)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            self?.close(panel: panel)
        })
    }

    private func close(panel: NSPanel) {
        panel.orderOut(nil)
        if self.panel === panel { self.panel = nil }
        currentAgent = nil
    }

    private func scheduleRetract(after duration: TimeInterval) {
        retractTimer?.invalidate()
        retractTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.retract() }
        }
    }
}

struct PulseGlow: ViewModifier {
    @State private var pulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(pulsing ? 1.18 : 1.0)
            .opacity(pulsing ? 0.3 : 0.9)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}

struct RunPopupView: View {
    let agentName: String
    let onTap: () -> Void

    @State private var liveText = ""
    @State private var observer: NSObjectProtocol?

    var body: some View {
        VStack(spacing: 6) {
            photoBadge
            bubble
        }
        .padding(.top, 4)
        .onAppear(perform: observeLogs)
        .onDisappear {
            if let o = observer { NotificationCenter.default.removeObserver(o) }
        }
        .onTapGesture { onTap() }
    }

    private var photoBadge: some View {
        ZStack {
            Circle()
                .stroke(Color.accentColor.opacity(0.6), lineWidth: 2)
                .frame(width: 56, height: 56)
                .modifier(PulseGlow())
            if let photo = ProfilePhotos.shared.circularPhoto(for: agentName, size: 48) {
                Image(nsImage: photo)
                    .resizable()
                    .frame(width: 48, height: 48)
            } else {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.25))
                    Text(agentMonogram)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.accentColor)
                }
                .frame(width: 48, height: 48)
            }
        }
        .frame(height: 60)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text("\(agentName) running")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Spacer()
                Text("live")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(liveText.isEmpty ? "Waiting for output…" : liveText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.primary.opacity(0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("bubble-text")
                }
                .frame(height: 130)
                .onChange(of: liveText) { _ in
                    proxy.scrollTo("bubble-text", anchor: .bottom)
                }
            }
        }
        .padding(10)
        .frame(width: 264)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.12)))
    }

    private var agentMonogram: String {
        let parts = agentName.split(separator: "-").map(String.init)
        let initials = parts.prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
        if initials.count == 2 { return initials }
        let firstWord = parts.first ?? agentName
        return String(firstWord.prefix(2)).uppercased()
    }

    private func observeLogs() {
        observer = NotificationCenter.default.addObserver(
            forName: SubworkerManager.runLogNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let name = note.userInfo?["name"] as? String,
                  name == agentName,
                  let delta = note.userInfo?["text"] as? String else { return }
            let field = note.userInfo?["field"] as? String ?? "text"
            if field == "reasoning" { return }
            if field == "tool" {
                if let data = delta.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let t = obj["tool"] as? String {
                    let line = "🔧 \(t)"
                    if !self.liveText.hasSuffix(line) {
                        self.liveText += (self.liveText.isEmpty ? "" : "\n") + line
                    }
                }
                return
            }
            if delta.isEmpty { return }
            if self.liveText.hasSuffix(delta) { return }
            if delta.hasPrefix(self.liveText) {
                self.liveText = delta
            } else if self.liveText.contains(delta) && delta.count < 80 {
                return
            } else {
                self.liveText += delta
            }
            if liveText.count > 4000 { liveText = String(liveText.suffix(2500)) }
        }
    }
}
