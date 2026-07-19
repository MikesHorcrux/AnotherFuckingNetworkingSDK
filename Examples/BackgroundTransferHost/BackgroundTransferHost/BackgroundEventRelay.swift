import Foundation
import AnotherFuckingNetworkingSDK

/// Buffers delegate callbacks until the host has restored its durable index.
///
/// A background URLSession can deliver a callback immediately after an app
/// relaunch. Keeping this tiny relay ahead of the lifecycle coordinator makes
/// the sample safe during that restore window instead of silently dropping an
/// early event.
actor BackgroundEventRelay {
    private var pending: [BackgroundTransferEvent] = []
    private var handler: (@Sendable (BackgroundTransferEvent) -> Void)?

    func receive(_ event: BackgroundTransferEvent) {
        guard let handler else {
            pending.append(event)
            return
        }
        handler(event)
    }

    func setHandler(
        _ handler: @escaping @Sendable (BackgroundTransferEvent) -> Void
    ) {
        self.handler = handler
        let pending = self.pending
        self.pending.removeAll(keepingCapacity: false)
        pending.forEach(handler)
    }
}
