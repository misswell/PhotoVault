import Photos
import SwiftUI
import UIKit

// MARK: - Pure dismissal policy (also exercised by tools/test-viewer-dismiss-state.swift)

struct ViewerDismissInteraction {
    private(set) var generation: UInt64 = 0
    private(set) var active: UInt64?
    private(set) var cancelling: UInt64?

    mutating func begin() -> UInt64 {
        generation &+= 1
        active = generation
        // Keep the previous cancellation token: a late appearance callback
        // must compare it with active, never assume it belongs to the new drag.
        return generation
    }

    mutating func cancel(_ token: UInt64) -> Bool {
        guard active == token else { return false }
        cancelling = token
        return true
    }

    mutating func settle(_ token: UInt64) -> Bool {
        guard active == token, cancelling == token else { return false }
        clear()
        return true
    }

    mutating func commit(_ token: UInt64) -> Bool {
        guard active == token else { return false }
        clear()
        return true
    }

    mutating func clear() {
        active = nil
        cancelling = nil
    }
}

func shouldBeginViewerInteractiveDismiss(
    willBegin: Bool, velocityX: CGFloat, velocityY: CGFloat, vetoed: Bool
) -> Bool {
    guard !vetoed else { return false }
    return willBegin || (velocityY > 0 && velocityY >= abs(velocityX) * 1.15)
}

// MARK: - Presentation input

/// Own the presentation's hit-test root rather than letting an internal hosting
/// view reject the entire second touch during UIKit's cancellation animation.
/// UIKit still installs and drives its zoom recognizers on this root.
@MainActor
private final class ViewerInteractionContainerView: UIView {
    var preservesInteractiveInput: (() -> Bool)?
    #if DEBUG
    var onPreservedInput: (() -> Void)?
    #endif

    override var isUserInteractionEnabled: Bool {
        get { super.isUserInteractionEnabled }
        set {
            if !newValue, preservesInteractiveInput?() == true {
                photoVaultTrace("viewer_preserved_interactive_input")
                #if DEBUG
                onPreservedInput?()
                #endif
                return
            }
            super.isUserInteractionEnabled = newValue
        }
    }
}

#if DEBUG
/// Passive window-level diagnostics. Never recognizes or prevents another
/// recognizer, and exists only for an explicitly enabled device repro session.
@MainActor
private final class ViewerTouchDeliveryProbe: UIGestureRecognizer {
    var phase: (() -> String)?
    var viewerSnapshot: ((CGPoint) -> String)?
    private var loggedMove = false

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        loggedMove = false
        record("began", touches: touches)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard !loggedMove else { return }
        loggedMove = true
        record("moved", touches: touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        record("ended", touches: touches)
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        record("cancelled", touches: touches)
        state = .failed
    }

    private func record(_ stage: String, touches: Set<UITouch>) {
        guard let touch = touches.first else { return }
        var chain: [String] = []
        var node = touch.view
        while let current = node, !(current is UIWindow) {
            chain.append("\(type(of: current))(enabled=\(current.isUserInteractionEnabled))")
            node = current.superview
        }
        let point = touch.location(in: view)
        photoVaultTrace("viewer_touch_delivery stage=\(stage) phase=\(phase?() ?? "none") chain=\(chain.joined(separator: "->")) viewer=\(viewerSnapshot?(point) ?? "none")")
    }
}
#endif

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

    /// Where the live viewer session stands with respect to the system's
    /// interactive zoom dismissal.
    ///
    /// Mirrored from `Coordinator.dismissalPhase` — which stays authoritative —
    /// so direction arbitration and lifecycle handling use the same state.
    /// Cancelling is not idle, but must still permit downward arbitration:
    /// failing a recognizer at touch-down loses that entire touch sequence.
    enum InteractiveDismissState {
        /// The viewer is at rest; a new pull-down may be arbitrated.
        case idle
        /// The user is dragging the system's interactive dismissal. It can
        /// still be cancelled, so nothing has been released yet.
        case dragging
        /// UIKit has decided to bounce the drag back, but the reverse
        /// animation is still running. Deliberately **not** `idle`: a
        /// transition is still in flight over this viewer.
        case cancelling
        /// The dismissal passed its commit point and is playing out.
        case committed

        var label: String {
            switch self {
            case .idle: return "idle"
            case .dragging: return "dragging"
            case .cancelling: return "cancelling"
            case .committed: return "committed"
            }
        }
    }

    private(set) var interactiveDismissState: InteractiveDismissState = .idle

    /// Whether a touch that is already travelling may keep arbitrating a
    /// downward pull.
    ///
    /// `.cancelling` answers **yes**. All this gate can ever do is take a drag
    /// away from the pager's *horizontal* pan, and a downward drag never pages
    /// it — so answering “no” cannot redirect the touch to anything useful, it
    /// can only make the pull-down disappear. It is also the wrong instant to
    /// decide: UIKit's bounce-back outlives the finger's first sampled points,
    /// and a recognizer that reports `.failed` at touch-down is finished for
    /// that whole touch sequence even after the bounce settles. That is the
    /// “cancel a pull-down, immediately pull down again, nothing happens” bug.
    ///
    /// `.dragging` and `.committed` answer no: there the system already owns
    /// the drag, or the viewer is on its way out.
    var mayArbitrateDownwardDrag: Bool {
        interactiveDismissState == .idle || interactiveDismissState == .cancelling
    }

    func setInteractiveDismissState(_ state: InteractiveDismissState) {
        interactiveDismissState = state
    }

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
    final class PhotoViewerHostingController<Root: View>: UIViewController {
        private let content: UIHostingController<Root>

        init(rootView: Root) {
            content = UIHostingController(rootView: rootView)
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func loadView() {
            let container = ViewerInteractionContainerView()
            container.backgroundColor = .black
            container.preservesInteractiveInput = { [weak self] in
                self?.interaction.active != nil
            }
            #if DEBUG
            container.onPreservedInput = { [weak self] in
                self?.verifyInteractiveHitTesting(stage: "preserved")
            }
            #endif
            view = container
            addChild(content)
            content.view.backgroundColor = .black
            content.view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(content.view)
            NSLayoutConstraint.activate([
                content.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                content.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                content.view.topAnchor.constraint(equalTo: container.topAnchor),
                content.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
            content.didMove(toParent: self)
        }

        override var childForStatusBarHidden: UIViewController? { content }
        override var childForStatusBarStyle: UIViewController? { content }
        override var childForHomeIndicatorAutoHidden: UIViewController? { content }
        override var childForScreenEdgesDeferringSystemGestures: UIViewController? { content }

        /// Carries the controller itself so a late `viewDidDisappear` from an
        /// already-settled viewer cannot be mistaken for the current one.
        var onVanishedWithoutCallback: ((UIViewController) -> Void)?
        /// A dismissal transition is starting; `interactive` says whether UIKit
        /// is driving it from the zoom transition's pull-down gesture, which
        /// can still be cancelled.
        var onDismissTransitionBegan: ((_ interactive: Bool, _ generation: UInt64?) -> Void)?
        /// An interactive pull-down was cancelled: the viewer stays
        /// on screen and everything the began hook released must be restored.
        /// Fires when the bounce-back has **settled**, not when UIKit decides
        /// to reverse — see `onDismissTransitionCancelling`.
        var onDismissTransitionCancelled: ((UInt64) -> Void)?
        /// UIKit has decided to reverse an interactive pull-down. The viewer
        /// stays on screen, but the reverse animation is still running, so
        /// this is not the same moment as `onDismissTransitionCancelled`.
        var onDismissTransitionCancelling: ((UInt64) -> Void)?
        /// An interactive pull-down passed the commit threshold: the zoom-out
        /// will finish, so the grid can come back while it plays.
        var onDismissTransitionCommitted: ((UInt64?) -> Void)?
        /// DEBUG: lets the bridge ask the hit-test question from inside the
        /// transition's own animation block, rather than before it starts.
        var onTransitionAnimationStep: (() -> Void)?
        /// Only a drag that actually began may report an outcome. Cleared when
        /// the transition settles, not when UIKit decides its outcome.
        private var interaction = ViewerDismissInteraction()
        var isInteractiveDismissActive: Bool { interaction.active != nil }
        #if DEBUG
        private let cancellationCounter = UILabel()
        private var cancellationCount = 0
        private var touchDeliveryProbe: ViewerTouchDeliveryProbe?

        private func verifyInteractiveHitTesting(stage: String) {
            guard ProcessInfo.processInfo.arguments.contains("-viewer-cancel-reentry-probe"),
                  let window = view.window else { return }
            let point = CGPoint(x: window.bounds.midX, y: window.bounds.height * 0.45)
            let hit = window.hitTest(point, with: nil)
            let reachesViewer = hit === view || hit?.isDescendant(of: view) == true
            photoVaultTraceLaunch(
                "viewer_cancel_hit_test stage=\(stage) active=\(String(describing: interaction.active)) "
                    + "cancelling=\(String(describing: interaction.cancelling)) enabled=\(view.isUserInteractionEnabled) "
                    + "reached=\(reachesViewer) hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil")"
            )
            assert(view.isUserInteractionEnabled && reachesViewer,
                   "Cancellable zoom must keep the viewer reachable for the next touch")
        }

        private func installTouchDeliveryProbe() {
            guard touchDeliveryProbe == nil,
                  ProcessInfo.processInfo.arguments.contains("-viewer-cancel-reentry-probe"),
                  let window = view.window else { return }
            let probe = ViewerTouchDeliveryProbe(target: nil, action: nil)
            probe.cancelsTouchesInView = false
            probe.delaysTouchesBegan = false
            probe.delaysTouchesEnded = false
            probe.phase = { [weak self] in
                guard let self else { return "gone" }
                return "active=\(String(describing: self.interaction.active)),cancelling=\(String(describing: self.interaction.cancelling))"
            }
            probe.viewerSnapshot = { [weak self, weak window] point in
                guard let self, let window else { return "gone" }
                let root = self.view!
                let local = root.convert(point, from: window)
                let hit = root.hitTest(local, with: nil)
                let pans = (root.gestureRecognizers ?? []).filter { $0 is UIPanGestureRecognizer }.map {
                    "\($0.name ?? String(describing: type(of: $0))):\($0.state.rawValue):enabled=\($0.isEnabled)"
                }.joined(separator: ",")
                return "enabled=\(root.isUserInteractionEnabled),hidden=\(root.isHidden),alpha=\(root.alpha),hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil"),pans=[\(pans)]"
            }
            window.addGestureRecognizer(probe)
            touchDeliveryProbe = probe
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            guard ProcessInfo.processInfo.arguments.contains("-viewer-cancel-reentry-probe") else { return }
            cancellationCounter.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            cancellationCounter.textColor = .clear
            cancellationCounter.text = "0"
            // A live 1x1 view at the top-left would swallow one point of touch
            // and skew exactly the gesture tests this counter exists for.
            cancellationCounter.isUserInteractionEnabled = false
            cancellationCounter.isAccessibilityElement = true
            cancellationCounter.accessibilityIdentifier = "viewer-cancel-count"
            view.addSubview(cancellationCounter)
        }
        #endif

        private func reportCancellationSettled(generation: UInt64) {
            guard interaction.settle(generation) else {
                photoVaultTrace("viewer_dismiss_stale_cancel_completion generation=\(generation) active=\(String(describing: interaction.active))")
                return
            }
            #if DEBUG
            cancellationCount += 1
            cancellationCounter.text = String(cancellationCount)
            #endif
            onDismissTransitionCancelled?(generation)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // A share sheet covering the viewer also reaches here; only a real
            // dismissal has `isBeingDismissed` set.
            guard isBeingDismissed else { return }

            guard let coordinator = transitionCoordinator else {
                interaction.clear()
                onDismissTransitionBegan?(false, nil)
                onDismissTransitionCommitted?(nil)
                return
            }

            let interactive = coordinator.initiallyInteractive
            let observedGeneration = interactive ? interaction.begin() : nil
            if !interactive { interaction.clear() }
            if interactive { view.isUserInteractionEnabled = true }
            onDismissTransitionBegan?(interactive, observedGeneration)

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
                onDismissTransitionCommitted?(nil)
                return
            }

            guard let observedGeneration else { return }
            coordinator.notifyWhenInteractionChanges { [weak self] context in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard self.interaction.active == observedGeneration else {
                        photoVaultTrace("viewer_dismiss_stale_interaction_change generation=\(observedGeneration) active=\(String(describing: self.interaction.active))")
                        return
                    }
                    if context.isCancelled {
                        guard self.interaction.cancel(observedGeneration) else { return }
                        self.onDismissTransitionCancelling?(observedGeneration)
                        #if DEBUG
                        self.verifyInteractiveHitTesting(stage: "cancelling")
                        #endif
                    } else {
                        guard self.interaction.commit(observedGeneration) else { return }
                        self.onDismissTransitionCommitted?(observedGeneration)
                    }
                }
            }

            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                MainActor.assumeIsolated {
                    guard let self, context.isCancelled else { return }
                    self.reportCancellationSettled(generation: observedGeneration)
                }
            }
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            #if DEBUG
            installTouchDeliveryProbe()
            #endif
            // Only a cancellation decision for the still-active generation can
            // settle here. Appearance from an older reversal cannot clear a new drag.
            guard !isBeingDismissed,
                  let cancelling = interaction.cancelling,
                  interaction.active == cancelling else { return }
            reportCancellationSettled(generation: cancelling)
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            interaction.clear()
            #if DEBUG
            if let probe = touchDeliveryProbe { probe.view?.removeGestureRecognizer(probe) }
            touchDeliveryProbe = nil
            #endif
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
        ///
        /// `.cancelling` exists because "UIKit decided to reverse" and "the
        /// reversal finished" are two different instants. A new system drag may
        /// interrupt cancellation; a queued programmatic close waits for settle.
        /// Every write mirrors the phase into the pager's direction gate.
        private enum DismissalPhase {
            /// The viewer is at rest and a new dismissal may begin.
            case idle
            /// An interactive pull-down is being dragged. UIKit may still
            /// cancel it, so nothing may be released yet.
            case interactive
            /// UIKit has reversed the pull-down, but the bounce-back animation
            /// is still running. Not `idle`: a transition is still in flight
            /// over this viewer, and a second dismissal issued here collides
            /// with it.
            case cancelling
            /// The dismissal will finish. The zoom-out is running and the grid
            /// may take touches again.
            case committed

            var mapsTo: PhotoViewerTransitionState.InteractiveDismissState {
                switch self {
                case .idle: return .idle
                case .interactive: return .dragging
                case .cancelling: return .cancelling
                case .committed: return .committed
                }
            }

            var label: String {
                switch self {
                case .idle: return "idle"
                case .interactive: return "interactive"
                case .cancelling: return "cancelling"
                case .committed: return "committed"
                }
            }
        }

        private weak var presenter: UIViewController?
        private weak var hosted: UIViewController?
        /// The current session. A committed outgoing session moves into
        /// retiringSessions when a new tap arrives, allowing UIKit to overlap
        /// the two zooms without letting old callbacks settle the new viewer.
        private var presentedRequestID: UUID?
        private var generation = 0
        private var activeInteractiveDismissGeneration: UInt64?
        #if DEBUG
        private var isVerifyingDismissLogic = false
        private var didRunInterruptionProbe = false
        private var debugReentryProbeFailures = 0
        #endif
        private var pendingRequest: PhotoViewerRequest?
        /// A dismissal the screen asked for while `dismissIfNeeded` had to
        /// refuse it, because a pull-down was still being dragged or bounced
        /// back. Issued by `dismissTransitionCancelled()` the moment the
        /// bounce-back settles — event-driven, never a timer.
        private var pendingDismissRequest = false
        /// Authoritative dismissal state. Every write is mirrored into
        /// `viewerTransitionState` by `dismissalPhaseChanged(from:)`, so the
        /// pager's downward-intent gate and this state machine can never
        /// disagree.
        private var dismissalPhase: DismissalPhase = .idle {
            didSet {
                if oldValue != dismissalPhase {
                    dismissalPhaseChanged(from: oldValue)
                }
            }
        }
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
            pendingDismissRequest = false
            activeInteractiveDismissGeneration = nil
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

            // A live request cancels any deferred close: the screen has
            // changed its mind about what should be on screen.
            pendingDismissRequest = false

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
                    activeInteractiveDismissGeneration = nil
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

            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-viewer-cancel-reentry-probe") {
                Self.verifyDismissGenerationIsolation()
            }
            #endif
            presentedRequestID = request.id
            activeInteractiveDismissGeneration = nil
            dismissalPhase = .idle
            // A fresh session inherits no debt from whatever closed the last
            // one; replaying a stale close here would dismiss the new viewer.
            pendingDismissRequest = false
            generation &+= 1
            let currentGeneration = generation

            // Install all lifecycle hooks before present: a downward drag can
            // interrupt zoom-in before its presentation completion is called.
            hosted = hosting
            hosting.onVanishedWithoutCallback = { [weak self] controller in
                self?.hostedViewDidVanish(controller: controller, sessionID: request.id)
            }
            hosting.onDismissTransitionBegan = { [weak self] interactive, generation in
                guard let self, self.presentedRequestID == request.id else { return }
                self.dismissTransitionBegan(interactive: interactive, generation: generation)
            }
            hosting.onDismissTransitionCancelling = { [weak self] generation in
                guard let self, self.presentedRequestID == request.id else { return }
                self.dismissTransitionCancelling(generation: generation)
            }
            hosting.onDismissTransitionCancelled = { [weak self] generation in
                guard let self, self.presentedRequestID == request.id else { return }
                self.dismissTransitionCancelled(generation: generation)
            }
            hosting.onDismissTransitionCommitted = { [weak self] generation in
                guard let self, self.presentedRequestID == request.id else { return }
                self.dismissTransitionCommitted(generation: generation)
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

        private func traceDismiss(_ message: String) {
            #if DEBUG
            if isVerifyingDismissLogic {
                photoVaultTrace(message + " synthetic=true")
                return
            }
            #endif
            photoVaultTrace(message)
        }

        /// A dismissal transition is starting. `interactive` distinguishes the
        /// system's pull-down (still cancellable) from a close button or any
        /// programmatic exit (already committed) — see `DismissalPhase`.
        ///
        /// `.cancelling` is accepted as well: if UIKit really begins a new
        /// interactive dismissal before the previous bounce-back settled, that
        /// is a live drag and tracking it beats pretending the reversal is
        /// still in progress.
        private func dismissTransitionBegan(interactive: Bool, generation: UInt64?) {
            guard interactive else {
                activeInteractiveDismissGeneration = nil
                return
            }
            guard let generation else {
                assertionFailure("Interactive dismissal requires a generation")
                return
            }
            guard dismissalPhase == .idle || dismissalPhase == .cancelling else { return }
            let reentered = dismissalPhase == .cancelling
            activeInteractiveDismissGeneration = generation
            dismissalPhase = .interactive
            traceDismiss("viewer_dismiss_interactive_begin generation=\(generation)")
            if reentered {
                traceDismiss("viewer_dismiss_reentered generation=\(generation)")
            }
        }

        /// The zoom-out will finish: the grid may take touches again and the
        /// viewer's own subtree stops hit testing, so the rest of the animation
        /// plays over a fully live grid. Nothing here touches alpha, transform,
        /// frame or the transition itself.
        private func dismissTransitionCommitted(generation: UInt64? = nil) {
            if let generation, generation != activeInteractiveDismissGeneration {
                traceDismiss("viewer_dismiss_stale_commit generation=\(generation) active=\(String(describing: activeInteractiveDismissGeneration))")
                return
            }
            activeInteractiveDismissGeneration = nil
            guard dismissalPhase != .committed else { return }
            traceDismiss("viewer_dismiss_committed generation=\(String(describing: generation))")
            dismissalPhase = .committed

            // Re-enable the grid directly as well as through SwiftUI state:
            // the state update lands a frame later, and the whole point is that
            // scrolling and tapping work while the zoom-out is still running.
            transitionCoordinator?.setGridInteractionEnabled(true)
            traceDismiss("grid_interaction_enabled")

            let root = outgoingViewerInteractionRoot()
            outgoingInteractionRoot = root
            root?.isUserInteractionEnabled = false
            traceDismiss(
                "viewer_interaction_root_disabled "
                    + "class=\(root.map { String(describing: type(of: $0)) } ?? "nil")"
            )
            #if DEBUG
            debugTraceInteractionHierarchy()
            traceDismiss(
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
        ///
        /// Reached only once the bounce-back has actually finished. The moment
        /// UIKit *decides* to reverse is `dismissTransitionCancelling()`.
        /// Keep these distinct so queued programmatic closes are replayed only
        /// after settlement. Direction arbitration does not issue a dismissal
        /// and remains available while UIKit is reversing.
        ///
        /// Only the matching cancellation may settle; a newer interactive
        /// drag must survive every late callback from the previous reversal.
        private func dismissTransitionCancelled(generation: UInt64) {
            guard generation == activeInteractiveDismissGeneration else {
                traceDismiss("viewer_dismiss_stale_cancelled generation=\(generation) active=\(String(describing: activeInteractiveDismissGeneration))")
                return
            }
            guard dismissalPhase == .cancelling else { return }
            traceDismiss("viewer_dismiss_cancelled_settled generation=\(generation)")
            activeInteractiveDismissGeneration = nil
            dismissalPhase = .idle
            restoreViewerInteraction()
            transitionCoordinator?.setGridInteractionEnabled(false)
            onDismissalCancelled?()
            // A close that arrived during the drag or the bounce-back was
            // refused then; now that the viewer is genuinely back at rest this
            // is the only place left to honour it.
            if pendingDismissRequest {
                traceDismiss("viewer_dismiss_deferred_replayed")
                dismissIfNeeded()
            }
        }

        /// Every dismissal state change, in one place: log it, hand the same
        /// value to the shared transition state, and check the invariant that
        /// `.cancelling` is only ever entered from a live drag.
        private func dismissalPhaseChanged(from previous: DismissalPhase) {
            let phase = dismissalPhase
            traceDismiss("viewer_dismiss_phase \(previous.label)->\(phase.label)")
            transitionCoordinator?.viewerTransitionState
                .setInteractiveDismissState(phase.mapsTo)
            #if DEBUG
            assert(
                !(previous == .idle && phase == .cancelling),
                "cancelling 只能由 interactive 进入"
            )
            if !isVerifyingDismissLogic, ProcessInfo.processInfo.arguments
                .contains("-viewer-cancel-reentry-probe") {
                debugCancelReentryProbe(from: previous)
            }
            #endif
        }

        #if DEBUG
        /// Exercises the production Bridge handlers without views or gestures.
        /// This proves callback isolation, never claims mid-animation UI input.
        private static func verifyDismissGenerationIsolation() {
            let probe = Coordinator()
            probe.isVerifyingDismissLogic = true
            var settled = 0
            probe.onDismissalCancelled = { settled += 1 }
            probe.dismissTransitionBegan(interactive: true, generation: 1)
            probe.dismissTransitionCancelling(generation: 1)
            probe.dismissTransitionBegan(interactive: true, generation: 2)
            probe.dismissTransitionCancelled(generation: 1)
            probe.dismissTransitionCancelling(generation: 1)
            probe.dismissTransitionCommitted(generation: 1)
            assert(probe.dismissalPhase == .interactive)
            assert(probe.activeInteractiveDismissGeneration == 2 && settled == 0)
            // Even a matching token cannot settle a drag without a cancel decision.
            probe.dismissTransitionCancelled(generation: 2)
            assert(probe.dismissalPhase == .interactive)
            probe.dismissTransitionCommitted(generation: 2)
            assert(probe.dismissalPhase == .committed)
            assert(probe.activeInteractiveDismissGeneration == nil)

            let cancelled = Coordinator()
            cancelled.isVerifyingDismissLogic = true
            cancelled.onDismissalCancelled = { settled += 1 }
            cancelled.dismissTransitionBegan(interactive: true, generation: 1)
            cancelled.dismissTransitionCancelling(generation: 1)
            cancelled.dismissTransitionCancelled(generation: 1)
            cancelled.dismissTransitionCancelled(generation: 1)
            assert(cancelled.dismissalPhase == .idle && settled == 1)
            assert(cancelled.activeInteractiveDismissGeneration == nil)
            photoVaultTraceLaunch("viewer_dismiss_generation_logic passed=true synthetic=true")
        }

        /// Samples the downward-arbitration gate across a real cancelled drag.
        ///
        /// XCUITest waits for idle before injecting input, so two serial XCTest
        /// drags never land inside UIKit's reverse animation. This does: it
        /// reads the gate at each phase change and re-runs the recognizer's own
        /// direction/gate resolution on the phase that used to swallow the
        /// second pull-down.
        private func debugCancelReentryProbe(from previous: DismissalPhase) {
            guard dismissalPhase != previous else { return }
            let gate = transitionCoordinator?.viewerTransitionState
                .mayArbitrateDownwardDrag ?? false
            switch (previous, dismissalPhase) {
            case (.idle, .interactive):
                photoVaultTraceLaunch(
                    "viewer_cancel_reentry_probe stage=dragging gate=\(gate)"
                )
            case (.cancelling, .interactive):
                photoVaultTraceLaunch("viewer_cancel_reentry_probe stage=reentered generation=\(String(describing: activeInteractiveDismissGeneration))")
            case (.interactive, .cancelling):
                if !gate { debugReentryProbeFailures += 1 }
                ViewerDownwardIntentGesture.debugVerifyCancellationReentry()
                photoVaultTraceLaunch(
                    "viewer_cancel_reentry_probe stage=cancelling gate=\(gate) "
                        + "want=true failures=\(debugReentryProbeFailures)"
                )
                assert(gate, "回弹期间封锁下拉仲裁，第二笔下拉会整笔失效")
            case (.cancelling, .idle):
                if !gate { debugReentryProbeFailures += 1 }
                photoVaultTraceLaunch(
                    "viewer_cancel_reentry_probe stage=settled gate=\(gate) "
                        + "want=true failures=\(debugReentryProbeFailures)"
                )
                assert(gate, "回弹结束后 downward intent 仍被封锁，下拉会被吞掉")
            default:
                break
            }
        }
        #endif

        /// UIKit has decided to reverse the pull-down, but the reverse
        /// animation is only starting. The viewer stays on screen — nothing
        /// released by the commit path needs restoring, because nothing was
        /// released — yet the session is emphatically not idle. Only direction
        /// arbitration remains available; programmatic dismissal still waits
        /// for `dismissTransitionCancelled()`.
        private func dismissTransitionCancelling(generation: UInt64) {
            guard generation == activeInteractiveDismissGeneration else {
                traceDismiss("viewer_dismiss_stale_cancelling generation=\(generation) active=\(String(describing: activeInteractiveDismissGeneration))")
                return
            }
            guard dismissalPhase == .interactive else { return }
            traceDismiss("viewer_dismiss_cancelling generation=\(generation)")
            dismissalPhase = .cancelling
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
            activeInteractiveDismissGeneration = nil
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
                // Preserve UIKit's normal decision and vetoes, but allow a
                // clearly downward pull to grab an in-flight cancellation.
                // Horizontal/zero velocity alone must never override willBegin.
                options.interactiveDismissShouldBegin = { context in
                    let vetoed = state.interactiveDismissVeto?() ?? false
                    let result = shouldBeginViewerInteractiveDismiss(
                        willBegin: context.willBegin,
                        velocityX: context.velocity.dx,
                        velocityY: context.velocity.dy,
                        vetoed: vetoed
                    )
                    photoVaultTrace(
                        "zoom_dismiss_should_begin willBegin=\(context.willBegin) "
                            + "velX=\(context.velocity.dx) velY=\(context.velocity.dy) "
                            + "state=\(state.interactiveDismissState.label) vetoed=\(vetoed) result=\(result)"
                    )
                    return result
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
            // A dismissal is already underway (an interactive drag, a
            // bounce-back still settling, or a zoom-out): the repeated
            // `sync(nil)` that a SwiftUI re-render produces must not issue a
            // second `dismiss`.
            guard dismissalPhase == .idle else {
                // Remember the ask. `.cancelling` can outlive this call by a
                // few hundred milliseconds, and nothing else would ever retry
                // it — the viewer would sit on screen with the screen side
                // already believing it is gone.
                if presentedRequestID != nil {
                    if !pendingDismissRequest {
                        photoVaultTrace(
                            "viewer_dismiss_deferred phase=\(dismissalPhase.label)"
                        )
                    }
                    pendingDismissRequest = true
                }
                return
            }
            pendingDismissRequest = false

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
