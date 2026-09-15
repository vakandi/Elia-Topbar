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
         let width: CGFloat = 310, height: CGFloat = 260, gap: CGFloat = 8
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
        let width: CGFloat=310, height: CGFloat=260, gap: CGFloat=8
        let barBottom = screen.frame.maxY - NSStatusBar.system.thickness
        let sorted = panels.keys.sorted()
        let totalWidth = CGFloat(sorted.count)*width + CGFloat(max(0,sorted.count-1))*gap
        var startX = dropX - totalWidth/2
        startX = max(screen.frame.minX+8, min(startX, screen.frame.maxX-totalWidth-8))
        for (idx,name) in sorted.enumerated() { guard let p=panels[name] else { continue }
            let x=startX+CGFloat(idx)*(width+gap)
            let frame=NSRect(x:x,y:barBottom-height,width:width,height:height)
            if p.frame.origin.x != x { NSAnimationContext.runAnimationGroup({ ctx in ctx.duration=0.35; ctx.timingFunction=CAMediaTimingFunction(name:.easeInEaseOut); p.animator().setFrame(frame, display:true) }) }
        }
    }
    private func makePanel(hiddenFrame: NSRect, agentName: String) -> NSPanel {
        let p = HoverPanel(contentRect: hiddenFrame, styleMask: [.borderless,.nonactivatingPanel], backing: .buffered, defer: false, agentName: agentName, owner: self)
        p.level = .statusBar; p.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle]
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false; p.isMovableByWindowBackground = false; p.worksWhenModal = true
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
}
private class HoverPanel: NSPanel {
    let agentName: String; weak var owner: RunPopupController?
    init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool, agentName: String, owner: RunPopupController) { self.agentName=agentName; self.owner=owner; super.init(contentRect:contentRect, styleMask:styleMask, backing:backing, defer:flag) }
    override func mouseEntered(with event: NSEvent){ owner?.setHover(true, for:agentName) }
    override func mouseExited(with event: NSEvent){ owner?.setHover(false, for:agentName) }
    override var canBecomeKey: Bool{ false }
}
struct PulseGlow: ViewModifier { @State private var pulsing=false; func body(content:Content)->some View{ content.scaleEffect(pulsing ? 1.18:1.0).opacity(pulsing ? 0.3:0.9).animation(.easeInOut(duration:0.9).repeatForever(autoreverses:true),value:pulsing).onAppear{pulsing=true} } }

// MARK: - RunPopupView — full livestream renderer (mirrors LogPopoverView)

struct RunPopupView: View {
    let agentName: String; let onTap: ()->Void
    let baseURL: String; let showSessionSelector: Bool; let disableAutoClose: Bool
    @State private var observer: NSObjectProtocol?
    @State private var verticalTodos: [RunTodoItem] = []
    @State private var isHoveringTodoModule = false
    @State private var liveEntries: [RunLiveEntry] = []
    @State private var liveRunning = true
    @State private var liveTick = 0
    @State private var sessions: [RunSessionInfo] = []
    @State private var sessionsLoading = false
    @State private var showSessions = false

    enum RunLiveEntry: Equatable {
        case text(String)
        case reasoning(String)
        case tool(name: String, input: String?, output: String?)
    }
    struct RunTodoItem: Equatable { let content:String; let status:String; let priority:String }
    struct RunSessionInfo: Codable, Identifiable { let id: String; let title: String? }

    var body: some View {
        VStack(spacing:6){
            photoBadge
            HStack(alignment:.top, spacing:0){
                if !verticalTodos.isEmpty {
                    popupVerticalTodoStripCollapsed
                        .frame(width: 28, height: 175)
                        .background(RunRoundedCorner(radius:14, corners:[.topLeft,.bottomLeft]).fill(.regularMaterial))
                        .overlay(RunRoundedCorner(radius:14, corners:[.topLeft,.bottomLeft]).stroke(Color.primary.opacity(0.12)))
                        .onHover{ h in withAnimation(.easeInOut(duration:0.18)){ if h { isHoveringTodoModule=true } } }
                }
                if showSessions { popupSessionSidebar }
                bubbleAttached
            }
            .overlay(alignment:.leading){
                if !verticalTodos.isEmpty && isHoveringTodoModule {
                    popupVerticalTodoStripExpanded
                        .frame(width: 180, height: 175)
                        .background(RunRoundedCorner(radius:14, corners:[.topLeft,.bottomLeft]).fill(.regularMaterial))
                        .overlay(RunRoundedCorner(radius:14, corners:[.topLeft,.bottomLeft]).stroke(Color.primary.opacity(0.12)))
                        .shadow(color:.black.opacity(0.22), radius:10, x:3, y:5)
                        .onHover{ h in withAnimation(.easeInOut(duration:0.18)){ isHoveringTodoModule=h } }
                        .transition(.opacity.combined(with: .move(edge:.leading)))
                        .zIndex(20)
                }
            }
        }
        .padding(.top,4)
        .frame(width: showSessions ? 400 : (verticalTodos.isEmpty ? 264 : 298))
        .animation(.easeInOut(duration:0.2), value: verticalTodos.isEmpty)
        .onAppear{ fetchRunHistory(); observeLogs(); startTick() }.onDisappear{ if let o=observer{NotificationCenter.default.removeObserver(o)} }.onTapGesture{onTap()}.onHover{ h in RunPopupController.shared.setHover(h, for:agentName) }
    }
    private var bubbleAttached: some View {
        let hasTodo = !verticalTodos.isEmpty
        let shape: AnyShape = hasTodo ? AnyShape(RunRoundedCorner(radius:14, corners:[.topRight,.bottomRight])) : AnyShape(RoundedRectangle(cornerRadius:14))
        return bubbleContent.background(shape.fill(.regularMaterial)).overlay(shape.stroke(Color.primary.opacity(0.12)))
    }
    private var bubbleContent: some View {
        VStack(alignment:.leading,spacing:4){
            HStack(spacing:6){
                Circle().fill(Color.green).frame(width:6,height:6)
                Text("\(agentName) running").font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
                Spacer()
                Button(action: { showSessions.toggle(); if showSessions && sessions.isEmpty { fetchSessionSessions() } }) { Image(systemName:"list.bullet").font(.system(size:9,weight:.semibold)).foregroundColor(.secondary).frame(width:16,height:16).background(Color.secondary.opacity(0.12)).clipShape(Circle()) }.buttonStyle(.plain).help("Switch session")
                Text(liveRunning ? "live" : "done").font(.caption2).foregroundColor(liveRunning ? .orange : .secondary)
                if liveRunning { Circle().fill(Color.orange).frame(width:5,height:5).opacity(0.9) }
            }
            ScrollViewReader{ proxy in
                ScrollView(showsIndicators:false){
                    LazyVStack(alignment:.leading, spacing:5){
                        if liveEntries.isEmpty {
                            HStack(spacing:6){
                                if liveRunning { ProgressView().controlSize(.mini).scaleEffect(0.7); Text("Waiting for output\(String(repeating:".", count:(liveTick%3)+1))").font(.system(size:9, design:.monospaced)).foregroundColor(.secondary) } else { Text("No output yet").font(.system(size:9, design:.monospaced)).foregroundColor(.secondary) }
                                Spacer()
                            }.padding(.vertical,4)
                        } else {
                            ForEach(Array(liveEntries.enumerated()), id:\.offset){ _, entry in
                                popupEntry(entry)
                            }
                        }
                        Color.clear.frame(height:1).id("run-bubble-bottom")
                    }.frame(maxWidth:.infinity, alignment:.leading)
                }.frame(height: 145).onChange(of: liveEntries){ _ in withAnimation(.easeOut(duration:0.15)){ proxy.scrollTo("run-bubble-bottom", anchor:.bottom) } }
            }
        }.padding(10).frame(width: showSessions ? 240 : 264, height: 175)
    }

    private var popupVerticalTodoStripCollapsed: some View {
        VStack(spacing:6){
            Image(systemName:"checklist").font(.system(size:7, weight:.semibold)).foregroundColor(.purple).padding(.top,6)
            Divider().opacity(0.3).padding(.horizontal,4)
            ForEach(Array(verticalTodos.prefix(10).enumerated()), id:\.offset){ _,t in
                ZStack{ Circle().fill(runTodoDotColor(t.status)).frame(width:7,height:7); if t.status=="in_progress"{ Circle().stroke(Color.blue.opacity(0.45),lineWidth:1.2).frame(width:10,height:10) } }.frame(width:10,height:10)
            }
            if verticalTodos.count>10{ Text("+\(verticalTodos.count-10)").font(.system(size:6)).foregroundColor(.secondary) }
            Spacer(minLength:2)
        }.padding(.vertical,6)
    }
    private var popupVerticalTodoStripExpanded: some View {
        VStack(spacing:6){
            HStack(spacing:4){
                Image(systemName:"checklist").font(.system(size:7, weight:.semibold)).foregroundColor(.purple)
                Text("TODO").font(.system(size:8, weight:.bold, design:.monospaced)).foregroundColor(.purple); Spacer(); Text("\(verticalTodos.filter{$0.status=="completed"}.count)/\(verticalTodos.count)").font(.system(size:7,weight:.medium, design:.monospaced)).foregroundColor(.secondary).padding(.horizontal,4).padding(.vertical,1).background(Color.purple.opacity(0.12)).cornerRadius(3)
            }.padding(.horizontal,6).padding(.top,6)
            Divider().opacity(0.3).padding(.horizontal,4)
            ForEach(Array(verticalTodos.prefix(10).enumerated()), id:\.offset){ _,t in
                HStack(spacing:5){
                    ZStack{ Circle().fill(runTodoDotColor(t.status)).frame(width:7,height:7); if t.status=="in_progress"{ Circle().stroke(Color.blue.opacity(0.45),lineWidth:1.2).frame(width:10,height:10) } }.frame(width:10,height:10)
                    Text(t.content).font(.system(size:8)).lineLimit(1).foregroundColor(t.status=="completed" ? .secondary : .primary).truncationMode(.tail)
                }.padding(.horizontal,6)
            }
            if verticalTodos.count>10{ Text("+\(verticalTodos.count-10)").font(.system(size:7)).foregroundColor(.secondary) }
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
        guard let url = URL(string: "\(baseURL)/sessions") else { sessionsLoading = false; return }
        var request = URLRequest(url: url); request.addValue("Bearer \(EliaAuth.token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: request) { data, _, _ in DispatchQueue.main.async { self.sessionsLoading = false; if let data = data, let sessions = try? JSONDecoder().decode([RunSessionInfo].self, from: data) { self.sessions = sessions } } }.resume()
    }

    private func fetchRunHistory(){
        guard let listURL = URL(string: "\(baseURL)/sessions/\(agentName)/list") else { return }
        var req = EliaAuth.authorize(listURL); req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req){ data,_,_ in
            guard let data=data, let json=try? JSONSerialization.jsonObject(with:data) as? [String:Any], let arr=json["sessions"] as? [[String:Any]], let first=arr.first, let sid=first["session_id"] as? String, !sid.isEmpty else { return }
            self.fetchMessagesForHistory(sessionId: sid)
        }.resume()
    }
    private func fetchMessagesForHistory(sessionId: String){
        guard let url = URL(string: "\(baseURL)/sessions/\(agentName)?session_id=\(sessionId)&limit=30") else { return }
        URLSession.shared.dataTask(with: EliaAuth.authorize(url)){ data,_,_ in
            guard let data=data, let json=try? JSONSerialization.jsonObject(with:data) as? [String:Any], let rawMessages=json["messages"] as? [[String:Any]] else { return }
            DispatchQueue.main.async{
                var historyEntries:[RunLiveEntry]=[]
                var latestTodos:[RunTodoItem]?=nil
                for raw in rawMessages {
                    guard let parts=raw["parts"] as? [[String:Any]] else { continue }
                    for part in parts {
                        guard let type=part["type"] as? String else { continue }
                        switch type {
                        case "text":
                            if let t=part["text"] as? String, !t.isEmpty { historyEntries.append(.text(t)) }
                        case "reasoning":
                            if let t=part["text"] as? String, !t.isEmpty { historyEntries.append(.reasoning(t)) }
                        case "tool":
                            let toolName=part["tool"] as? String ?? "tool"
                            let inputStr:String? = {
                                if let s=part["input"] as? String { return s }
                                if let d=part["input"] as? [String:Any], let jd=try? JSONSerialization.data(withJSONObject:d), let s=String(data:jd,encoding:.utf8){ return s }
                                if let n=part["input"] as? NSNumber { return n.stringValue }
                                return nil
                            }()
                            let outputStr:String? = {
                                if let s=part["output"] as? String { return s }
                                if let n=part["output"] as? NSNumber { return n.stringValue }
                                if let d=part["output"] as? [String:Any], let jd=try? JSONSerialization.data(withJSONObject:d), let s=String(data:jd,encoding:.utf8){ return s }
                                if let a=part["output"] as? [Any], let jd=try? JSONSerialization.data(withJSONObject:a), let s=String(data:jd,encoding:.utf8){ return s }
                                return nil
                            }()
                            historyEntries.append(.tool(name: toolName, input: inputStr, output: outputStr))
                            if toolName.lowercased().contains("todo"){
                                if let todos=runExtractTodos(input: inputStr, output: outputStr, delta: inputStr ?? ""), !todos.isEmpty { latestTodos=todos }
                                else if let s=inputStr, let todos=runScanTodosFromString(s), !todos.isEmpty { latestTodos=todos }
                            }
                        default: break
                        }
                    }
                }
                if latestTodos == nil {
                    for raw in rawMessages.reversed(){
                        guard let parts=raw["parts"] as? [[String:Any]] else { continue }
                        for part in parts where (part["tool"] as? String)?.lowercased().contains("todo") == true {
                            let inputStr:String? = {
                                if let s=part["input"] as? String { return s }
                                if let d=part["input"] as? [String:Any], let jd=try? JSONSerialization.data(withJSONObject:d), let s=String(data:jd,encoding:.utf8){ return s }
                                return nil
                            }()
                            let outputStr=part["output"] as? String
                            if let todos=runExtractTodos(input: inputStr, output: outputStr, delta: inputStr ?? ""), !todos.isEmpty { latestTodos=todos; break }
                        }
                        if latestTodos != nil { break }
                    }
                }
                if let todos=latestTodos, !todos.isEmpty { self.verticalTodos=todos }
                if !historyEntries.isEmpty {
                    let capped = historyEntries.count > 40 ? Array(historyEntries.suffix(40)) : historyEntries
                    if self.liveEntries.isEmpty { self.liveEntries=capped } else {
                        var merged=capped
                        for e in self.liveEntries where !merged.contains(e) { merged.append(e) }
                        self.liveEntries=Array(merged.suffix(50))
                    }
                }
            }
        }.resume()
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
