import SwiftUI

enum LivestreamEntry: Equatable, Identifiable {
    case reasoning(id: String, text: String)
    case text(id: String, text: String)
    case tool(id: String, name: String, input: String?, output: String?)

    var id: String {
        switch self {
        case .reasoning(let id, _): return id
        case .text(let id, _): return id
        case .tool(let id, _, _, _): return id
        }
    }

    var isReasoning: Bool { if case .reasoning = self { return true }; return false }
    var isText: Bool { if case .text = self { return true }; return false }
    var isTool: Bool { if case .tool = self { return true }; return false }
}

struct LivestreamTodoItem: Equatable {
    let content: String
    let status: String
    let priority: String
}
