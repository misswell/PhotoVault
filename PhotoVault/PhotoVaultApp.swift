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

/// The app's `ScenePhase`, answerable from **any** hierarchy.
///
/// `@Environment(\.scenePhase)` cannot be trusted everywhere in this app. The
/// detail page is hosted by a `UIHostingController` that
/// `PhotoViewerPresentationBridge` creates by hand and presents itself, and a
/// SwiftUI hierarchy with no `Scene` behind it reads that environment key's
/// **default** value — `.background`. Everything inside the viewer therefore
/// believed the app was backgrounded: a slideshow started from a detail page
/// (its autoplay task guards on the scene being active) sat on the first photo
/// forever, while the very same slideshow started from the grid played fine,
/// and `VideoAssetViewer` refused to start a video.
///
/// This is the single answer, taken from `UIApplication` itself, so it is
/// correct inside the viewer, inside a presentation made from the viewer and
/// in the app's own hierarchy. Screens that live in the app's hierarchy may
/// keep using the environment; anything reachable from the viewer must use
/// this instead.
@MainActor
final class AppSceneState: ObservableObject {
    static let shared = AppSceneState()

    /// The app is in the foreground until the system says otherwise: nothing
    /// can be opened from a backgrounded app, and the first notification
    /// corrects this immediately.
    @Published private(set) var phase: ScenePhase = .active

    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        let signals: [(Notification.Name, ScenePhase)] = [
            (UIApplication.didBecomeActiveNotification, .active),
            (UIApplication.willResignActiveNotification, .inactive),
            (UIApplication.didEnterBackgroundNotification, .background),
        ]
        observers = signals.map { name, phase in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.phase != phase else { return }
                    self.phase = phase
                }
            }
        }
    }
}
