import Foundation
import Combine
import SwiftUI

@MainActor final class LivestreamStore: ObservableObject {
    static let shared = LivestreamStore()

    struct AgentStream {
        var entries: [LivestreamEntry] = []
        var version: UInt64 = 0
        var cappedAt: Int = 0
    }

    @Published private(set) var streams: [String: AgentStream] = [:]
    @Published private(set) var todos: [String: [LivestreamTodoItem]] = [:]
    /// Latest session this agent's todos/stream were synced from. Used to drop
    /// stale per-session state (e.g. previous run's todo list) when a new run
    /// with a different sessionId arrives.
    private(set) var sessionForAgent: [String: String] = [:]

    struct SubagentKey: Hashable {
        let parentAgent: String
        let sessionId: String
        let description: String
        let agent: String
        let kind: String
        let teamRunId: String?
        var id: String { "\(parentAgent):\(sessionId)" }
        init(parentAgent: String, sessionId: String, description: String, agent: String, kind: String = "subagent", teamRunId: String? = nil) {
            self.parentAgent = parentAgent; self.sessionId = sessionId; self.description = description; self.agent = agent; self.kind = kind; self.teamRunId = teamRunId
        }
    }
    @Published private(set) var subagentStreams: [SubagentKey: AgentStream] = [:]
    @Published private(set) var subagentTodos: [SubagentKey: [LivestreamTodoItem]] = [:]
    let subagentThrottled = PassthroughSubject<SubagentKey, Never>()
    private var subagentThrottleWork: [SubagentKey: DispatchWorkItem] = [:]

    let throttled = PassthroughSubject<String, Never>()
    private var throttleWork: [String: DispatchWorkItem] = [:]

    private let textCap = 12000
    private let textKeep = 8000
    private let toolCap = 80

    func stream(for agent: String) -> [LivestreamEntry] { streams[agent]?.entries ?? [] }
    func todo(for agent: String) -> [LivestreamTodoItem] { todos[agent] ?? [] }

    func appendDelta(agent: String, field: String, delta: String) {
        if delta.isEmpty { return }
        if streams[agent] == nil { streams[agent] = AgentStream() }
        var entries = streams[agent]!.entries

        switch field {
        case "reasoning":
            if let last = entries.last, case .reasoning(let id, let cur) = last {
                if delta == cur || cur.hasSuffix(delta) || (cur.contains(delta) && delta.count < 40) { return }
                var next: String
                if delta.hasPrefix(cur) { next = delta }
                else if cur.isEmpty { next = delta }
                else { next = cur + delta }
                if next.count > textCap { next = String(next.suffix(textKeep)) }
                entries[entries.count - 1] = .reasoning(id: id, text: next)
            } else {
                let capped = delta.count > textCap ? String(delta.suffix(textKeep)) : delta
                entries.append(.reasoning(id: UUID().uuidString, text: capped))
            }
        case "tool":
            let parsed: (String, String?, String?) = {
                if let data = delta.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let tool = (obj["tool"] as? String ?? obj["name"] as? String ?? "tool")
                    if let s = obj["input"] as? String { return (tool, s, obj["output"] as? String) }
                    if let d = obj["input"] as? [String: Any], let jd = try? JSONSerialization.data(withJSONObject: d), let s = String(data: jd, encoding: .utf8) { return (tool, s, obj["output"] as? String) }
                    if obj["filePath"] != nil || obj["oldString"] != nil || obj["content"] != nil { return (tool, delta, obj["output"] as? String) }
                    if obj["todos"] != nil { return (tool, delta, obj["output"] as? String) }
                    return (tool, obj["input"] as? String, obj["output"] as? String)
                }
                return (delta.isEmpty ? "tool" : delta, nil, nil)
            }()
            if let last = entries.last, case .tool(let lid, let ln, let li, let lo) = last, ln == parsed.0 && li == parsed.1 && lo == parsed.2 { return }
            entries.append(.tool(id: UUID().uuidString, name: parsed.0, input: parsed.1, output: parsed.2))
            if entries.count > toolCap {
                let drop = entries.count - toolCap
                entries.removeFirst(drop)
                streams[agent]?.cappedAt += drop
            }
            if let extracted = LivestreamParsing.extractTodos(input: parsed.1, output: parsed.2, delta: delta), !extracted.isEmpty {
                todos[agent] = extracted
            } else if delta.lowercased().contains("todos") {
                if let extracted = LivestreamParsing.extractTodos(input: parsed.1, output: parsed.2, delta: delta), !extracted.isEmpty { todos[agent] = extracted }
            }
            streams[agent]?.entries = entries
            streams[agent]?.version += 1
            throttle(agent)
            return
        default:
            let lower = delta.lowercased()
            if lower.contains("todos"), let extracted = LivestreamParsing.extractTodos(input: nil, output: nil, delta: delta), !extracted.isEmpty {
                todos[agent] = extracted
                entries.append(.tool(id: UUID().uuidString, name: "todowrite", input: delta, output: nil))
                if entries.count > toolCap { entries.removeFirst(entries.count - toolCap) }
                streams[agent]?.entries = entries
                streams[agent]?.version += 1
                throttle(agent)
                return
            }
            if let last = entries.last, case .text(let id, let cur) = last {
                if delta == cur { return }
                if delta.count < 80 && cur.contains(delta) { return }
                if cur.hasSuffix(delta) { return }
                var next: String
                if delta.hasPrefix(cur) { next = delta } else { next = cur + delta }
                if next.count > textCap { next = String(next.suffix(textKeep)) }
                entries[entries.count - 1] = .text(id: id, text: next)
            } else {
                let capped = delta.count > textCap ? String(delta.suffix(textKeep)) : delta
                entries.append(.text(id: UUID().uuidString, text: capped))
            }
        }

        if entries.count > toolCap + 20 {
            let drop = entries.count - toolCap
            entries.removeFirst(drop)
            streams[agent]?.cappedAt += drop
        }
        streams[agent]?.entries = entries
        streams[agent]?.version += 1
        throttle(agent)
    }

    func mergeHistory(agent: String, sessionId: String, rawMessages: [[String: Any]]) {
        if sessionForAgent[agent] != sessionId {
            sessionForAgent[agent] = sessionId
            todos[agent] = nil
        }
        if rawMessages.isEmpty { return }
        if streams[agent] == nil { streams[agent] = AgentStream() }
        var historyEntries: [LivestreamEntry] = []
        var latestTodos: [LivestreamTodoItem]? = nil
        for raw in rawMessages {
            guard let parts = raw["parts"] as? [[String: Any]] else { continue }
            for part in parts {
                guard let type = part["type"] as? String else { continue }
                switch type {
                case "text":
                    if let t = part["text"] as? String, !t.isEmpty { historyEntries.append(.text(id: UUID().uuidString, text: t)) }
                case "reasoning":
                    if let t = part["text"] as? String, !t.isEmpty { historyEntries.append(.reasoning(id: UUID().uuidString, text: t)) }
                case "tool":
                    let toolName = part["tool"] as? String ?? "tool"
                    let inputStr: String? = {
                        if let s = part["input"] as? String { return s }
                        if let d = part["input"] as? [String: Any], let jd = try? JSONSerialization.data(withJSONObject: d), let s = String(data: jd, encoding: .utf8) { return s }
                        if let n = part["input"] as? NSNumber { return n.stringValue }
                        return nil
                    }()
                    let outputStr: String? = {
                        if let s = part["output"] as? String { return s }
                        if let n = part["output"] as? NSNumber { return n.stringValue }
                        if let d = part["output"] as? [String: Any], let jd = try? JSONSerialization.data(withJSONObject: d), let s = String(data: jd, encoding: .utf8) { return s }
                        if let a = part["output"] as? [Any], let jd = try? JSONSerialization.data(withJSONObject: a), let s = String(data: jd, encoding: .utf8) { return s }
                        return nil
                    }()
                    historyEntries.append(.tool(id: UUID().uuidString, name: toolName, input: inputStr, output: outputStr))
                    if toolName.lowercased().contains("todo") {
                        if let todos = LivestreamParsing.extractTodos(input: inputStr, output: outputStr, delta: inputStr ?? ""), !todos.isEmpty { latestTodos = todos }
                    }
                default: break
                }
            }
        }
        if latestTodos == nil {
            for raw in rawMessages.reversed() {
                guard let parts = raw["parts"] as? [[String: Any]] else { continue }
                for part in parts where (part["tool"] as? String)?.lowercased().contains("todo") == true {
                    let inputStr: String? = {
                        if let s = part["input"] as? String { return s }
                        if let d = part["input"] as? [String: Any], let jd = try? JSONSerialization.data(withJSONObject: d), let s = String(data: jd, encoding: .utf8) { return s }
                        return nil
                    }()
                    let outputStr = part["output"] as? String
                    if let todos = LivestreamParsing.extractTodos(input: inputStr, output: outputStr, delta: inputStr ?? ""), !todos.isEmpty { latestTodos = todos; break }
                }
                if latestTodos != nil { break }
            }
        }
        if let extracted = latestTodos, !extracted.isEmpty {
            todos[agent] = extracted
        } else if latestTodos == nil && todos[agent] == nil {
            todos[agent] = []
        }
        if historyEntries.isEmpty { return }

        var current = streams[agent]!.entries
        if current.isEmpty {
            let capped = historyEntries.count > 80 ? Array(historyEntries.suffix(80)) : historyEntries
            streams[agent]!.entries = capped
            streams[agent]!.version += 1
            throttled.send(agent)
            return
        }

        let existingFingerprints = Set(current.map { entryFingerprint($0) })
        var toInsert: [LivestreamEntry] = []
        for h in historyEntries {
            let fp = entryFingerprint(h)
            if !existingFingerprints.contains(fp) { toInsert.append(h) }
        }
        if toInsert.isEmpty { return }
        let merged = toInsert + current
        let capped = merged.count > 120 ? Array(merged.suffix(120)) : merged
        streams[agent]!.entries = capped
        streams[agent]!.version += 1
        throttled.send(agent)
    }

    private func entryFingerprint(_ e: LivestreamEntry) -> String {
        switch e {
        case .reasoning(_, let t): return "r:\(t.prefix(120))"
        case .text(_, let t): return "t:\(t.prefix(120))"
        case .tool(_, let n, let i, let o): return "tool:\(n):\(i?.prefix(80) ?? ""):\(o?.prefix(80) ?? "")"
        }
    }

    func clear(agent: String, reason: String) {
        streams[agent] = AgentStream()
        todos[agent] = nil
        throttled.send(agent)
        let keys = subagentStreams.keys.filter { $0.parentAgent == agent }
        for k in keys { subagentStreams[k] = nil; subagentTodos[k] = nil; subagentThrottled.send(k) }
    }

    func subagentStream(for key: SubagentKey) -> [LivestreamEntry] { subagentStreams[key]?.entries ?? [] }
    func subagentTodo(for key: SubagentKey) -> [LivestreamTodoItem] { subagentTodos[key] ?? [] }

    func extractSubagents(parentAgent: String, rawMessages: [[String: Any]]) -> [SubagentKey] {
        var seen: Set<String> = []
        var out: [SubagentKey] = []
        AppLog.d("extractSubagents parent=\(parentAgent) rawCount=\(rawMessages.count)")
        for raw in rawMessages {
            guard let parts = raw["parts"] as? [[String: Any]] else { continue }
            for part in parts where part["type"] as? String == "tool" {
                let tool = (part["tool"] as? String ?? "").lowercased()
                if tool == "team_create" {
                    let outStr = part["output"] as? String ?? ""
                    var teamId: String? = nil
                    if let data = outStr.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        teamId = obj["teamRunId"] as? String
                        if let rt = obj["runtimeState"] as? [String: Any], let members = rt["members"] as? [[String: Any]] {
                            for m in members {
                                guard let sid = m["sessionId"] as? String, !sid.isEmpty, !seen.contains(sid) else { continue }
                                seen.insert(sid)
                                let name = m["name"] as? String ?? "team-member"
                                let agent = m["subagent_type"] as? String ?? m["agentType"] as? String ?? "member"
                                out.append(SubagentKey(parentAgent: parentAgent, sessionId: sid, description: name, agent: agent, kind: "team", teamRunId: teamId))
                            }
                        }
                    }
                    if out.isEmpty {
                        if let outDict = part["output"] as? [String: Any], let rt = outDict["runtimeState"] as? [String: Any], let members = rt["members"] as? [[String: Any]] {
                            if teamId == nil { teamId = outDict["teamRunId"] as? String }
                            for m in members {
                                guard let sid = m["sessionId"] as? String, !sid.isEmpty, !seen.contains(sid) else { continue }
                                seen.insert(sid)
                                let name = m["name"] as? String ?? "team-member"
                                let agent = m["subagent_type"] as? String ?? "member"
                                out.append(SubagentKey(parentAgent: parentAgent, sessionId: sid, description: name, agent: agent, kind: "team", teamRunId: teamId))
                            }
                        }
                    }
                    if out.isEmpty {
                        var pendingDesc = "Team creating…"
                        let input = part["input"]
                        if let d = input as? [String: Any], let n = d["name"] as? String { pendingDesc = n }
                        else if let s = input as? String, let data = s.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            if let n = obj["name"] as? String { pendingDesc = n }
                            else if let inline = obj["inline_spec"] as? String, let idata = inline.data(using: .utf8), let iobj = try? JSONSerialization.jsonObject(with: idata) as? [String: Any], let n = iobj["name"] as? String { pendingDesc = n }
                        } else if let inline = (input as? [String: Any])?["inline_spec"] as? String, let data = inline.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let n = obj["name"] as? String {
                            pendingDesc = n
                        }
                        let pendingId = "pending:team:\(parentAgent):\(pendingDesc)"
                        if !seen.contains(pendingId) {
                            seen.insert(pendingId)
                            out.append(SubagentKey(parentAgent: parentAgent, sessionId: pendingId, description: pendingDesc, agent: "team", kind: "team"))
                        }
                    }
                    continue
                }
                guard tool == "call_omo_agent" || tool == "task" else { continue }
                let input = part["input"]
                var desc = ""
                var agent = "explore"
                if let d = input as? [String: Any] {
                    desc = d["description"] as? String ?? d["prompt"] as? String ?? ""
                    agent = d["subagent_type"] as? String ?? d["agent"] as? String ?? "explore"
                    if desc.isEmpty, let p = d["prompt"] as? String { desc = String(p.prefix(60)) }
                } else if let s = input as? String, let data = s.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    desc = obj["description"] as? String ?? obj["prompt"] as? String ?? ""
                    agent = obj["subagent_type"] as? String ?? obj["agent"] as? String ?? "explore"
                }
                let outStr = part["output"] as? String ?? ""
                let sessId: String? = {
                    if let m = outStr.range(of: #"Session ID:\s*(ses_[A-Za-z0-9]+)"#, options: .regularExpression) {
                        let sub = String(outStr[m]); if let r = sub.range(of: #"ses_[A-Za-z0-9]+"#, options: .regularExpression) { return String(sub[r]) }
                    }
                    if let d = part["input"] as? [String: Any], let sid = d["sessionId"] as? String { return sid }
                    return nil
                }()
                guard let sid = sessId, !sid.isEmpty, !seen.contains(sid) else { continue }
                seen.insert(sid)
                let cleanDesc = desc.isEmpty ? tool : String(desc.prefix(80))
                let k: String = tool == "call_omo_agent" ? "call_omo" : (tool == "team_create" ? "team" : "task")
                out.append(SubagentKey(parentAgent: parentAgent, sessionId: sid, description: cleanDesc, agent: agent, kind: k))
            }
        }
        if out.contains(where: { $0.sessionId.hasPrefix("ses_") }) {
            out.removeAll { $0.sessionId.hasPrefix("pending:team") }
        }
        for raw in rawMessages {
            guard let parts = raw["parts"] as? [[String: Any]] else { continue }
            for part in parts where (part["tool"] as? String ?? "").lowercased() == "team_task_create" {
                var teamId: String? = nil
                if let d = part["input"] as? [String: Any] { teamId = d["teamRunId"] as? String }
                else if let s = part["input"] as? String, let data = s.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { teamId = obj["teamRunId"] as? String }
                let outStr = part["output"] as? String ?? ""
                var subject = ""
                var tid = ""
                if let data = outStr.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let task = obj["task"] as? [String: Any] {
                    subject = task["subject"] as? String ?? task["description"] as? String ?? ""
                    tid = task["id"] as? String ?? ""
                    if teamId == nil { teamId = obj["teamRunId"] as? String ?? task["teamRunId"] as? String }
                }
                if subject.isEmpty {
                    if let d = part["input"] as? [String: Any] { subject = d["subject"] as? String ?? d["description"] as? String ?? "" }
                    else if let s = part["input"] as? String, let data = s.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { subject = obj["subject"] as? String ?? obj["description"] as? String ?? "" }
                }
                if tid.isEmpty { tid = subject }
                if subject.isEmpty { subject = "task" }
                let keyId = "task:\(parentAgent):\(teamId ?? ""):\(tid)"
                if seen.contains(keyId) { continue }
                seen.insert(keyId)
                out.append(SubagentKey(parentAgent: parentAgent, sessionId: keyId, description: String(subject.prefix(60)), agent: "task", kind: "team_task", teamRunId: teamId))
            }
        }
        if !out.isEmpty { AppLog.d("extractSubagents found \(out.count) for \(parentAgent): \(out.map{$0.sessionId})") }
        return out
    }

    func mergeSubagentHistory(key: SubagentKey, rawMessages: [[String: Any]]) {
        if rawMessages.isEmpty { return }
        if subagentStreams[key] == nil { subagentStreams[key] = AgentStream() }
        var history: [LivestreamEntry] = []
        var latest: [LivestreamTodoItem]? = nil
        for raw in rawMessages {
            guard let parts = raw["parts"] as? [[String: Any]] else { continue }
            for part in parts {
                guard let type = part["type"] as? String else { continue }
                switch type {
                case "text": if let t = part["text"] as? String, !t.isEmpty { history.append(.text(id: UUID().uuidString, text: t)) }
                case "reasoning": if let t = part["text"] as? String, !t.isEmpty { history.append(.reasoning(id: UUID().uuidString, text: t)) }
                case "tool":
                    let n = part["tool"] as? String ?? "tool"
                    let iStr: String? = {
                        if let s = part["input"] as? String { return s }
                        if let d = part["input"] as? [String: Any], let jd = try? JSONSerialization.data(withJSONObject: d), let s = String(data: jd, encoding: .utf8) { return s }
                        return nil
                    }()
                    let oStr = part["output"] as? String
                    history.append(.tool(id: UUID().uuidString, name: n, input: iStr, output: oStr))
                    if n.lowercased().contains("todo"), let todos = LivestreamParsing.extractTodos(input: iStr, output: oStr, delta: iStr ?? ""), !todos.isEmpty { latest = todos }
                default: break
                }
            }
        }
        if let ex = latest, !ex.isEmpty { subagentTodos[key] = ex }
        if history.isEmpty { return }
        var cur = subagentStreams[key]!.entries
        if cur.isEmpty {
            subagentStreams[key]!.entries = history.count > 60 ? Array(history.suffix(60)) : history
            subagentStreams[key]!.version += 1
            subagentThrottled.send(key)
            objectWillChange.send()
            return
        }
        let fps = Set(cur.map { entryFingerprint($0) })
        var toInsert: [LivestreamEntry] = []
        for h in history { if !fps.contains(entryFingerprint(h)) { toInsert.append(h) } }
        if toInsert.isEmpty { return }
        let merged = toInsert + cur
        subagentStreams[key]!.entries = merged.count > 100 ? Array(merged.suffix(100)) : merged
        subagentStreams[key]!.version += 1
        objectWillChange.send()
        subagentThrottled.send(key)
    }

    private func throttle(_ agent: String) {
        throttleWork[agent]?.cancel()
        let work = DispatchWorkItem { self.throttled.send(agent) }
        throttleWork[agent] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        objectWillChange.send()
    }
}
