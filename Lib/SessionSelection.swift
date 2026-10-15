import Foundation

/// Which session an agent surface is showing.
///
/// Two different questions used to share one slot: "what session is the run writing
/// to" (driven by WebSocket deltas) and "what session did the user click" (driven by
/// the list). The run answered the second one on the user's behalf, so picking an old
/// session snapped straight back to the live stream.
///
/// The split makes that impossible rather than merely unlikely: `viewing` is writable
/// only by `select`, which only the list taps call. A live event cannot reach it.
public struct SessionSelection: Equatable {
    /// Session the current run is writing to. Written by WebSocket events.
    public private(set) var live: String?
    /// Session the user picked. Written only by `select`.
    public private(set) var viewing: String?

    public init(live: String? = nil, viewing: String? = nil) {
        self.live = live
        self.viewing = viewing
    }

    /// True when nothing has been picked, or the pick is the live session.
    public var isViewingLive: Bool { viewing == nil || viewing == live }

    public mutating func observeLive(_ id: String) { live = id }
    public mutating func select(_ id: String) { viewing = id }
    public mutating func clear() { viewing = nil }

    /// Whether a payload for `incoming` belongs on screen right now.
    public func renders(_ incoming: String) -> Bool {
        viewing == nil || viewing == incoming
    }
}