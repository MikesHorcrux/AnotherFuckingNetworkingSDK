import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        let box = CompletionBox(completionHandler)
        Task { @MainActor in
            HostModel.shared.handleBackgroundEvents(
                identifier: identifier,
                completionHandler: { box.call() }
            )
        }
    }
}

/// Apple's completion handler is supplied as a non-Sendable closure even
/// though the SDK stores it behind a Sendable delegate boundary.
private final class CompletionBox: @unchecked Sendable {
    private let closure: () -> Void

    init(_ closure: @escaping () -> Void) {
        self.closure = closure
    }

    func call() {
        closure()
    }
}
