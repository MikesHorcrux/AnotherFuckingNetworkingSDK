import Foundation

/// A small synchronous critical region for callback-facing state.
///
/// `NSLock` remains the deployment-compatible primitive for the package's
/// iOS 15 and macOS 12 floor. The unchecked conformance is confined here: the
/// value is accessible only while the lock is held, the closure never escapes,
/// and no lock is held across an `await`.
final class CriticalState<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    @discardableResult
    func withCriticalRegion<Result>(
        _ operation: (inout Value) throws -> Result
    ) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation(&value)
    }
}
