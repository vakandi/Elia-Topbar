import AppKit

/// The system Liquid Glass effect, available from macOS 26.
///
/// The deployment target is macOS 13, so every call site has to survive
/// an older system. When the effect is unavailable the host view is
/// installed bare and the SwiftUI view keeps its own material: the panel
/// looks exactly the same as before this file existed.
enum GlassBackground {

    /// True when the running system can render `NSGlassEffectView`.
    static let isAvailable: Bool = {
        if #available(macOS 26.0, *) { return true }
        return false
    }()

    /// Install `host` as the panel's content, wrapped in glass on macOS 26+.
    ///
    /// `NSGlassEffectView` embeds its `contentView` inside the effect: the
    /// host view must not paint an opaque fill of its own or the glass is
    /// hidden behind it.
    static func install(host: NSView, in panel: NSPanel, cornerRadius: CGFloat) {
        host.autoresizingMask = [.width, .height]
        guard #available(macOS 26.0, *) else {
            panel.contentView = host
            return
        }
        let glass = NSGlassEffectView(frame: panel.contentLayoutRect)
        glass.cornerRadius = cornerRadius
        glass.style = .regular
        glass.autoresizingMask = [.width, .height]
        // The panels carry light text in dark mode. Glass does not change
        // the text colour when it passes over a bright window, so a slight
        // tint keeps the contrast readable on any backdrop.
        glass.tintColor = NSColor.black.withAlphaComponent(0.28)
        host.frame = glass.bounds
        glass.contentView = host
        panel.contentView = glass
    }
}
