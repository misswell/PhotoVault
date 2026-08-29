import SwiftUI
import UIKit

@main
struct PhotoVaultApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.didReceiveMemoryWarningNotification
                    )
                ) { _ in
                    PhotoImageManager.shared.stopCachingAll()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // Only a real backgrounding releases decode caches; .inactive
            // fires for Control Center, banners and app-switcher
            // pass-throughs, and wiping then would refill every thumbnail
            // on return.
            guard phase == .background else { return }
            PhotoImageManager.shared.dropTransientCaches()
        }
    }
}
