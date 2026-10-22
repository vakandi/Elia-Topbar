import AppKit
import Combine
import SwiftUI

/// The agent picker.
///
/// A small panel at the top right of the screen: the **photo of every
/// agent** and its name. A click picks the agent, and the voice command
/// goes to it — the three audio modes (push-to-talk key, push-to-talk
/// hotkey, wake word) all use it.
///
/// The panel is a `.nonactivatingPanel`: it takes the click without pulling
/// the keyboard away from whatever the user is typing.
@MainActor
final class VoiceAgentPickerController {

    static let shared = VoiceAgentPickerController()

    private var panel: NSPanel?
    private var host: NSHostingView<AnyView>?
    let model = VoiceAgentPickerModel()
    private var rosterObserver: AnyCancellable?

    private static let margin: CGFloat = 14
    private static let cellSize: CGFloat = 46

    private init() {}

    /// The height the listening bar has to leave free.
    var reservedHeight: CGFloat { 84 }

    /// Show the picker. `agents` is the roster, `selected` the agent the
    /// voice commands currently go to.
    private var photoCache: [String: NSImage?] = [:]

    func show(agents: [String], selected: String?, candidates: [String] = [], subtitle: String = "", onSelect: @escaping (String) -> Void) {
        let candidateSet = Set(candidates.filter { agents.contains($0) })
        let recent = AudioSettings.recentVoiceAgents.filter { agents.contains($0) && !candidateSet.contains($0) }
        var ordered: [String] = []
        ordered.append(contentsOf: candidates.filter { agents.contains($0) })
        ordered.append(contentsOf: recent)
        ordered.append(contentsOf: agents.filter { !ordered.contains($0) })
        let photos = ordered.map { name in
            if let cached = photoCache[name] {
                return (name, cached, candidateSet.contains(name))
            }
            let photo = ProfilePhotos.shared.circularPhoto(for: name, size: Self.cellSize)
            photoCache[name] = photo
            return (name, photo, candidateSet.contains(name))
        }
        model.agents = photos
        model.selected = selected
        model.candidateNames = candidateSet
        model.subtitle = subtitle
        model.onSelect = onSelect
        model.onKeepAlive = { [weak self] in self?.keepAlive() }

        if panel == nil { makePanel() }
        guard let panel else { return }
        resize(panel)
        position(panel)
        panel.orderFrontRegardless()
    }

    private func keepAlive() { }

    /// Hide the picker.
    func hide() {
        panel?.orderOut(nil)
    }

    /// True when the picker is on screen.
    var isVisible: Bool { panel?.isVisible ?? false }

    /// Keep the picker in sync with the roster of the bridge.
    func setRoster(_ agents: [String]) {
        model.roster = agents
    }

    // MARK: - Panel

    private func makePanel() {
        let rect = NSRect(origin: .zero, size: NSSize(width: 200, height: 80))
        let panel = NSPanel(contentRect: rect,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = false

        let host = NSHostingView(rootView: AnyView(VoiceAgentPickerView(model: model)))
        host.frame = rect
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        self.panel = panel
        self.host = host
    }

    private func resize(_ panel: NSPanel) {
        let count = max(1, model.agents.count)
        let width = min(560, CGFloat(count) * (Self.cellSize + 10) + 24)
        let size = NSSize(width: width, height: Self.cellSize + 30)
        guard panel.frame.size != size else { return }
        var frame = panel.frame
        frame.size = size
        panel.setFrame(frame, display: true)
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let screen else { return }
        let menuBar = NSStatusBar.system.thickness
        let x = screen.frame.maxX - panel.frame.width - Self.margin
        let y = screen.frame.maxY - menuBar - panel.frame.height - Self.margin
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// The state of the picker.
@MainActor
final class VoiceAgentPickerModel: ObservableObject {
    /// The agents, with their photo already resolved.
    @Published var agents: [(name: String, photo: NSImage?, isCandidate: Bool)] = []
    @Published var selected: String?
    @Published var candidateNames: Set<String> = []
    @Published var subtitle: String = ""
    /// The roster of the bridge, kept for the refresh.
    @Published var roster: [String] = []
    var onSelect: ((String) -> Void)?
    var onKeepAlive: (() -> Void)?
}

/// The picker itself: a row of photos with the name under each.
struct VoiceAgentPickerView: View {
    @ObservedObject var model: VoiceAgentPickerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Voice to…")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                if !model.subtitle.isEmpty {
                    Text(model.subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.leading, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.agents, id: \.name) { agent in
                        Button {
                            model.selected = agent.name
                            model.onSelect?(agent.name)
                        } label: {
                            VStack(spacing: 3) {
                                if let photo = agent.photo {
                                    Image(nsImage: photo)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 38, height: 38)
                                        .clipShape(Circle())
                                } else {
                                    Circle()
                                        .fill(Color.secondary.opacity(0.25))
                                        .frame(width: 38, height: 38)
                                        .overlay(
                                            Text(String(agent.name.prefix(1)).uppercased())
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(.secondary)
                                        )
                                }
                                Text(agent.name)
                                    .font(.system(size: 9, weight: agent.isCandidate ? .bold : .regular))
                                    .foregroundStyle(agent.isCandidate ? Color.accentColor
                                                    : (model.selected == agent.name ? Color.accentColor : Color.secondary))
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(agent.name)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .onHover { hovering in
            if hovering { model.onKeepAlive?() }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}
