import SwiftUI

@main
struct PhotoVaultApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            // Only a real backgrounding releases decode caches; .inactive
            // fires for Control Center, banners and app-switcher
            // pass-throughs, and wiping then would refill every thumbnail
            // on return.
            guard phase == .background else { return }
            PhotoImageManager.shared.dropTransientCaches()
            PhotoImageManager.shared.cancelRequests(exactly: .slideshow)
        }
    }
}
