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

    private(set) var viewerTransitionState = PhotoViewerTransitionState(
        index: 0,
        assetIdentifier: nil
    )

    func beginViewerSession(index: Int, assetIdentifier: String?) {
        // Outgoing and incoming viewers may coexist during a system zoom.
        // Their callbacks must never clear or retarget each other's state.
        viewerTransitionState = PhotoViewerTransitionState(
            index: index, assetIdentifier: assetIdentifier
        )
    }

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

    /// True when `view` is the registered grid or one of its ancestors, so
    /// disabling `view`'s touches would disable the grid's too.
    ///
    /// The dismissal override walks up from the viewer looking for the highest
    /// view that is still the viewer's own; this is the fence that stops it
    /// from crossing into a shared ancestor (the transition root, a SwiftUI
    /// wrapper, the window) and taking the grid down with it.
    func containsRegisteredGrid(in view: UIView) -> Bool {
        guard let collectionView else { return false }
        return collectionView === view || collectionView.isDescendant(of: view)
    }

    /// Re-enable the grid's touches the moment a dismissal commits, instead of
    /// waiting for the next SwiftUI update to push `isActive` back down. The
    /// SwiftUI state still changes; this only removes the one-frame gap during
    /// which the zoom-out is already running over a grid that cannot be touched.
    func setGridInteractionEnabled(_ enabled: Bool) {
        collectionView?.isUserInteractionEnabled = enabled
    }

    #if DEBUG
    /// The single question this fix turns on: while the zoom-out is running,
    /// would a touch at a grid cell reach the grid? Asked with a real
    /// `hitTest` so the answer reflects the actual view stack rather than the
    /// state the bridge believes it set.
    func debugHitTestProbe() -> String {
        guard let collectionView, let window = collectionView.window else {
            return "grid=no-window"
        }
        let point = collectionView.convert(
            CGPoint(x: collectionView.bounds.midX, y: collectionView.bounds.midY),
            to: window
        )
        guard let hit = window.hitTest(point, with: nil) else {
            return "grid=hitTest-nil enabled=\(collectionView.isUserInteractionEnabled)"
        }
        let reached = hit === collectionView || hit.isDescendant(of: collectionView)
        return "grid=reached:\(reached) hit=\(String(describing: type(of: hit))) "
            + "enabled=\(collectionView.isUserInteractionEnabled)"
    }
    #endif

    #if DEBUG
    /// Test-only input through the same delegate as a real grid selection.
    func debugSelectPhoto(at index: Int) {
        guard let collectionView, index < collectionView.numberOfItems(inSection: 0) else { return }
        let path = IndexPath(item: index, section: 0)
        guard let cell = collectionView.cellForItem(at: path),
              let window = cell.window else { return }
        let point = cell.convert(CGPoint(x: cell.bounds.midX, y: cell.bounds.midY), to: window)
        let hit = window.hitTest(point, with: nil)
        let reached = hit === cell || hit?.isDescendant(of: cell) == true
        photoVaultTraceLaunch("interruption_probe_grid_hit=\(reached)")
        guard reached else { return }
        collectionView.delegate?.collectionView?(collectionView, didSelectItemAt: path)
    }
    #endif

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
        /// Carries the controller itself so a late `viewDidDisappear` from an
        /// already-settled viewer cannot be mistaken for the current one.
        var onVanishedWithoutCallback: ((UIViewController) -> Void)?
        /// A dismissal transition is starting; `interactive` says whether UIKit
        /// is driving it from the zoom transition's pull-down gesture, which
        /// can still be cancelled.
        var onDismissTransitionBegan: ((_ interactive: Bool) -> Void)?
        /// An interactive pull-down that began was cancelled: the viewer stays
        /// on screen and everything the began hook released must be restored.
        var onDismissTransitionCancelled: (() -> Void)?
        /// An interactive pull-down passed the commit threshold: the zoom-out
        /// will finish, so the grid can come back while it plays.
        var onDismissTransitionCommitted: (() -> Void)?
        /// DEBUG: lets the bridge ask the hit-test question from inside the
        /// transition's own animation block, rather than before it starts.
        var onTransitionAnimationStep: (() -> Void)?
        /// Only a drag that actually began may report an outcome.
        private var isInteractiveDismissActive = false

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // A share sheet covering the viewer also reaches here; only a real
            // dismissal has `isBeingDismissed` set.
            guard isBeingDismissed else { return }

            guard let coordinator = transitionCoordinator else {
                // Nothing to observe, and a dismissal is by definition not
                // cancellable at this point.
                onDismissTransitionBegan?(false)
                onDismissTransitionCommitted?()
                return
            }

            let interactive = coordinator.initiallyInteractive
            if interactive { isInteractiveDismissActive = true }
            onDismissTransitionBegan?(interactive)

            // DEBUG: step inside the transition's animation block so the
            // "can the grid be touched yet?" question is answered while the
            // zoom-out is actually running, not before or after it.
            coordinator.animate(alongsideTransition: { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.onTransitionAnimationStep?()
                }
            }, completion: nil)

            guard interactive else {
                // Close button and every programmatic exit: not cancellable, so
                // the dismissal is committed the moment it starts.
                onDismissTransitionCommitted?()
                return
            }

            // ⚠️ `viewWillDisappear` fires when the DRAG starts, so it is not a
            // commit signal — a short drag returns through `viewWillAppear`. The
            // transition coordinator is the only trustworthy source: it reports
            // once when the interaction ends, and `isCancelled` says which way.
            coordinator.notifyWhenInteractionChanges { [weak self] context in
                MainActor.assumeIsolated {
                    guard let self, self.isInteractiveDismissActive else { return }
                    self.isInteractiveDismissActive = false
                    if context.isCancelled {
                        self.onDismissTransitionCancelled?()
                    } else {
                        self.onDismissTransitionCommitted?()
                    }
                }
            }
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            // Fallback for a cancelled drag whose coordinator callback never
            // arrived: the viewer is coming back and must be reachable again.
            // Idempotent — the bridge ignores a cancel when nothing is in
            // flight.
            if isInteractiveDismissActive {
                isInteractiveDismissActive = false
                onDismissTransitionCancelled?()
            }
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            isInteractiveDismissActive = false
            onVanishedWithoutCallback?(self)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIAdaptivePresentationControllerDelegate {
        /// How far the current dismissal has got.
        ///
        /// The old code collapsed "a drag began" and "the viewer is going away"
        /// into one boolean, so a cancelled pull-down was indistinguishable from
        /// a committed close — and the grid was released for both.
        private enum DismissalPhase {
            case idle
            /// An interactive pull-down is being dragged. UIKit may still
            /// cancel it, so nothing may be released yet.
            case interactive
            /// The dismissal will finish. The zoom-out is running and the grid
            /// may take touches again.
            case committed
        }

        private weak var presenter: UIViewController?
        private weak var hosted: UIViewController?
        /// The current session. A committed outgoing session moves into
        /// retiringSessions when a new tap arrives, allowing UIKit to overlap
        /// the two zooms without letting old callbacks settle the new viewer.
        private var presentedRequestID: UUID?
        private var generation = 0
        #if DEBUG
        private var didRunInterruptionProbe = false
        #endif
        private var pendingRequest: PhotoViewerRequest?
        private var dismissalPhase: DismissalPhase = .idle
        private var retiringSessions: [UUID: (controller: UIViewController, interactionRoot: UIView?)] = [:]
        /// The highest ancestor that belongs to the viewer alone and was
        /// therefore safe to take out of hit testing. Never the grid, its
        /// ancestors, the window or the shared transition root.
        private weak var outgoingInteractionRoot: UIView?
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
            dismissalPhase = .idle
            makeViewer = nil
            restoreViewerInteraction()
            for session in retiringSessions.values {
                session.interactionRoot?.isUserInteractionEnabled = true
            }
            retiringSessions.removeAll()
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
            } else if request.id != presentedRequestID,
                      dismissalPhase != .idle {
                pendingRequest = request
                if dismissalPhase == .committed, let hosted,
                   hosted.isBeingDismissed, let presentedRequestID {
                    // UIKit's zoom can accept a new presentation during the
                    // outgoing zoom. Do not serialize taps behind its completion.
                    // UIKit may reuse the transition container for the new
                    // viewer. Only the outgoing view remains disabled now.
                    restoreViewerInteraction()
                    hosted.view.isUserInteractionEnabled = false
                    retiringSessions[presentedRequestID] = (hosted, hosted.view)
                    self.hosted = nil
                    self.presentedRequestID = nil
                    dismissalPhase = .idle
                    photoVaultTraceLaunch("viewer_reopen_during_dismissal")
                    flushPendingRequest()
                }
            }
            // A different request while a viewer is simply on screen
            // (phase == .idle) is ignored: the viewer is full-screen and owns
            // its own navigation.
        }

        /// Presents on first open, a new tap during committed dismissal, or
        /// lifecycle completion. No animation-completion gate or retry loop.
        private func flushPendingRequest() {
            guard presentedRequestID == nil,
                  let request = pendingRequest,
                  let presenter,
                  let makeViewer,
                  let transitionCoordinator,
                  presenter.view.window != nil
            else { return }

            guard presenter.presentedViewController == nil
                || presenter.presentedViewController?.isBeingDismissed == true else {
                // An unrelated live presentation still owns this presenter.
                // A dismissing zoom is explicitly allowed through above.
                photoVaultTrace("pending_viewer_request_deferred")
                return
            }

            pendingRequest = nil
            photoVaultTrace("pending_viewer_request_presented")
            present(
                request: request,
                presenter: presenter,
                makeViewer: makeViewer,
                transitionCoordinator: transitionCoordinator
            )
        }

        private func present(
            request: PhotoViewerRequest,
            presenter: UIViewController,
            makeViewer: @escaping (PhotoViewerRequest) -> PhotoViewerHostingController<Viewer>,
            transitionCoordinator: PhotoGridTransitionCoordinator
        ) {
            transitionCoordinator.beginViewerSession(
                index: request.index, assetIdentifier: request.assetIdentifier
            )
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
            dismissalPhase = .idle
            generation &+= 1
            let currentGeneration = generation

            // Install all lifecycle hooks before present: a downward drag can
            // interrupt zoom-in before its presentation completion is called.
            hosted = hosting
            hosting.onVanishedWithoutCallback = { [weak self] controller in
                self?.hostedViewDidVanish(controller: controller, sessionID: request.id)
            }
            hosting.onDismissTransitionBegan = { [weak self] interactive in
                guard let self, self.presentedRequestID == request.id else { return }
                self.dismissTransitionBegan(interactive: interactive)
            }
            hosting.onDismissTransitionCancelled = { [weak self] in
                guard let self, self.presentedRequestID == request.id else { return }
                self.dismissTransitionCancelled()
            }
            hosting.onDismissTransitionCommitted = { [weak self] in
                guard let self, self.presentedRequestID == request.id else { return }
                self.dismissTransitionCommitted()
            }
            #if DEBUG
            hosting.onTransitionAnimationStep = { [weak self] in
                guard let self, self.presentedRequestID == request.id else { return }
                self.debugProbeMidTransition()
            }
            #endif

            ViewerPerformanceTrace.viewerPresentStart()
            presenter.present(hosting, animated: !reduceMotion) { [weak self] in
                guard let self, self.generation == currentGeneration,
                      self.hosted === hosting else { return }
                photoVaultTrace("viewer_present_complete")
                Self.debugDumpTransitionGestures(
                    presentationController: hosting.presentationController
                )
            }
            hosting.presentationController?.delegate = self
            #if DEBUG
            if !didRunInterruptionProbe,
               ProcessInfo.processInfo.arguments.contains("-viewer-interruption-probe") {
                didRunInterruptionProbe = true
                // One-shot synthetic actions inside real UIKit transitions;
                // XCUITest itself waits for animation idle before injecting input.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak hosting] in
                    guard let self, let hosting, self.hosted === hosting else { return }
                    photoVaultTraceLaunch("interruption_probe_open_active=\(hosting.transitionCoordinator != nil)")
                    self.dismissIfNeeded()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak hosting] in
                        guard let self, let hosting else { return }
                        photoVaultTraceLaunch("interruption_probe_dismiss_active=\(hosting.isBeingDismissed && hosting.transitionCoordinator != nil)")
                        self.transitionCoordinator?.debugSelectPhoto(at: 2)
                    }
                }
            }
            #endif
        }

        /// A dismissal transition is starting. `interactive` distinguishes the
        /// system's pull-down (still cancellable) from a close button or any
        /// programmatic exit (already committed) — see `DismissalPhase`.
        private func dismissTransitionBegan(interactive: Bool) {
            photoVaultTrace(
                "viewer_dismiss_transition_began interactive=\(interactive)"
            )
            guard dismissalPhase == .idle else { return }
            // The commit hook owns both the phase and the interaction release.
            // Setting committed here would make that hook return too early.
            if interactive { dismissalPhase = .interactive }
        }

        /// The zoom-out will finish: the grid may take touches again and the
        /// viewer's own subtree stops hit testing, so the rest of the animation
        /// plays over a fully live grid. Nothing here touches alpha, transform,
        /// frame or the transition itself.
        private func dismissTransitionCommitted() {
            guard dismissalPhase != .committed else { return }
            photoVaultTrace("viewer_dismiss_committed")
            dismissalPhase = .committed

            // Re-enable the grid directly as well as through SwiftUI state:
            // the state update lands a frame later, and the whole point is that
            // scrolling and tapping work while the zoom-out is still running.
            transitionCoordinator?.setGridInteractionEnabled(true)
            photoVaultTrace("grid_interaction_enabled")

            let root = outgoingViewerInteractionRoot()
            outgoingInteractionRoot = root
            root?.isUserInteractionEnabled = false
            photoVaultTrace(
                "viewer_interaction_root_disabled "
                    + "class=\(root.map { String(describing: type(of: $0)) } ?? "nil")"
            )
            #if DEBUG
            debugTraceInteractionHierarchy()
            photoVaultTrace(
                "dismiss_probe "
                    + (transitionCoordinator?.debugHitTestProbe() ?? "no-coordinator")
            )
            // Only non-nil on the interactive path, which commits mid-transition.
            installMidTransitionProbe()
            #endif

            onDismissalCommitted?()
        }

        /// An interactive pull-down was cancelled: the viewer stays on screen,
        /// so everything the commit path released must be restored — a disabled
        /// viewer here would leave a live viewer that no touch can reach.
        private func dismissTransitionCancelled() {
            guard dismissalPhase != .idle else { return }
            photoVaultTrace("viewer_dismiss_cancelled")
            dismissalPhase = .idle
            restoreViewerInteraction()
            transitionCoordinator?.setGridInteractionEnabled(false)
            onDismissalCancelled?()
        }

        /// Give the viewer's touches back and cover the grid again.
        private func restoreViewerInteraction() {
            outgoingInteractionRoot?.isUserInteractionEnabled = true
            outgoingInteractionRoot = nil
        }

        /// The highest view that is still the viewer's own branch of the
        /// hierarchy — the only thing safe to take out of hit testing.
        ///
        /// Walking straight up to the window is what broke this before: the
        /// view below the window (UITransitionView or a SwiftUI wrapper) can be
        /// a shared ancestor of the viewer *and* the grid, so disabling it
        /// disabled the grid too and nothing responded until the animation
        /// ended. Stop as soon as the next ancestor would contain the grid.
        private func outgoingViewerInteractionRoot() -> UIView? {
            guard let hostedView = hosted?.view
                ?? presenter?.presentedViewController?.view
            else { return nil }

            var candidate = hostedView
            var current = hostedView.superview
            while let view = current, !(view is UIWindow) {
                if transitionCoordinator?.containsRegisteredGrid(in: view) == true {
                    break
                }
                candidate = view
                current = view.superview
            }
            return candidate
        }

        #if DEBUG
        /// The hit-test question asked from inside the running transition.
        private func debugProbeMidTransition() {
            // An interactive drag registers this at DRAG START, when the viewer
            // is still supposed to own the touch (the drag can still cancel).
            // Only a committed dismissal may report a hit-test answer.
            guard dismissalPhase == .committed else {
                photoVaultTrace("dismiss_probe_mid_transition phase=interactive")
                return
            }
            photoVaultTrace(
                "dismiss_probe_mid_transition "
                    + (transitionCoordinator?.debugHitTestProbe() ?? "no-coordinator")
            )
        }

        /// DEBUG: the interactive path only reaches `.committed` while the
        /// transition is already running, so it has to register here rather
        /// than in `viewWillDisappear`.
        private func installMidTransitionProbe() {
            guard let transition = hosted?.transitionCoordinator else { return }
            transition.animate(alongsideTransition: { [weak self] _ in
                MainActor.assumeIsolated { self?.debugProbeMidTransition() }
            }, completion: nil)
        }
        #endif

        #if DEBUG
        /// One-shot census of the dismissal hierarchy: for every ancestor of
        /// the viewer, whether it also contains the grid. This is the evidence
        /// that the interaction override stayed inside the viewer's branch.
        private func debugTraceInteractionHierarchy() {
            guard let hostedView = hosted?.view else { return }
            var view: UIView? = hostedView
            var depth = 0
            while let current = view, !(current is UIWindow) {
                let containsGrid = transitionCoordinator?
                    .containsRegisteredGrid(in: current) == true
                photoVaultTrace(
                    "dismiss_hierarchy depth=\(depth) "
                        + "class=\(String(describing: type(of: current))) "
                        + "containsGrid=\(containsGrid) "
                        + "interaction=\(current.isUserInteractionEnabled)"
                )
                view = current.superview
                depth += 1
            }
        }
        #endif

        /// Runs when the presented viewer's view disappeared but the bridge
        /// still had it registered — i.e. UIKit dismissed it without our
        /// `dismissIfNeeded` completing (the system's interactive pull-down).
        /// `controller` identifies the session: a late `viewDidDisappear` from
        /// an already-settled viewer must not tear down the one that replaced
        /// it.
        private func hostedViewDidVanish(controller: UIViewController, sessionID: UUID) {
            guard hosted === controller
                || retiringSessions[sessionID]?.controller === controller else { return }
            photoVaultTrace("viewer_hosted_view_did_vanish")
            ViewerPerformanceTrace.viewerDismissStart()
            finishDismissal(sessionID: sessionID)
        }

        /// The single settle point of every dismissal. The programmatic
        /// `dismiss` completion, UIKit ending the presentation on its own and
        /// the presentation-controller delegate all funnel here, and matching
        /// the session id makes it idempotent so the routes cannot fight each
        /// other.
        private func finishDismissal(sessionID: UUID?) {
            guard let sessionID else { return }
            if let retired = retiringSessions.removeValue(forKey: sessionID) {
                retired.interactionRoot?.isUserInteractionEnabled = true
                photoVaultTraceLaunch("viewer_retired_dismiss_complete")
                onDismissed?(sessionID)
                return
            }
            guard presentedRequestID == sessionID else { return }
            photoVaultTrace("viewer_dismiss_complete")
            presentedRequestID = nil
            // Always hand the viewer's touches back before dropping the last
            // reference to it: leaving a view disabled here would strand a live
            // viewer that nothing can reach.
            restoreViewerInteraction()
            hosted = nil
            dismissalPhase = .idle
            generation &+= 1
            ViewerPerformanceTrace.viewerDismissEnd()

            // Flush any request that arrived before UIKit marked the old
            // controller as dismissing. Most replacement taps already took
            // the immediate path in sync. Report only this session's ID.
            flushPendingRequest()
            onDismissed?(sessionID)
        }

        private static func zoomTransition(
            coordinator: PhotoGridTransitionCoordinator,
            reduceMotion: Bool
        ) -> UIViewController.Transition {
            let state = coordinator.viewerTransitionState
            let options = UIViewController.Transition.ZoomOptions()
            options.dimmingColor = .black
            if !reduceMotion {
                // The viewer raises this while the photo is zoomed in or a
                // page transition is in flight: a one-finger drag then belongs
                // to panning the photo or the pager, not to dismissal.
                options.interactiveDismissShouldBegin = { context in
                    photoVaultTrace(
                        "zoom_dismiss_should_begin willBegin=\(context.willBegin) "
                            + "velY=\(Int(context.velocity.dy))"
                    )
                    let vetoed = state.interactiveDismissVeto?() ?? false
                    return !vetoed
                }
                // Align the morph with the photo itself (aspect-fit letterbox
                // excluded) so the zoom grows out of and lands on the image,
                // not the full-screen container.
                options.alignmentRectProvider = { context in
                    return state
                        .zoomAlignmentRectProvider?(
                            context.zoomedViewController.view.bounds.size
                        )
                }
            }
            return .zoom(options: options) { [weak coordinator] _ in
                guard !reduceMotion, let coordinator else { return nil }
                return coordinator.sourceView(
                    index: state.currentIndex,
                    assetIdentifier: state.currentAssetIdentifier
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
            // A dismissal is already underway (an interactive drag, or a
            // zoom-out): the repeated `sync(nil)` that a SwiftUI re-render
            // produces must not issue a second `dismiss`.
            guard dismissalPhase == .idle else { return }

            guard let dismissedID = presentedRequestID else {
                // Nothing is presented. Only report a withdrawal when a queued
                // request was actually dropped: this runs on every SwiftUI
                // update, so a plain re-render with no viewer must stay silent.
                guard let voidedID = pendingRequest?.id else { return }
                pendingRequest = nil
                onDismissed?(voidedID)
                return
            }

            generation &+= 1
            let presenter = self.presenter
            guard let target = hosted ?? presenter?.presentedViewController else {
                // Nothing is actually on screen; treat the request as already
                // settled instead of leaving the grid paused forever.
                photoVaultTrace("viewer_dismiss_no_target")
                ViewerPerformanceTrace.viewerDismissStart()
                ViewerPerformanceTrace.viewerDismissEnd()
                presentedRequestID = nil
                hosted = nil
                flushPendingRequest()
                onDismissed?(dismissedID)
                return
            }

            ViewerPerformanceTrace.viewerDismissStart()
            // A programmatic close is not cancellable, so it commits the moment
            // it is issued: the grid comes back for the whole zoom-out, not
            // after it.
            dismissTransitionCommitted()
            target.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { [weak self] in
                self?.finishDismissal(sessionID: dismissedID)
            }
        }

        /// Safety net for a dismissal UIKit starts on its own (for example if
        /// an ancestor is torn down). Keeps the grid's active state in sync.
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            photoVaultTrace("viewer_presentation_controller_did_dismiss")
            // Ignore a stale controller: a presentation that already ended must
            // not settle the session that replaced it.
            guard let hosted,
                  presentationController.presentedViewController === hosted
            else { return }
            finishDismissal(sessionID: presentedRequestID)
        }
    }
}
