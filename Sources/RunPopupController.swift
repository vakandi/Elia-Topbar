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
         let width: CGFloat = 280, height: CGFloat = 250, gap: CGFloat = 8
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
        let width: CGFloat=280, height: CGFloat=250, gap: CGFloat=8
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
 struct RunPopupView: View {
     let agentName: String; let onTap: ()->Void
     let baseURL: String; let showSessionSelector: Bool; let disableAutoClose: Bool
     @State private var liveText=""; @State private var observer: NSObjectProtocol?
     @State private var verticalTodos: [TodoItem] = []
     @State private var isHoveringTodoModule = false
     @State private var sessions: [SessionInfo] = []
     @State private var sessionsLoading = false
     @State private var showSessions = false
     var body: some View {
         HStack(spacing:0){
             if !verticalTodos.isEmpty {
                 verticalTodoStrip
                     .frame(width: isHoveringTodoModule ? 180 : 28)
                     .background(Color(nsColor:.controlBackgroundColor).opacity(0.95))
                     .overlay(Rectangle().frame(width:1).foregroundColor(Color.primary.opacity(0.08)), alignment:.trailing)
                     .onHover{ h in isHoveringTodoModule=h }
                     .animation(.easeInOut(duration:0.2), value:isHoveringTodoModule)
             }
             if showSessions { sessionSidebar }
             VStack(spacing:6){ photoBadge; bubble }.padding(.top,4).frame(width: showSessions ? 240 : 264)
         }
         .frame(width: showSessions ? 400 : 264)
         .onAppear(perform:observeLogs).onDisappear{ if let o=observer{NotificationCenter.default.removeObserver(o)} }.onTapGesture{onTap()}.onHover{ h in RunPopupController.shared.setHover(h, for:agentName) }
     }
     private struct TodoItem { let content:String; let status:String; let priority:String }
     private struct SessionInfo: Codable, Identifiable { let id: String; let title: String? }
     private var verticalTodoStrip: some View {
        VStack(spacing:6){
            ForEach(Array(verticalTodos.prefix(8).enumerated()), id:\.offset){ _,t in
                HStack(spacing:5){
                    ZStack{ Circle().fill(todoDotColor(t.status)).frame(width:7,height:7); if t.status=="in_progress"{ Circle().stroke(Color.blue.opacity(0.4),lineWidth:1.5).frame(width:10,height:10) } }.frame(width:10,height:10)
                    if isHoveringTodoModule{ Text(t.content).font(.system(size:9)).lineLimit(1).foregroundColor(t.status=="completed" ? .secondary : .primary) }
                }
            }
            if verticalTodos.count>8{ Text("+\(verticalTodos.count-8)").font(.system(size:8)).foregroundColor(.secondary) }
        }.padding(.vertical,8).padding(.horizontal, isHoveringTodoModule ? 6 : 4)
    }
    private func todoDotColor(_ s:String)->Color{ switch s{ case "completed": return .green; case "in_progress": return .blue; default: return .orange } }
    private var photoBadge: some View {
        ZStack{
            Circle().stroke(Color.accentColor.opacity(0.6),lineWidth:2).frame(width:56,height:56).modifier(PulseGlow())
            if let photo=ProfilePhotos.shared.circularPhoto(for:agentName,size:48){ Image(nsImage:photo).resizable().frame(width:48,height:48) } else { ZStack{ Circle().fill(Color.accentColor.opacity(0.25)); Text(agentMonogram).font(.system(size:18,weight:.bold)).foregroundColor(.accentColor) }.frame(width:48,height:48) }
        }.frame(height:60)
    }
     private var bubble: some View {
         VStack(alignment:.leading,spacing:4){
             HStack(spacing:6){ Circle().fill(Color.green).frame(width:6,height:6); Text("\(agentName) running").font(.caption).fontWeight(.semibold).foregroundColor(.secondary); Spacer()
             Button(action: { showSessions.toggle(); if showSessions && sessions.isEmpty { fetchSessionSessions() } }) { Image(systemName:"list.bullet").font(.system(size:9,weight:.semibold)).foregroundColor(.secondary).frame(width:16,height:16).background(Color.secondary.opacity(0.12)).clipShape(Circle()) }.buttonStyle(.plain).help("Switch session")
             Text("live").font(.caption2).foregroundColor(.orange) }
             ScrollViewReader{ proxy in ScrollView{ Group{ if liveText.isEmpty { Text("Waiting for output…").font(.system(size:9,design:.monospaced)).foregroundColor(.secondary) } else { MarkdownView(text: liveText, baseColor: .primary.opacity(0.85)).font(.system(size: 9)).textSelection(.enabled) } }.frame(maxWidth:.infinity,alignment:.leading).id("bubble-text") }.frame(height:120).onChange(of:liveText){ _ in proxy.scrollTo("bubble-text", anchor:.bottom) } }
         }.padding(10).frame(width: showSessions ? 240 : 264).background(RoundedRectangle(cornerRadius:14).fill(.regularMaterial)).overlay(RoundedRectangle(cornerRadius:14).stroke(Color.primary.opacity(0.12)))
     }
     private var sessionSidebar: some View {
          VStack(spacing:0) {
              if let photo = ProfilePhotos.shared.circularPhoto(for: agentName, size: 36) {
                  Image(nsImage: photo).resizable().frame(width:36,height:36)
              } else {
                  ZStack { Circle().fill(Color.accentColor.opacity(0.25)); Text(agentMonogram).font(.system(size:12,weight:.bold)).foregroundColor(.accentColor) }.frame(width:36,height:36)
              }
              Text(agentName).font(.caption2).fontWeight(.semibold).lineLimit(1).padding(.top,2)
              Divider()
              if sessionsLoading {
                  ProgressView().controlSize(.mini).padding(4)
              } else if sessions.isEmpty {
                  Text("No sessions").font(.caption2).foregroundColor(.secondary).padding(4)
              } else {
                  ScrollView {
                      LazyVStack(spacing:0) {
                          ForEach(sessions) { s in
                              Button(action: { showSessions = false }) {
                                  HStack(spacing:3){
                                      Circle().fill(Color.accentColor.opacity(0.4)).frame(width:5,height:5)
                                      Text(s.title ?? "Session").font(.caption2).lineLimit(1).foregroundColor(.primary)
                                  }.frame(maxWidth:.infinity, alignment:.leading).padding(.horizontal,5).padding(.vertical,2)
                                      .background(Color.primary.opacity(0.06)).cornerRadius(5)
                              }.buttonStyle(.plain)
                          }
                      }
                  }
              }
              Divider()
              Button(action: { showSessions = false }) {
                  HStack(spacing:3){ Image(systemName:"xmark").font(.system(size:7)); Text("Close").font(.system(size:7)) }
                  .foregroundColor(.secondary).frame(maxWidth:.infinity)
              }.buttonStyle(.plain)
          }.frame(width: 160)
          .background(RoundedRectangle(cornerRadius:14).fill(Color(NSColor.controlBackgroundColor)))
          .overlay(RoundedRectangle(cornerRadius:14).stroke(Color.primary.opacity(0.12)))
     }
     private var agentMonogram: String { let parts=agentName.split(separator:"-").map(String.init); let initials=parts.prefix(2).compactMap{$0.first.map(String.init)}.joined().uppercased(); if initials.count==2{return initials}; let firstWord=parts.first ?? agentName; return String(firstWord.prefix(2)).uppercased() }
     private func fetchSessionSessions() {
         sessionsLoading = true
         guard let url = URL(string: "\(baseURL)/sessions") else { sessionsLoading = false; return }
         var request = URLRequest(url: url)
         request.addValue("Bearer \(EliaAuth.token)", forHTTPHeaderField: "Authorization")
         URLSession.shared.dataTask(with: request) { data, resp, error in
             DispatchQueue.main.async {
                 self.sessionsLoading = false
                 if let data = data, let sessions = try? JSONDecoder().decode([SessionInfo].self, from: data) {
                     self.sessions = sessions
                 }
             }
         }.resume()
     }
     private func observeLogs(){ observer=NotificationCenter.default.addObserver(forName:SubworkerManager.runLogNotification,object:nil,queue:.main){ note in guard let name=note.userInfo?["name"] as? String,name==agentName,let delta=note.userInfo?["text"] as? String else{return}; let field=note.userInfo?["field"] as? String ?? "text"; if field=="reasoning"{
                     let md = delta.split(separator:"\n").map{ "> \($0)" }.joined(separator:"\n")
                     if self.liveText.hasSuffix(md) { return }
                     self.liveText += (self.liveText.isEmpty ? "" : "\n\n") + md
                     if liveText.count>6000{ liveText=String(liveText.suffix(3500)) }
                     return
                 }; if field=="tool"{ if let data=delta.data(using:.utf8),let obj=try? JSONSerialization.jsonObject(with:data) as?[String:Any],let t=obj["tool"] as? String{
                     if t.lowercased()=="todowrite"{
                         if let input = obj["input"] as? String, let d = input.data(using:.utf8), let o = try? JSONSerialization.jsonObject(with:d) as?[String:Any], let arr=o["todos"] as?[[String:Any]]{
                             let todos=arr.compactMap{ d->TodoItem? in guard let c=d["content"] as?String else{return nil}; return TodoItem(content:c,status:(d["status"] as?String ?? "pending").lowercased(),priority:(d["priority"] as?String ?? "medium").lowercased())}
                             verticalTodos=todos
                         } else if let arr=obj["todos"] as?[[String:Any]]{
                             let todos=arr.compactMap{ d->TodoItem? in guard let c=d["content"] as?String else{return nil}; return TodoItem(content:c,status:(d["status"] as?String ?? "pending").lowercased(),priority:(d["priority"] as?String ?? "medium").lowercased())}
                             verticalTodos=todos
                         }
                     }
                     let line="🔧 \(t)"; if !self.liveText.hasSuffix(line){ self.liveText+=(self.liveText.isEmpty ? "" : "\n")+line } }; return }; if delta.isEmpty{return}; if self.liveText.hasSuffix(delta){return}; if delta.hasPrefix(self.liveText){self.liveText=delta} else if self.liveText.contains(delta) && delta.count<80{return} else{self.liveText+=delta}; if liveText.count>4000{liveText=String(liveText.suffix(2500))} } }
     }
