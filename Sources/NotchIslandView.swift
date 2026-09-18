import SwiftUI
import AppKit

struct NotchIslandView: View {
    let agents: [NotchIslandAgent]
    let onTap: (String) -> Void
    let onPrimaryTap: () -> Void

    @AppStorage("dropPhotoShape") private var photoShape: String = "round"
    @AppStorage("primaryIconStyle") private var primaryStyle: String = "default"

    private var visible: [NotchIslandAgent] {
        agents.filter { $0.running || $0.hasError }.prefix(8).map { $0 }
    }

    private var isSquare: Bool { photoShape == "square" }

    private var runningCount: Int { agents.filter(\.running).count }

    private var hasRunning: Bool { visible.contains(where: \.running) }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(visible, id: \.name) { agent in
                    Button(action: { onTap(agent.name) }) {
                        IslandDot(agent: agent, isSquare: isSquare)
                    }
                    .buttonStyle(.plain)
                    .help(agent.name)
                }
                if visible.isEmpty {
                    Circle()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 13, height: 13)
                }
            }
            .frame(width: 44, alignment: .center)
            Spacer(minLength: 0)
            Button(action: onPrimaryTap) {
                HStack(spacing: 3) {
                    if primaryStyle == "default" || !hasRunning {
                        Image(nsImage: GrokStyles.composed(style: "default", barHeight: 20, phase: 0))
                            .resizable()
                            .scaledToFit()
                            .frame(width: 22, height: 22)
                    } else {
                        TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { timeline in
                            Image(nsImage: GrokStyles.composed(
                                style: primaryStyle,
                                barHeight: 20,
                                phase: timeline.date.timeIntervalSinceReferenceDate * 2.6
                            ))
                            .resizable()
                            .scaledToFit()
                            .frame(width: 22, height: 22)
                        }
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

    private let dot: CGFloat = 16

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
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white)
            }
            if agent.hasError {
                Text("!")
                    .font(.system(size: 8, weight: .black))
                    .foregroundColor(.white)
                    .frame(width: 10, height: 10)
                    .background(Circle().fill(Color.red))
                    .overlay(Circle().stroke(Color.white, lineWidth: 1))
                    .offset(x: 7, y: -7)
            }
        }
        .frame(width: 22, height: 22)
    }
}

private struct AnyShape: Shape {
    private let pathFn: (CGRect) -> Path
    init<S: Shape>(_ shape: S) {
        pathFn = { rect in shape.path(in: rect) }
    }
    func path(in rect: CGRect) -> Path { pathFn(rect) }
}
