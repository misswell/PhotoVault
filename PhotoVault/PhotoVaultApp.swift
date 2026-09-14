import SwiftUI
import UIKit

@main
struct PhotoVaultApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                #if DEBUG
                // Triggered by `--pv-ai-selfcheck`; answers the questions that
                // can only be settled on real hardware. Detached because it
                // loads the model and opens the index.
                .task {
                    if AISearchSelfCheck.isRequested {
                        await Task.detached(priority: .userInitiated) {
                            await AISearchSelfCheck.run()
                        }.value
                    }
                }
                #endif
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
            // LAN folder screens have no PHCachingImageManager behind them;
            // their decoded thumbnails and viewer frames are ours to release,
            // and the grid ones are re-read from the on-disk cache on return.
            LANFolderImageCache.shared.removeAll()
        }
    }
}
