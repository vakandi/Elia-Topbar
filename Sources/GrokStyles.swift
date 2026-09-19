import AppKit

// Single source of truth for the primary-icon running animations.
// Used by the live menu-bar icon (EliaTopBarApp) and the settings preview
// (TopbarSettingsView) so both always render the same motion.
// Phase unit: ~2.6 units per second at the 15fps icon timer.
enum GrokStyles {
    static let all: [(id: String, label: String)] = [
        ("default", "Default (banner + count)"),
        ("grok", "Grok orbit"),
        ("grokIcon", "Grok orbit + icon"),
        ("pulseIcon", "Pulse behind icon"),
        ("orbit", "Orbit dot"),
        ("pulse", "Pulse rings"),
        ("arc", "Arc spinner"),
    ]

    static func ringOverlay(style: String, barHeight: CGFloat, phase: Double) -> NSImage {
        let size = barHeight * 0.92
        let c = CGPoint(x: size / 2, y: size / 2)
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            switch style {
            case "grok", "grokIcon":
                let sq: CGFloat = style == "grok" ? size * 0.82 : size * 0.92
                let half = sq / 2, rad: CGFloat = sq * 0.28
                let r = NSRect(x: c.x - half, y: c.y - half, width: sq, height: sq)
                let perim: CGFloat = 4 * (sq - 2 * rad) + 2 * CGFloat.pi * rad
                NSColor.labelColor.withAlphaComponent(0.16).setStroke()
                let t = NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad); t.lineWidth = 1.2; t.stroke()
                let visLen = perim * 0.68, orbitPhase = -CGFloat(phase) * 10
                let head = NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad); head.lineWidth = 2; head.lineCapStyle = .round
                head.setLineDash([visLen, perim - visLen], count: 2, phase: orbitPhase); NSColor.labelColor.withAlphaComponent(0.95).setStroke(); head.stroke()
                let tail = NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad); tail.lineWidth = 2; tail.lineCapStyle = .round
                tail.setLineDash([perim * 0.22, perim * 0.78], count: 2, phase: orbitPhase + visLen + perim * 0.05); NSColor.labelColor.withAlphaComponent(0.35).setStroke(); tail.stroke()
                if style == "grok" {
                    let pulse = 0.5 - 0.5 * cos(phase * 2.2); let cr: CGFloat = size * 0.08 + CGFloat(pulse) * size * 0.04
                    NSColor.labelColor.withAlphaComponent(0.95).setFill(); NSBezierPath(ovalIn: NSRect(x: c.x - cr, y: c.y - cr, width: cr * 2, height: cr * 2)).fill()
                }
            case "pulseIcon":
                let sc = 1 + 0.38 * sin(phase); let rr: CGFloat = size * 0.38 * sc; let sq: CGFloat = size * 0.92, rad: CGFloat = sq * 0.27
                NSColor.systemGreen.withAlphaComponent(0.26).setFill(); NSBezierPath(roundedRect: NSRect(x: c.x - rr * 1.45, y: c.y - rr * 1.45, width: rr * 2.9, height: rr * 2.9), xRadius: rad, yRadius: rad).fill()
                NSColor.systemGreen.setFill(); NSBezierPath(roundedRect: NSRect(x: c.x - rr * 0.95, y: c.y - rr * 0.95, width: rr * 1.9, height: rr * 1.9), xRadius: rad * 0.7, yRadius: rad * 0.7).fill()
            case "orbit":
                let sq: CGFloat = size * 0.92, half = sq / 2, rad: CGFloat = sq * 0.28
                let r = NSRect(x: c.x - half, y: c.y - half, width: sq, height: sq)
                NSColor.labelColor.withAlphaComponent(0.18).setStroke()
                let track = NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad); track.lineWidth = 1.2; track.stroke()
                let a = CGFloat(phase * 2.0)
                let dotR = sq * 0.36
                let dot = NSRect(x: c.x + cos(a) * dotR - 2, y: c.y + sin(a) * dotR - 2, width: 4, height: 4)
                NSColor.labelColor.withAlphaComponent(0.95).setFill(); NSBezierPath(ovalIn: dot).fill()
            case "pulse":
                for i in 0..<3 {
                    let t = CGFloat((phase * 0.45 + Double(i) / 3.0).truncatingRemainder(dividingBy: 1.0))
                    let sq: CGFloat = size * (0.34 + 0.58 * t)
                    let half = sq / 2, rad: CGFloat = sq * 0.28
                    let r = NSRect(x: c.x - half, y: c.y - half, width: sq, height: sq)
                    NSColor.labelColor.withAlphaComponent(0.75 * (1 - t)).setStroke()
                    let ring = NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad); ring.lineWidth = 1.6; ring.stroke()
                }
                NSColor.labelColor.withAlphaComponent(0.95).setFill()
                NSBezierPath(ovalIn: NSRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)).fill()
            case "arc":
                let d = size * 0.8
                let r = NSRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
                NSColor.labelColor.withAlphaComponent(0.16).setStroke()
                let track = NSBezierPath(ovalIn: r); track.lineWidth = 2; track.stroke()
                let circ = CGFloat.pi * d
                let arcLen = circ * 0.7
                let head = NSBezierPath(ovalIn: r); head.lineWidth = 2; head.lineCapStyle = .round
                head.setLineDash([arcLen, circ - arcLen], count: 2, phase: -CGFloat(phase) * 10)
                NSColor.labelColor.withAlphaComponent(0.95).setStroke(); head.stroke()
            default: break
            }
            return true
        }
    }

    static func composed(style: String, barHeight: CGFloat, phase: Double) -> NSImage {
        if style == "default" {
            if let cached = defaultIcon { return cached }
            if let p = Bundle.main.path(forResource: "icon_running_topbar", ofType: "png"),
               let im = NSImage(contentsOfFile: p) {
                im.isTemplate = false
                defaultIcon = im
                return im
            }
            return NSImage(size: NSSize(width: barHeight, height: barHeight), flipped: false) { _ in true }
        }
        let size = barHeight * 0.92
        let frame = bannerBase(style: style, barHeight: barHeight).copy() as! NSImage
        frame.lockFocus()
        ringOverlay(style: style, barHeight: barHeight, phase: phase).draw(
            in: NSRect(x: 0, y: (frame.size.height - size) / 2, width: size, height: size),
            from: NSRect(origin: .zero, size: NSSize(width: size, height: size)),
            operation: .sourceOver, fraction: 1.0)
        frame.unlockFocus()
        frame.isTemplate = false
        return frame
    }

    private static var baseCache: [String: NSImage] = [:]
    private static var frameCache: [String: NSImage] = [:]
    private static var defaultIcon: NSImage?

    static func islandFrame(style: String, barHeight: CGFloat, phase: Double) -> NSImage {
        let bucket = Int(phase * 15) % 512
        let key = "\(style)|\(barHeight)|\(bucket)"
        if let hit = frameCache[key] { return hit }
        let frame = composed(style: style, barHeight: barHeight, phase: phase)
        frameCache[key] = frame
        return frame
    }

    static func bannerBase(style: String, barHeight: CGFloat) -> NSImage {
        let key = "\(style)|\(barHeight)"
        if let cached = baseCache[key] { return cached }
        let size = barHeight * 0.92
        let base = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in true }
        guard style == "grokIcon" || style == "pulseIcon" else {
            baseCache[key] = base
            return base
        }
        if let icon = Bundle.main.path(forResource: "icon_running_topbar", ofType: "png").flatMap({ NSImage(contentsOfFile: $0) }) {
            let s: CGFloat = size * 0.78
            let sq: CGFloat = size * 0.92, rad: CGFloat = sq * 0.27
            let rr = NSRect(x: size / 2 - s / 2, y: size / 2 - s / 2, width: s, height: s)
            base.lockFocus()
            let inset = (sq - s) / 2; let iconRad = max(0, rad - inset)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rr, xRadius: iconRad, yRadius: iconRad).addClip()
            icon.draw(in: rr, from: NSRect(origin: .zero, size: icon.size), operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            base.unlockFocus()
        }
        baseCache[key] = base
        return base
    }
}
