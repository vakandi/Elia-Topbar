import AppKit
import Combine
import SwiftUI

/// The listening bar.
///
/// A borderless panel pinned to the top-right of the screen, **below** the
/// menu bar so it never covers the clock. It never becomes the key window:
/// the user is talking, not clicking, and stealing focus mid-sentence would
/// break whatever they were typing.
@MainActor
final class VoiceHUDController {

    static let shared = VoiceHUDController()

    private var panel: NSPanel?
    private var host: NSHostingView<AnyView>?
    let model = VoiceHUDModel()
    private var expansionObserver: AnyCancellable?

    private static let compactSize = NSSize(width: 360, height: 84)
    private static let expandedSize = NSSize(width: 420, height: 260)
    private static let margin: CGFloat = 14

    private init() {
        // The expand button lives in the view, so the panel has to follow
        // the model to resize itself.
        expansionObserver = model.$isExpanded
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let panel = self.panel else { return }
                    self.resize(panel)
                    self.position(panel)
                }
            }
    }

    /// Update the bar. Creates the panel the first time.
    func update(status: VoiceHUDStatus,
                transcript: String = "",
                level: Float = 0,
                agent: String? = nil,
                candidates: [String] = [],
                onSelect: ((String) -> Void)? = nil,
                onChangeAgent: (() -> Void)? = nil,
                onCancel: (() -> Void)? = nil) {
        if let onCancel { model.onCancel = onCancel }
        model.status = status
        model.transcript = transcript
        model.level = level
        model.agent = agent
        model.candidates = candidates
        // The photo is resolved here, not in the view: `ProfilePhotos` is
        // main-actor isolated, and a SwiftUI body closure that is not
        // main-actor isolated would make the runtime do an executor check
        // that segfaults. The view only ever sees a plain image.
        model.photo = agent.flatMap { ProfilePhotos.shared.circularPhoto(for: $0, size: 68) }
        if let onSelect { model.onSelect = onSelect }
        model.changeAgent = onChangeAgent

        if panel == nil { makePanel() }
        guard let panel else { return }
        resize(panel)
        position(panel)
        panel.orderFrontRegardless()
    }

    /// Hide the bar.
    func hide() {
        panel?.orderOut(nil)
    }

    /// Show or clear a banner on the bar without touching the rest.
    func setBanner(_ text: String?) {
        model.banner = text
        if text != nil, panel == nil { makePanel() }
        if let panel {
            resize(panel)
            position(panel)
            panel.orderFrontRegardless()
        }
    }

    /// True when the bar is on screen.
    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    /// Flip the expanded state (the transcript view).
    func toggleExpanded() {
        model.isExpanded.toggle()
        if let panel { resize(panel) }
    }

    // MARK: - Panel

    private func makePanel() {
        let rect = NSRect(origin: .zero, size: Self.compactSize)
        let panel = NSPanel(contentRect: rect,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        // Must stay false: a released panel cannot be reused.
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = false

        let host = NSHostingView(rootView: AnyView(VoiceHUDView(model: model)))
        host.frame = rect
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        self.panel = panel
        self.host = host
    }

    private func resize(_ panel: NSPanel) {
        let size = model.isExpanded ? Self.expandedSize : Self.compactSize
        guard panel.frame.size != size else { return }
        var frame = panel.frame
        let bottom = frame.minY
        frame.size = size
        frame.origin.y = bottom
        panel.setFrame(frame, display: true)
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let screen else { return }
        // Below the menu bar: the bar must never sit under the clock.
        let menuBar = NSStatusBar.system.thickness
        let x = screen.frame.maxX - panel.frame.width - Self.margin
        let y = screen.frame.maxY - menuBar - panel.frame.height - Self.margin
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// What the bar is doing.
enum VoiceHUDStatus: Equatable {
    case idle
    case listening
    case transcribing
    case both
    case sent(String)
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "Ready"
        case .listening: return "Listening"
        case .transcribing: return "Transcribing"
        case .both: return "Listening · transcribing"
        case .sent(let agent): return "Sent to \(agent)"
        case .failed: return "Voice error"
        }
    }

    /// The ring colour: green while it listens, orange while it writes.
    var tint: Color {
        switch self {
        case .idle: return .secondary
        case .listening: return .green
        case .transcribing: return .orange
        case .both: return .blue
        case .sent: return .green
        case .failed: return .red
        }
    }

    var showsCancel: Bool {
        switch self {
        case .idle, .sent: return false
        default: return true
        }
    }
}

/// The observable state of the bar.
@MainActor
final class VoiceHUDModel: ObservableObject {
    @Published var status: VoiceHUDStatus = .idle
    @Published var transcript: String = ""
    @Published var level: Float = 0
    @Published var agent: String?
    @Published var candidates: [String] = []
    @Published var isExpanded = false
    @Published var changeAgent: (() -> Void)?
    @Published var onCancel: (() -> Void)?
    /// An optional banner shown above the transcript (e.g. "server offline").
    @Published var banner: String?
    /// The agent's photo, resolved outside the view body.
    @Published var photo: NSImage?
    var onSelect: ((String) -> Void)?
}

/// The bar itself.
struct VoiceHUDView: View {
    @ObservedObject var model: VoiceHUDModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VoiceAvatarView(agent: model.agent,
                            photo: model.photo,
                            status: model.status,
                            level: model.level)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.status.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(model.status.tint)
                    if let agent = model.agent {
                        Text("· \(agent)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button {
                        model.isExpanded.toggle()
                    } label: {
                        Image(systemName: model.isExpanded
                              ? "chevron.down.circle.fill"
                              : "chevron.up.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Show the transcript")

                    if model.onCancel != nil, model.status.showsCancel {
                        Button {
                            model.onCancel?()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Cancel")
                    }
                }

                if model.isExpanded {
                    ScrollView {
                        Text(model.transcript.isEmpty ? "…" : model.transcript)
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text(model.transcript.isEmpty ? placeholder : model.transcript)
                        .font(.system(size: 12))
                        .foregroundStyle(model.transcript.isEmpty ? .secondary : .primary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let banner = model.banner {
                    Text(banner)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                if !model.candidates.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(model.candidates, id: \.self) { candidate in
                            Button {
                                model.onSelect?(candidate)
                            } label: {
                                Text(candidate)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }

                if let changeAgent = model.changeAgent {
                    Button(action: changeAgent) {
                        Text("Change agent")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(model.status.tint.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }

    private var placeholder: String {
        switch model.status {
        case .listening: return "Say “Ok <agent>” or give the order…"
        case .transcribing: return "Writing it down…"
        case .both: return "Listening and transcribing…"
        case .sent: return "Command sent"
        case .failed: return "Something went wrong"
        case .idle: return "Ready"
        }
    }
}

/// The avatar: the agent's photo when it is known, the app icon otherwise,
/// with a status ring around it.
///
/// `@MainActor` on purpose: the body closures of a view are only
/// main-actor isolated when the view itself says so, and touching a
/// main-actor object from a non-isolated closure makes the Swift runtime do
/// an executor check that segfaults.
struct VoiceAvatarView: View {
    let agent: String?
    let photo: NSImage?
    let status: VoiceHUDStatus
    let level: Float

    var body: some View {
        ZStack {
            VoiceStatusRing(status: status, level: level)
            avatar
                .frame(width: 34, height: 34)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
        }
        .frame(width: 52, height: 52)
    }

    @ViewBuilder
    private var avatar: some View {
        if let photo {
            Image(nsImage: photo)
                .resizable()
                .scaledToFill()
        } else if let icon = BrandAssets.sherlock {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .padding(3)
        } else {
            Circle().fill(status.tint)
        }
    }
}

/// The ring around the avatar. Its colour and shape tell the status:
/// a solid arc while listening, a dashed arc while transcribing, two arcs
/// when both happen, a check when the command went out, a warning when it
/// did not.
struct VoiceStatusRing: View {
    let status: VoiceHUDStatus
    let level: Float

    @State private var spin = false

    var body: some View {
        ZStack {
            switch status {
            case .listening:
                arc(trim: 0.28, dash: nil, tint: .green)
            case .transcribing:
                arc(trim: 0.22, dash: [3, 6], tint: .orange)
            case .both:
                ZStack {
                    arc(trim: 0.28, dash: nil, tint: .green)
                    arc(trim: 0.22, dash: [3, 6], tint: .orange)
                        .padding(3)
                }
            case .sent:
                Circle().strokeBorder(Color.green, lineWidth: 2.5)
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.green)
            case .failed:
                Circle().strokeBorder(Color.red, lineWidth: 2.5)
                Image(systemName: "exclamationmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.red)
            case .idle:
                Circle().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 2.5)
            }
        }
        .frame(width: 46, height: 46)
        .onAppear { spin = true }
        .onChange(of: status) { _ in
            // Toggling (rather than re-assigning `true`) is what restarts
            // the rotation when the status changes, e.g. listening -> transcribing.
            spin = false
            DispatchQueue.main.async { spin = true }
        }
    }

    private func arc(trim: CGFloat, dash: [CGFloat]?, tint: Color) -> some View {
        Circle()
            .trim(from: 0, to: trim)
            .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: dash ?? []))
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
    }
}
