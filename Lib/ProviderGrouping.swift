import Foundation

/// Orders model rows into provider groups for the model menu.
///
/// The roster used to label every model `opencode-zen`, which put all 139 rows in
/// one flat list. The bridge now reports each model's real provider, so the menu can
/// group them. `opencode` (OpenCode's own Zen models) stays pinned on top because
/// those are the default and the ones most runs use.
public struct ModelRow: Equatable {
    public let id: String
    public let name: String
    public let provider: String

    public init(id: String, name: String, provider: String) {
        self.id = id
        self.name = name
        self.provider = provider
    }
}

public enum ProviderGrouping {
    /// Always rendered first, whatever else the roster contains.
    public static let pinnedFirst = "opencode"

    public static func ordered(_ rows: [ModelRow]) -> [(provider: String, rows: [ModelRow])] {
        var order: [String] = []
        var buckets: [String: [ModelRow]] = [:]
        for row in rows {
            if buckets[row.provider] == nil {
                order.append(row.provider)
                buckets[row.provider] = []
            }
            buckets[row.provider]?.append(row)
        }

        var sorted = order.sorted()
        if let pinned = sorted.firstIndex(of: pinnedFirst) {
            let p = sorted.remove(at: pinned)
            sorted.insert(p, at: 0)
        }

        return sorted.map { provider in
            (provider: provider, rows: buckets[provider] ?? [])
        }
    }
}