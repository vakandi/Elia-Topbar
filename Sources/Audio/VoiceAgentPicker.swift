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

    func show(agents: [String], selected: String?, candidates: [String] = [], subtitle: String = "", onClose: @escaping () -> Void = {}, onSelect: @escaping (String) -> Void) {
        let candidateSet = Set(candidates.filter { agents.contains($0) })
        let recent = AudioSettings.recentVoiceAgents.filter { agents.contains($0) }
        // The agent used last for voice control always leads, before even the
        // near-miss candidates, so reusing the same agent never needs a scroll.
        var ordered: [String] = []
        if let last = recent.first { ordered.append(last) }
        ordered.append(contentsOf: candidates.filter { agents.contains($0) && !ordered.contains($0) })
        ordered.append(contentsOf: recent.filter { !ordered.contains($0) })
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
        model.onClose = onClose
        model.showToken = UUID()
        model.onMouseEnter = { [weak self] in self?.handleMouseEnter() }
        model.onMouseLeave = { [weak self] in self?.handleMouseLeave() }

        if panel == nil { makePanel() }
        guard let panel else { return }
        resize(panel)
        position(panel)
        panel.orderFrontRegardless()
    }

    private func handleMouseEnter() { }
    private func handleMouseLeave() { }

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

        let host = TrackingHostingView(rootView: AnyView(VoiceAgentPickerView(model: model)))
        host.frame = rect
        host.autoresizingMask = [.width, .height]
        host.onEnter = { [weak self] in self?.model.onMouseEnter?() }
        host.onExit = { [weak self] in self?.model.onMouseLeave?() }
        GlassBackground.install(host: host, in: panel, cornerRadius: 12)

        self.panel = panel
        self.host = host
    }

    private func resize(_ panel: NSPanel) {
        let count = max(1, model.agents.count)
        let width = min(620, CGFloat(count) * (VoiceAgentPickerView.labelWidth + 10) + 24)
        let header: CGFloat = model.subtitle.isEmpty ? 0 : 34
        let size = NSSize(width: width, height: Self.cellSize + 30 + header)
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
    var onClose: (() -> Void)?
    var onMouseEnter: (() -> Void)?
    var onMouseLeave: (() -> Void)?
    /// A fresh identity per show, so the row starts at its first agent
    /// instead of keeping the scroll offset of the previous run.
    @Published var showToken = UUID()
}

/// The picker itself: a row of photos with the name under each.
struct VoiceAgentPickerView: View {
    @ObservedObject var model: VoiceAgentPickerModel

    /// Every column is the same width, so a long agent name cannot stretch
    /// its cell and push the others around. The full name stays in the
    /// tooltip.
    static let labelWidth: CGFloat = 54
    static let nameLimit = 8

    private func shortName(_ name: String) -> String {
        name.count > Self.nameLimit ? String(name.prefix(Self.nameLimit)) + "…" : name
    }

    /// The transcript as it was heard. Whisper answers a lone "…" when the
    /// capture held nothing but noise, and printing that reads as a broken
    /// placeholder — so a punctuation-only result is reported as no speech.
    private var readableTranscript: String {
        let trimmed = model.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let hasLetters = trimmed.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        return hasLetters ? trimmed : "Rien entendu"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    if !readableTranscript.isEmpty {
                        Text(verbatim: readableTranscript)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("Voice to…")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)

                if let onClose = model.onClose {
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Close")
                }
            }
            .padding(.trailing, 2)

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
                                Text(shortName(agent.name))
                                    .font(.system(size: 9, weight: agent.isCandidate ? .bold : .regular))
                                    .foregroundStyle(agent.isCandidate ? Color.accentColor
                                                    : (model.selected == agent.name ? Color.accentColor : Color.secondary))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .frame(width: Self.labelWidth)
                        }
                        .buttonStyle(.plain)
                        .help(agent.name)
                    }
                }
                .padding(.horizontal, 4)
            }
            .id(model.showToken)
        }
        .padding(8)
        .background {
            if !GlassBackground.isAvailable {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(GlassBackground.isAvailable ? 0.12 : 0.2),
                        lineWidth: 1)
        )
    }
}


/// NSHostingView subclass that tracks mouse enter/exit via a tracking area,
/// because SwiftUI's `.onHover` does not fire inside a non-activating panel.
final class TrackingHostingView: NSHostingView<AnyView> {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        onEnter?()
    }

    override func mouseExited(with event: NSEvent) {
        onExit?()
    }
}
