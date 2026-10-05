import SwiftUI
import UIKit

/// Pure policy: the system transition decides whether its interactive dismissal
/// may begin; the app can only veto it (photo zoomed, page swipe in flight,
/// filmstrip scrubbing). Never turns `willBegin == false` into `true` — that
/// would let UIKit start an interaction *it* already judged impossible.
func shouldBeginViewerInteractiveDismiss(willBegin: Bool, vetoed: Bool) -> Bool {
    guard !vetoed else { return false }
    return willBegin
}

/// The one thing the app still owns about the photo viewer: **when to ask UIKit
/// to push or pop**, and **whether the grid under the transition may be
/// touched**.
///
/// It is not a transition state machine. There is no presentation phase, no
/// dismissal phase, no generation, no pending queue, no cooldown and no timer —
/// because UIKit's fluid transition already sequences all of that. A pop that
/// has not finished does not block a push; the navigator simply pushes, and the
/// system interpolates between the two transitions.
/// ⚠️ Deliberately **not** the navigation controller's delegate. Measured on
/// device-class iOS: on compact width SwiftUI's `NavigationStack` shares the
/// split view's own `UINavigationController` (the window contains exactly one),
/// and that controller's delegate is what drives sidebar → detail navigation.
/// Installing the navigator as its delegate silently broke every sidebar row —
/// the row stayed selected but the detail column stopped changing. The
/// navigation bar is therefore managed from the viewer's lifecycle and the
/// anchor's `viewWillAppear`, never by owning the delegate.
@MainActor
final class PhotoViewerNavigator: NSObject, ObservableObject {
    /// Mirrors "the grid should not take touches right now".
    ///
    /// This is a UI-state decision, not an animation mirror: it is `false` the
    /// moment a dismissal commits (so the grid scrolls and taps *during* the
    /// zoom-out), and `true` again as soon as a new viewer is asked for. The
    /// screens observe it; the grid's `isActive` and the collection view's
    /// `isUserInteractionEnabled` both follow.
    @Published private(set) var isGridInteractionBlocked = false

    weak var navigationController: UINavigationController?
    private weak var gridTransitionCoordinator: PhotoGridTransitionCoordinator?

    /// The viewer the user is currently asking for. Cleared only when *that*
    /// session ends, so a late callback from an older viewer can never speak
    /// for a newer one.
    private var desiredSessionID: UUID?

    /// A viewer whose dismissal is already committed: the grid is live again
    /// while its zoom-out finishes, and this keeps the reference around so a
    /// late `didDisappear` can be recognised as belonging to it.
    private weak var exposedOutgoingViewer: PhotoViewerHostingController?

    /// The viewer this navigator most recently pushed.
    private(set) weak var currentViewer: PhotoViewerHostingController?

    var isViewerOnStack: Bool {
        navigationController?.viewControllers.contains {
            $0 is PhotoViewerHostingController
        } ?? false
    }

    deinit {
        // `deinit` of a @MainActor class cannot touch main-actor state; nothing
        // to release beyond what ARC already drops.
    }

    // MARK: - Attach

    /// Called by the navigation anchor once the dedicated `NavigationStack` has
    /// produced a real `UINavigationController`.
    func attach(navigationController: UINavigationController) {
        guard self.navigationController !== navigationController else { return }
        self.navigationController = navigationController
        photoVaultTraceLaunch("viewer_nav_attach stack=\(stackDescription())")
    }

    // MARK: - Open

    /// Push a viewer. **Unconditionally**: no check for an in-flight pop, no
    /// wait for `didShow`, no queue. If the previous zoom-out is still playing,
    /// UIKit runs the push into it — that is the fluid behaviour, and gating it
    /// is precisely what made "点了一下没反应" reproducible.
    func open(
        request: PhotoViewerRequest,
        gridTransitionCoordinator: PhotoGridTransitionCoordinator?,
        makeRootView: @escaping (PhotoViewerTransitionState, @escaping () -> Void) -> AnyView
    ) {
        guard let navigationController else {
            assertionFailure("Photo viewer 必须运行在独立 NavigationStack")
            photoVaultTraceLaunch("viewer_nav_push_rejected reason=no-navigation-controller")
            return
        }

        // A request may be reused (e.g. reopen the same photo). Its identity is
        // not the identity of a controller whose callbacks can still arrive.
        let sessionID = UUID()
        let state = PhotoViewerTransitionState(
            sessionID: sessionID,
            index: request.index,
            assetIdentifier: request.assetIdentifier
        )
        let viewer = PhotoViewerHostingController(
            sessionID: sessionID,
            transitionState: state,
            rootView: makeRootView(state, { [weak self] in self?.close(sessionID: sessionID) })
        )
        viewer.viewerNavigator = self
        viewer.gridTransitionCoordinator = gridTransitionCoordinator
        // Configured **before** the push: from the first frame of the zoom-in
        // the transition already knows its veto and its source rect, so a
        // downward drag can take over mid-animation and a source cell can never
        // be resolved from another session's state.
        viewer.preferredTransition = Self.zoomTransition(
            state: state,
            coordinator: gridTransitionCoordinator
        )
        self.gridTransitionCoordinator = gridTransitionCoordinator
        currentViewer = viewer
        desiredSessionID = sessionID
        setGridInteractionBlocked(true)
        photoVaultTraceLaunch("viewer_nav_push_requested \(state.debugLabel)")
        navigationController.pushViewController(
            viewer,
            animated: !UIAccessibility.isReduceMotionEnabled
        )
        traceStack("push")
        #if DEBUG
        lastOpen = (request, makeRootView)
        debugRunFluidProbeIfNeeded()
        #endif
    }

    // MARK: - Close

    /// Pop the viewer the user is asking to close. Programmatic exits (close
    /// button, 移出相册) are not cancellable, so the grid is released right away
    /// and the rest of the zoom-out plays over a live grid.
    func close(sessionID: UUID? = nil) {
        guard let navigationController else { return }
        guard let viewer = currentViewer,
              navigationController.topViewController === viewer,
              sessionID == nil || sessionID == viewer.sessionID
        else {
            photoVaultTraceLaunch("viewer_nav_pop_ignored reason=no-viewer-on-stack")
            reconcileGridInteraction()
            return
        }
        photoVaultTraceLaunch("viewer_nav_pop_requested \(viewer.transitionState.debugLabel)")
        releaseGrid(viewer: viewer, interactive: false)
        navigationController.popViewController(
            animated: !UIAccessibility.isReduceMotionEnabled
        )
        traceStack("pop")
    }

    // MARK: - Viewer lifecycle (forwarded by PhotoViewerHostingController)

    func viewerWillAppear(_ viewer: PhotoViewerHostingController) {
        guard exposedOutgoingViewer !== viewer,
              desiredSessionID == viewer.sessionID
                || (desiredSessionID == nil && navigationController?.topViewController === viewer)
        else { return }
        // The viewer carries its own top bar (关闭 / 信息 / 全屏), so UIKit's has
        // to go. `animated: false` on purpose: animating the bar while the zoom
        // transition runs fights it for the same run-loop frames. The grid gets
        // the bar back from its own anchor's `viewWillAppear`.
        PhotoViewerContainerChrome.setHidden(true, from: viewer)
    }

    func viewerIsAppearing(_ viewer: PhotoViewerHostingController) {
        // Nothing to do: the transition is already running and must not be
        // gated. Kept as an explicit hook because it is the moment the zoom-in
        // becomes interruptible.
    }

    /// The viewer has settled on screen (or came back from a cancelled pull).
    func viewerDidAppear(_ viewer: PhotoViewerHostingController) {
        // During an interrupted push UIKit can finish A's appearance inside
        // popViewController. A has already committed its exit at that point.
        // Later A callbacks also must not take ownership away from B.
        guard navigationController?.topViewController === viewer,
              exposedOutgoingViewer !== viewer,
              desiredSessionID == nil || desiredSessionID == viewer.sessionID
        else {
            photoVaultTraceLaunch("viewer_appearance_ignored \(viewer.transitionState.debugLabel)")
            return
        }
        PhotoViewerContainerChrome.setHidden(true, from: viewer)
        exposedOutgoingViewer = nil
        currentViewer = viewer
        desiredSessionID = viewer.sessionID
        // Covers the bounce-back that ends without a cancellation callback.
        restoreViewerInteraction(viewer)
        reconcileGridInteraction()
        traceStack("didAppear")
        #if DEBUG
        debugTraceTouchReachability(stage: "didAppear")
        #endif
    }

    /// Give the viewer's touches back after a cancelled interactive pop.
    ///
    /// 🔴 Measured on device-class iOS, this is the whole "下拉偶发/永久失效"
    /// bug, and it is **UIKit's own state**, not the app's: during an
    /// interactive pop UIKit sets the pushed controller's hosting view
    /// `isUserInteractionEnabled = false`, and on the **cancel** path it never
    /// restores it. The hierarchy captured at `viewDidAppear` after a
    /// bounce-back reads
    ///
    ///     _UIHostingView<AnyView>(enabled=false)->UIViewControllerWrapperView(enabled=true)->…
    ///
    /// while a freshly pushed viewer reads `enabled=true`. The system zoom
    /// dismissal's recognizers live on exactly that hosting view (see
    /// `ViewerPagingCollectionView`, same window dump), so while it is disabled
    /// the next pull-down is never recognised at all — no
    /// `zoom_dismiss_should_begin`, no `viewWillDisappear`, nothing. Several
    /// pulls do nothing; one later pull lands after UIKit happens to re-enable
    /// it, which is why the failure looks random.
    ///
    /// Restoring it is the inverse of a transition gate: it hands the user
    /// their input back instead of withholding it. It is event-driven (the
    /// transition's own cancellation callback, or `viewDidAppear`), never a
    /// timer, and it never overrides an in-flight write from UIKit.
    private func restoreViewerInteraction(_ viewer: PhotoViewerHostingController) {
        guard !viewer.view.isUserInteractionEnabled else { return }
        viewer.view.isUserInteractionEnabled = true
        photoVaultTraceLaunch(
            "viewer_interaction_restored \(viewer.transitionState.debugLabel)"
        )
    }

    func viewerWillDisappear(
        _ viewer: PhotoViewerHostingController,
        transitionCoordinator: UIViewControllerTransitionCoordinator?
    ) {
        // No coordinator (or a non-interactive one) means a programmatic pop:
        // it cannot be cancelled, so the grid is released immediately.
        guard let transitionCoordinator, transitionCoordinator.initiallyInteractive else {
            releaseGrid(viewer: viewer, interactive: false)
            return
        }

        // The system's pull-down can still be cancelled, so nothing is released
        // until UIKit says which way it went. `notifyWhenInteractionChanges`
        // fires on the decision — and again if the decision is revised.
        transitionCoordinator.notifyWhenInteractionChanges { [weak self, weak viewer] context in
            MainActor.assumeIsolated {
                guard let self, let viewer else { return }
                if context.isCancelled {
                    self.interactivePopCancelled(viewer)
                } else {
                    self.releaseGrid(viewer: viewer, interactive: true)
                }
            }
        }
        // The decision callback runs BEFORE the bounce finishes. UIKit can
        // write interaction=false again during that bounce. Repair once more
        // at its real completion, without delaying or gating a new gesture.
        transitionCoordinator.animate(alongsideTransition: nil) { [weak self, weak viewer] context in
            MainActor.assumeIsolated {
                guard context.isCancelled, let self, let viewer,
                      self.ownsInteractivePop(viewer) else { return }
                self.restoreViewerInteraction(viewer)
                photoVaultTraceLaunch("viewer_pop_cancel_completed \(viewer.transitionState.debugLabel)")
                #if DEBUG
                self.debugTraceTouchReachability(stage: "cancelCompleted")
                #endif
            }
        }
    }

    func viewerDidDisappear(_ viewer: PhotoViewerHostingController) {
        if desiredSessionID == viewer.sessionID {
            desiredSessionID = nil
        }
        if exposedOutgoingViewer === viewer {
            exposedOutgoingViewer = nil
        }
        if currentViewer === viewer {
            currentViewer = nil
        }
        reconcileGridInteraction()
        traceStack("didDisappear")
        #if DEBUG
        debugCheckStackInvariant()
        #endif
    }

    // MARK: - Pop outcomes

    /// The zoom-out will finish: the grid takes touches from here on, even
    /// though the viewer is still animating away. This is what lets the user
    /// tap the next photo while the previous zoom-out is playing.
    private func releaseGrid(viewer: PhotoViewerHostingController, interactive: Bool) {
        guard currentViewer === viewer,
              desiredSessionID == nil || desiredSessionID == viewer.sessionID
        else {
            photoVaultTraceLaunch("viewer_grid_release_ignored \(viewer.transitionState.debugLabel)")
            return
        }
        if desiredSessionID == viewer.sessionID {
            desiredSessionID = nil
        }
        exposedOutgoingViewer = viewer
        setGridInteractionBlocked(false)
        if interactive {
            photoVaultTraceLaunch(
                "viewer_pop_interaction_committed \(viewer.transitionState.debugLabel)"
            )
        }
        traceStack("releaseGrid")
        #if DEBUG
        installMidPopProbe(viewer: viewer, interactive: interactive)
        #endif
    }

    /// An interactive pull-down bounced back: the viewer is still on screen, so
    /// the grid must stop taking touches again.
    private func interactivePopCancelled(_ viewer: PhotoViewerHostingController) {
        guard ownsInteractivePop(viewer) else { return }
        desiredSessionID = viewer.sessionID
        exposedOutgoingViewer = nil
        setGridInteractionBlocked(true)
        // The viewer is staying: undo every disable UIKit applied for a
        // dismissal that is no longer happening.
        restoreViewerInteraction(viewer)
        #if DEBUG
        viewer.reportInteractiveDismissCancelled()
        #endif
        photoVaultTraceLaunch(
            "viewer_pop_interaction_cancelled \(viewer.transitionState.debugLabel)"
        )
        traceStack("popCancelled")
    }

    /// Callback ownership only: never a condition on starting push/pop input.
    private func ownsInteractivePop(_ viewer: PhotoViewerHostingController) -> Bool {
        currentViewer === viewer
            && (desiredSessionID == nil || desiredSessionID == viewer.sessionID)
            && (navigationController?.topViewController === viewer || desiredSessionID == viewer.sessionID)
    }

    // MARK: - Grid interaction

    /// One decision, three inputs: the session the user wants, the session
    /// already on its way out, and what the navigation stack actually holds.
    /// Deliberately not an animation state machine — it only answers "should the
    /// grid take touches right now".
    private func reconcileGridInteraction() {
        if desiredSessionID != nil {
            setGridInteractionBlocked(true)
            return
        }
        if exposedOutgoingViewer != nil {
            setGridInteractionBlocked(false)
            return
        }
        setGridInteractionBlocked(isViewerOnStack)
    }

    private func setGridInteractionBlocked(_ blocked: Bool) {
        // Push the value into the collection view synchronously as well: the
        // SwiftUI update lands a frame later, and the whole point is that the
        // grid responds in the same run loop turn the zoom-out commits.
        gridTransitionCoordinator?.setGridInteractionEnabled(!blocked)
        guard isGridInteractionBlocked != blocked else { return }
        isGridInteractionBlocked = blocked
        photoVaultTraceLaunch("viewer_grid_interaction blocked=\(blocked)")
    }

    // MARK: - Transition configuration

    /// Built per viewer session, capturing **that session's** state.
    ///
    /// `interactiveDismissShouldBegin`'s context does not expose the zoomed
    /// controller, and a closure that reached for a shared "current viewer"
    /// would be exactly the cross-session bug this refactor removes. Capturing
    /// the session state closes both holes at once.
    private static func zoomTransition(
        state: PhotoViewerTransitionState,
        coordinator: PhotoGridTransitionCoordinator?
    ) -> UIViewController.Transition {
        let options = UIViewController.Transition.ZoomOptions()
        options.dimmingColor = .black
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        if !reduceMotion {
            // UIKit owns begin eligibility; the app can only veto it.
            options.interactiveDismissShouldBegin = { context in
                let vetoed = state.interactiveDismissVeto?() ?? false
                let result = shouldBeginViewerInteractiveDismiss(
                    willBegin: context.willBegin,
                    vetoed: vetoed
                )
                // Logged unconditionally: "UIKit asked and the app did not
                // veto, yet nothing happened" is exactly the symptom this trace
                // has to be able to distinguish from "UIKit never asked".
                photoVaultTraceLaunch(
                    "zoom_dismiss_should_begin \(state.debugLabel) "
                        + "willBegin=\(context.willBegin) velX=\(Int(context.velocity.dx)) "
                        + "velY=\(Int(context.velocity.dy)) vetoed=\(vetoed) result=\(result)"
                )
                return result
            }
            // Align the morph with the photo itself (aspect-fit letterbox
            // excluded) so it grows out of and lands on the image, not the
            // full-screen container.
            options.alignmentRectProvider = { context in
                state.zoomAlignmentRectProvider?(context.zoomedViewController.view.bounds.size)
            }
        }
        return .zoom(options: options) { _ in
            guard !reduceMotion, let coordinator else { return nil }
            // Read *this* viewer's state: an overlapping pop→push has two live
            // sessions, and each must resolve its own grid cell.
            let source = coordinator.sourceView(
                index: state.currentIndex,
                assetIdentifier: state.currentAssetIdentifier
            )
            photoVaultTrace("viewer_zoom_source \(state.debugLabel) found=\(source != nil)")
            return source
        }
    }

    // MARK: - Diagnostics

    private func stackDescription() -> String {
        guard let navigationController else { return "<unattached>" }
        return navigationController.viewControllers
            .map { $0 is PhotoViewerHostingController ? "Viewer" : String(describing: type(of: $0)) }
            .joined(separator: ">")
    }


    private func traceStack(_ action: String) {
        photoVaultTraceLaunch("viewer_nav_stack action=\(action) stack=\(stackDescription())")
    }

    #if DEBUG
    private var fluidProbeFailures = 0
    private var didStartFluidProbe = false
    private var retiredProbeViewer: PhotoViewerHostingController?
    private var lastOpen: (
        request: PhotoViewerRequest,
        makeRootView: (PhotoViewerTransitionState, @escaping () -> Void) -> AnyView
    )?

    /// App-internal probe for what XCUITest cannot inject: input *during* a
    /// running transition. It never fakes touches — it calls exactly the same
    /// entry points the UI calls (open / close) and reads the navigation stack
    /// afterwards, so it proves the absence of a transition gate.
    private func debugRunFluidProbeIfNeeded() {
        guard !didStartFluidProbe,
              ProcessInfo.processInfo.arguments.contains("-viewer-fluid-transition-probe")
                || ProcessInfo.processInfo.arguments.contains("-viewer-session-ownership-probe")
        else { return }
        didStartFluidProbe = true
        photoVaultTraceLaunch("viewer_fluid_transition_probe step=push_started failures=\(fluidProbeFailures)")
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.debugInterruptOpeningAnimation()
        }
    }

    private func debugInterruptOpeningAnimation() {
        guard let viewer = currentViewer else {
            fluidProbeFailures += 1
            photoVaultTraceLaunch("viewer_fluid_transition_probe step=interrupt_open missing=true failures=\(fluidProbeFailures)")
            return
        }
        photoVaultTraceLaunch(
            "viewer_fluid_transition_probe step=interrupt_open \(viewer.transitionState.debugLabel) "
                + "stack=\(stackDescription())"
        )
        retiredProbeViewer = viewer
        // Close while the zoom-in is still playing. If a transition gate
        // existed, this would be swallowed and the viewer would survive.
        close()
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.debugReopenDuringPop()
        }
    }

    private func debugReopenDuringPop() {
        guard let lastOpen else {
            fluidProbeFailures += 1
            return
        }
        photoVaultTraceLaunch(
            "viewer_fluid_transition_probe step=push_during_pop stack=\(stackDescription())"
        )
        // Push B while A's pop is still animating. No queue, no judgement about
        // whether A has finished.
        open(
            request: lastOpen.request,
            gridTransitionCoordinator: gridTransitionCoordinator,
            makeRootView: lastOpen.makeRootView
        )
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.debugVerifyOverlap()
        }
    }

    private func debugVerifyOverlap() {
        let viewers = navigationController?.viewControllers.filter {
            $0 is PhotoViewerHostingController
        } ?? []
        if viewers.count != 1 {
            fluidProbeFailures += 1
        }
        photoVaultTraceLaunch(
            "viewer_fluid_transition_probe step=overlap_verified viewers=\(viewers.count) "
                + "stack=\(stackDescription()) failures=\(fluidProbeFailures)"
        )
        debugCheckStackInvariant()
        debugVerifyRetiredSessionCallbacks()
    }

    /// Exercises deliberately late callbacks against the real mounted stack.
    /// It is a lifecycle-order probe, not a simulated finger or animation.
    private func debugVerifyRetiredSessionCallbacks() {
        defer { retiredProbeViewer = nil }
        guard ProcessInfo.processInfo.arguments.contains("-viewer-session-ownership-probe"),
              let retired = retiredProbeViewer,
              let active = navigationController?.topViewController as? PhotoViewerHostingController,
              active !== retired else { return }
        var failures = 0
        func verify(_ step: String) {
            let passed = currentViewer === active
                && desiredSessionID == active.sessionID
                && isGridInteractionBlocked
                && navigationController?.topViewController === active
                && retired.sessionID != active.sessionID
                && active.navigationItem.hidesBackButton
                && retired.navigationItem.hidesBackButton
            if !passed { failures += 1 }
            photoVaultTraceLaunch("viewer_session_probe step=\(step) passed=\(passed)")
        }
        verify("before_retired_callbacks")
        viewerWillAppear(retired)
        verify("retired_willAppear")
        viewerDidAppear(retired)
        verify("retired_didAppear")
        releaseGrid(viewer: retired, interactive: false)
        verify("retired_release")
        interactivePopCancelled(retired)
        verify("retired_cancel")
        viewerDidDisappear(retired)
        verify("retired_didDisappear")
        close(sessionID: retired.sessionID)
        verify("retired_close")
        active.debugStatus.sessionProbe = failures == 0 ? "passed" : "failed \(failures)"
    }

    /// The stack may never accumulate viewers: every pop must actually leave the
    /// stack (root → B, never root → A → B → C).
    private func debugCheckStackInvariant() {
        guard let navigationController else { return }
        let viewers = navigationController.viewControllers.filter {
            $0 is PhotoViewerHostingController
        }
        if viewers.count > 1 {
            fluidProbeFailures += 1
            photoVaultTraceLaunch(
                "viewer_nav_stack_invariant_violation viewers=\(viewers.count) stack=\(stackDescription())"
            )
        }
    }

    /// Answers "would a touch at the middle of the screen reach the viewer?"
    /// with a real `hitTest`, and reports every ancestor's interaction flag.
    ///
    /// This is the question a stalled pull-down turns on: when the system's
    /// zoom dismissal stops engaging after a couple of cancelled drags, either
    /// UIKit never asks the app (probe shows the viewer still reachable, so the
    /// block is above us) or something in the chain was left disabled.
    private func debugTraceTouchReachability(stage: String) {
        guard ProcessInfo.processInfo.arguments.contains("-viewer-cancel-reentry-probe"),
              let viewer = currentViewer ?? navigationController?.topViewController as? PhotoViewerHostingController,
              let window = viewer.view.window
        else { return }
        let point = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
        let hit = window.hitTest(point, with: nil)
        let reachesViewer = hit === viewer.view
            || hit?.isDescendant(of: viewer.view) == true
        var chain: [String] = []
        var node: UIView? = viewer.view
        while let current = node, !(current is UIWindow) {
            chain.append("\(type(of: current))(enabled=\(current.isUserInteractionEnabled))")
            node = current.superview
        }
        // The system's zoom dismissal recognizers: their presence, enabled flag
        // and state are what decide whether the *next* pull can begin. Logged
        // together with reachability so a stalled pull-down can be attributed
        // to either "the app blocks touches" or "UIKit's own gesture is not
        // armed/startable".
        var zoomGestures: [String] = []
        func scan(_ node: UIView) {
            for gesture in node.gestureRecognizers ?? []
            where gesture.name.map({ $0.contains("ZoomInteractiveDismiss") }) == true {
                zoomGestures.append(
                    "\(gesture.name ?? "?")=state:\(gesture.state.rawValue) "
                        + "enabled:\(gesture.isEnabled) view:\(String(describing: type(of: node)))"
                )
            }
            for child in node.subviews { scan(child) }
        }
        scan(window)
        photoVaultTraceLaunch(
            "viewer_touch_reachability stage=\(stage) reached=\(reachesViewer) "
                + "hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil") "
                + "viewerEnabled=\(viewer.view.isUserInteractionEnabled) "
                + "chain=\(chain.joined(separator: "->")) "
                + "zoom=[\(zoomGestures.joined(separator: ";"))]"
        )
    }

    /// Mid-animation evidence: asked from inside the running zoom-out, with a
    /// real `hitTest`, whether a touch at a grid cell would reach the grid.
    private func installMidPopProbe(
        viewer: PhotoViewerHostingController,
        interactive: Bool
    ) {
        guard ProcessInfo.processInfo.arguments.contains("-viewer-fluid-transition-probe"),
              let coordinator = viewer.transitionCoordinator else { return }
        coordinator.animate(alongsideTransition: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let hit = self.gridTransitionCoordinator?.debugHitTestProbe() ?? "no-grid"
                photoVaultTrace(
                    "viewer_pop_mid_transition interactive=\(interactive) \(hit)"
                )
                if ProcessInfo.processInfo.arguments.contains("-viewer-fluid-transition-probe"),
                   self.didStartFluidProbe {
                    // Prove the grid is not merely re-enabled but reachable:
                    // the same hit-test gates this synthetic selection.
                    self.gridTransitionCoordinator?.debugSelectPhoto(at: 2)
                }
            }
        }, completion: nil)
    }
    #endif
}

// MARK: - Navigation anchor

/// Hands the navigator the `UINavigationController` of the `NavigationStack` it
/// lives in.
///
/// On compact width a `NavigationSplitView` keeps its own internal navigation
/// stack, and pushing the viewer onto *that* one corrupts the split view's
/// detail presentation: after a pop the sidebar stops navigating entirely. The
/// LAN branch already avoids this with a dedicated stack; every grid branch that
/// can open the viewer does the same, and this anchor is how the navigator finds
/// it.
struct PhotoViewerNavigationAnchor: UIViewControllerRepresentable {
    let navigator: PhotoViewerNavigator

    func makeUIViewController(context: Context) -> PhotoViewerNavigationAnchorController {
        PhotoViewerNavigationAnchorController(navigator: navigator)
    }

    func updateUIViewController(
        _ controller: PhotoViewerNavigationAnchorController,
        context: Context
    ) {
        controller.navigator = navigator
        controller.attachIfPossible()
    }
}

@MainActor
final class PhotoViewerNavigationAnchorController: UIViewController {
    weak var navigator: PhotoViewerNavigator?

    init(navigator: PhotoViewerNavigator) {
        self.navigator = navigator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func loadView() {
        let view = UIView()
        view.backgroundColor = .clear
        // Zero-size and inert: it exists only to read the navigation controller.
        view.isUserInteractionEnabled = false
        self.view = view
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        attachIfPossible()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        attachIfPossible()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        attachIfPossible()
        // The grid is on screen again: give it back UIKit's navigation bar.
        // An underlying SwiftUI anchor may reappear while a new viewer is
        // already being pushed. Its lifecycle must not reveal home chrome.
        if navigator?.isGridInteractionBlocked != true {
            PhotoViewerContainerChrome.setHidden(false, from: self)
        }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        attachIfPossible()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        attachIfPossible()
        guard navigationController == nil else { return }
        assertionFailure("Photo viewer 必须运行在独立 NavigationStack")
    }

    func attachIfPossible() {
        guard let navigationController else { return }
        navigator?.attach(navigationController: navigationController)
    }

}
