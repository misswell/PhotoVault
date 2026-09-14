import Photos
import SwiftUI
import UIKit

// MARK: - Transition state

/// Live pointer to the photo the viewer is currently showing.
///
/// The zoom transition's source view is resolved when the transition runs,
/// not when the viewer was opened: the user may have swiped dozens of photos
/// (or deleted the opening one) before coming back. Reading the current asset
/// identifier here — never the index the viewer started on — is what makes the
/// zoom-out land on the right grid cell.
@MainActor
final class PhotoViewerTransitionState {
    private(set) var currentIndex: Int
    private(set) var currentAssetIdentifier: String?

    /// Set by the live viewer while it is on screen. Returns true when the
    /// system's interactive zoom dismissal must not engage (image zoomed in,
    /// page transition in flight) so a one-finger drag keeps panning the
    /// photo or the pager instead.
    var interactiveDismissVeto: (() -> Bool)?

    /// The rect inside the presented viewer that currently holds the photo
    /// itself (aspect-fit letterbox excluded). The zoom transition aligns the
    /// source cell to this rect, so the photo — not a full-screen letterbox —
    /// is what morphs into the grid cell. nil means "no preference".
    var zoomAlignmentRectProvider: ((_ containerSize: CGSize) -> CGRect?)?

    init(index: Int, assetIdentifier: String?) {
        self.currentIndex = index
        self.currentAssetIdentifier = assetIdentifier
    }

    func update(index: Int, assetIdentifier: String?) {
        currentIndex = index
        currentAssetIdentifier = assetIdentifier
    }
}

// MARK: - Grid source registry

/// The minimum a grid exposes so the zoom transition can find a source cell.
/// Implemented by both the library grid and the paged unsorted grid.
@MainActor
protocol PhotoGridAssetProviding: AnyObject {
    var assetCount: Int { get }
    func assetIdentifier(at index: Int) -> String?
}

/// Resolves "which grid cell is this photo in?" for the system zoom transition.
///
/// It holds a weak reference to the live collection view instead of building a
/// 100k-entry identifier → index map. The viewer already knows its current
/// index, so the lookup is verified with one comparison and only falls back to
/// a bounded nearby scan when the data source shifted (a photo was deleted, or
/// new photos changed the sort position).
@MainActor
final class PhotoGridTransitionCoordinator: ObservableObject {
    private weak var collectionView: UICollectionView?
    private weak var assetProvider: (any PhotoGridAssetProviding)?

    let viewerTransitionState = PhotoViewerTransitionState(
        index: 0,
        assetIdentifier: nil
    )

    func register(
        collectionView: UICollectionView,
        assetProvider: any PhotoGridAssetProviding
    ) {
        self.collectionView = collectionView
        self.assetProvider = assetProvider
    }

    func unregister(collectionView: UICollectionView) {
        guard self.collectionView === collectionView else { return }
        self.collectionView = nil
        self.assetProvider = nil
    }

    /// The view the system should zoom from or back to. Returning nil makes
    /// UIKit fall back to its default transition; the zoom transition is an
    /// enhancement and must never block opening or closing the viewer.
    func sourceView(index: Int, assetIdentifier: String?) -> UIView? {
        guard let collectionView,
              let provider = assetProvider,
              collectionView.window != nil
        else { return nil }

        guard let resolvedIndex = resolveIndex(
            index: index,
            assetIdentifier: assetIdentifier,
            count: provider.assetCount
        ) else { return nil }

        let indexPath = IndexPath(item: resolvedIndex, section: 0)
        if !collectionView.indexPathsForVisibleItems.contains(indexPath) {
            collectionView.scrollToItem(
                at: indexPath,
                at: .centeredVertically,
                animated: false
            )
            collectionView.layoutIfNeeded()
        }

        guard let cell = collectionView.cellForItem(at: indexPath) as? PhotoGridCell
        else { return nil }
        // Prefer the thumbnail itself so the zoom grows out of the photo
        // rather than an empty cell; fall back to the content view.
        return cell.zoomSourceView
    }

    /// Resolve which item currently holds this asset. The viewer's index is
    /// trusted only after verification; when it no longer matches, scan a
    /// small window around it (deletions shift indexes by a few positions)
    /// before giving up.
    private func resolveIndex(
        index: Int,
        assetIdentifier: String?,
        count: Int
    ) -> Int? {
        guard count > 0, let provider = assetProvider else { return nil }
        let identifier = assetIdentifier.flatMap {
            $0.isEmpty ? nil : $0
        }

        if let identifier {
            if index >= 0, index < count,
               provider.assetIdentifier(at: index) == identifier {
                return index
            }

            let radius = 24
            let lower = max(0, index - radius)
            let upper = min(count - 1, index + radius)
            if lower <= upper {
                for candidate in lower...upper where
                    provider.assetIdentifier(at: candidate) == identifier {
                    return candidate
                }
            }

            // The asset the viewer is showing no longer exists in this grid
            // (it was deleted). Zooming into whatever took its slot would
            // land on the wrong photo, so report "no source" and let UIKit
            // run its plain fade-out instead.
            return nil
        }

        // No identifier yet (an unsorted page may still be resolving): use
        // the index only if valid.
        return (index >= 0 && index < count) ? index : nil
    }
}

// MARK: - Presentation bridge

/// Presents `PhotoViewerView` from a real UIKit presentation so the iOS 26
/// system zoom transition can be attached to it.
///
/// `fullScreenCover` cannot do this: SwiftUI owns the hosting controller and
/// applies its presentation immediately, so `preferredTransition` would be set
/// too late. This bridge builds the hosting controller itself.
/// DEBUG-only touch observer for the zoom-out animation. Sits at window
/// level above the presentation container and passes every touch through;
/// its only job is counting how many hit-tests arrive mid-animation so a
/// "taps don't work until the animation ends" report can be split into
/// "events never reach the window" vs "our view stack swallows them".
final class MidDismissTouchProbe: UIView {
    nonisolated(unsafe) static var touchCount = 0
    nonisolated(unsafe) static var current: MidDismissTouchProbe?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        MidDismissTouchProbe.touchCount += 1
        return nil
    }
}

struct PhotoViewerPresentationBridge<Viewer: View>: UIViewControllerRepresentable {
    let request: PhotoViewerRequest?
    let makeViewer: (PhotoViewerRequest) -> Viewer
    let transitionCoordinator: PhotoGridTransitionCoordinator
    /// A dismissal committed: the zoom-out runs over a live grid, so the
    /// screen should re-enable scrolling and taps right away.
    var onDismissalCommitted: (() -> Void)?
    /// An interactive pull-down was cancelled: the viewer stays on screen,
    /// so the screen must cover the grid again.
    var onDismissalCancelled: (() -> Void)?
    /// The viewer session with this id finished dismissing. A screen can
    /// ignore the callback when a newer open request superseded it.
    var onDismissed: ((UUID?) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let presenter = UIViewController()
        presenter.view.backgroundColor = .clear
        presenter.view.isUserInteractionEnabled = false
        context.coordinator.attach(presenter: presenter)
        return presenter
    }

    func updateUIViewController(_ presenter: UIViewController, context: Context) {
        context.coordinator.onDismissed = onDismissed
        context.coordinator.onDismissalCommitted = onDismissalCommitted
        context.coordinator.onDismissalCancelled = onDismissalCancelled
        context.coordinator.sync(
            presenter: presenter,
            request: request,
            makeViewer: { request in
                PhotoViewerHostingController(rootView: makeViewer(request))
            },
            transitionCoordinator: transitionCoordinator
        )
    }

    static func dismantleUIViewController(
        _ presenter: UIViewController,
        coordinator: Coordinator
    ) {
        coordinator.detach()
    }

    /// The bridge's own hosting controller. Its `viewDidDisappear` is the
    /// safety net that reconciles app state when UIKit ends the presentation
    /// on its own — an interactive zoom pull-down, an ancestor teardown — and
    /// no delegate callback reaches `dismissIfNeeded`'s completion. Without
    /// this the screen would keep `isViewerTransitioning` true forever and
    /// the grid underneath would stay interaction-disabled: the dismissed
    /// viewer looks gone but every tap lands nowhere.
    ///
    /// ⚠️ An interactive pull-down fires `viewWillDisappear` when the DRAG
    /// starts and `viewWillAppear` again when it is cancelled — so the began
    /// hook alone is not a commit signal; the paired cancel hook exists
    /// precisely because a began-but-cancelled dismissal leaves the viewer
    /// on screen.
    final class PhotoViewerHostingController<Root: View>: UIHostingController<Root> {
        var onVanishedWithoutCallback: (() -> Void)?
        /// A dismissal transition started (commit OR an interactive drag
        /// beginning). Only a real dismissal also passes `isBeingDismissed`;
        /// a share sheet covering this viewer does not.
        var onDismissTransitionBegan: (() -> Void)?
        /// An interactive pull-down that began was cancelled: the viewer
        /// stays on screen and everything the began hook released must be
        /// restored.
        var onDismissTransitionCancelled: (() -> Void)?
        private var isDismissTransitionActive = false

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if isBeingDismissed {
                isDismissTransitionActive = true
                onDismissTransitionBegan?()
            }
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            if isDismissTransitionActive {
                isDismissTransitionActive = false
                onDismissTransitionCancelled?()
            }
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            isDismissTransitionActive = false
            onVanishedWithoutCallback?()
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIAdaptivePresentationControllerDelegate {
        private weak var presenter: UIViewController?
        private weak var hosted: UIViewController?
        private var presentedRequestID: UUID?
        private var generation = 0
        private var pendingRequest: PhotoViewerRequest?
        /// Set when a dismissal transition has committed (zoom-out in
        /// flight): a new open request supersedes the dying session instead
        /// of being ignored.
        private var isDismissTransitionInFlight = false
        private var isScheduledPresentRetry = false
        private var makeViewer: ((PhotoViewerRequest) -> PhotoViewerHostingController<Viewer>)?
        private weak var transitionCoordinator: PhotoGridTransitionCoordinator?
        /// Carries the id of the viewer session that finished dismissing, so
        /// the screen can ignore the callback when a newer open request has
        /// already superseded it.
        var onDismissed: ((UUID?) -> Void)?
        /// The dismissal transition committed: the zoom-out now runs over a
        /// live grid, so the screen can re-enable scrolling and taps while
        /// the animation finishes.
        var onDismissalCommitted: (() -> Void)?
        /// An interactive pull-down was cancelled: the viewer stayed on
        /// screen, so the screen must cover the grid again.
        var onDismissalCancelled: (() -> Void)?

        func attach(presenter: UIViewController) {
            self.presenter = presenter
            // SwiftUI may have produced a request before the presenter was in
            // a window; flush it now.
            flushPendingRequest()
        }

        func detach() {
            presenter = nil
            hosted = nil
            presentedRequestID = nil
            pendingRequest = nil
            isDismissTransitionInFlight = false
            isScheduledPresentRetry = false
            makeViewer = nil
            endDismissalInteractionOverride()
        }

        func sync(
            presenter: UIViewController,
            request: PhotoViewerRequest?,
            makeViewer: @escaping (PhotoViewerRequest) -> PhotoViewerHostingController<Viewer>,
            transitionCoordinator: PhotoGridTransitionCoordinator
        ) {
            self.makeViewer = makeViewer
            self.transitionCoordinator = transitionCoordinator

            guard let request else {
                dismissIfNeeded()
                return
            }

            if presentedRequestID == nil {
                pendingRequest = request
                flushPendingRequest()
            } else if isDismissTransitionInFlight,
                      request.id != presentedRequestID {
                // The old viewer is zooming out and the user already tapped
                // the next photo: supersede the dying session instead of
                // dropping the request. The queued open presents the moment
                // the presenter is free. The dismissing session's OWN request
                // also re-arrives here whenever the wake-the-grid callback
                // triggers a SwiftUI update — same id, so it is ignored.
                presentedRequestID = nil
                pendingRequest = request
                flushPendingRequest()
            }
            // A different request while a viewer is simply on screen is
            // ignored: the viewer is full-screen and owns its own navigation.
        }

        private func flushPendingRequest() {
            guard presentedRequestID == nil,
                  let request = pendingRequest,
                  let presenter,
                  let makeViewer,
                  let transitionCoordinator,
                  presenter.view.window != nil
            else { return }

            // A previous dismissal may still be animating out. UIKit cannot
            // start a new presentation from this presenter until it is fully
            // gone, so keep the request queued and retry on the main queue
            // instead of dropping it.
            if presenter.presentedViewController != nil {
                schedulePresentRetry()
                return
            }

            pendingRequest = nil
            present(
                request: request,
                presenter: presenter,
                makeViewer: makeViewer,
                transitionCoordinator: transitionCoordinator
            )
        }

        private func schedulePresentRetry() {
            guard !isScheduledPresentRetry else { return }
            isScheduledPresentRetry = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                isScheduledPresentRetry = false
                flushPendingRequest()
            }
        }

        private func present(
            request: PhotoViewerRequest,
            presenter: UIViewController,
            makeViewer: @escaping (PhotoViewerRequest) -> PhotoViewerHostingController<Viewer>,
            transitionCoordinator: PhotoGridTransitionCoordinator
        ) {
            let hosting = makeViewer(request)
            // Opaque black so the aspect-fit letterbox reads as a black
            // canvas at rest: the transition's dimming only covers the
            // animated and interactive phases, not the steady state. The
            // zoom morph still tracks the photo itself because the
            // alignment rect provider reports the fitted image frame.
            hosting.view.backgroundColor = .black
            hosting.modalPresentationStyle = .overFullScreen
            hosting.modalTransitionStyle = .crossDissolve
            // Must stay false: the zoom transition's interactive pull-down
            // dismissal is the presentation controller's own gesture, and
            // `isModalInPresentation` disables exactly that gesture.
            hosting.isModalInPresentation = false

            let controller = transitionCoordinator
            let reduceMotion = UIAccessibility.isReduceMotionEnabled
            hosting.preferredTransition = Self.zoomTransition(
                coordinator: controller,
                reduceMotion: reduceMotion
            )

            transitionCoordinator.viewerTransitionState.update(
                index: request.index,
                assetIdentifier: request.assetIdentifier
            )

            presentedRequestID = request.id
            isDismissTransitionInFlight = false
            generation &+= 1
            let currentGeneration = generation

            ViewerPerformanceTrace.viewerPresentStart()
            presenter.present(hosting, animated: !reduceMotion) { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.hosted = hosting
                // `presentationController` does not exist until the
                // presentation is underway, so this cannot be installed
                // before `present(_:animated:completion:)`.
                hosting.presentationController?.delegate = self
                // Safety net for any dismissal UIKit starts on its own: if
                // the hosting view goes away while the bridge still believes
                // a presentation is active, reconcile app state. Idempotent —
                // a programmatic dismissal already cleared the bookkeeping by
                // the time this runs.
                hosting.onVanishedWithoutCallback = { [weak self] in
                    self?.hostedViewDidVanish()
                }
                // Commit point of every dismissal: the zoom-out now runs over
                // a live grid.
                hosting.onDismissTransitionBegan = { [weak self] in
                    self?.dismissTransitionBegan()
                }
                hosting.onDismissTransitionCancelled = { [weak self] in
                    self?.dismissTransitionCancelled()
                }
                photoVaultTrace("viewer_present_complete")
                Self.debugDumpTransitionGestures(
                    presentationController: hosting.presentationController
                )
            }
        }

        /// A dismissal started — either a committed close-button zoom-out or
        /// the BEGINNING of an interactive pull-down drag (UIKit fires
        /// `viewWillDisappear` at drag start; a cancel comes back through
        /// `dismissTransitionCancelled`). Hand touches straight through the
        /// presentation container so the user can scroll the grid — or open
        /// the next photo — without waiting for the animation.
        private func dismissTransitionBegan() {
            photoVaultTrace("viewer_dismiss_transition_began")
            isDismissTransitionInFlight = true
            releasePresentationContainerInteraction()
            onDismissalCommitted?()
        }

        /// An interactive pull-down was cancelled: the viewer stays on
        /// screen, so everything `dismissTransitionBegan` released must be
        /// restored — a disabled container here would leave a live viewer
        /// that no touch can reach.
        private func dismissTransitionCancelled() {
            guard isDismissTransitionInFlight else { return }
            photoVaultTrace("viewer_dismiss_transition_cancelled")
            isDismissTransitionInFlight = false
            endDismissalInteractionOverride()
            restorePresentationContainerInteraction()
            onDismissalCancelled?()
        }

        private var interactionReassertTimer: Timer?
        private var interactionReassertTicksRemaining = 0

        private func releasePresentationContainerInteraction() {
            guard let container = presentationContainer() else { return }
            container.isUserInteractionEnabled = false
            #if DEBUG
            installMidDismissProbe(container: container)
            #endif
            // UIKit's transition bookkeeping can re-enable the container when
            // the interactive drag commits — its setup runs AFTER the
            // `viewWillDisappear` hook that disabled it, and a re-enabled
            // container swallows every touch for the rest of the zoom-out
            // (the "动画没结束就不能操作" symptom). Re-assert the disabled
            // state for the first moment of the animation; the container is
            // torn down with the dismissal anyway.
            interactionReassertTimer?.invalidate()
            interactionReassertTicksRemaining = 10
            interactionReassertTimer = Timer.scheduledTimer(
                withTimeInterval: 0.08,
                repeats: true
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.interactionReassertTick()
                }
            }
        }

        @MainActor
        private func interactionReassertTick() {
            defer {
                interactionReassertTicksRemaining -= 1
                if interactionReassertTicksRemaining <= 0 {
                    interactionReassertTimer?.invalidate()
                    interactionReassertTimer = nil
                }
            }
            guard isDismissTransitionInFlight,
                  let container = presentationContainer()
            else {
                interactionReassertTimer?.invalidate()
                interactionReassertTimer = nil
                return
            }
            if container.isUserInteractionEnabled {
                photoVaultTrace(
                    "container_interaction_reasserted (UIKit re-enabled it)"
                )
                container.isUserInteractionEnabled = false
            }
        }

        private func stopInteractionReassert() {
            interactionReassertTimer?.invalidate()
            interactionReassertTimer = nil
        }

        /// DEBUG: a window-level pass-through observer above the transition
        /// view, so mid-animation touches can be counted.
        fileprivate func installMidDismissProbe(container: UIView) {
            MidDismissTouchProbe.current?.removeFromSuperview()
            guard let window = container.window else { return }
            MidDismissTouchProbe.touchCount = 0
            let probe = MidDismissTouchProbe(frame: window.bounds)
            probe.isUserInteractionEnabled = true
            probe.backgroundColor = .clear
            window.addSubview(probe)
            MidDismissTouchProbe.current = probe
        }

        fileprivate func endDismissalInteractionOverride() {
            stopInteractionReassert()
            #if DEBUG
            MidDismissTouchProbe.current?.removeFromSuperview()
            MidDismissTouchProbe.current = nil
            if MidDismissTouchProbe.touchCount > 0 {
                photoVaultTrace(
                    "mid_dismiss_touches=\(MidDismissTouchProbe.touchCount)"
                )
            }
            MidDismissTouchProbe.touchCount = 0
            #endif
        }

        private func restorePresentationContainerInteraction() {
            guard let container = presentationContainer() else { return }
            container.isUserInteractionEnabled = true
        }

        /// The presentation container is the view directly below the window
        /// (UITransitionView for modal presentations). Walking all the way up
        /// would reach the window itself — disabling that would freeze the
        /// whole app.
        private func presentationContainer() -> UIView? {
            guard let hosted else { return nil }
            var container = hosted.view.superview
            while let parent = container?.superview, !(parent is UIWindow) {
                container = parent
            }
            return container
        }

        /// Runs when the presented viewer's view disappeared but the bridge
        /// still had it registered — i.e. UIKit dismissed it without our
        /// `dismissIfNeeded` completing. Reset the bookkeeping exactly like
        /// the programmatic path does, and tell the screen so the grid wakes
        /// back up.
        private func hostedViewDidVanish() {
            guard presentedRequestID != nil else { return }
            let dismissedID = presentedRequestID
            photoVaultTrace("viewer_hosted_view_did_vanish")
            presentedRequestID = nil
            isDismissTransitionInFlight = false
            hosted = nil
            endDismissalInteractionOverride()
            generation &+= 1
            ViewerPerformanceTrace.viewerDismissStart()
            ViewerPerformanceTrace.viewerDismissEnd()
            onDismissed?(dismissedID)
        }

        private static func zoomTransition(
            coordinator: PhotoGridTransitionCoordinator,
            reduceMotion: Bool
        ) -> UIViewController.Transition {
            let options = UIViewController.Transition.ZoomOptions()
            options.dimmingColor = .black
            if !reduceMotion {
                // The viewer raises this while the photo is zoomed in or a
                // page transition is in flight: a one-finger drag then belongs
                // to panning the photo or the pager, not to dismissal.
                options.interactiveDismissShouldBegin = { [weak coordinator] context in
                    guard let coordinator else { return false }
                    photoVaultTrace(
                        "zoom_dismiss_should_begin willBegin=\(context.willBegin) "
                            + "velY=\(Int(context.velocity.dy))"
                    )
                    let vetoed = coordinator.viewerTransitionState
                        .interactiveDismissVeto?() ?? false
                    return !vetoed
                }
                // Align the morph with the photo itself (aspect-fit letterbox
                // excluded) so the zoom grows out of and lands on the image,
                // not the full-screen container.
                options.alignmentRectProvider = { [weak coordinator] context in
                    guard let coordinator else { return nil }
                    return coordinator.viewerTransitionState
                        .zoomAlignmentRectProvider?(
                            context.zoomedViewController.view.bounds.size
                        )
                }
            }
            return .zoom(options: options) { [weak coordinator] _ in
                guard !reduceMotion, let coordinator else { return nil }
                return coordinator.sourceView(
                    index: coordinator.viewerTransitionState.currentIndex,
                    assetIdentifier: coordinator.viewerTransitionState.currentAssetIdentifier
                )
            }
        }

        /// One-time DEBUG census of the gesture recognizers UIKit installs on
        /// the presentation container and presented view. Used to diagnose why
        /// the interactive zoom pull-down may never begin; remove once the
        /// pull-down is verified on device.
        private static func debugDumpTransitionGestures(
            presentationController: UIPresentationController?
        ) {
            #if DEBUG
            guard let presentationController else {
                photoVaultTrace("gesture_dump no_presentation_controller")
                return
            }
            func dump(view: UIView, path: String) {
                let recognizers = (view.gestureRecognizers ?? [])
                    .map { "\($0.name ?? String(describing: type(of: $0)))" }
                    .joined(separator: ",")
                if !recognizers.isEmpty {
                    photoVaultTrace("gesture_dump \(path)<\(type(of: view))> [\(recognizers)]")
                }
                for subview in view.subviews {
                    dump(view: subview, path: path + "->")
                }
            }
            if let containerView = presentationController.containerView {
                for subview in containerView.subviews {
                    dump(view: subview, path: "container")
                }
            } else {
                photoVaultTrace("gesture_dump no_container_view")
            }
            #endif
        }

        private func dismissIfNeeded() {
            guard presentedRequestID != nil else {
                let voidedID = pendingRequest?.id
                pendingRequest = nil
                onDismissed?(voidedID)
                return
            }
            let dismissedID = presentedRequestID
            presentedRequestID = nil
            isDismissTransitionInFlight = false
            generation &+= 1
            let presenter = self.presenter
            let hosted = self.hosted
            guard let target = hosted ?? presenter?.presentedViewController else {
                // Nothing is actually on screen; treat the request as already
                // settled instead of leaving the grid paused forever.
                photoVaultTrace("viewer_dismiss_no_target")
                ViewerPerformanceTrace.viewerDismissStart()
                ViewerPerformanceTrace.viewerDismissEnd()
                onDismissed?(dismissedID)
                return
            }
            ViewerPerformanceTrace.viewerDismissStart()
            target.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { [weak self, weak target] in
                guard let self else { return }
                // A newer session may already own `hosted` (the user opened
                // the next photo while this zoom-out was running) — don't
                // clobber its bookkeeping.
                if self.hosted === target {
                    self.hosted = nil
                }
                self.endDismissalInteractionOverride()
                ViewerPerformanceTrace.viewerDismissEnd()
                photoVaultTrace("viewer_dismiss_complete")
                self.onDismissed?(dismissedID)
            }
        }

        /// Safety net for a dismissal UIKit starts on its own (for example if
        /// an ancestor is torn down). Keeps the grid's active state in sync.
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            photoVaultTrace("viewer_presentation_controller_did_dismiss")
            guard presentedRequestID != nil else { return }
            let dismissedID = presentedRequestID
            presentedRequestID = nil
            hosted = nil
            generation &+= 1
            endDismissalInteractionOverride()
            onDismissed?(dismissedID)
        }
    }
}
