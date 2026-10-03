import SwiftUI
import UIKit

/// The detail NavigationStack can sit inside both a split-view navigation
/// controller and the home TabView. Hide their chrome for the full-screen
/// viewer, without taking over any navigation delegate or transition.
@MainActor
enum PhotoViewerContainerChrome {
    static func setHidden(_ hidden: Bool, from controller: UIViewController) {
        var ancestor: UIViewController? = controller
        while let current = ancestor {
            if let navigation = current as? UINavigationController {
                navigation.setNavigationBarHidden(hidden, animated: false)
            }
            if let tabs = current as? UITabBarController {
                tabs.setTabBarHidden(hidden, animated: false)
            }
            ancestor = current.parent
        }
    }
}

#if DEBUG
@MainActor
final class PhotoViewerDebugStatus: ObservableObject {
    @Published var cancellationCount = 0
    @Published var sessionProbe = "pending"
}

private struct PhotoViewerDebugStatusView: View {
    @ObservedObject var status: PhotoViewerDebugStatus

    var body: some View {
        VStack(spacing: 0) {
            if ProcessInfo.processInfo.arguments.contains("-viewer-cancel-reentry-probe") {
                Text(String(status.cancellationCount))
                    .accessibilityIdentifier("viewer-cancel-count")
            }
            if ProcessInfo.processInfo.arguments.contains("-viewer-session-ownership-probe") {
                Text(status.sessionProbe)
                    .accessibilityIdentifier("viewer-session-probe")
            }
        }
        .font(.system(size: 1))
        .foregroundStyle(.clear)
        .frame(width: 1, height: 1)
        .allowsHitTesting(false)
    }
}
#endif

/// One viewer session, hosted for real UIKit navigation.
///
/// It is a plain `UIHostingController` — no interaction-overriding container,
/// no dismissal generation bookkeeping, no mirrored animation phase. The system
/// zoom transition is a **navigation** transition now: push in, pop out, and
/// UIKit interpolates between two transitions on its own when the user keeps
/// going. Everything this controller does is report UIKit lifecycle events to
/// the navigator, which turns them into exactly one business decision: "may the
/// grid be touched yet?".
///
/// The previous design had to mirror `DismissalPhase`, generations and a
/// pending-request queue because it owned a *modal* presentation whose
/// cancellation animation could outlive several user intents. A pushed
/// controller has no such gap: the stack is the state.
@MainActor
final class PhotoViewerHostingController: UIHostingController<AnyView> {
    let sessionID: UUID
    let transitionState: PhotoViewerTransitionState

    /// Weak: the navigator owns the screen's session bookkeeping, and a viewer
    /// retained by its own navigator while the navigator is being torn down
    /// would keep the whole screen alive.
    weak var viewerNavigator: PhotoViewerNavigator?

    /// Where the zoom transition finds its source cell. Resolved from *this*
    /// viewer's `transitionState` — never from a shared "current viewer" slot,
    /// which is what let an overlapping pop→push read the wrong session.
    weak var gridTransitionCoordinator: PhotoGridTransitionCoordinator?

    #if DEBUG
    let debugStatus: PhotoViewerDebugStatus
    #endif

    init(sessionID: UUID, transitionState: PhotoViewerTransitionState, rootView: AnyView) {
        self.sessionID = sessionID
        self.transitionState = transitionState
        #if DEBUG
        let debugStatus = PhotoViewerDebugStatus()
        self.debugStatus = debugStatus
        super.init(rootView: AnyView(rootView.overlay(alignment: .topLeading) {
            PhotoViewerDebugStatusView(status: debugStatus)
        }))
        #else
        super.init(rootView: rootView)
        #endif
        // Opaque black so the aspect-fit letterbox reads as a black canvas at
        // rest: the transition's dimming only covers the animated/interactive
        // phases, so a clear background would show the grid through it.
        view.backgroundColor = .black
        // The viewer is full-screen and owns its own top bar.
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }

    #if DEBUG
    /// Counts pull-downs UIKit actually started and then cancelled. A UI test
    /// cannot tell "the viewer bounced back" from "the viewer never reacted", so
    /// this counter is the evidence that each short pull really ran. It is
    /// incremented by the navigator from the transition's own cancellation
    /// callback — never from a synthetic touch.
    func reportInteractiveDismissCancelled() {
        debugStatus.cancellationCount += 1
    }
    #endif

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        photoVaultTraceLaunch("viewer_viewWillAppear \(transitionState.debugLabel)")
        viewerNavigator?.viewerWillAppear(self)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        photoVaultTraceLaunch("viewer_viewIsAppearing \(transitionState.debugLabel)")
        viewerNavigator?.viewerIsAppearing(self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        photoVaultTraceLaunch("viewer_viewDidAppear \(transitionState.debugLabel)")
        viewerNavigator?.viewerDidAppear(self)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        photoVaultTraceLaunch(
            "viewer_viewWillDisappear \(transitionState.debugLabel) "
                + "interactive=\(transitionCoordinator?.initiallyInteractive ?? false)"
        )
        viewerNavigator?.viewerWillDisappear(
            self,
            transitionCoordinator: transitionCoordinator
        )
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        photoVaultTraceLaunch("viewer_viewDidDisappear \(transitionState.debugLabel)")
        viewerNavigator?.viewerDidDisappear(self)
    }
}
