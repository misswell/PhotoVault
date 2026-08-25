import SwiftUI

@main
struct PhotoVaultApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            PhotoImageManager.shared.stopCachingAll()
            PhotoImageManager.shared.cancelRequests(exactly: .slideshow)
        }
    }
}
