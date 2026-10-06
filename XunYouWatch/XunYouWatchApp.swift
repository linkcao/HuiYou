import SwiftUI

@main
struct XunYouWatchApp: App {
    @StateObject private var model = WatchModel()

    var body: some Scene {
        WindowGroup {
            WatchHomeView()
                .environmentObject(model)
        }
    }
}
