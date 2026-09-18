import AppKit
import SwiftUI

struct NotchIslandAgent: Equatable {
    let name: String
    let running: Bool
    let hasError: Bool
    let photo: NSImage?

    static func == (lhs: NotchIslandAgent, rhs: NotchIslandAgent) -> Bool {
        lhs.name == rhs.name && lhs.running == rhs.running && lhs.hasError == rhs.hasError
    }

    var monogram: String {
        let parts = name.split(separator: "-")
        let letters = parts.prefix(2).compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

@MainActor
final class NotchIslandController {
    static let shared = NotchIslandController()
    private var panel: NSPanel?
    private var onAgentClick: ((String) -> Void)?
    private var onPrimaryClick: (() -> Void)?

    func show(agents: [NotchIslandAgent], onAgentClick: @escaping (String) -> Void, onPrimaryClick: @escaping () -> Void) {
        self.onAgentClick = onAgentClick
        self.onPrimaryClick = onPrimaryClick
        let panel = self.panel ?? makePanel()
        self.panel = panel
        positionPanel(panel)
        panel.contentView = NSHostingView(rootView: NotchIslandView(agents: agents, onTap: { [weak self] name in
            self?.onAgentClick?(name)
        }, onPrimaryTap: { [weak self] in
            self?.onPrimaryClick?()
        }))
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func primaryMenuPoint() -> NSPoint? {
        guard let panel else { return nil }
        let f = panel.frame
        let x = max(f.minX + 8, min(f.maxX - 22, f.maxX - 8))
        return NSPoint(x: x, y: f.minY)
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 32),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .ignoresCycle, .stationary]
        return p
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let screen = targetScreen() else { return }
        let notchW = notchWidth(on: screen)
        let pillW = notchW + 88
        let h: CGFloat = 32
        let frame = NSRect(
            x: screen.frame.midX - pillW / 2,
            y: screen.frame.maxY - h,
            width: pillW,
            height: h
        )
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if let notch = screens.first(where: { $0.safeAreaInsets.top > 0 }) { return notch }
        return NSScreen.main ?? screens.first
    }

    private func notchWidth(on screen: NSScreen) -> CGFloat {
        guard screen.safeAreaInsets.top > 0 else { return 190 }
        if #available(macOS 14.0, *) {
            let left = screen.auxiliaryTopLeftArea?.width ?? 0
            let right = screen.auxiliaryTopRightArea?.width ?? 0
            if left > 0 || right > 0 { return screen.frame.width - left - right + 4 }
        }
        return 200
    }
}
