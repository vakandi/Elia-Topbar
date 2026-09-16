import AppKit
import SwiftUI
 @MainActor final class RunPopupController {
     static let shared = RunPopupController()
     private var panels: [String: NSPanel] = [:]
     private var retractTimers: [String: Timer] = [:]
     private var hoverStates: [String: Bool] = [:]
     private var durations: [String: TimeInterval] = [:]
     private var noAutoClose: Set<String> = []
    private func logPopup(_ msg: String) {
        let line = "[\(Date())] \(msg)\n"
        if let data = line.data(using: .utf8) {
            let url = URL(fileURLWithPath: "/tmp/EliaTopBar.log")
            if FileManager.default.fileExists(atPath: url.path) {
                if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
            } else { try? data.write(to: url) }
        }
        print("[EliaDrop] \(msg)")
    }
     func show(for agentName: String, dropX: CGFloat, duration: TimeInterval, baseURL: String = "http://localhost:5656", showSessionSelector: Bool = false, disableAutoClose: Bool = false) {
         logPopup("show agent=\(agentName) dropX=\(dropX) duration=\(duration) panelsBefore=\(panels.count) screen=\(String(describing: NSScreen.main?.frame))")
         guard duration > 0, let screen = NSScreen.main else { logPopup("show abort duration<=0 or no screen"); return }
         if panels[agentName] != nil { logPopup("show already has panel for \(agentName) reschedule"); if !disableAutoClose { scheduleRetract(for: agentName, after: duration) }; return }
         let width: CGFloat = 340, height: CGFloat = 260, gap: CGFloat = 8
         let barBottom = screen.frame.maxY - NSStatusBar.system.thickness
         let count = panels.count + 1
         let totalWidth = CGFloat(count) * width + CGFloat(count-1) * gap
         var startX = dropX - totalWidth/2
         startX = max(screen.frame.minX+8, min(startX, screen.frame.maxX-totalWidth-8))
         let idx = panels.count
         let x = startX + CGFloat(idx)*(width+gap)
         let finalFrame = NSRect(x: x, y: barBottom-height, width: width, height: height)
         let hiddenFrame = NSRect(x: x, y: screen.frame.maxY, width: width, height: height)
         let panel = makePanel(hiddenFrame: hiddenFrame, agentName: agentName)
         panel.contentView = NSHostingView(rootView: RunPopupView(agentName: agentName, onTap: { [weak self] in self?.retract(for: agentName) }, baseURL: baseURL, showSessionSelector: showSessionSelector, disableAutoClose: disableAutoClose))
          panels[agentName]=panel; durations[agentName]=duration; hoverStates[agentName]=false
          if disableAutoClose { noAutoClose.insert(agentName) } else { noAutoClose.remove(agentName) }
          repositionAll(dropX: dropX)
          panel.orderFrontRegardless()
          panel.alphaValue = 0
          NSAnimationContext.runAnimationGroup({ ctx in ctx.duration=0.62; ctx.timingFunction=CAMediaTimingFunction(controlPoints:0.22,1,0.36,1); ctx.allowsImplicitAnimation=true; panel.animator().setFrame(finalFrame, display:true); panel.animator().alphaValue = 1 }, completionHandler: { panel.alphaValue = 1 })
          if !disableAutoClose { scheduleRetract(for: agentName, after: duration) }
     }
    private func repositionAll(dropX: CGFloat) {
        guard let screen = NSScreen.main else { return }
        let width: CGFloat=340, height: CGFloat=260, gap: CGFloat=8
        let barBottom = screen.frame.maxY - NSStatusBar.system.thickness
        let sorted = panels.keys.sorted()
        let totalWidth = CGFloat(sorted.count)*width + CGFloat(max(0,sorted.count-1))*gap
        var startX = dropX - totalWidth/2
        startX = max(screen.frame.minX+8, min(startX, screen.frame.maxX-totalWidth-8))
        for (idx,name) in sorted.enumerated() { guard let p=panels[name] else { continue }
            let x=startX+CGFloat(idx)*(width+gap)
            var frame=p.frame; frame.origin.x=x
            if p.frame.origin.x != x { NSAnimationContext.runAnimationGroup({ ctx in ctx.duration=0.35; ctx.timingFunction=CAMediaTimingFunction(name:.easeInEaseOut); p.animator().setFrame(frame, display:true) }) }
        }
    }
    private func makePanel(hiddenFrame: NSRect, agentName: String) -> NSPanel {
        let p = HoverPanel(contentRect: hiddenFrame, styleMask: [.borderless,.nonactivatingPanel], backing: .buffered, defer: false, agentName: agentName, owner: self)
        p.level = .statusBar; p.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle]
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false; p.isMovableByWindowBackground = canDrag(for: agentName); p.isMovable = true; p.worksWhenModal = true
        return p
    }
    func retract(for agentName: String) {
        guard let panel=panels[agentName], let screen=NSScreen.main else { return }
        retractTimers[agentName]?.invalidate(); retractTimers[agentName]=nil
        let target=NSRect(x:panel.frame.origin.x,y:screen.frame.maxY,width:panel.frame.width,height:panel.frame.height)
        NSAnimationContext.runAnimationGroup({ ctx in ctx.duration=0.42; ctx.timingFunction=CAMediaTimingFunction(controlPoints:0.4,0,0.6,1); ctx.allowsImplicitAnimation=true; panel.animator().setFrame(target,display:true); panel.animator().alphaValue = 0.85 }, completionHandler:{ [weak self] in self?.close(for:agentName,panel:panel) })
    }
     private func close(for name: String, panel: NSPanel) { panel.orderOut(nil); panels[name]=nil; hoverStates[name]=nil; durations[name]=nil; noAutoClose.remove(name) }
    private func scheduleRetract(for agentName: String, after duration: TimeInterval) {
        retractTimers[agentName]?.invalidate()
        retractTimers[agentName]=Timer.scheduledTimer(withTimeInterval: duration, repeats:false){ [weak self] _ in Task{ @MainActor [weak self] in guard let self else{return}; if self.hoverStates[agentName]==true{return}; self.retract(for:agentName) } }
    }
    var panelCount: Int { panels.count }
    func hasPanel(for name: String) -> Bool { panels[name] != nil }
     func setHover(_ hovering: Bool, for agentName: String) {
         hoverStates[agentName]=hovering
         if hovering { retractTimers[agentName]?.invalidate(); retractTimers[agentName]=nil }
         else if !noAutoClose.contains(agentName) { scheduleRetract(for: agentName, after:1.5) }
     }
    var isDraggableEnabled: Bool { UserDefaults.standard.bool(forKey:"dropDraggableEnabled") }
    func isLocked(for name: String) -> Bool { (UserDefaults.standard.dictionary(forKey:"dropLockedStates") as? [String:Bool])?[name] ?? false }
    func setLocked(_ locked: Bool, for name: String) { var d=(UserDefaults.standard.dictionary(forKey:"dropLockedStates") as? [String:Bool]) ?? [:]; d[name]=locked; UserDefaults.standard.set(d, forKey:"dropLockedStates"); panels[name]?.isMovableByWindowBackground = canDrag(for: name) }
    func canDrag(for name: String) -> Bool { isDraggableEnabled && !isLocked(for: name) }
    func panelOrigin(for name: String) -> CGPoint? { panels[name]?.frame.origin }
    func setPanelOrigin(_ origin: CGPoint, for name: String) { guard let p=panels[name] else { return }; var f=p.frame; f.origin=origin; p.setFrame(f, display:true) }
    func refreshAllDraggable() { for (name,p) in panels { p.isMovableByWindowBackground = canDrag(for: name) } }
    func updateHeight(for agentName: String, to newHeight: CGFloat) {
        guard let p=panels[agentName], let screen=NSScreen.main else { return }
        let barBottom = screen.frame.maxY - NSStatusBar.system.thickness
        var f=p.frame
        let h = max(260, min(newHeight, screen.frame.height - 60))
        let currentTop = p.frame.origin.y + p.frame.size.height
        let top = abs(currentTop - barBottom) > 4 ? currentTop : barBottom
        f.size.height = h
        f.origin.y = top - h
        if f.origin.y < screen.frame.minY + 8 { f.origin.y = screen.frame.minY + 8 }
        if f != p.frame { p.setFrame(f, display:true, animate:true) }
    }
    func closeAll() {
        let count = panels.count
        AppLog.d("closeAll Drops count=\(count)")
        for (name,p) in panels { p.orderOut(nil) }
        retractTimers.values.forEach{ $0.invalidate() }
        retractTimers.removeAll()
        panels.removeAll()
        hoverStates.removeAll()
        durations.removeAll()
        noAutoClose.removeAll()
    }
}
private class HoverPanel: NSPanel {
    let agentName: String; weak var owner: RunPopupController?
    init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool, agentName: String, owner: RunPopupController) { self.agentName=agentName; self.owner=owner; super.init(contentRect:contentRect, styleMask:styleMask, backing:backing, defer:flag) }
    override func mouseEntered(with event: NSEvent){ owner?.setHover(true, for:agentName) }
    override func mouseExited(with event: NSEvent){ owner?.setHover(false, for:agentName) }
    override var canBecomeKey: Bool{ false }
    override var canBecomeMain: Bool { false }
    override func mouseDown(with event: NSEvent) {
        if let o=owner, o.canDrag(for: agentName) {
            performDrag(with: event)
            return
        }
        super.mouseDown(with: event)
    }
    override var isMovableByWindowBackground: Bool {
        get { super.isMovableByWindowBackground }
        set { super.isMovableByWindowBackground = newValue }
    }
}
struct PulseGlow: ViewModifier { @State private var pulsing=false; func body(content:Content)->some View{ content.scaleEffect(pulsing ? 1.18:1.0).opacity(pulsing ? 0.3:0.9).animation(.easeInOut(duration:0.9).repeatForever(autoreverses:true),value:pulsing).onAppear{pulsing=true} } }
struct GrokWorkingDot: View {
    @State private var dashPhase: CGFloat = 0
    var body: some View {
        let sq: CGFloat = 8, rad: CGFloat = 1.8
        let perim: CGFloat = 4*(sq-2*rad) + 2*CGFloat.pi*rad
        let headLen = perim*0.62
        let tailLen = perim*0.22
        return ZStack{
            RoundedRectangle(cornerRadius:rad).stroke(Color.primary.opacity(0.18), lineWidth:1).frame(width:sq,height:sq)
            RoundedRectangle(cornerRadius:rad).stroke(Color.accentColor, style: StrokeStyle(lineWidth:1.35, lineCap:.round, dash:[headLen, perim-headLen], dashPhase:dashPhase)).frame(width:sq,height:sq)
            RoundedRectangle(cornerRadius:rad).stroke(Color.accentColor.opacity(0.42), style: StrokeStyle(lineWidth:1.1, lineCap:.round, dash:[tailLen, perim-tailLen], dashPhase:dashPhase+headLen+perim*0.06)).frame(width:sq,height:sq)
            Circle().fill(Color.accentColor).frame(width:2.4,height:2.4)
        }.frame(width:sq,height:sq).onAppear{ withAnimation(.linear(duration:0.85).repeatForever(autoreverses:false)){ dashPhase=perim } }
    }
}

// MARK: - RunPopupView — full livestream renderer (mirrors LogPopoverView)

struct RunPopupView: View {
    let agentName: String; let onTap: ()->Void
    let baseURL: String; let showSessionSelector: Bool; let disableAutoClose: Bool
    @State private var observer: NSObjectProtocol?
    @State private var verticalTodos: [RunTodoItem] = []
    @State private var historyReady = false
    @State private var isHoveringTodoModule = false
    @State private var liveEntries: [RunLiveEntry] = []
    @State private var liveRunning = true
    @State private var liveTick = 0
    @State private var sessions: [RunSessionInfo] = []
    @State private var sessionsLoading = false
    @State private var showSessions = false
    @State private var isLockedCached: Bool = false
    @State private var draggableEnabledState: Bool = UserDefaults.standard.bool(forKey:"dropDraggableEnabled")
    @State private var draggableObserver: NSObjectProtocol?
    @State private var isPinnedToBottom: Bool = true
    @State private var pendingBubbleScroll: DispatchWorkItem? = nil
    @State private var pendingPinnedFalse: DispatchWorkItem? = nil
    private static let bubbleBottomId = "run-bubble-bottom"
    private static let bubbleScrollSpace = "run-bubble-scroll"
    @ObservedObject private var livestream = LivestreamStore.shared
    @State private var agentRunning: Bool? = nil
    @State private var agentLastError: String? = nil
    @State private var agentEnabled: Bool? = nil
    @State private var trafficInWindow: Int = 0
    @State private var trafficOutWindow: Int = 0
    @State private var trafficInRate: Double = 0
    @State private var trafficOutRate: Double = 0
    @State private var trafficObserver: NSObjectProtocol?
    @State private var trafficTimer: Timer? = nil
    @State private var statusTimer: Timer? = nil
    private func startStatusRefresh(){ statusTimer?.invalidate(); let t = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true){ _ in Task{ @MainActor in self.fetchAgentStatus() } }; RunLoop.main.add(t, forMode: .common); statusTimer = t }
    @State private var showStickerPinned: Bool = false
    @State private var subagentKeys: [LivestreamStore.SubagentKey] = []
    @State private var subagentPollTimers: [LivestreamStore.SubagentKey: Timer] = [:]
    @State private var expandedSubagent: LivestreamStore.SubagentKey? = nil
    @State private var isHoveringLive: Bool = false
    @State private var isHoveringSubagent: Bool = false
    @State private var pendingHoverOff: DispatchWorkItem? = nil
    @State private var pendingSubagentHoverOff: DispatchWorkItem? = nil
    private var showSticker: Bool { (showStickerPinned || isHoveringLive) && panelsSticker }
    private func setHoverSubagent(_ hovering: Bool){
        pendingSubagentHoverOff?.cancel()
        if hovering {
            pendingSubagentHoverOff=nil
            if !isHoveringSubagent { withAnimation(.easeInOut(duration:0.15)){ isHoveringSubagent=true } }
        } else {
            let w=DispatchWorkItem{ withAnimation(.easeInOut(duration:0.15)){ isHoveringSubagent=false } }
            pendingSubagentHoverOff=w
            DispatchQueue.main.asyncAfter(deadline:.now()+0.12, execute:w)
        }
    }
    private func setHoverLive(_ hovering: Bool){
        pendingHoverOff?.cancel()
        if hovering {
            pendingHoverOff=nil
            if !isHoveringLive { withAnimation(.easeInOut(duration:0.15)){ isHoveringLive=true } }
        } else {
            let w=DispatchWorkItem{ withAnimation(.easeInOut(duration:0.15)){ isHoveringLive=false } }
            pendingHoverOff=w
            DispatchQueue.main.asyncAfter(deadline:.now()+0.12, execute:w)
        }
    }

    enum RunLiveEntry: Equatable {
        case text(String)
        case reasoning(String)
        case tool(name: String, input: String?, output: String?)
    }
    struct RunTodoItem: Equatable { let content:String; let status:String; let priority:String }
    struct RunSessionInfo: Codable, Identifiable { let id: String; let title: String? }

    private var dropPosition: String { UserDefaults.standard.string(forKey:"dropIconPosition") ?? "above" }
    private var panelsSticker: Bool { UserDefaults.standard.object(forKey:"dropShowSticker") as? Bool ?? true }
    private var panelsTodo: Bool { UserDefaults.standard.object(forKey:"dropShowTodo") as? Bool ?? true }
    private var panelsSubagents: Bool { UserDefaults.standard.object(forKey:"dropShowSubagents") as? Bool ?? true }
    private var subagentPosition: String { UserDefaults.standard.string(forKey:"subagentPosition") ?? "right" }
    private var teamTasksPosition: String { UserDefaults.standard.string(forKey:"teamTasksPosition") ?? "side" }
    private var draggableEnabled: Bool { draggableEnabledState }
    var body: some View {
        Group {
            switch dropPosition {
            case "left":
                VStack(spacing:6){
                    if showSticker { stickerHeader.onHover{ setHoverLive($0) }.transition(.opacity.combined(with:.move(edge:.top))) }
                    if teamTasksPosition=="above" { teamTasksAboveBar }
                    HStack(alignment:.center, spacing:8){
                        photoBadge
                        mainCard
                    }
                    subagentStack
                }.padding(.top,4)
            case "right":
                VStack(spacing:6){
                    if showSticker { stickerHeader.onHover{ setHoverLive($0) }.transition(.opacity.combined(with:.move(edge:.top))) }
                    if teamTasksPosition=="above" { teamTasksAboveBar }
                    HStack(alignment:.center, spacing:8){
                        mainCard
                        photoBadge
                    }
                    subagentStack
                }.padding(.top,4)
            case "inlineTiny":
                VStack(spacing:6){ if showSticker { stickerHeader.onHover{ setHoverLive($0) }.transition(.opacity.combined(with:.move(edge:.top))) }; if teamTasksPosition=="above" { teamTasksAboveBar }; mainCard; subagentStack }.padding(.top,4)
            default:
                VStack(spacing:6){
                    photoBadge
                    if showSticker { stickerHeader.onHover{ setHoverLive($0) }.transition(.opacity.combined(with:.move(edge:.top))) }
                    if teamTasksPosition=="above" { teamTasksAboveBar }
                    mainCard
                    subagentStack
                }.padding(.top,4)
            }
        }
        .frame(width: {
            let hasTodo = historyReady && panelsTodo && !effectiveTodos.isEmpty
            let hasSub = historyReady && !filteredSubagentsForSide.isEmpty
            if showSessions { return 400 }
            if hasTodo && hasSub { return 326 }
            if hasTodo || hasSub { return 298 }
            return 264
        }())
        .animation(.easeInOut(duration:0.22), value: showSticker)
        .animation(.easeInOut(duration:0.2), value: effectiveTodos.isEmpty)
        .animation(.easeInOut(duration:0.2), value: subagentKeys.isEmpty)
        .onAppear{ showStickerPinned=false; isHoveringLive=false; historyReady=false; verticalTodos=[]; subagentKeys=[]; expandedSubagent=nil; isLockedCached=RunPopupController.shared.isLocked(for: agentName); draggableEnabledState=UserDefaults.standard.bool(forKey:"dropDraggableEnabled"); observeDraggable(); observeTraffic(); fetchAgentStatus(); fetchRunHistory(); observeLogs(); startTick(); startStatusRefresh() }.onDisappear{ if let o=observer{NotificationCenter.default.removeObserver(o)}; if let d=draggableObserver{NotificationCenter.default.removeObserver(d)}; if let t=trafficObserver{NotificationCenter.default.removeObserver(t)}; trafficTimer?.invalidate(); statusTimer?.invalidate(); stopAllSubagentPolling() }.onTapGesture{onTap()}.onHover{ h in RunPopupController.shared.setHover(h, for:agentName) }
        .onChange(of: showStickerPinned){ _ in updatePanelForSubagents() }
        .onChange(of: isHoveringLive){ _ in updatePanelForSubagents() }
        .onReceive(livestream.throttled){ agent in if agent==agentName { refreshSubagentsFromLive() } }
        .onReceive(livestream.subagentThrottled){ key in if key.parentAgent==agentName { /* subagent updated, no action needed, view auto-refreshes */ } }
    }
    private func bubbleAttachedConfigured(hasLeft: Bool, hasRight: Bool) -> some View {
        var corners: RunRoundedCorner.RunCornerSet = []
        if !hasLeft { corners.insert(.topLeft); corners.insert(.bottomLeft) }
        if !hasRight { corners.insert(.topRight); corners.insert(.bottomRight) }
        let shape: AnyShape = corners.isEmpty ? AnyShape(Rectangle()) : AnyShape(RunRoundedCorner(radius:14, corners:corners))
        return bubbleContent.background(shape.fill(.regularMaterial)).overlay(shape.stroke(Color.primary.opacity(0.12)))
    }

    @ViewBuilder private var stickerHeader: some View {
        if !historyReady {
            HStack{ ProgressView().controlSize(.mini).scaleEffect(0.7); Text("Loading session…").font(.system(size:7)).foregroundColor(.secondary); Spacer() }.padding(.horizontal,6).padding(.vertical,4).frame(maxWidth:.infinity).background(RoundedRectangle(cornerRadius:8).fill(Color(nsColor:.controlBackgroundColor).opacity(0.9)).overlay(RoundedRectangle(cornerRadius:8).stroke(Color.primary.opacity(0.12))))
        } else {
            let tools = storeEntries.filter{ if case .tool = $0 { return true } else { return false } }.count
            let msgs = storeEntries.filter{ if case .text = $0 { return true } else if case .reasoning = $0 { return true } else { return false } }.count
            HStack(spacing:6){
            HStack(spacing:4){
                Image(systemName:"antenna.radiowaves.left.and.right").font(.system(size:7, weight:.bold)).foregroundColor(.secondary)
                HStack(spacing:2){
                    Text("↓").font(.system(size:7, weight:.bold)).foregroundColor(.blue)
                    Text(formatRate(trafficInRate)).font(.system(size:7, weight:.semibold, design:.monospaced)).foregroundColor(.blue)
                }
                HStack(spacing:2){
                    Text("↑").font(.system(size:7, weight:.bold)).foregroundColor(.green)
                    Text(formatRate(trafficOutRate)).font(.system(size:7, weight:.semibold, design:.monospaced)).foregroundColor(.green)
                }
            }.padding(.horizontal,6).padding(.vertical,3).background(Color.primary.opacity(0.07)).cornerRadius(6)
            Spacer()
            HStack(spacing:3){ Image(systemName:"wrench.and.screwdriver").font(.system(size:7)); Text("\(tools) tools").font(.system(size:7, weight:.medium)).foregroundColor(.purple) }.padding(.horizontal,5).padding(.vertical,3).background(Color.purple.opacity(0.10)).cornerRadius(6)
            HStack(spacing:3){ Image(systemName:"bubble.left").font(.system(size:7)); Text("\(msgs) msgs").font(.system(size:7, weight:.medium)).foregroundColor(.blue) }.padding(.horizontal,5).padding(.vertical,3).background(Color.blue.opacity(0.10)).cornerRadius(6)
            }.padding(.horizontal,6).padding(.vertical,4).frame(maxWidth:.infinity).background(RoundedRectangle(cornerRadius:8).fill(.regularMaterial)).overlay(RoundedRectangle(cornerRadius:8).stroke(Color.primary.opacity(0.12)))
            }
    }
    @ViewBuilder private var teamTasksAboveBar: some View {
        let tasks = subagentKeys.filter{ $0.kind=="team_task" }
        if !panelsSubagents || tasks.isEmpty || teamTasksPosition != "above" {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators:false){
                HStack(spacing:6){
                    Image(systemName:"list.bullet").font(.system(size:7, weight:.bold)).foregroundColor(.orange)
                    ForEach(tasks, id:\.self){ k in
                        let isSel = expandedSubagent==k
                        HStack(spacing:3){
                            Group{ if isWorking(k) { GrokWorkingDot() } else { Text("✅").font(.system(size:6)) } }.frame(width:8,height:8)
                            Text(k.description).font(.system(size:7, weight:.medium)).foregroundColor(isSel ? .orange : .primary).lineLimit(1)
                        }.padding(.horizontal,6).padding(.vertical,4).background(isSel ? Color.orange.opacity(0.15) : Color.orange.opacity(0.08)).cornerRadius(6).overlay(RoundedRectangle(cornerRadius:6).stroke(isSel ? Color.orange.opacity(0.3) : Color.clear))
                        .onTapGesture{ withAnimation(.easeInOut(duration:0.15)){ expandedSubagent = isSel ? nil : k } }
                    }
                }.padding(.horizontal,6).padding(.vertical,4)
            }.frame(maxWidth:.infinity).background(RoundedRectangle(cornerRadius:8).fill(Color.orange.opacity(0.08))).overlay(RoundedRectangle(cornerRadius:8).stroke(Color.orange.opacity(0.18)))
        }
    }
    private var subagentStack: some View {
        Group {
            if panelsSubagents, historyReady, let exp = expandedSubagent, subagentKeys.contains(exp) {
                SubagentBubbleView(key: exp, baseURL: baseURL, onClose: { withAnimation(.easeInOut(duration:0.18)){ expandedSubagent=nil } })
                    .transition(.opacity.combined(with:.move(edge:.top)))
                    .onChange(of: expandedSubagent){ _ in updatePanelForSubagents() }
            }
        }
    }
    private func updatePanelForSubagents(){
        let baseH: CGFloat = 260
        let stickerH: CGFloat = showSticker ? 36 : 0
        let subH: CGFloat = expandedSubagent==nil ? 0 : 110
        let newH = baseH + (showSticker ? 6 : 0) + subH + 12
        RunPopupController.shared.updateHeight(for: agentName, to: newH)
    }
    private var mainCard: some View {
        let cardH: CGFloat = 175
        let hasTodo = historyReady && panelsTodo && !effectiveTodos.isEmpty
        let hasSubLeft = historyReady && !filteredSubagentsForSide.isEmpty && subagentPosition=="left"
        let hasSubRight = historyReady && !filteredSubagentsForSide.isEmpty && subagentPosition=="right"
        return HStack(alignment:.top, spacing:0){
            if hasSubLeft {
                ZStack(alignment:.leading){
                    subagentVerticalStripCollapsed
                        .frame(width: 28, height: cardH)
                        .background(RunRoundedCorner(radius:14, corners:[.topLeft,.bottomLeft]).fill(.regularMaterial))
                        .overlay(RunRoundedCorner(radius:14, corners:[.topLeft,.bottomLeft]).stroke(Color.primary.opacity(0.12)))
                        .opacity(isHoveringSubagent ? 0 : 1)
                    if isHoveringSubagent {
                        subagentVerticalStripExpanded
                            .frame(width: 180, height: cardH)
                            .background(RunRoundedCorner(radius:14, corners:[.topLeft,.bottomLeft]).fill(.regularMaterial))
                            .overlay(RunRoundedCorner(radius:14, corners:[.topLeft,.bottomLeft]).stroke(Color.primary.opacity(0.12)))
                            .shadow(color:.black.opacity(0.22), radius:10, x:3, y:5)
                            .transition(.opacity.combined(with:.move(edge:.leading)))
                    }
                }.frame(width:28, height:cardH, alignment:.leading).zIndex(10).onHover{ v in setHoverSubagent(v) }
            }
            if hasTodo {
                ZStack(alignment:.leading){
                    popupVerticalTodoStripCollapsed
                        .frame(width: 28, height: cardH)
                        .background(RunRoundedCorner(radius:14, corners: hasSubLeft ? [] : [.topLeft,.bottomLeft]).fill(.regularMaterial))
                        .overlay(RunRoundedCorner(radius:14, corners: hasSubLeft ? [] : [.topLeft,.bottomLeft]).stroke(Color.primary.opacity(0.12)))
                        .opacity(isHoveringTodoModule ? 0 : 1)
                    if isHoveringTodoModule {
                        popupVerticalTodoStripExpanded
                            .frame(width: 180, height: cardH)
                            .background(RunRoundedCorner(radius:14, corners:[.topLeft,.bottomLeft]).fill(.regularMaterial))
                            .overlay(RunRoundedCorner(radius:14, corners:[.topLeft,.bottomLeft]).stroke(Color.primary.opacity(0.12)))
                            .shadow(color:.black.opacity(0.22), radius:10, x:3, y:5)
                            .transition(.opacity.combined(with:.move(edge:.leading)))
                    }
                }.frame(width:28, height:cardH, alignment:.leading).zIndex(10).onHover{ v in withAnimation(.easeInOut(duration:0.15)){ isHoveringTodoModule = v } }
            }
            if showSessions { popupSessionSidebar }
            bubbleAttachedConfigured(hasLeft: hasTodo || hasSubLeft, hasRight: hasSubRight)
            if hasSubRight {
                ZStack(alignment:.trailing){
                    subagentVerticalStripCollapsed
                        .frame(width: 28, height: cardH)
                        .background(RunRoundedCorner(radius:14, corners:[.topRight,.bottomRight]).fill(.regularMaterial))
                        .overlay(RunRoundedCorner(radius:14, corners:[.topRight,.bottomRight]).stroke(Color.primary.opacity(0.12)))
                        .opacity(isHoveringSubagent ? 0 : 1)
                    if isHoveringSubagent {
                        subagentVerticalStripExpanded
                            .frame(width: 180, height: cardH)
                            .background(RunRoundedCorner(radius:14, corners:[.topRight,.bottomRight]).fill(.regularMaterial))
                            .overlay(RunRoundedCorner(radius:14, corners:[.topRight,.bottomRight]).stroke(Color.primary.opacity(0.12)))
                            .shadow(color:.black.opacity(0.22), radius:10, x:-3, y:5)
                            .transition(.opacity.combined(with:.move(edge:.trailing)))
                    }
                }.frame(width:28, height:cardH, alignment:.trailing).onHover{ v in setHoverSubagent(v) }
            }
        }
    }
    private var bubbleAttached: some View {
        let hasTodo = panelsTodo && !effectiveTodos.isEmpty
        let shape: AnyShape = hasTodo ? AnyShape(RunRoundedCorner(radius:14, corners:[.topRight,.bottomRight])) : AnyShape(RoundedRectangle(cornerRadius:14))
        return bubbleContent.background(shape.fill(.regularMaterial)).overlay(shape.stroke(Color.primary.opacity(0.12)))
    }
    private var inlineTinyPhoto: some View {
        Group {
            if let photo=ProfilePhotos.shared.circularPhoto(for:agentName,size:16){ Image(nsImage:photo).resizable().frame(width:16,height:16).clipShape(Circle()).overlay(Circle().stroke(Color.primary.opacity(0.12),lineWidth:0.5)) } else { ZStack{ Circle().fill(Color.accentColor.opacity(0.22)); Text(agentMonogram).font(.system(size:7,weight:.bold)).foregroundColor(.accentColor) }.frame(width:16,height:16) }
        }
    }
    private struct RunBubbleBottomKey: PreferenceKey { static var defaultValue: CGFloat=0; static func reduce(value:inout CGFloat,nextValue:()->CGFloat){ value=nextValue() } }
    private func requestBubbleScroll(proxy: ScrollViewProxy, force: Bool=false){
        guard force || isPinnedToBottom else { return }
        pendingBubbleScroll?.cancel()
        let w=DispatchWorkItem{ withAnimation(.easeOut(duration:0.15)){ proxy.scrollTo(Self.bubbleBottomId, anchor:.bottom) } }
        pendingBubbleScroll=w
        DispatchQueue.main.asyncAfter(deadline:.now()+0.05, execute:w)
    }
    private var storeEntries: [RunLiveEntry] {
        livestream.stream(for: agentName).map { e in
            switch e {
            case .reasoning(_, let t): return .reasoning(t)
            case .text(_, let t): return .text(t)
            case .tool(_, let n, let i, let o): return .tool(name: n, input: i, output: o)
            }
        }
    }
    private var effectiveTodos: [RunTodoItem] {
        guard historyReady else { return [] }
        return livestream.todo(for: agentName).map { RunTodoItem(content: $0.content, status: $0.status, priority: $0.priority) }
    }
    private var liveStatus: (text:String, color:Color, dot:Color?) {
        if let running = agentRunning {
            if running { return ("live", .orange, .orange) }
            if let err=agentLastError, !err.isEmpty { return ("error", .red, .red) }
            if let en=agentEnabled, !en { return ("disabled", .secondary, nil) }
            return ("done", .secondary, nil)
        }
        return (liveRunning ? "live" : "done", liveRunning ? .orange : .secondary, liveRunning ? .orange : nil)
    }
    private func fetchAgentStatus(){
        guard let url=URL(string:"\(baseURL)/status/\(agentName)") else { return }
        URLSession.shared.dataTask(with: EliaAuth.authorize(url)){ data,_,_ in
            guard let data=data, let json=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { return }
            DispatchQueue.main.async{
                agentRunning = json["running"] as? Bool
                agentLastError = json["last_error"] as? String
                agentEnabled = json["enabled"] as? Bool
            }
        }.resume()
    }
    private var bubbleContent: some View {
        VStack(alignment:.leading,spacing:4){
            HStack(spacing:6){
                if dropPosition=="inlineTiny" { inlineTinyPhoto }
                Circle().fill(Color.green).frame(width:6,height:6)
                Text("\(agentName) running").font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
                Spacer()
                if draggableEnabled {
                    Button(action: { let newLock = !isLockedCached; isLockedCached=newLock; RunPopupController.shared.setLocked(newLock, for: agentName) }){
                        Image(systemName: isLockedCached ? "lock.fill" : "lock.open.fill").font(.system(size:8,weight:.semibold)).foregroundColor(isLockedCached ? .red.opacity(0.8) : .secondary).frame(width:16,height:16).background(Color.secondary.opacity(isLockedCached ? 0.18 : 0.12)).clipShape(Circle())
                    }.buttonStyle(.plain).help(isLockedCached ? "Unlock dragging" : "Lock position")
                }
                Button(action: { showSessions.toggle(); if showSessions && sessions.isEmpty { fetchSessionSessions() } }) { Image(systemName:"list.bullet").font(.system(size:9,weight:.semibold)).foregroundColor(.secondary).frame(width:16,height:16).background(Color.secondary.opacity(0.12)).clipShape(Circle()) }.buttonStyle(.plain).help("Switch session")
                Button(action: { withAnimation(.easeInOut(duration:0.18)){ showStickerPinned.toggle() } }){
                    HStack(spacing:3){
                        Text(liveStatus.text).font(.caption2).foregroundColor(liveStatus.color)
                        if let dot=liveStatus.dot { Circle().fill(dot).frame(width:5,height:5).opacity(0.9) }
                        Image(systemName: showSticker ? "chevron.up" : "chevron.down").font(.system(size:6, weight:.bold)).foregroundColor(.secondary.opacity(0.6))
                    }.padding(.horizontal,5).padding(.vertical,2).background(Color.primary.opacity(showSticker ? 0.12 : 0.06)).cornerRadius(6)
                }.buttonStyle(.plain).help(showSticker ? "Hide live details" : "Show live details — hover also shows")
                .onHover{ setHoverLive($0) }
            }
            GeometryReader{ outer in
                ScrollViewReader{ proxy in
                    ScrollView(showsIndicators:false){
                        VStack(alignment:.leading, spacing:5){
                            if storeEntries.isEmpty {
                                HStack(spacing:6){
                                    if liveRunning { ProgressView().controlSize(.mini).scaleEffect(0.7); Text("Waiting for output\(String(repeating:".", count:(liveTick%3)+1))").font(.system(size:9, design:.monospaced)).foregroundColor(.secondary) } else { Text("No output yet").font(.system(size:9, design:.monospaced)).foregroundColor(.secondary) }
                                    Spacer()
                                }.padding(.vertical,4)
                            } else {
                                ForEach(Array(storeEntries.enumerated()), id:\.offset){ _, entry in
                                    popupEntry(entry)
                                }
                            }
                            Color.clear.frame(height:1).id(Self.bubbleBottomId)
                                .background(GeometryReader{ g in Color.clear.preference(key: RunBubbleBottomKey.self, value: g.frame(in:.named(Self.bubbleScrollSpace)).maxY) })
                        }.frame(maxWidth:.infinity, alignment:.leading).padding(.bottom, 24)
                    }
                    .coordinateSpace(name: Self.bubbleScrollSpace)
                    .onPreferenceChange(RunBubbleBottomKey.self){ maxY in
                        let atBottom = maxY <= outer.size.height + 24
                        if atBottom {
                            pendingPinnedFalse?.cancel(); pendingPinnedFalse=nil
                            if !isPinnedToBottom { isPinnedToBottom = true }
                        } else {
                            if isPinnedToBottom {
                                pendingPinnedFalse?.cancel()
                                let work = DispatchWorkItem { isPinnedToBottom = false }
                                pendingPinnedFalse = work
                                DispatchQueue.main.asyncAfter(deadline: .now()+0.08, execute: work)
                            }
                        }
                    }
                    .onChange(of: storeEntries){ _ in requestBubbleScroll(proxy: proxy) }
                    .onAppear{
                        isPinnedToBottom=true
                        for d in [0.06,0.18,0.35,0.6] as [Double] {
                            DispatchQueue.main.asyncAfter(deadline:.now()+d){ requestBubbleScroll(proxy: proxy, force:true) }
                        }
                    }
                    .overlay(alignment:.bottom){
                        if !isPinnedToBottom && !storeEntries.isEmpty {
                            Button(action: { pendingPinnedFalse?.cancel(); pendingPinnedFalse=nil; isPinnedToBottom=true; requestBubbleScroll(proxy: proxy, force:true) }){
                                Image(systemName:"arrow.down").font(.system(size:9, weight:.bold)).foregroundColor(.white).frame(width:22,height:22).background(Circle().fill(Color.accentColor)).shadow(color:.black.opacity(0.22), radius:4, x:0,y:2)
                            }.buttonStyle(.plain).padding(.bottom,6).transition(.scale.combined(with:.opacity))
                        }
                    }
                }
            }.frame(height: 145)
        }.padding(10).frame(width: showSessions ? 240 : 264, height: 175)
    }
    private func formatRate(_ koPerSec: Double) -> String {
        if koPerSec >= 1000 { return String(format: "%.2f Mo/s", koPerSec/1000) }
        return String(format: "%.1f ko/s", koPerSec)
    }
    private func observeTraffic(){
        trafficObserver = NotificationCenter.default.addObserver(forName: SubworkerManager.runLogNotification, object: nil, queue: .main){ note in
            guard let name = note.userInfo?["name"] as? String, name==agentName, let delta = note.userInfo?["text"] as? String else { return }
            trafficInWindow += delta.utf8.count
        }
        trafficTimer?.invalidate()
        trafficTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true){ _ in
            Task{ @MainActor in
                trafficInRate = Double(trafficInWindow)/1000.0
                trafficOutRate = Double(trafficOutWindow)/1000.0
                trafficInWindow = 0; trafficOutWindow = 0
                if agentRunning == nil { fetchAgentStatus() }
            }
        }
        RunLoop.main.add(trafficTimer!, forMode: .common)
    }
    private var popupVerticalTodoStripCollapsed: some View {
        VStack(spacing:6){
            Image(systemName:"checklist").font(.system(size:7, weight:.semibold)).foregroundColor(.purple).padding(.top,6)
            Divider().opacity(0.3).padding(.horizontal,4)
            ForEach(Array(effectiveTodos.prefix(10).enumerated()), id:\.offset){ _,t in
                ZStack{ Circle().fill(runTodoDotColor(t.status)).frame(width:7,height:7); if t.status=="in_progress"{ Circle().stroke(Color.blue.opacity(0.45),lineWidth:1.2).frame(width:10,height:10) } }.frame(width:10,height:10)
            }
            if effectiveTodos.count>10{ Text("+\(effectiveTodos.count-10)").font(.system(size:6)).foregroundColor(.secondary) }
            Spacer(minLength:2)
        }.padding(.vertical,6)
    }
    private var popupVerticalTodoStripExpanded: some View {
        VStack(spacing:6){
            HStack(spacing:4){
                Image(systemName:"checklist").font(.system(size:7, weight:.semibold)).foregroundColor(.purple)
                Text("TODO").font(.system(size:8, weight:.bold, design:.monospaced)).foregroundColor(.purple); Spacer(); Text("\(effectiveTodos.filter{$0.status=="completed"}.count)/\(effectiveTodos.count)").font(.system(size:7,weight:.medium, design:.monospaced)).foregroundColor(.secondary).padding(.horizontal,4).padding(.vertical,1).background(Color.purple.opacity(0.12)).cornerRadius(3)
            }.padding(.horizontal,6).padding(.top,6)
            Divider().opacity(0.3).padding(.horizontal,4)
            ForEach(Array(effectiveTodos.prefix(10).enumerated()), id:\.offset){ _,t in
                HStack(spacing:5){
                    ZStack{ Circle().fill(runTodoDotColor(t.status)).frame(width:7,height:7); if t.status=="in_progress"{ Circle().stroke(Color.blue.opacity(0.45),lineWidth:1.2).frame(width:10,height:10) } }.frame(width:10,height:10)
                    Text(t.content).font(.system(size:8)).lineLimit(1).foregroundColor(t.status=="completed" ? .secondary : .primary).truncationMode(.tail)
                }.padding(.horizontal,6)
            }
            if effectiveTodos.count>10{ Text("+\(effectiveTodos.count-10)").font(.system(size:7)).foregroundColor(.secondary) }
            Spacer(minLength:2)
        }.padding(.vertical,6)
    }
    private var filteredSubagentsForSide: [LivestreamStore.SubagentKey] {
        guard panelsSubagents else { return [] }
        return subagentKeys.filter{ !(teamTasksPosition=="above" && $0.kind=="team_task") }
    }
    private var groupedSubagents: [String?: [LivestreamStore.SubagentKey]] {
        Dictionary(grouping: filteredSubagentsForSide, by: { $0.teamRunId })
    }
    private func isWorking(_ k: LivestreamStore.SubagentKey) -> Bool {
        if isSubagentComplete(k) { return false }
        return agentRunning==true
    }
    private func isSubagentComplete(_ k: LivestreamStore.SubagentKey) -> Bool {
        for e in livestream.stream(for: agentName) {
            if case .tool(_, let name, _, let output) = e, name.lowercased()=="background_output",
               let o = output, o.contains("Task Result"), o.contains(k.sessionId) { return true }
        }
        return false
    }
    private var subagentVerticalStripCollapsed: some View {
        let keys = filteredSubagentsForSide
        let perCol = 12
        let cols = max(1, (keys.count + perCol - 1) / perCol)
        return VStack(spacing:6){
            Image(systemName:"person.2.fill").font(.system(size:7, weight:.semibold)).foregroundColor(.pink).padding(.top,6)
            Divider().opacity(0.3).padding(.horizontal,4)
            HStack(alignment:.top, spacing:2){
                ForEach(0..<cols, id:\.self){ col in
                    let slice = Array(keys.dropFirst(col*perCol).prefix(perCol))
                    VStack(spacing:4){
                        ForEach(slice, id:\.self){ k in
                            Group{
                                if isWorking(k) { GrokWorkingDot() }
                                else { Text("✅").font(.system(size:7)) }
                            }.frame(width:10,height:10)
                        }
                    }.frame(width:12)
                }
            }
            Spacer(minLength:2)
        }.padding(.vertical,6)
    }
    private var subagentVerticalStripExpanded: some View {
        let groups = groupedSubagents
        return VStack(spacing:6){
            HStack(spacing:4){
                Image(systemName:"person.2.fill").font(.system(size:7, weight:.semibold)).foregroundColor(.pink)
                Text("SUBAGENTS").font(.system(size:7, weight:.bold, design:.monospaced)).foregroundColor(.pink); Spacer(); Text("\(subagentKeys.count)").font(.system(size:7,weight:.medium, design:.monospaced)).foregroundColor(.secondary).padding(.horizontal,4).padding(.vertical,1).background(Color.pink.opacity(0.12)).cornerRadius(3)
            }.padding(.horizontal,6).padding(.top,6)
            Divider().opacity(0.3).padding(.horizontal,4)
            if groups.count>1 {
                ForEach(Array(groups.keys.enumerated()), id:\.offset){ _, teamId in
                    let keys = groups[teamId] ?? []
                    let teamName = teamId ?? "bg"
                    VStack(alignment:.leading, spacing:3){
                        Text(teamName).font(.system(size:6, weight:.bold, design:.monospaced)).foregroundColor(.secondary).padding(.horizontal,6)
                        ForEach(keys, id:\.self){ k in
                            let isSel = expandedSubagent==k
                            let tools = livestream.subagentStream(for: k).filter{ if case .tool = $0 { return true } else { return false }}.count
                            let msgs = livestream.subagentStream(for: k).filter{ if case .text = $0 { return true } else if case .reasoning = $0 { return true } else { return false }}.count
                            let badgeColor: Color = k.kind=="team" ? .blue : k.kind=="call_omo" ? .purple : k.kind=="task" ? .orange : .secondary
                            let badgeText = k.kind=="team" ? "team" : k.kind=="call_omo" ? "bg" : k.kind=="task" ? "task" : k.kind
                            Button(action: { withAnimation(.easeInOut(duration:0.18)){ expandedSubagent = isSel ? nil : k } }){
                                HStack(spacing:5){
                                    Group{ if isWorking(k) { GrokWorkingDot() } else { Text("✅").font(.system(size:6)) } }.frame(width:8,height:8)
                                    Text(k.description).font(.system(size:7, weight:.semibold)).foregroundColor(isSel ? .pink : .primary).lineLimit(1)
                                    Text(badgeText).font(.system(size:5, weight:.bold, design:.monospaced)).foregroundColor(.white).padding(.horizontal,3).padding(.vertical,1).background(badgeColor).cornerRadius(3)
                                    Spacer()
                                    Text("\(tools)⧉ \(msgs)✉︎").font(.system(size:6, design:.monospaced)).foregroundColor(.secondary)
                                }.padding(.horizontal,6).padding(.vertical,4).background(isSel ? Color.pink.opacity(0.10) : Color.clear).cornerRadius(6)
                            }.buttonStyle(.plain)
                        }
                    }.padding(.vertical,4).background(Color.primary.opacity(0.04)).cornerRadius(6)
                }
            } else {
                ForEach(subagentKeys, id:\.self){ k in
                    let isSel = expandedSubagent==k
                    let tools = livestream.subagentStream(for: k).filter{ if case .tool = $0 { return true } else { return false }}.count
                    let msgs = livestream.subagentStream(for: k).filter{ if case .text = $0 { return true } else if case .reasoning = $0 { return true } else { return false }}.count
                    let badgeColor: Color = k.kind=="team" ? .blue : k.kind=="call_omo" ? .purple : k.kind=="task" ? .orange : .secondary
                    let badgeText = k.kind=="team" ? "team" : k.kind=="call_omo" ? "bg" : k.kind=="task" ? "task" : k.kind
                    Button(action: { withAnimation(.easeInOut(duration:0.18)){ expandedSubagent = isSel ? nil : k } }){
                        HStack(spacing:5){
                            Group{ if isWorking(k) { GrokWorkingDot() } else { Text("✅").font(.system(size:6)) } }.frame(width:8,height:8)
                            Text(k.description).font(.system(size:7, weight:.semibold)).foregroundColor(isSel ? .pink : .primary).lineLimit(1)
                            Text(badgeText).font(.system(size:5, weight:.bold, design:.monospaced)).foregroundColor(.white).padding(.horizontal,3).padding(.vertical,1).background(badgeColor).cornerRadius(3)
                            Spacer()
                            Text("\(tools)⧉ \(msgs)✉︎").font(.system(size:6, design:.monospaced)).foregroundColor(.secondary)
                        }.padding(.horizontal,6).padding(.vertical,4).background(isSel ? Color.pink.opacity(0.10) : Color.clear).cornerRadius(6)
                    }.buttonStyle(.plain)
                }
            }
            Spacer(minLength:2)
        }.padding(.vertical,6)
    }
    private var popupVerticalTodoStrip: some View { popupVerticalTodoStripCollapsed }

    private var photoBadge: some View {
        ZStack{
            Circle().stroke(Color.accentColor.opacity(0.6),lineWidth:2).frame(width:56,height:56).modifier(PulseGlow())
            if let photo=ProfilePhotos.shared.circularPhoto(for:agentName,size:48){ Image(nsImage:photo).resizable().frame(width:48,height:48) } else { ZStack{ Circle().fill(Color.accentColor.opacity(0.25)); Text(agentMonogram).font(.system(size:18,weight:.bold)).foregroundColor(.accentColor) }.frame(width:48,height:48) }
        }.frame(height:60)
    }

    private var bubble: some View { bubbleAttached }

    @ViewBuilder
    private func popupEntry(_ entry: RunLiveEntry) -> some View {
        switch entry {
        case .reasoning(let r):
            HStack(alignment:.top, spacing:5){
                Rectangle().fill(Color.purple.opacity(0.35)).frame(width:2).cornerRadius(1)
                MarkdownView(text: r, baseColor: .secondary).font(.system(size:8)).fixedSize(horizontal:false, vertical:true)
            }
        case .text(let t):
            MarkdownView(text: streamingSafeMarkdown(t), baseColor: .primary.opacity(0.88)).font(.system(size:9)).fixedSize(horizontal:false, vertical:true).textSelection(.enabled)
        case .tool(let name, let input, let output):
            let lname = name.lowercased()
            if lname == "todowrite", let todos = runParseTodoWrite(input, output: output), !todos.isEmpty {
                runTodoBanner(todos: todos)
            } else if lname == "edit", let inp = input, let diff = runParseEdit(inp) {
                runEditBanner(filePath: diff.path, oldString: diff.old, newString: diff.new)
            } else if lname == "write", let inp = input, let wp = runParseWrite(inp) {
                runWriteBanner(filePath: wp.path, contentPreview: wp.preview, output: output)
            } else if lname == "bash" || lname == "shell" || lname == "interactive_bash" {
                runTerminalBanner(tool: name, input: input, output: output)
            } else if lname == "skill" {
                runSkillBanner(input: input, output: output)
            } else {
                runGenericBanner(name: name, input: input, output: output)
            }
        }
    }

    // MARK: - Banners (compact versions of LogPopoverView banners)

    private func runTodoBanner(todos: [RunTodoItem]) -> some View {
        let completed = todos.filter{ $0.status=="completed"}.count
        let inProg = todos.filter{ $0.status=="in_progress"}.count
        return VStack(alignment:.leading, spacing:0){
            HStack(spacing:4){
                Image(systemName:"checklist").font(.system(size:7)).foregroundColor(.purple)
                Text("Todo").font(.system(size:8, weight:.semibold, design:.monospaced)).foregroundColor(.purple)
                Text("\(completed)/\(todos.count)").font(.system(size:7, weight:.medium, design:.monospaced)).foregroundColor(.secondary).padding(.horizontal,4).padding(.vertical,1).background(Color.purple.opacity(0.12)).cornerRadius(3)
                if inProg>0 { Text("\(inProg) ●").font(.system(size:7)).foregroundColor(.blue) }
                Spacer()
            }.padding(.horizontal,6).padding(.vertical,4).background(Color.purple.opacity(0.08)).clipShape(RunRoundedCorner(radius:5, corners:[.topLeft,.topRight]))
            VStack(alignment:.leading, spacing:0){
                ForEach(Array(todos.prefix(8).enumerated()), id:\.offset){ _,t in
                    HStack(spacing:5){
                        ZStack{ Circle().fill(runTodoDotColor(t.status)).frame(width:6,height:6); if t.status=="in_progress"{ Circle().stroke(Color.blue.opacity(0.4), lineWidth:1).frame(width:8,height:8)} }.frame(width:8,height:8)
                        Text(t.content).font(.system(size:8)).foregroundColor(t.status=="completed" ? .secondary : .primary).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength:0)
                        Circle().fill(runTodoPriorityColor(t.priority)).frame(width:5,height:5)
                    }.padding(.horizontal,6).padding(.vertical,3).background(t.status=="in_progress" ? Color.blue.opacity(0.06) : t.status=="completed" ? Color.green.opacity(0.04) : Color.clear)
                    if t.content != todos.prefix(8).last?.content { Divider().opacity(0.2) }
                }
                if todos.count>8 { Text("… \(todos.count-8) more").font(.system(size:7)).foregroundColor(.secondary).padding(4) }
            }.background(Color(nsColor:.controlBackgroundColor)).clipShape(RunRoundedCorner(radius:5, corners:[.bottomLeft,.bottomRight]))
        }.overlay(RoundedRectangle(cornerRadius:5).stroke(Color.purple.opacity(0.22), lineWidth:1))
    }

    private func runTerminalBanner(tool: String, input: String?, output: String?) -> some View {
        let cmd: String = {
            guard let inp = input, !inp.isEmpty, let d = inp.data(using:.utf8), let obj = try? JSONSerialization.jsonObject(with:d) as? [String:Any], let c = obj["command"] as? String else { return input ?? "" }
            return c
        }()
        let preview = cmd.isEmpty ? (input ?? "") : cmd
        let out = output ?? ""
        return VStack(alignment:.leading, spacing:0){
            HStack(spacing:4){
                Image(systemName:"terminal").font(.system(size:7, weight:.bold)).foregroundColor(.orange)
                Text("Terminal").font(.system(size:8, weight:.semibold, design:.monospaced)).foregroundColor(.orange)
                Text(tool).font(.system(size:7, design:.monospaced)).foregroundColor(.secondary)
                Spacer()
            }.padding(.horizontal,6).padding(.vertical,4).background(Color.orange.opacity(0.12)).clipShape(RunRoundedCorner(radius:5, corners:[.topLeft,.topRight]))
            VStack(alignment:.leading, spacing:3){
                if !preview.isEmpty {
                    Text("$ \(preview)").font(.system(size:8, design:.monospaced)).foregroundColor(.primary.opacity(0.85)).lineLimit(3).truncationMode(.tail).textSelection(.enabled).padding(.horizontal,6).padding(.top,4)
                }
                if !out.isEmpty {
                    Text(String(out.prefix(400))).font(.system(size:7, design:.monospaced)).foregroundColor(.secondary).lineLimit(4).truncationMode(.tail).textSelection(.enabled).padding(.horizontal,6).padding(.bottom,4)
                }
                if preview.isEmpty && out.isEmpty { Text("—").font(.system(size:7, design:.monospaced)).foregroundColor(.secondary).padding(6) }
            }.background(Color(nsColor:.textBackgroundColor)).clipShape(RunRoundedCorner(radius:5, corners:[.bottomLeft,.bottomRight]))
        }.overlay(RoundedRectangle(cornerRadius:5).stroke(Color.orange.opacity(0.25), lineWidth:1))
    }

    private func runSkillBanner(input: String?, output: String?) -> some View {
        let skillName: String = {
            guard let inp = input, let d = inp.data(using:.utf8), let obj = try? JSONSerialization.jsonObject(with:d) as? [String:Any] else { return input?.prefix(40).description ?? "skill" }
            return (obj["name"] as? String) ?? (obj["skill"] as? String) ?? "skill"
        }()
        let content = runFormatToolContent(name: "skill", input: input, output: output)
        return VStack(alignment:.leading, spacing:0){
            HStack(spacing:4){
                Image(systemName:"wand.and.stars").font(.system(size:7)).foregroundColor(.indigo)
                Text(skillName).font(.system(size:8, weight:.semibold, design:.monospaced)).foregroundColor(.indigo)
                Spacer()
            }.padding(.horizontal,6).padding(.vertical,4).background(Color.indigo.opacity(0.10)).clipShape(RunRoundedCorner(radius:5, corners:[.topLeft,.topRight]))
            if !content.isEmpty { Text(content).font(.system(size:8, design:.monospaced)).foregroundColor(.primary.opacity(0.8)).lineLimit(4).padding(6).background(Color(nsColor:.controlBackgroundColor)).clipShape(RunRoundedCorner(radius:5, corners:[.bottomLeft,.bottomRight])) }
        }.overlay(RoundedRectangle(cornerRadius:5).stroke(Color.indigo.opacity(0.22), lineWidth:1))
    }

    private func runEditBanner(filePath: String, oldString: String, newString: String) -> some View {
        let name = (filePath as NSString).lastPathComponent
        let dir = (filePath as NSString).deletingLastPathComponent
        let oldLines = oldString.components(separatedBy:"\n")
        let newLines = newString.components(separatedBy:"\n")
        let diff = runLineDiff(old: oldLines, new: newLines)
        let added = diff.filter{ $0.kind == .added }.count
        let removed = diff.filter{ $0.kind == .removed }.count
        return VStack(alignment:.leading, spacing:0){
            HStack(spacing:4){
                Image(systemName:"pencil.and.scribble").font(.system(size:7)).foregroundColor(.orange)
                VStack(alignment:.leading, spacing:0){ Text(name).font(.system(size:8, weight:.semibold, design:.monospaced)).foregroundColor(.orange).lineLimit(1); if !dir.isEmpty { Text(dir).font(.system(size:6, design:.monospaced)).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle) } }
                Spacer(); Text("+\(added) −\(removed)").font(.system(size:7, weight:.medium, design:.monospaced)).foregroundColor(.secondary).padding(.horizontal,4).padding(.vertical,1).background(Color.secondary.opacity(0.1)).cornerRadius(3)
            }.padding(.horizontal,6).padding(.vertical,4).background(Color.orange.opacity(0.08)).clipShape(RunRoundedCorner(radius:5, corners:[.topLeft,.topRight]))
            VStack(alignment:.leading, spacing:0){
                ForEach(Array(diff.prefix(20).enumerated()), id:\.offset){ _,row in
                    HStack(spacing:4){ Text(row.kind.prefix).font(.system(size:7, weight:.medium, design:.monospaced)).foregroundColor(row.kind.color).frame(width:8); Text(row.text).font(.system(size:7, design:.monospaced)).foregroundColor(row.kind == .added ? .green : row.kind == .removed ? .red : .primary.opacity(0.85)).lineLimit(1).truncationMode(.tail); Spacer(minLength:0) }.padding(.horizontal,4).padding(.vertical,1).background(row.kind.bg)
                }
                if diff.count>20 { Text("… \(diff.count-20) more").font(.system(size:7)).foregroundColor(.secondary).padding(4) }
            }.background(Color(nsColor:.controlBackgroundColor)).clipShape(RunRoundedCorner(radius:5, corners:[.bottomLeft,.bottomRight]))
        }.overlay(RoundedRectangle(cornerRadius:5).stroke(Color.orange.opacity(0.22), lineWidth:1))
    }

    private func runWriteBanner(filePath: String, contentPreview: String, output: String?) -> some View {
        let name = (filePath as NSString).lastPathComponent
        let dir = (filePath as NSString).deletingLastPathComponent
        return VStack(alignment:.leading, spacing:0){
            HStack(spacing:4){
                Image(systemName:"doc.badge.plus").font(.system(size:7)).foregroundColor(.green)
                VStack(alignment:.leading, spacing:0){ Text(name).font(.system(size:8, weight:.semibold, design:.monospaced)).foregroundColor(.green).lineLimit(1); if !dir.isEmpty { Text(dir).font(.system(size:6, design:.monospaced)).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle) } }
                Spacer()
            }.padding(.horizontal,6).padding(.vertical,4).background(Color.green.opacity(0.09)).clipShape(RunRoundedCorner(radius:5, corners:[.topLeft,.topRight]))
            if !contentPreview.isEmpty { Text(contentPreview).font(.system(size:7, design:.monospaced)).foregroundColor(.primary.opacity(0.75)).lineLimit(4).padding(6).background(Color(nsColor:.controlBackgroundColor)).clipShape(RunRoundedCorner(radius:5, corners:[.bottomLeft,.bottomRight])) }
        }.overlay(RoundedRectangle(cornerRadius:5).stroke(Color.green.opacity(0.22), lineWidth:1))
    }

    private func runGenericBanner(name: String, input: String?, output: String?) -> some View {
        let color = runToolColor(name)
        let icon = runToolIcon(name)
        let title = runToolDisplayName(name)
        let content = runFormatToolContent(name: name, input: input, output: output)
        let safe = content.isEmpty ? "—" : content
        return VStack(alignment:.leading, spacing:0){
            HStack(spacing:4){
                Image(systemName: icon).font(.system(size:7)).foregroundColor(color)
                Text(title).font(.system(size:8, weight:.semibold, design:.monospaced)).foregroundColor(color)
                Spacer()
            }.padding(.horizontal,6).padding(.vertical,4).background(color.opacity(0.09)).clipShape(RunRoundedCorner(radius:5, corners:[.topLeft,.topRight]))
            Text(safe).font(.system(size:7, design:.monospaced)).foregroundColor(.primary.opacity(0.8)).lineLimit(4).truncationMode(.tail).textSelection(.enabled).padding(6).background(Color(nsColor:.controlBackgroundColor)).clipShape(RunRoundedCorner(radius:5, corners:[.bottomLeft,.bottomRight]))
        }.overlay(RoundedRectangle(cornerRadius:5).stroke(color.opacity(0.2), lineWidth:1))
    }

    private var popupSessionSidebar: some View {
         VStack(spacing:0) {
             if let photo = ProfilePhotos.shared.circularPhoto(for: agentName, size: 36) { Image(nsImage: photo).resizable().frame(width:36,height:36) } else { ZStack { Circle().fill(Color.accentColor.opacity(0.25)); Text(agentMonogram).font(.system(size:12,weight:.bold)).foregroundColor(.accentColor) }.frame(width:36,height:36) }
             Text(agentName).font(.caption2).fontWeight(.semibold).lineLimit(1).padding(.top,2)
             Divider()
             if sessionsLoading { ProgressView().controlSize(.mini).padding(4) } else if sessions.isEmpty { Text("No sessions").font(.caption2).foregroundColor(.secondary).padding(4) } else {
                 ScrollView { LazyVStack(spacing:0) { ForEach(sessions) { s in Button(action: { showSessions = false }) { HStack(spacing:3){ Circle().fill(Color.accentColor.opacity(0.4)).frame(width:5,height:5); Text(s.title ?? "Session").font(.caption2).lineLimit(1).foregroundColor(.primary) }.frame(maxWidth:.infinity, alignment:.leading).padding(.horizontal,5).padding(.vertical,2).background(Color.primary.opacity(0.06)).cornerRadius(5) }.buttonStyle(.plain) } } }
             }
             Divider()
             Button(action: { showSessions = false }) { HStack(spacing:3){ Image(systemName:"xmark").font(.system(size:7)); Text("Close").font(.system(size:7)) }.foregroundColor(.secondary).frame(maxWidth:.infinity) }.buttonStyle(.plain)
         }.frame(width: 160).background(RoundedRectangle(cornerRadius:14).fill(Color(NSColor.controlBackgroundColor))).overlay(RoundedRectangle(cornerRadius:14).stroke(Color.primary.opacity(0.12)))
    }
    private var agentMonogram: String { let parts=agentName.split(separator:"-").map(String.init); let initials=parts.prefix(2).compactMap{$0.first.map(String.init)}.joined().uppercased(); if initials.count==2{return initials}; let firstWord=parts.first ?? agentName; return String(firstWord.prefix(2)).uppercased() }
    private func fetchSessionSessions() {
        sessionsLoading = true
        guard let url = URL(string: "\(baseURL)/sessions/\(agentName)/list") else { sessionsLoading = false; return }
        URLSession.shared.dataTask(with: EliaAuth.authorize(url)) { data, _, _ in
            DispatchQueue.main.async {
                self.sessionsLoading = false
                guard let data=data, let json=try? JSONSerialization.jsonObject(with:data) as? [String:Any], let rawSessions=json["sessions"] as? [[String:Any]] else { return }
                self.sessions = rawSessions.compactMap{ s in
                    guard let sid=s["session_id"] as? String, !sid.isEmpty else { return nil }
                    return RunSessionInfo(id: sid, title: s["title"] as? String)
                }
            }
        }.resume()
    }

    private func fetchRunHistory(){
        // Empty state on open: never merge the previous session here. Live
        // WebSocket events via observeLogs() populate entries, todos and
        // subagents as soon as the agent actually produces new output.
        Task { @MainActor in self.historyReady = true }
    }
    private func fetchMessagesForHistory(sessionId: String){
        guard let url = URL(string: "\(baseURL)/sessions/\(agentName)?session_id=\(sessionId)&limit=30") else { historyReady = true; return }
        URLSession.shared.dataTask(with: EliaAuth.authorize(url)){ data,_,_ in
            guard let data=data, let json=try? JSONSerialization.jsonObject(with:data) as? [String:Any], let rawMessages=json["messages"] as? [[String:Any]] else {
                Task { @MainActor in self.historyReady = true }
                return
            }
            Task { @MainActor in
                LivestreamStore.shared.mergeHistory(agent: self.agentName, sessionId: sessionId, rawMessages: rawMessages)
                self.updateSubagents(from: rawMessages)
                self.historyReady = true
            }
        }.resume()
    }
    private func updateSubagents(from rawMessages: [[String: Any]]){
        let keys = LivestreamStore.shared.extractSubagents(parentAgent: agentName, rawMessages: rawMessages)
        AppLog.d("updateSubagents \(agentName) history keys=\(keys.map{$0.sessionId})")
        let liveEntries = LivestreamStore.shared.stream(for: agentName)
        var liveRaw: [[String: Any]] = []
        for e in liveEntries {
            if case .tool(_, let name, let input, let output) = e, ["call_omo_agent","task","team_create"].contains(name.lowercased()) {
                var part: [String: Any] = ["type":"tool","tool":name]
                if let i=input { part["input"]=i }
                if let o=output { part["output"]=o }
                liveRaw.append(["parts":[part]])
            }
        }
        var liveKeys: [LivestreamStore.SubagentKey] = []
        if !liveRaw.isEmpty {
            liveKeys = LivestreamStore.shared.extractSubagents(parentAgent: agentName, rawMessages: liveRaw)
            AppLog.d("updateSubagents \(agentName) live keys=\(liveKeys.map{$0.sessionId})")
        }
        var merged = keys
        for k in liveKeys where !merged.contains(k) { merged.append(k) }
        let hasReal = merged.contains { $0.sessionId.hasPrefix("ses_") }
        if hasReal { merged.removeAll { $0.sessionId.hasPrefix("pending:team") } }
        let oldKeys = subagentKeys
        subagentKeys = merged
        for k in merged where !oldKeys.contains(k) && !k.sessionId.hasPrefix("pending:") && !k.sessionId.hasPrefix("task:") {
            AppLog.d("start polling new subagent \(k.sessionId) for \(agentName)")
            startPollingSubagent(k)
        }
        for k in oldKeys where !merged.contains(k) {
            subagentPollTimers[k]?.invalidate()
            subagentPollTimers.removeValue(forKey: k)
            AppLog.d("stopped polling removed subagent \(k.sessionId) for \(agentName)")
        }
        AppLog.d("subagentKeys now \(subagentKeys.map{$0.sessionId}) for \(agentName)")
    }
    private func refreshSubagentsFromLive(){
        let liveEntries = LivestreamStore.shared.stream(for: agentName)
        var liveRaw: [[String: Any]] = []
        for e in liveEntries {
            if case .tool(_, let name, let input, let output) = e, ["call_omo_agent","task","team_create"].contains(name.lowercased()) {
                var part: [String: Any] = ["type":"tool","tool":name]
                if let i=input { part["input"]=i }
                if let o=output { part["output"]=o }
                liveRaw.append(["parts":[part]])
            }
        }
        if liveRaw.isEmpty { return }
        let liveKeys = LivestreamStore.shared.extractSubagents(parentAgent: agentName, rawMessages: liveRaw)
        let hasReal = liveKeys.contains { $0.sessionId.hasPrefix("ses_") }
        if hasReal { subagentKeys.removeAll { $0.sessionId.hasPrefix("pending:team") } }
        for k in liveKeys where !subagentKeys.contains(k) {
            subagentKeys.append(k)
            if !k.sessionId.hasPrefix("pending:") { startPollingSubagent(k) }
        }
    }
    private func startPollingSubagent(_ key: LivestreamStore.SubagentKey){
        guard subagentPollTimers[key]==nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true){ _ in
            Task{ @MainActor in self.pollSubagent(key) }
        }
        RunLoop.main.add(t, forMode: .common)
        subagentPollTimers[key]=t
        pollSubagent(key)
    }
    private func pollSubagent(_ key: LivestreamStore.SubagentKey){
        guard let url=URL(string:"\(baseURL)/sessions/\(agentName)?session_id=\(key.sessionId)&limit=30") else { return }
        URLSession.shared.dataTask(with: EliaAuth.authorize(url)){ data,_,_ in
            guard let data=data, let json=try? JSONSerialization.jsonObject(with:data) as? [String:Any], let raw=json["messages"] as? [[String:Any]] else { return }
            Task{ @MainActor in LivestreamStore.shared.mergeSubagentHistory(key: key, rawMessages: raw) }
        }.resume()
    }
    private func stopAllSubagentPolling(){
        for t in subagentPollTimers.values { t.invalidate() }
        subagentPollTimers.removeAll()
    }

    // MARK: - Live streaming — coalesced entries + vertical todos

    private func startTick(){ Timer.scheduledTimer(withTimeInterval:1.0, repeats:true){ _ in if liveRunning { liveTick+=1 } } }

    private func observeLogs(){
        observer=NotificationCenter.default.addObserver(forName:SubworkerManager.runLogNotification, object:nil, queue:.main){ note in
            guard let name=note.userInfo?["name"] as? String, name==agentName, let delta=note.userInfo?["text"] as? String else{return}
            let field=note.userInfo?["field"] as? String ?? "text"
            appendLiveDelta(field: field, delta: delta)
        }
    }
    private func observeDraggable(){
        draggableObserver=NotificationCenter.default.addObserver(forName:.eliaRunPopupDraggableChanged, object:nil, queue:.main){ _ in self.draggableEnabledState=UserDefaults.standard.bool(forKey:"dropDraggableEnabled") }
    }
    private func appendLiveDelta(field: String, delta: String){
        if delta.isEmpty { return }
        switch field {
        case "reasoning":
            if let last = liveEntries.last, case .reasoning(let cur) = last {
                if delta==cur || cur.hasSuffix(delta) || (cur.contains(delta) && delta.count<40) { return }
                var next: String
                if delta.hasPrefix(cur) { next = delta } else if cur.isEmpty { next = delta } else { next = cur + delta }
                if next.count>12000 { next = String(next.suffix(8000)) }
                liveEntries[liveEntries.count-1] = .reasoning(next)
            } else {
                let capped = delta.count>12000 ? String(delta.suffix(8000)) : delta
                liveEntries.append(.reasoning(capped))
            }
            if liveEntries.count>50 { liveEntries = Array(liveEntries.suffix(50)) }
        case "tool":
            let parsed: (String, String?, String?) = {
                if let data=delta.data(using:.utf8), let obj=try? JSONSerialization.jsonObject(with:data) as? [String:Any]{
                    let tool=(obj["tool"] as? String ?? obj["name"] as? String ?? "tool")
                    if let s=obj["input"] as? String { return (tool, s, obj["output"] as? String) }
                    if let d=obj["input"] as? [String:Any], let jd=try? JSONSerialization.data(withJSONObject:d), let s=String(data:jd, encoding:.utf8){ return (tool, s, obj["output"] as? String) }
                    if obj["filePath"] != nil || obj["oldString"] != nil || obj["content"] != nil { return (tool, delta, obj["output"] as? String) }
                    if obj["todos"] != nil { return (tool, delta, obj["output"] as? String) }
                    return (tool, obj["input"] as? String, obj["output"] as? String)
                }
                return (delta.isEmpty ? "tool" : delta, nil, nil)
            }()
            if let last=liveEntries.last, case .tool(let ln, let li, let lo)=last, ln==parsed.0 && li==parsed.1 && lo==parsed.2 { return }
            liveEntries.append(.tool(name: parsed.0, input: parsed.1, output: parsed.2))
            if liveEntries.count>50 { liveEntries = Array(liveEntries.suffix(50)) }
            let isTodoTool = parsed.0.lowercased().contains("todo")
            let hasTodosPayload = delta.lowercased().contains("todos") || (parsed.1?.lowercased().contains("todos") ?? false) || (parsed.2?.lowercased().contains("todos") ?? false)
            if isTodoTool || hasTodosPayload {
                if let todos=runExtractTodos(input: parsed.1, output: parsed.2, delta: delta), !todos.isEmpty { verticalTodos=todos }
            }
        default:
            let lower = delta.lowercased()
            if lower.contains("todos"), let todos=runExtractTodos(input: nil, output: nil, delta: delta), !todos.isEmpty {
                verticalTodos=todos
                liveEntries.append(.tool(name:"todowrite", input:delta, output:nil))
                if liveEntries.count>50 { liveEntries = Array(liveEntries.suffix(50)) }
                return
            }
            if delta.contains("content") && lower.contains("todos") {
                if let todos=runExtractTodos(input: delta, output: nil, delta: delta), !todos.isEmpty {
                    verticalTodos=todos
                }
            }
            if let last=liveEntries.last, case .text(let cur)=last {
                if delta == cur { return }
                if delta.count < 80 && cur.contains(delta) { return }
                var next: String
                if delta.hasPrefix(cur) { next = delta } else if cur.hasSuffix(delta) { return } else { next = cur + delta }
                if next.count > 12000 { next = String(next.suffix(8000)) }
                liveEntries[liveEntries.count - 1] = .text(next)
            } else {
                let capped=delta.count>12000 ? String(delta.suffix(8000)) : delta
                liveEntries.append(.text(capped))
            }
            if liveEntries.count>50 { liveEntries = Array(liveEntries.suffix(50)) }
        }
    }

    private func runExtractTodos(input: String?, output: String?, delta: String) -> [RunTodoItem]? {
        if let t=runParseTodoWrite(input, output:output), !t.isEmpty { return t }
        if let t=runParseTodoWrite(delta, output:nil), !t.isEmpty { return t }
        for raw in [input, output, delta] {
            guard let s = raw, !s.isEmpty, s.lowercased().contains("todos") else { continue }
            if let todos = runScanTodosFromString(s), !todos.isEmpty { return todos }
            if let d = s.data(using:.utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                if let found = runFindTodosRecursive(obj), !found.isEmpty { return found }
            }
        }
        if let data=delta.data(using:.utf8), let obj=try? JSONSerialization.jsonObject(with:data) as? [String:Any]{
            if let found = runFindTodosRecursive(obj), !found.isEmpty { return found }
        }
        for raw in [input, output, delta] {
            if let s = raw, let todos = runScanTodosFromString(s), !todos.isEmpty { return todos }
        }
        return nil
    }
    private func runScanTodosFromString(_ s: String) -> [RunTodoItem]? {
        guard s.lowercased().contains("content") else { return nil }
        var todos:[RunTodoItem]=[]
        let contentPat = "\"content\"\\s*:\\s*\"((?:\\\\\"|[^\"])*)\""
        let statusPat = "\"status\"\\s*:\\s*\"([^\"]*)\""
        let priorityPat = "\"priority\"\\s*:\\s*\"([^\"]*)\""
        guard let contentRegex = try? NSRegularExpression(pattern: contentPat),
              let statusRegex = try? NSRegularExpression(pattern: statusPat),
              let priorityRegex = try? NSRegularExpression(pattern: priorityPat) else { return nil }
        let ns = s as NSString
        let matches = contentRegex.matches(in: s, range: NSRange(location:0,length:ns.length))
        for m in matches {
            let contentRange = m.range(at:1)
            guard contentRange.location != NSNotFound else { continue }
            var content = ns.substring(with: contentRange).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: " ")
            if content.hasSuffix("…") { content = String(content.dropLast()) }
            content = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if content.isEmpty { continue }
            let searchStart = m.range.location
            let searchLen = min(400, ns.length - searchStart)
            let searchRange = NSRange(location: searchStart, length: searchLen)
            let searchSlice = ns.substring(with: searchRange)
            var status = "pending"
            var priority = "medium"
            if let sm = statusRegex.firstMatch(in: searchSlice, range: NSRange(location:0,length:(searchSlice as NSString).length)) {
                let r = sm.range(at:1); if r.location != NSNotFound { status = (searchSlice as NSString).substring(with:r).lowercased() }
            }
            if let pm = priorityRegex.firstMatch(in: searchSlice, range: NSRange(location:0,length:(searchSlice as NSString).length)) {
                let r = pm.range(at:1); if r.location != NSNotFound { priority = (searchSlice as NSString).substring(with:r).lowercased() }
            }
            todos.append(RunTodoItem(content: String(content.prefix(120)), status: status, priority: priority))
            if todos.count >= 12 { break }
        }
        return todos.isEmpty ? nil : todos
    }
    private func runFindTodosRecursive(_ obj: Any) -> [RunTodoItem]? {
        if let dict = obj as? [String: Any] {
            if let arr = dict["todos"] as? [[String: Any]], !arr.isEmpty {
                let todos = arr.compactMap{ d -> RunTodoItem? in guard let c=d["content"] as? String, !c.isEmpty else {return nil}; return RunTodoItem(content:c,status:(d["status"] as? String ?? "pending").lowercased(),priority:(d["priority"] as? String ?? "medium").lowercased())}
                if !todos.isEmpty { return todos }
            }
            for v in dict.values { if let r = runFindTodosRecursive(v), !r.isEmpty { return r } }
        } else if let arr = obj as? [Any] {
            for v in arr { if let r = runFindTodosRecursive(v), !r.isEmpty { return r } }
        }
        return nil
    }

    // MARK: - Helpers (mirrored from LogPopoverView, compact)

    private func runHostPath(_ p:String)->String{
        if p.hasPrefix("/data/"){ return p.replacingOccurrences(of:"/data/", with:"/Users/vakandi/EliaAI/", options:.anchored)}
        if p=="/data"{ return "/Users/vakandi/EliaAI"}
        return p
    }
    private struct RunEditPayload{let path:String; let old:String; let new:String}
    private struct RunWritePayload{let path:String; let preview:String}
    private func runParseEdit(_ raw:String)->RunEditPayload?{
        guard let data=raw.data(using:.utf8), let obj=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else{return nil}
        let path=(obj["filePath"] as? String ?? obj["file_path"] as? String ?? obj["path"] as? String ?? "").trimmingCharacters(in:.whitespaces); guard !path.isEmpty else{return nil}
        let old=obj["oldString"] as? String ?? obj["old_string"] as? String ?? obj["oldText"] as? String ?? ""
        let new=obj["newString"] as? String ?? obj["new_string"] as? String ?? obj["newText"] as? String ?? ""
        if old.isEmpty && new.isEmpty{return nil}
        return RunEditPayload(path:runHostPath(path), old:old, new:new)
    }
    private func runParseWrite(_ raw:String)->RunWritePayload?{
        guard let data=raw.data(using:.utf8), let obj=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else{return nil}
        let path=(obj["filePath"] as? String ?? obj["file_path"] as? String ?? obj["path"] as? String ?? "").trimmingCharacters(in:.whitespaces); guard !path.isEmpty else{return nil}
        let content=obj["content"] as? String ?? ""
        return RunWritePayload(path:runHostPath(path), preview:String(content.prefix(400)))
    }
    private func runParseTodoWrite(_ input:String?, output:String?)->[RunTodoItem]?{
        let raw=(input?.isEmpty==false ? input : output) ?? ""; guard !raw.isEmpty, let data=raw.data(using:.utf8), let obj=try? JSONSerialization.jsonObject(with:data) as? [String:Any], let arr=obj["todos"] as? [[String:Any]], !arr.isEmpty else{return nil}
        return arr.compactMap{ d in guard let c=d["content"] as? String, !c.isEmpty else{return nil}; return RunTodoItem(content:c,status:(d["status"] as?String ?? "pending").lowercased(),priority:(d["priority"] as?String ?? "medium").lowercased())}
    }
    private func runTodoDotColor(_ s:String)->Color{ switch s{ case "completed": return .green; case "in_progress": return .blue; case "cancelled": return .red; default: return .orange } }
    private func runTodoPriorityColor(_ p:String)->Color{ switch p{ case "high": return .red.opacity(0.7); case "medium": return .orange.opacity(0.7); default: return .secondary } }
    private func runToolIcon(_ n:String)->String{
        switch n.lowercased(){
        case "bash","shell","interactive_bash": return "terminal"
        case "read","view": return "doc.text"
        case "write","edit": return "pencil.and.document"
        case "grep","search": return "magnifyingglass"
        case "glob","find": return "folder"
        case "task","agent","call_omo_agent": return "person.2"
        case "skill": return "wand.and.stars"
        case "background_output","background_cancel": return "arrow.triangle.2.circlepath"
        case "codegraph_explore": return "point.3.connected.trianglepath.dotted"
        case "websearch","web_search_exa","webfetch": return "globe"
        default: return "wrench.and.screwdriver"
        }
    }
    private func runToolDisplayName(_ n:String)->String{
        switch n.lowercased(){
        case "bash": return "Terminal"
        case "interactive_bash": return "Shell"
        case "read": return "Read File"
        case "write": return "Write File"
        case "edit": return "Edit File"
        case "grep": return "Search"
        case "glob": return "Find Files"
        case "task": return "Subtask"
        case "call_omo_agent": return "Agent Call"
        case "skill": return "Skill"
        case "background_output": return "BG Output"
        case "background_cancel": return "BG Cancel"
        case "codegraph_explore": return "CodeGraph"
        case "websearch","web_search_exa": return "Web Search"
        case "webfetch": return "Fetch URL"
        default: return n
        }
    }
    private func runToolColor(_ n:String)->Color{
        switch n.lowercased(){
        case "bash","shell","interactive_bash": return .orange
        case "read","view": return .cyan
        case "write": return .green
        case "edit": return .yellow
        case "grep","search","glob","find": return .purple
        case "task","agent","call_omo_agent": return .pink
        case "skill": return .indigo
        case "background_output","background_cancel": return .teal
        case "codegraph_explore": return .mint
        case "websearch","web_search_exa","webfetch": return .blue
        default: return .blue
        }
    }
    private func runFormatToolContent(name:String, input:String?, output:String?)->String{
        var parts:[String]=[]
        if let input, !input.isEmpty { let f=runFormatToolInput(name:name, raw:input); if !f.isEmpty{ parts.append(f)}}
        if let output, !output.isEmpty { let d=output.count>500 ? String(output.prefix(500))+"…" : output; parts.append(d)}
        return parts.joined(separator:"\n")
    }
    private func runFormatToolInput(name:String, raw:String)->String{
        guard let data=raw.data(using:.utf8), let obj=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else{
            let t=raw.trimmingCharacters(in:.whitespacesAndNewlines); if t=="{}" || t=="()" || t.isEmpty {return ""}; return String(raw.prefix(400))
        }
        if obj.isEmpty{return ""}
        func fp(_ o:[String:Any])->String?{ (o["filePath"] as? String ?? o["file_path"] as? String ?? o["path"] as? String ?? o["filepath"] as? String) }
        switch name.lowercased(){
        case "bash","shell","interactive_bash": if let c=obj["command"] as? String {return "$ \(c)"}
        case "read": if let p=fp(obj){return runHostPath(p)}
        case "write": if let p=fp(obj){ let hp=runHostPath(p); if let c=obj["content"] as? String, !c.isEmpty {return "\(hp)\n\(c.prefix(150))"}; return hp}
        case "edit": if let p=fp(obj){return runHostPath(p)}
        case "grep": if let pat=obj["pattern"] as? String {return pat}
        case "glob": if let pat=obj["pattern"] as? String {return pat}
        case "task": if let pr=obj["prompt"] as? String {return String(pr.prefix(200))}; if let d=obj["description"] as? String {return d}
        case "websearch","web_search_exa": if let q=obj["query"] as? String {return q}
        case "webfetch": if let u=obj["url"] as? String {return u}
        case "codegraph_explore": if let q=obj["query"] as? String {return q}
        default: break
        }
        let fallback=["command","query","pattern","filePath","content","url","prompt","description","script","selector"]
        for k in fallback{ if let v=obj[k] as? String, !v.isEmpty {return "\(k): \(v.prefix(200))"}}
        return String(raw.prefix(400))
    }
    private func streamingSafeMarkdown(_ text:String)->String{
        let t=text.trimmingCharacters(in:.whitespacesAndNewlines); if t.isEmpty{return text}
        let c=text.components(separatedBy:"```").count-1; if c%2==1{return text+"\n```"}; return text
    }
    private enum RunDiffKind{ case added, removed, unchanged; var prefix:String{switch self{case .added:return "+";case .removed:return "−";case .unchanged:return " "}}; var color:Color{switch self{case .added:return .green;case .removed:return .red;case .unchanged:return .secondary}}; var bg:Color{switch self{case .added:return Color.green.opacity(0.08);case .removed:return Color.red.opacity(0.08);case .unchanged:return .clear}} }
    private struct RunDiffRow{let kind:RunDiffKind; let text:String}
    private func runLineDiff(old:[String], new:[String])->[RunDiffRow]{
        if old.isEmpty{return new.map{RunDiffRow(kind:.added,text:$0)}}; if new.isEmpty{return old.map{RunDiffRow(kind:.removed,text:$0)}}
        var i=0,j=0; var out:[RunDiffRow]=[]
        while i<old.count || j<new.count{
            if i<old.count && j<new.count && old[i]==new[j]{ out.append(RunDiffRow(kind:.unchanged,text:old[i])); i+=1; j+=1 }
            else if j<new.count && (i>=old.count || !old[i...].contains(new[j])){ out.append(RunDiffRow(kind:.added,text:new[j])); j+=1 }
            else if i<old.count{ out.append(RunDiffRow(kind:.removed,text:old[i])); i+=1 }
            else{ out.append(RunDiffRow(kind:.added,text:new[j])); j+=1 }
        }
        return out
    }
}

struct SubagentBubbleView: View {
    let key: LivestreamStore.SubagentKey
    let baseURL: String
    var onClose: (() -> Void)? = nil
    @ObservedObject private var store = LivestreamStore.shared
    @State private var isPinned = true
    @State private var pending: DispatchWorkItem? = nil
    @State private var pendingFalse: DispatchWorkItem? = nil
    private let bottomId = "sub-bubble-bottom"
    private let space = "sub-bubble-space"

    private struct BottomKey: PreferenceKey { static var defaultValue: CGFloat=0; static func reduce(value:inout CGFloat,nextValue:()->CGFloat){ value=nextValue() } }

    private var entries: [LivestreamEntry] { store.subagentStream(for: key) }
    private var todos: [LivestreamTodoItem] { store.subagentTodo(for: key) }

    var body: some View {
        VStack(alignment:.leading, spacing:4){
            HStack(spacing:6){
                if let onClose = onClose {
                    Button(action: onClose){
                        Image(systemName:"xmark").font(.system(size:7, weight:.bold)).foregroundColor(.secondary).frame(width:16,height:16).background(Color.secondary.opacity(0.12)).clipShape(Circle())
                    }.buttonStyle(.plain).help("Hide subagent")
                }
                Image(systemName:"person.2.fill").font(.system(size:8)).foregroundColor(.pink)
                Text(key.description).font(.system(size:8, weight:.semibold)).foregroundColor(.primary).lineLimit(1)
                Text(key.agent).font(.system(size:6, design:.monospaced)).foregroundColor(.secondary).padding(.horizontal,4).padding(.vertical,1).background(Color.pink.opacity(0.12)).cornerRadius(4)
                Spacer()
                Text("\(entries.filter{ if case .tool = $0 { return true } else { return false }}.count) tools").font(.system(size:6)).foregroundColor(.purple)
                Text("\(entries.filter{ if case .text = $0 { return true } else if case .reasoning = $0 { return true } else { return false }}.count) msgs").font(.system(size:6)).foregroundColor(.blue)
                Circle().fill(Color.pink).frame(width:6,height:6)
            }
            if !todos.isEmpty {
                HStack(spacing:4){
                    ForEach(Array(todos.prefix(3).enumerated()), id:\.offset){ _, t in
                        HStack(spacing:2){ Circle().fill(t.status=="completed" ? Color.green : t.status=="in_progress" ? Color.blue : Color.orange).frame(width:5,height:5); Text(t.content).font(.system(size:6)).lineLimit(1).foregroundColor(.secondary) }.padding(.horizontal,4).padding(.vertical,2).background(Color.primary.opacity(0.06)).cornerRadius(4)
                    }
                    if todos.count>3 { Text("+\(todos.count-3)").font(.system(size:6)).foregroundColor(.secondary) }
                }
            }
            GeometryReader{ outer in
                ScrollViewReader{ proxy in
                    ScrollView(showsIndicators:false){
                        VStack(alignment:.leading, spacing:4){
                            if entries.isEmpty {
                                HStack{ ProgressView().controlSize(.mini).scaleEffect(0.6); Text("Subagent waiting…").font(.system(size:7, design:.monospaced)).foregroundColor(.secondary); Spacer() }.padding(4)
                            } else {
                                ForEach(entries){ e in subEntry(e) }
                            }
                            Color.clear.frame(height:1).id(bottomId).background(GeometryReader{ g in Color.clear.preference(key: BottomKey.self, value: g.frame(in:.named(space)).maxY) })
                        }.frame(maxWidth:.infinity, alignment:.leading).padding(.bottom, 16)
                    }
                    .coordinateSpace(name: space)
                    .onPreferenceChange(BottomKey.self){ maxY in
                        let atBottom = maxY <= outer.size.height + 16
                        if atBottom { pendingFalse?.cancel(); pendingFalse=nil; if !isPinned { isPinned=true } }
                        else if isPinned {
                            pendingFalse?.cancel()
                            let w=DispatchWorkItem{ isPinned=false }
                            pendingFalse=w
                            DispatchQueue.main.asyncAfter(deadline:.now()+0.12, execute:w)
                        }
                    }
                    .onChange(of: entries){ _ in if isPinned { withAnimation(.easeOut(duration:0.12)){ proxy.scrollTo(bottomId, anchor:.bottom) } } }
                    .onAppear{
                        isPinned=true
                        for d in [0.06,0.18,0.35] as [Double] { DispatchQueue.main.asyncAfter(deadline:.now()+d){ withAnimation(.easeOut(duration:0.12)){ proxy.scrollTo(bottomId, anchor:.bottom) } } }
                    }
                    .overlay(alignment:.bottom){
                        if !isPinned && !entries.isEmpty {
                            Button(action: { pendingFalse?.cancel(); pendingFalse=nil; isPinned=true; withAnimation(.easeOut(duration:0.12)){ proxy.scrollTo(bottomId, anchor:.bottom) } }){
                                Image(systemName:"arrow.down").font(.system(size:7, weight:.bold)).foregroundColor(.white).frame(width:18,height:18).background(Circle().fill(Color.pink)).shadow(color:.black.opacity(0.2), radius:3, x:0,y:1)
                            }.buttonStyle(.plain).padding(.bottom,4).transition(.scale.combined(with:.opacity))
                        }
                    }
                }
            }.frame(height: 90)
        }.padding(8).background(RoundedRectangle(cornerRadius:10).fill(.regularMaterial)).overlay(RoundedRectangle(cornerRadius:10).stroke(Color.pink.opacity(0.18)))
    }

    @ViewBuilder private func subEntry(_ e: LivestreamEntry) -> some View {
        switch e {
        case .reasoning(_, let t):
            HStack(alignment:.top, spacing:4){ Rectangle().fill(Color.purple.opacity(0.3)).frame(width:2).cornerRadius(1); MarkdownView(text: t, baseColor: .secondary).font(.system(size:7)).fixedSize(horizontal:false, vertical:true) }
        case .text(_, let t):
            MarkdownView(text: LivestreamParsing.streamingSafeMarkdown(t), baseColor: .primary.opacity(0.85)).font(.system(size:7)).fixedSize(horizontal:false, vertical:true).textSelection(.enabled)
        case .tool(_, let name, let input, let output):
            let lname=name.lowercased()
            if lname=="todowrite", let todos=LivestreamParsing.extractTodos(input: input, output: output, delta: input ?? ""), !todos.isEmpty {
                HStack(spacing:4){ Image(systemName:"checklist").font(.system(size:7)); Text("\(todos.count) todos").font(.system(size:7)).foregroundColor(.purple) }.padding(4).background(Color.purple.opacity(0.08)).cornerRadius(6)
            } else if lname=="edit", let inp=input, let d=LivestreamParsing.parseEdit(inp) {
                HStack(spacing:4){ Image(systemName:"pencil").font(.system(size:7)).foregroundColor(.orange); Text((d.path as NSString).lastPathComponent).font(.system(size:7, design:.monospaced)).foregroundColor(.orange).lineLimit(1); Spacer(); Text("+\(d.new.components(separatedBy:"\n").count) -\(d.old.components(separatedBy:"\n").count)").font(.system(size:6, design:.monospaced)).foregroundColor(.secondary) }.padding(4).background(Color.orange.opacity(0.08)).cornerRadius(6)
            } else {
                HStack(spacing:4){ Image(systemName: LivestreamParsing.toolIcon(name)).font(.system(size:7)).foregroundColor(LivestreamParsing.toolColor(name)); Text(LivestreamParsing.toolDisplayName(name)).font(.system(size:7, weight:.semibold)).foregroundColor(LivestreamParsing.toolColor(name)); Spacer() }.padding(4).background(LivestreamParsing.toolColor(name).opacity(0.08)).cornerRadius(6)
                let c=LivestreamParsing.formatToolContent(name: name, input: input, output: output)
                if !c.isEmpty {
                    Text(c).font(.system(size:6, design:.monospaced)).foregroundColor(.secondary).lineLimit(3).padding(.horizontal,4)
                }
            }
        }
    }
}

private struct RunRoundedCorner: Shape {
    var radius: CGFloat
    var corners: RunCornerSet
    struct RunCornerSet: OptionSet { let rawValue: Int; static let topLeft=RunCornerSet(rawValue:1<<0); static let topRight=RunCornerSet(rawValue:1<<1); static let bottomLeft=RunCornerSet(rawValue:1<<2); static let bottomRight=RunCornerSet(rawValue:1<<3) }
    func path(in rect:CGRect)->Path{
        var path=Path(); let r=min(radius, min(rect.width, rect.height)/2)
        let tl=corners.contains(.topLeft) ? r:0, tr=corners.contains(.topRight) ? r:0, bl=corners.contains(.bottomLeft) ? r:0, br=corners.contains(.bottomRight) ? r:0
        path.move(to:CGPoint(x:rect.minX+tl,y:rect.minY)); path.addLine(to:CGPoint(x:rect.maxX-tr,y:rect.minY))
        if tr>0{path.addArc(tangent1End:CGPoint(x:rect.maxX,y:rect.minY),tangent2End:CGPoint(x:rect.maxX,y:rect.minY+tr),radius:tr)}
        path.addLine(to:CGPoint(x:rect.maxX,y:rect.maxY-br)); if br>0{path.addArc(tangent1End:CGPoint(x:rect.maxX,y:rect.maxY),tangent2End:CGPoint(x:rect.maxX-br,y:rect.maxY),radius:br)}
        path.addLine(to:CGPoint(x:rect.minX+bl,y:rect.maxY)); if bl>0{path.addArc(tangent1End:CGPoint(x:rect.minX,y:rect.maxY),tangent2End:CGPoint(x:rect.minX,y:rect.maxY-bl),radius:bl)}
        path.addLine(to:CGPoint(x:rect.minX,y:rect.minY+tl)); if tl>0{path.addArc(tangent1End:CGPoint(x:rect.minX,y:rect.minY),tangent2End:CGPoint(x:rect.minX+tl,y:rect.minY),radius:tl)}
        path.closeSubpath(); return path
    }
}
