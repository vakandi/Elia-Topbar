import Foundation

/// Holds one value, written once, read from anywhere.
///
/// The voice feature runs an operation that may never finish (a system
/// permission prompt nobody answers, an on-device model that takes its
/// time). The deadline is enforced by polling this box instead of by
/// suspending the caller on a continuation: a continuation resumed from
/// another thread leaves the runtime's "current executor" bookkeeping in a
/// state that SwiftUI trips over later, and the whole app dies in
/// `MainActor.assumeIsolated`.
final class ValueBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?

    init() {}

    /// Store the value. The first writer wins.
    func set(_ newValue: T) {
        lock.lock()
        if value == nil { value = newValue }
        lock.unlock()
    }

    /// The value, once it is there.
    func get() -> T? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
