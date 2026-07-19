import SwiftUI

@main
struct BackgroundTransferHostApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self)
    private var appDelegate

    @State private var model = HostModel.shared

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
