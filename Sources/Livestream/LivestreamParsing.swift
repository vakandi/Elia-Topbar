import SwiftUI
import Foundation

enum LivestreamParsing {

    static func hostPath(_ path: String) -> String {
        if path.hasPrefix("/data/") { return path.replacingOccurrences(of: "/data/", with: "/Users/vakandi/EliaAI/", options: .anchored) }
        if path == "/data" { return "/Users/vakandi/EliaAI" }
        return path
    }

    struct EditPayload { let path: String; let old: String; let new: String }
    struct WritePayload { let path: String; let preview: String }

    static func parseEdit(_ raw: String) -> EditPayload? {
        guard let data = raw.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let path = (obj["filePath"] as? String ?? obj["file_path"] as? String ?? obj["path"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        let old = obj["oldString"] as? String ?? obj["old_string"] as? String ?? obj["oldText"] as? String ?? ""
        let new = obj["newString"] as? String ?? obj["new_string"] as? String ?? obj["newText"] as? String ?? ""
        if old.isEmpty && new.isEmpty { return nil }
        return EditPayload(path: hostPath(path), old: old, new: new)
    }

    static func parseWrite(_ raw: String) -> WritePayload? {
        guard let data = raw.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let path = (obj["filePath"] as? String ?? obj["file_path"] as? String ?? obj["path"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        let content = obj["content"] as? String ?? ""
        return WritePayload(path: hostPath(path), preview: String(content.prefix(500)))
    }

    static func parseTodoWrite(_ input: String?, output: String?) -> [LivestreamTodoItem]? {
        let raw = (input?.isEmpty == false ? input : output) ?? ""
        guard !raw.isEmpty, let data = raw.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let arr = obj["todos"] as? [[String: Any]], !arr.isEmpty else { return nil }
        return arr.compactMap { d in guard let c = d["content"] as? String, !c.isEmpty else { return nil }; return LivestreamTodoItem(content: c, status: (d["status"] as? String ?? "pending").lowercased(), priority: (d["priority"] as? String ?? "medium").lowercased()) }
    }

    static func scanTodosFromString(_ s: String) -> [LivestreamTodoItem]? {
        guard s.lowercased().contains("content") else { return nil }
        var todos: [LivestreamTodoItem] = []
        let contentPat = "\"content\"\\s*:\\s*\"((?:\\\\\"|[^\"])*)\""
        let statusPat = "\"status\"\\s*:\\s*\"([^\"]*)\""
        let priorityPat = "\"priority\"\\s*:\\s*\"([^\"]*)\""
        guard let contentRegex = try? NSRegularExpression(pattern: contentPat),
              let statusRegex = try? NSRegularExpression(pattern: statusPat),
              let priorityRegex = try? NSRegularExpression(pattern: priorityPat) else { return nil }
        let ns = s as NSString
        let matches = contentRegex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let cr = m.range(at: 1)
            guard cr.location != NSNotFound else { continue }
            var content = ns.substring(with: cr).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: " ")
            if content.hasSuffix("…") { content = String(content.dropLast()) }
            content = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if content.isEmpty { continue }
            let searchStart = m.range.location
            let searchLen = min(400, ns.length - searchStart)
            let searchRange = NSRange(location: searchStart, length: searchLen)
            let slice = ns.substring(with: searchRange)
            var status = "pending"
            var priority = "medium"
            if let sm = statusRegex.firstMatch(in: slice, range: NSRange(location: 0, length: (slice as NSString).length)) {
                let r = sm.range(at: 1); if r.location != NSNotFound { status = (slice as NSString).substring(with: r).lowercased() }
            }
            if let pm = priorityRegex.firstMatch(in: slice, range: NSRange(location: 0, length: (slice as NSString).length)) {
                let r = pm.range(at: 1); if r.location != NSNotFound { priority = (slice as NSString).substring(with: r).lowercased() }
            }
            todos.append(LivestreamTodoItem(content: String(content.prefix(120)), status: status, priority: priority))
            if todos.count >= 12 { break }
        }
        return todos.isEmpty ? nil : todos
    }

    static func extractTodos(input: String?, output: String?, delta: String) -> [LivestreamTodoItem]? {
        if let t = parseTodoWrite(input, output: output), !t.isEmpty { return t }
        if let t = parseTodoWrite(delta, output: nil), !t.isEmpty { return t }
        for raw in [input, output, delta] {
            guard let s = raw, !s.isEmpty, s.lowercased().contains("todos") else { continue }
            if let todos = scanTodosFromString(s), !todos.isEmpty { return todos }
            if let d = s.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let found = findTodosRecursive(obj), !found.isEmpty { return found }
        }
        if let data = delta.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let found = findTodosRecursive(obj), !found.isEmpty { return found }
        for raw in [input, output, delta] { if let s = raw, let todos = scanTodosFromString(s), !todos.isEmpty { return todos } }
        return nil
    }

    static func findTodosRecursive(_ obj: Any) -> [LivestreamTodoItem]? {
        if let dict = obj as? [String: Any] {
            if let arr = dict["todos"] as? [[String: Any]], !arr.isEmpty {
                let todos = arr.compactMap { d -> LivestreamTodoItem? in guard let c = d["content"] as? String, !c.isEmpty else { return nil }; return LivestreamTodoItem(content: c, status: (d["status"] as? String ?? "pending").lowercased(), priority: (d["priority"] as? String ?? "medium").lowercased()) }
                if !todos.isEmpty { return todos }
            }
            for v in dict.values { if let r = findTodosRecursive(v), !r.isEmpty { return r } }
        } else if let arr = obj as? [Any] {
            for v in arr { if let r = findTodosRecursive(v), !r.isEmpty { return r } }
        }
        return nil
    }

    static func toolIcon(_ name: String) -> String {
        switch name.lowercased() {
        case "bash", "shell", "interactive_bash": return "terminal"
        case "read", "view": return "doc.text"
        case "write", "edit": return "pencil.and.document"
        case "grep", "search": return "magnifyingglass"
        case "glob", "find": return "folder"
        case "task", "agent", "call_omo_agent": return "person.2"
        case "skill": return "wand.and.stars"
        case "background_output", "background_cancel": return "arrow.triangle.2.circlepath"
        case "codegraph_explore": return "point.3.connected.trianglepath.dotted"
        case "websearch", "web_search_exa", "webfetch": return "globe"
        default: return "wrench.and.screwdriver"
        }
    }

    static func toolDisplayName(_ name: String) -> String {
        switch name.lowercased() {
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
        case "websearch", "web_search_exa": return "Web Search"
        case "webfetch": return "Fetch URL"
        default: return name
        }
    }

    static func toolColor(_ name: String) -> Color {
        switch name.lowercased() {
        case "bash", "shell", "interactive_bash": return .orange
        case "read", "view": return .cyan
        case "write": return .green
        case "edit": return .yellow
        case "grep", "search", "glob", "find": return .purple
        case "task", "agent", "call_omo_agent": return .pink
        case "skill": return .indigo
        case "background_output", "background_cancel": return .teal
        case "codegraph_explore": return .mint
        case "websearch", "web_search_exa", "webfetch": return .blue
        default: return .blue
        }
    }

    static func formatToolContent(name: String, input: String?, output: String?) -> String {
        var parts: [String] = []
        if let input, !input.isEmpty { let f = formatToolInput(name: name, raw: input); if !f.isEmpty { parts.append(f) } }
        if let output, !output.isEmpty { let d = output.count > 600 ? String(output.prefix(600)) + "…" : output; parts.append(d) }
        return parts.joined(separator: "\n")
    }

    static func formatToolInput(name: String, raw: String) -> String {
        guard let data = raw.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines); if t == "{}" || t == "()" || t.isEmpty { return "" }; return String(raw.prefix(500))
        }
        if obj.isEmpty { return "" }
        func fp(_ o: [String: Any]) -> String? { (o["filePath"] as? String ?? o["file_path"] as? String ?? o["path"] as? String ?? o["filepath"] as? String) }
        switch name.lowercased() {
        case "bash", "shell", "interactive_bash": if let c = obj["command"] as? String { return "$ \(c)" }
        case "read": if let p = fp(obj) { return hostPath(p) }
        case "write": if let p = fp(obj) { let hp = hostPath(p); if let c = obj["content"] as? String, !c.isEmpty { return "\(hp)\n\(c.prefix(200))" }; return hp }
        case "edit": if let p = fp(obj) { return hostPath(p) }
        case "grep": if let pat = obj["pattern"] as? String { return pat }
        case "glob": if let pat = obj["pattern"] as? String { return pat }
        case "task": if let pr = obj["prompt"] as? String { return String(pr.prefix(300)) }; if let d = obj["description"] as? String { return d }
        case "websearch", "web_search_exa": if let q = obj["query"] as? String { return q }
        case "webfetch": if let u = obj["url"] as? String { return u }
        case "codegraph_explore": if let q = obj["query"] as? String { return q }
        default: break
        }
        let fallback = ["command", "query", "pattern", "filePath", "content", "url", "prompt", "description", "script", "selector"]
        for k in fallback { if let v = obj[k] as? String, !v.isEmpty { return "\(k): \(v.prefix(300))" } }
        return String(raw.prefix(500))
    }

    static func streamingSafeMarkdown(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines); if t.isEmpty { return text }
        let c = text.components(separatedBy: "```").count - 1; if c % 2 == 1 { return text + "\n```" }; return text
    }

    static func todoDotColor(_ status: String) -> Color {
        switch status { case "completed": return .green; case "in_progress": return .blue; case "cancelled": return .red; default: return .orange }
    }
    static func todoPriorityColor(_ p: String) -> Color {
        switch p { case "high": return .red.opacity(0.7); case "medium": return .orange.opacity(0.7); default: return .secondary }
    }
}
