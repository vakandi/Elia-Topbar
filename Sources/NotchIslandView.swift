import SwiftUI
import AppKit

struct NotchIslandView: View {
    let agents: [NotchIslandAgent]
    let onTap: (String) -> Void
    let onPrimaryTap: () -> Void

    @AppStorage("dropPhotoShape") private var photoShape: String = "round"
    @AppStorage("primaryIconStyle") private var primaryStyle: String = "default"

    private var visible: [NotchIslandAgent] {
        NotchIslandMetrics.shown(agents)
    }

    private var isSquare: Bool { photoShape == "square" }

    private var dot: CGFloat { NotchIslandMetrics.dotSize(count: visible.count) }

    private var runningCount: Int { agents.filter(\.running).count }

    private var hasRunning: Bool { visible.contains(where: \.running) }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: NotchIslandMetrics.spacing(count: visible.count)) {
                ForEach(visible, id: \.name) { agent in
                    Button(action: { onTap(agent.name) }) {
                        IslandDot(agent: agent, isSquare: isSquare, dot: dot)
                    }
                    .buttonStyle(.plain)
                    .help(agent.name)
                }
                if visible.isEmpty {
                    Circle()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: dot, height: dot)
                }
            }
            .frame(width: NotchIslandMetrics.leftWidth(count: visible.count), alignment: .trailing)
            Spacer(minLength: 0)
            Button(action: onPrimaryTap) {
                HStack(spacing: 3) {
                    if primaryStyle == "default" || !hasRunning {
                        Image(nsImage: GrokStyles.composed(style: "default", barHeight: 20, phase: 0))
                            .resizable()
                            .scaledToFit()
                            .frame(width: 22, height: 22)
                    } else {
                        // GPU-composited animation: static base blitted once, ring
                        // rotates on the render server at display refresh. No
                        // per-frame NSImage alloc/lockFocus, no TimelineView
                        // re-renders, no Image(nsImage:) texture re-uploads.
                        IslandPrimaryIcon(style: primaryStyle)
                            .frame(width: 22, height: 22)
                            .id(primaryStyle)
                    }
                    Text("\(runningCount)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.85))
    }
}

private struct IslandDot: View {
    let agent: NotchIslandAgent
    let isSquare: Bool
    let dot: CGFloat

    private var dotShape: AnyShape {
        if isSquare {
            AnyShape(RoundedRectangle(cornerRadius: dot * 0.27, style: .continuous))
        } else {
            AnyShape(Circle())
        }
    }

    var body: some View {
        ZStack {
            dotShape
                .fill(agent.hasError ? Color.red : Color.green)
                .frame(width: dot, height: dot)
            if let photo = agent.photo {
                Image(nsImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(width: dot - 2, height: dot - 2)
                    .clipShape(dotShape)
            } else {
                Text(agent.monogram)
                    .font(.system(size: dot > 18 ? 8 : 7, weight: .bold))
                    .foregroundColor(.white)
            }
            if agent.hasError {
                Text("!")
                    .font(.system(size: 8, weight: .black))
                    .foregroundColor(.white)
                    .frame(width: 10, height: 10)
                    .background(Circle().fill(Color.red))
                    .overlay(Circle().stroke(Color.white, lineWidth: 1))
                    .offset(x: dot / 2 - 1, y: -(dot / 2 - 1))
            }
        }
        .frame(width: dot + 1, height: dot + 1)
    }
}

private struct AnyShape: Shape {
    private let pathFn: (CGRect) -> Path
    init<S: Shape>(_ shape: S) {
        pathFn = { rect in shape.path(in: rect) }
    }
    func path(in rect: CGRect) -> Path { pathFn(rect) }
}
private struct IslandPrimaryIcon: View {
    let style: String
    // Static app-icon base, blitted once (GrokStyles caches the bitmap).
    private var baseImage: NSImage? {
        (style == "grokIcon" || style == "pulseIcon")
            ? GrokStyles.bannerBase(style: style, barHeight: 20) : nil
    }

    var body: some View {
        ZStack {
            if let base = baseImage {
                Image(nsImage: base)
                    .resizable()
                    .scaledToFit()
            }
            switch style {
            case "grok":
                GrokOrbitRing(showCenterDot: true, sqFactor: 0.82)
            case "grokIcon":
                GrokOrbitRing(showCenterDot: false, sqFactor: 0.92)
            case "orbit":
                OrbitDotRing()
            case "arc":
                ArcSpinnerRing()
            case "pulse":
                PulseRings()
            case "pulseIcon":
                PulseIconGlow()
            default:
                GrokOrbitRing(showCenterDot: false, sqFactor: 0.82)
            }
        }
    }
}

// MARK: - GPU rings (render-server animations, zero per-frame CPU bitmaps)

private struct GrokOrbitRing: View {
    let showCenterDot: Bool
    var sqFactor: CGFloat = 0.82
    @State private var dashPhase: CGFloat = 0
    @State private var pulseUp = false
    // Matches GrokStyles: sq = size*0.82 ("grok") or size*0.92 ("grokIcon").
    private var sq: CGFloat { 20 * 0.92 * sqFactor }
    private var rad: CGFloat { sq * 0.28 }
    // Same perimeter as the NSBezierPath dash math so the glow travels
    // at the original speed: 4*(sq-2*rad) + 2*pi*rad.
    private var perim: CGFloat { 4 * (sq - 2 * rad) + 2 * CGFloat.pi * rad }
    private var visLen: CGFloat { perim * 0.68 }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: rad, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1.2)
                .frame(width: sq, height: sq)
            // Fixed square; only the dash offset animates so the bright
            // segment travels around the border (like setLineDash phase).
            RoundedRectangle(cornerRadius: rad, style: .continuous)
                .stroke(Color.white.opacity(0.95),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round,
                                           dash: [visLen, perim - visLen],
                                           dashPhase: dashPhase))
                .frame(width: sq, height: sq)
            RoundedRectangle(cornerRadius: rad, style: .continuous)
                .stroke(Color.white.opacity(0.35),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round,
                                           dash: [perim * 0.22, perim * 0.78],
                                           dashPhase: dashPhase + visLen + perim * 0.05))
                .frame(width: sq, height: sq)
            if showCenterDot {
                Circle()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: 3.2, height: 3.2)
                    .scaleEffect(pulseUp ? 1.5 : 1.0)
            }
        }
        .onAppear {
            dashPhase = 0
            // One full perimeter per loop (~2s, same speed as before);
            // dashPhase wraps modulo perim so the loop is seamless.
            withAnimation(.linear(duration: 2.0).repeatForever(autoreverses: false)) { dashPhase = -perim }
            if showCenterDot {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulseUp = true }
            }
        }
    }
}

private struct OrbitDotRing: View {
    @State private var angle: Double = 0
    private let sq: CGFloat = 20 * 0.92 * 0.92
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: sq * 0.28, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1.2)
                .frame(width: sq, height: sq)
            Circle()
                .fill(Color.white.opacity(0.95))
                .frame(width: 4, height: 4)
                .offset(x: sq * 0.36)
                .rotationEffect(.degrees(angle))
        }
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { angle = 360 }
        }
    }
}

private struct ArcSpinnerRing: View {
    @State private var angle: Double = 0
    private var d: CGFloat { 20 * 0.92 * 0.8 }
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.16), lineWidth: 2)
                .frame(width: d, height: d)
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(Color.white.opacity(0.95), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: d, height: d)
                .rotationEffect(.degrees(angle))
        }
        .onAppear {
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { angle = 360 }
        }
    }
}

private struct PulseRings: View {
    @State private var expand = false
    private let size: CGFloat = 20 * 0.92
    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .stroke(Color.white.opacity(expand ? 0 : 0.75), lineWidth: 1.6)
                    .frame(width: size * 0.34, height: size * 0.34)
                    .scaleEffect(expand ? 2.0 : 0.6)
                    .animation(.linear(duration: 1.8).repeatForever(autoreverses: false).delay(Double(i) * 0.6), value: expand)
            }
            Circle().fill(Color.white.opacity(0.95)).frame(width: 4, height: 4)
        }
        .onAppear { expand = true }
    }
}

private struct PulseIconGlow: View {
    @State private var up = false
    private let size: CGFloat = 20 * 0.92
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(Color.green.opacity(0.26))
                .frame(width: size * 0.76, height: size * 0.76)
                .scaleEffect(up ? 1.38 : 1.0)
            RoundedRectangle(cornerRadius: size * 0.27 * 0.7, style: .continuous)
                .fill(Color.green)
                .frame(width: size * 0.52, height: size * 0.52)
                .scaleEffect(up ? 1.25 : 0.95)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { up = true }
        }
    }
}
