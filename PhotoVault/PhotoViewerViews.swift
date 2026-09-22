import Photos
import SwiftUI
import UIKit
import AVKit
import PhotosUI
import OSLog

#if DEBUG
enum PagerDiagnostics {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.misswell.PhotoVault",
        category: "Pager"
    )
    private static let maxLogBytes = 512 * 1024
    private static let fileQueue = DispatchQueue(
        label: "com.misswell.PhotoVault.pager-diagnostics",
        qos: .utility
    )
    private static let sessionLock = NSLock()
    nonisolated(unsafe) private static var hasStartedSession = false

    /// Resolved once. This used to hit `FileManager` for the caches directory
    /// on every log call, which happens per scrub frame.
    private static let logURL: URL = {
        let cachesDirectory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0]
        return cachesDirectory
            .appendingPathComponent("PhotoVault", isDirectory: true)
            .appendingPathComponent("PagerDiagnostics.log")
    }()

    static func beginSession() {
        sessionLock.lock()
        guard !hasStartedSession else {
            sessionLock.unlock()
            return
        }
        hasStartedSession = true
        sessionLock.unlock()
        let url = logURL
        fileQueue.async {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? Data().write(to: url, options: .atomic)
        }
        log("session started")
    }

    /// `@autoclosure` matters here: the call sites interpolate indices and
    /// sizes on every scrub frame, and the release build's no-op stub used to
    /// still build every one of those strings before throwing them away.
    static func log(_ message: @autoclosure () -> String) {
        let message = message()
        logger.log(level: .debug, "\(message, privacy: .public)")

        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = logURL
        fileQueue.async {
            let fileManager = FileManager.default
            try? fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
               let size = attributes[.size] as? NSNumber,
               size.intValue + data.count > maxLogBytes {
                try? fileManager.removeItem(at: url)
            }
            if fileManager.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                do {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } catch {
                    try? handle.close()
                }
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
#else
enum PagerDiagnostics {
    static func beginSession() {}
    static func log(_ message: @autoclosure () -> String) {}
}
#endif

@MainActor
private final class MediaAudioSession: ObservableObject {
    static let shared = MediaAudioSession()

    @Published private(set) var isMuted = true

    private init() {}

    func toggleMuted() {
        setMuted(!isMuted)
    }

    func suspendForBackground() {
        guard !isMuted else { return }
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    func resumeAfterBackground() {
        guard !isMuted else { return }
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback)
            try audioSession.setActive(true)
        } catch {
            isMuted = true
        }
    }

    private func setMuted(_ muted: Bool) {
        guard muted != isMuted else { return }

        if muted {
            isMuted = true
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
            PagerDiagnostics.log("media audio muted=true")
            return
        }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback)
            try audioSession.setActive(true)
            isMuted = false
            PagerDiagnostics.log("media audio muted=false session=playback")
        } catch {
            isMuted = true
            PagerDiagnostics.log(
                "media audio activation failed error=\(error.localizedDescription)"
            )
        }
    }
}

private extension PHAsset {
    var hasPlayableAudio: Bool {
        mediaType == .video
            || (mediaType == .image && mediaSubtypes.contains(.photoLive))
    }
}

private struct MediaAudioButton: View {
    @ObservedObject private var audioSession = MediaAudioSession.shared

    var body: some View {
        Button {
            audioSession.toggleMuted()
        } label: {
            Image(systemName: audioSession.isMuted
                ? "speaker.slash.fill"
                : "speaker.wave.2.fill")
                .font(.headline)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 36, height: 36)
                .glassEffect(.regular.interactive(), in: Circle())
                .frame(width: 46, height: 46)
                .contentShape(Rectangle())
        }
        .animation(.snappy(duration: 0.22), value: audioSession.isMuted)
        .accessibilityLabel(audioSession.isMuted ? "打开声音" : "静音")
    }
}

private func viewerPageTransition(
    style: PhotoSwipeStyle,
    direction: Int
) -> AnyTransition {
    let insertionEdge: Edge = direction >= 0 ? .trailing : .leading
    let removalEdge: Edge = direction >= 0 ? .leading : .trailing

    switch style {
    case .system:
        return .identity
    case .fade:
        return .opacity
    case .push:
        return .asymmetric(
            insertion: .move(edge: insertionEdge),
            removal: .move(edge: removalEdge)
        )
    case .zoom:
        return .asymmetric(
            insertion: .scale(scale: 0.88).combined(with: .opacity),
            removal: .scale(scale: 1.08).combined(with: .opacity)
        )
    }
}

private func slideshowPageTransition(
    style: SlideshowTransitionStyle,
    direction: Int
) -> AnyTransition {
    let insertionEdge: Edge = direction >= 0 ? .trailing : .leading
    let removalEdge: Edge = direction >= 0 ? .leading : .trailing

    switch style {
    case .fade:
        return .opacity
    case .slide:
        return .asymmetric(
            insertion: .move(edge: insertionEdge),
            removal: .move(edge: removalEdge)
        )
    case .zoom:
        return .asymmetric(
            insertion: .scale(scale: 0.9).combined(with: .opacity),
            removal: .scale(scale: 1.06).combined(with: .opacity)
        )
    case .dissolve:
        return .opacity.combined(with: .scale(scale: 0.96))
    }
}

/// Shared motion vocabulary for both viewer variants. Opening and closing the
/// viewer is owned by the system zoom transition (`preferredTransition`), so
/// there is deliberately no custom presentation or dismissal trajectory here:
/// the drag feedback, the fly-out and the fade-out that used to live in this
/// enum were removed with it.
private enum ViewerMotion {
    static let chrome = AppMotion.viewerChrome
    static let cancellation = AppMotion.viewerCancellation
    static let reducedMotionDuration = 0.18

    static var reducedMotion: Animation {
        AppMotion.reducedMotion
    }

    static func chromeOpacity(isVisible: Bool) -> Double {
        isVisible ? 1 : 0
    }

    /// Commit threshold for the *custom* pager styles only. The default
    /// system-style pager hands pull-down to the zoom transition's own
    /// interactive dismissal, which decides commit/cancel with UIKit physics;
    /// the custom fade/push/zoom styles never reach it, so they still need a
    /// velocity-aware decision here.
    static func shouldDismiss(
        translation: CGFloat,
        predictedTranslation: CGFloat,
        viewportHeight: CGFloat
    ) -> Bool {
        let directThreshold = min(max(viewportHeight * 0.14, 112), 168)
        let projectedThreshold = min(max(viewportHeight * 0.25, 220), 320)
        return translation > directThreshold
            || predictedTranslation > projectedThreshold
    }
}

private enum ViewerDragAxis: Equatable {
    case undecided
    case vertical
    case horizontal
}

private struct ViewerDismissDrag {
    let translation: CGSize
    let predictedEndTranslation: CGSize
}

private struct ViewerMediaView: View {
    let asset: PHAsset
    let targetSize: CGSize
    let contentMode: PHImageContentMode
    let requestPriority: PhotoRequestPriority
    /// An already-decoded frame (normally the grid thumbnail that was tapped).
    /// Only the page the viewer was opened on receives one; every other page
    /// loads through the normal PhotoKit path.
    let initialImage: UIImage?
    /// True inside the zoom-transitioned viewer: the letterbox canvas stays
    /// transparent so the system dimming provides the black backdrop and the
    /// zoom-out morphs the photo itself back into its grid cell.
    let transparentCanvas: Bool
    let onReady: (Bool) -> Void
    let onZoomingChanged: ((Bool) -> Void)?

    init(
        asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFit,
        requestPriority: PhotoRequestPriority = .viewer,
        initialImage: UIImage? = nil,
        transparentCanvas: Bool = false,
        onReady: @escaping (Bool) -> Void = { _ in },
        onZoomingChanged: ((Bool) -> Void)? = nil
    ) {
        self.asset = asset
        self.targetSize = targetSize
        self.contentMode = contentMode
        self.requestPriority = requestPriority
        self.initialImage = initialImage
        self.transparentCanvas = transparentCanvas
        self.onReady = onReady
        self.onZoomingChanged = onZoomingChanged
    }

    @ViewBuilder
    var body: some View {
        switch asset.mediaType {
        case .video:
            VideoAssetViewer(
                asset: asset,
                requestPriority: requestPriority,
                transparentCanvas: transparentCanvas,
                onReady: onReady
            )
        case .image where asset.mediaSubtypes.contains(.photoLive):
            LivePhotoAssetViewer(
                asset: asset,
                targetSize: targetSize,
                contentMode: contentMode,
                requestPriority: requestPriority,
                transparentCanvas: transparentCanvas,
                onReady: onReady
            )
        default:
            ZoomableAssetView(
                asset: asset,
                targetSize: targetSize,
                contentMode: contentMode,
                requestPriority: requestPriority,
                initialImage: initialImage,
                canvasBackground: transparentCanvas ? Color.clear : nil,
                onLoadStateChange: onReady,
                onZoomingChanged: onZoomingChanged
            )
        }
    }
}

/// Resolves downward intent before the horizontal scroll view starts paging.
/// This recognizer only arbitrates; UIKit's zoom gesture still owns every pixel
/// of the dismissal. No replacement scroll-view delegate or failure dependency.
final class ViewerDownwardIntentGesture: UIGestureRecognizer, UIGestureRecognizerDelegate {
    weak var pagingPan: UIGestureRecognizer?
    var canReserveDownwardDrag: (() -> Bool)?
    /// The viewer session's live dismissal state, read on every sampled move.
    /// UIKit still owns the actual zoom transition.
    weak var transitionState: PhotoViewerTransitionState?
    private var origin: CGPoint?
    private var didLogGating = false

    init(pagingPan: UIGestureRecognizer) {
        self.pagingPan = pagingPan
        super.init(target: nil, action: nil)
        delegate = self
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    /// Whether the pager may give up the downward direction right now.
    ///
    /// Live, and re-asked on every sampled move: the gate can flip while the
    /// finger is still travelling (UIKit finishing a bounce-back being the
    /// common case). Deciding it once at touch-down is what lost the whole
    /// gesture, because `.failed` is terminal for that touch sequence.
    private var mayReserveDownwardDrag: Bool {
        guard canReserveDownwardDrag?() == true else { return false }
        guard let transitionState else { return true }
        return transitionState.mayArbitrateDownwardDrag
    }

    /// Whether this landing finger should be tracked at all.
    ///
    /// Deliberately says nothing about the dismissal state: the gate is
    /// evaluated per move, so a touch that lands during a bounce-back can
    /// still be reserved once the bounce settles under the finger.
    private func shouldTrackAtTouchDown(fingers: Int, hasOrigin: Bool) -> Bool {
        fingers == 1 && !hasOrigin
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        // A recognition cycle that did not settle is the recognizer's own
        // problem; forcing a state here would fight UIKit's reset. Only a
        // fresh cycle may decide anything.
        guard state == .possible else { return }
        let fingers = event.allTouches?.count ?? 0
        // Multiple fingers mean pinch/zoom, never a pull-down.
        guard shouldTrackAtTouchDown(fingers: fingers, hasOrigin: origin != nil),
              let touch = touches.first else {
            state = .failed
            return
        }
        origin = touch.location(in: view)
        photoVaultTrace(
            "viewer_downward_intent began dismissState="
                + (transitionState?.interactiveDismissState.label ?? "none")
        )
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first else { return }
        moveTracking(to: touch.location(in: view))
    }

    private func moveTracking(to location: CGPoint) {
        if state == .began || state == .changed {
            state = .changed
            return
        }
        guard state == .possible else { return }
        switch resolution(at: location) {
        case .hold:
            break
        case .gated:
            // Downward, but the gate is shut. Reported once per touch: this is
            // the state that replaced "fail the touch", so a device log can
            // tell a pull-down that is still alive from one that was dropped.
            guard !didLogGating else { return }
            didLogGating = true
            photoVaultTrace(
                "viewer_downward_intent gated dismissState="
                    + (transitionState?.interactiveDismissState.label ?? "none")
            )
        case .release:
            // Clearly horizontal or upward: hand the drag to the pager now
            // rather than sitting on it until the finger lifts.
            state = .failed
            photoVaultTrace("viewer_downward_intent released to pager")
        case .reserve:
            state = .began
            photoVaultTrace("viewer_downward_intent reserved")
        }
    }

    private enum DownwardDecision {
        /// Movement below the threshold that resolves a direction.
        case tooClose
        /// Far enough to have a direction, and that direction is downward.
        case downward
        /// Far enough, and the drag is leaving the pull-down (horizontal/up).
        case away
        /// No origin recorded, so nothing may be concluded.
        case undecided
    }

    private func decision(at location: CGPoint) -> DownwardDecision {
        guard let origin else { return .undecided }
        let dx = location.x - origin.x
        let dy = location.y - origin.y
        guard hypot(dx, dy) >= 6 else { return .tooClose }
        // A slightly diagonal pull remains a dismissal; clearly horizontal
        // motion and upward drags immediately leave the pager alone.
        return dy > 0 && dy >= abs(dx) ? .downward : .away
    }

    /// What a sampled point means for this touch: direction crossed with the
    /// live dismissal gate.
    ///
    /// `.hold` and `.gated` both keep the recognizer `.possible`, which blocks
    /// nothing — touches are delivered immediately (`delaysTouchesBegan/Ended`
    /// are off) and this recognizer can only ever prevent the pager's pan,
    /// never UIKit's own dismissal gesture. So waiting out the bounce-back
    /// costs nothing, while failing the touch costs the gesture.
    private enum DownwardResolution {
        /// Nothing to conclude from this sample yet.
        case hold
        /// Downward, but the gate is shut; keep tracking and re-check.
        case gated
        /// Downward and the pager may give up the direction.
        case reserve
        /// Not a pull-down; leave the drag to the pager.
        case release
    }

    private func resolution(at location: CGPoint) -> DownwardResolution {
        switch decision(at: location) {
        case .tooClose, .undecided:
            return .hold
        case .away:
            return .release
        case .downward:
            return mayReserveDownwardDrag ? .reserve : .gated
        }
    }

    #if DEBUG
    /// Runs from the bridge's real cancelling phase on the same helpers touch
    /// delivery uses, over a throwaway state object.
    ///
    /// It checks what a pull-down *concludes*. It never drives a recognizer
    /// through UIKit's state machine: setting `.began` outside live touch
    /// handling is what crashed the earlier version of this probe.
    static func debugVerifyCancellationReentry() {
        let pager = UIPanGestureRecognizer()
        let intent = ViewerDownwardIntentGesture(pagingPan: pager)
        // Strong local: `transitionState` is weak, and the probe owns the only
        // reference to this throwaway session state.
        let session = PhotoViewerTransitionState(index: 0, assetIdentifier: nil)
        intent.transitionState = session
        intent.canReserveDownwardDrag = { true }

        // A second finger lands while UIKit is still bouncing the first back.
        session.setInteractiveDismissState(.cancelling)
        assert(intent.shouldTrackAtTouchDown(fingers: 1, hasOrigin: false),
               "回弹没结束就放弃落指，会让第二笔下拉整笔失效")
        assert(!intent.shouldTrackAtTouchDown(fingers: 2, hasOrigin: false),
               "多指是缩放，不参与下拉仲裁")
        intent.origin = .zero
        assert(intent.decision(at: CGPoint(x: 1, y: 12)) == .downward,
               "第二笔下拉必须仍能识别出向下")
        assert(intent.decision(at: CGPoint(x: 12, y: 1)) == .away,
               "横向拖动必须交给分页器")
        assert(intent.resolution(at: CGPoint(x: 2, y: 40)) == .reserve,
               "回弹期间的下拉必须仍能占住方向")

        // While the system already owns a drag, or is on its way out, the
        // recognizer must step aside without failing the touch.
        session.setInteractiveDismissState(.dragging)
        assert(intent.resolution(at: CGPoint(x: 2, y: 40)) == .gated,
               "系统正在拖动时仲裁器必须让路")
        session.setInteractiveDismissState(.committed)
        assert(intent.resolution(at: CGPoint(x: 2, y: 40)) == .gated,
               "退出进行中必须让路")

        // The same touch, once the bounce has settled: still reservable.
        session.setInteractiveDismissState(.idle)
        assert(intent.resolution(at: CGPoint(x: 2, y: 40)) == .reserve,
               "回弹结束后，同一笔触摸必须能占住下拉方向")

        assert(intent.canPrevent(pager), "下拉方向不能交给横向分页器")
        assert(!intent.canPrevent(UIPanGestureRecognizer()), "不得阻止系统退出手势")
        photoVaultTraceLaunch("viewer_cancel_reentry_tracking passed=true")
    }
    #endif

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        switch state {
        case .possible: state = .failed
        case .began, .changed: state = .ended
        default: break
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        switch state {
        case .possible: state = .failed
        case .began, .changed: state = .cancelled
        default: break
        }
    }

    override func reset() {
        super.reset()
        origin = nil
        didLogGating = false
        #if DEBUG
        photoVaultTrace("viewer_downward_intent_reset")
        #endif
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        preventedGestureRecognizer === pagingPan
    }

    /// Only the pager's pan may not preempt this arbitration recognizer.
    ///
    /// Answering `false` across the board made the recognizer unpreventable by
    /// *anything*, which puts it above UIKit's own zoom dismissal gesture — and
    /// this recognizer is nothing but an arbiter between the pager and that
    /// gesture. When a cancelled pull-back was still settling, the system
    /// gesture could not take over, this one still reserved the drag, and the
    /// whole touch was dropped by both.
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        preventingGestureRecognizer !== pagingPan
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        otherGestureRecognizer !== pagingPan
    }
}

/// UIKit's page controller owns the interactive transition from beginning to
/// end. SwiftUI's TabView is convenient for a static pager, but resetting its
/// selection while its internal UIPageViewController is still animating can
/// make the next swipe a no-op. This wrapper keeps one controller per nearby
/// asset and lets the delegate report the completed page exactly once.
private struct NativePhotoPager: UIViewControllerRepresentable {
    let pageCount: Int
    @Binding var currentIndex: Int
    var isScrubbing: Bool = false
    /// The live viewer session's dismissal state, consulted by the downward
    /// intent recognizer. nil means "no system dismissal to arbitrate against"
    /// and leaves the pager alone.
    var transitionState: PhotoViewerTransitionState? = nil
    let assetProvider: (Int) -> PHAsset?
    let targetSize: CGSize
    let contentMode: PHImageContentMode
    let neighborPriority: PhotoRequestPriority
    /// First-frame seed for exactly one page: the asset the viewer opened on.
    let initialPreviewImage: UIImage?
    let initialAssetIdentifier: String?
    let onMediaReady: ((Bool) -> Void)?
    let onZoomingChanged: ((Bool) -> Void)?
    let onPagingChanged: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        PagerDiagnostics.beginSession()
        return Coordinator(
            currentIndex: $currentIndex,
            transitionState: transitionState
        )
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal,
            options: [
                UIPageViewController.OptionsKey.interPageSpacing: 0
            ]
        )
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        context.coordinator.attach(controller: controller)
        context.coordinator.update(
            pageCount: pageCount,
            currentIndex: currentIndex,
            isScrubbing: isScrubbing,
            assetProvider: assetProvider,
            targetSize: targetSize,
            contentMode: contentMode,
            neighborPriority: neighborPriority,
            initialPreviewImage: initialPreviewImage,
            initialAssetIdentifier: initialAssetIdentifier,
            onMediaReady: onMediaReady,
            onZoomingChanged: onZoomingChanged,
            onPagingChanged: onPagingChanged
        )
        return controller
    }

    func updateUIViewController(
        _ controller: UIPageViewController,
        context: Context
    ) {
        context.coordinator.update(
            pageCount: pageCount,
            currentIndex: currentIndex,
            isScrubbing: isScrubbing,
            assetProvider: assetProvider,
            targetSize: targetSize,
            contentMode: contentMode,
            neighborPriority: neighborPriority,
            initialPreviewImage: initialPreviewImage,
            initialAssetIdentifier: initialAssetIdentifier,
            onMediaReady: onMediaReady,
            onZoomingChanged: onZoomingChanged,
            onPagingChanged: onPagingChanged
        )
    }

    static func dismantleUIViewController(
        _ uiViewController: UIPageViewController,
        coordinator: Coordinator
    ) {
        coordinator.invalidate()
    }

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource,
        UIPageViewControllerDelegate {
        private weak var pageController: UIPageViewController?
        private var downwardIntentGesture: ViewerDownwardIntentGesture?
        /// Held weakly: the session's state belongs to the grid's transition
        /// coordinator, and a pager outliving that session must not keep a
        /// stale gate alive — a released reference simply means "no gate".
        private weak var transitionState: PhotoViewerTransitionState?
        private var pageCount = 0
        private var displayedIndex: Int?
        private var assetProvider: ((Int) -> PHAsset?) = { _ in nil }
        private var targetSize = CGSize.zero
        private var contentMode: PHImageContentMode = .aspectFit
        private var neighborPriority: PhotoRequestPriority = .slideshow
        private var initialPreviewImage: UIImage?
        private var initialAssetIdentifier: String?
        private var onMediaReady: ((Bool) -> Void)?
        private var onZoomingChanged: ((Bool) -> Void)?
        private var onPagingChanged: ((Bool) -> Void)?
        private var isZooming = false
        private var pages: [Int: PhotoPagerPageController] = [:]
        /// The content identity currently rendered by each page's hosting
        /// controller, so an unchanged page is never rebuilt.
        private var pageIdentities: [Int: String] = [:]
        private var currentIndexBinding: Binding<Int>
        private var pendingProgrammaticIndex: Int?
        private var isScrubbing = false
        private var lastUpdateSignature = ""
        private var lastPageContentSignature = ""
        private var isManualTransitionInProgress = false

        init(currentIndex: Binding<Int>, transitionState: PhotoViewerTransitionState?) {
            currentIndexBinding = currentIndex
            self.transitionState = transitionState
            PagerDiagnostics.log("coordinator init index=\(currentIndex.wrappedValue)")
        }

        func attach(controller: UIPageViewController) {
            pageController = controller
            guard let scrollView = controller.view.subviews.compactMap({ $0 as? UIScrollView }).first
            else { return }
            let intent = ViewerDownwardIntentGesture(pagingPan: scrollView.panGestureRecognizer)
            intent.canReserveDownwardDrag = { [weak self] in
                guard let self else { return false }
                return !self.isZooming && !self.isManualTransitionInProgress
                    && !self.isScrubbing && self.pendingProgrammaticIndex == nil
            }
            // Keep downward direction arbitration alive during reversal as well.
            // Failing here hands the second drag to the horizontal pager for
            // its entire touch sequence, even after the bounce has settled.
            intent.transitionState = transitionState
            scrollView.addGestureRecognizer(intent)
            downwardIntentGesture = intent
        }

        func invalidate() {
            guard pageController != nil || !pages.isEmpty else { return }
            PagerDiagnostics.log(
                "coordinator invalidate displayed=\(displayedIndex.map(String.init) ?? "none")"
            )

            // A cover can begin its dismissal while UIPageViewController is
            // still finishing a horizontal transition. Detach the delegates
            // before releasing the hosted pages so a late UIKit callback
            // cannot write into the screen that is already going away.
            if let downwardIntentGesture {
                downwardIntentGesture.view?.removeGestureRecognizer(downwardIntentGesture)
            }
            downwardIntentGesture = nil
            pageController?.dataSource = nil
            pageController?.delegate = nil
            pageController?.view.isUserInteractionEnabled = false
            pages.removeAll()
            pendingProgrammaticIndex = nil
            displayedIndex = nil

            // The SwiftUI owner may be in the middle of removing this
            // representable. Publishing the final zoom/paging values here
            // re-enters its @State setters from UIKit's animation callback
            // and can trip Swift's exclusivity checker. Once the pager is
            // being dismantled, no consumer can act on these values anyway;
            // sever callbacks before clearing the local flags.
            onMediaReady = nil
            onZoomingChanged = nil
            onPagingChanged = nil
            if isZooming {
                isZooming = false
            }
            if isManualTransitionInProgress {
                isManualTransitionInProgress = false
            }
            assetProvider = { _ in nil }
            pageController = nil
        }

        func update(
            pageCount: Int,
            currentIndex: Int,
            isScrubbing: Bool,
            assetProvider: @escaping (Int) -> PHAsset?,
            targetSize: CGSize,
            contentMode: PHImageContentMode,
            neighborPriority: PhotoRequestPriority,
            initialPreviewImage: UIImage?,
            initialAssetIdentifier: String?,
            onMediaReady: ((Bool) -> Void)?,
            onZoomingChanged: ((Bool) -> Void)?,
            onPagingChanged: ((Bool) -> Void)?
        ) {
            self.pageCount = max(0, pageCount)
            self.assetProvider = assetProvider
            self.targetSize = targetSize
            self.contentMode = contentMode
            self.neighborPriority = neighborPriority
            // Set once, from the opening request. Never refreshed afterwards:
            // the seed belongs to the asset the viewer was opened on, and a
            // later update carrying a different preview must not re-seed an
            // unrelated page.
            if self.initialAssetIdentifier == nil {
                self.initialPreviewImage = initialPreviewImage
                self.initialAssetIdentifier = initialAssetIdentifier
            }
            self.onMediaReady = onMediaReady
            self.onZoomingChanged = onZoomingChanged
            self.onPagingChanged = onPagingChanged
            self.isScrubbing = isScrubbing

            guard self.pageCount > 0,
                  let pageController
            else { return }

            let clampedIndex = min(
                max(0, currentIndex),
                self.pageCount - 1
            )

            let displayed = self.displayedIndex.map(String.init) ?? "none"
            let pending = self.pendingProgrammaticIndex.map(String.init) ?? "none"
            let updateSignature = "count=\(self.pageCount) current=\(clampedIndex) displayed=\(displayed) pending=\(pending)"
            if updateSignature != lastUpdateSignature {
                lastUpdateSignature = updateSignature
                PagerDiagnostics.log("update \(updateSignature)")
            }

            guard let displayedIndex else {
                setInitialPage(to: clampedIndex)
                return
            }

            let pageContentSignature = makePageContentSignature(around: clampedIndex)
            if pageContentSignature != lastPageContentSignature {
                lastPageContentSignature = pageContentSignature
                if isManualTransitionInProgress || pendingProgrammaticIndex != nil {
                    // The completed transition refreshes the stable pages.
                    // Never replace a hosting controller's root view while
                    // UIPageViewController is tracking an interactive scroll.
                } else {
                    refreshPages(around: clampedIndex)
                }
            }

            if displayedIndex != clampedIndex {
                // Filmstrip scrubbing produces a burst of index changes per
                // gesture. Animated transitions would queue behind the
                // pending guard and lag behind the finger, so scrub steps
                // swap pages instantly instead.
                if isScrubbing {
                    if let targetPage = page(at: clampedIndex) {
                        let direction: UIPageViewController.NavigationDirection =
                            clampedIndex > displayedIndex ? .forward : .reverse
                        PagerDiagnostics.log(
                            "scrub transition from=\(displayedIndex) to=\(clampedIndex)"
                        )
                        pageController.setViewControllers(
                            [targetPage],
                            direction: direction,
                            animated: false
                        )
                        self.displayedIndex = clampedIndex
                        if isZooming {
                            isZooming = false
                            onZoomingChanged?(false)
                        }
                        // `refreshPages(around:)` already ran above with this
                        // same `clampedIndex`; the second call only rebuilt
                        // three full-screen pages per scrub frame.
                    }
                    return
                }

                // SwiftUI may call updateUIViewController more than once while
                // the destination page is downloading. Do not restart the same
                // UIKit transition on every asset/cache update.
                if pendingProgrammaticIndex == clampedIndex {
                    return
                }
                guard pendingProgrammaticIndex == nil else { return }

                // A filmstrip tap or another external control can change the
                // binding without going through the page controller delegate.
                // Move directly to that asset and leave the controller centered
                // there; there is no selection value to reset afterward.
                guard let visiblePage = pageController.viewControllers?
                    .first as? PhotoPagerPageController
                else { return }

                let direction: UIPageViewController.NavigationDirection =
                    clampedIndex > visiblePage.index ? .forward : .reverse
                guard let targetPage = page(at: clampedIndex) else { return }
                pendingProgrammaticIndex = clampedIndex
                let directionName = direction == .forward ? "forward" : "reverse"
                PagerDiagnostics.log(
                    "external transition from=\(visiblePage.index) to=\(clampedIndex) direction=\(directionName)"
                )
                pageController.setViewControllers(
                    [targetPage],
                    direction: direction,
                    animated: true
                ) { [weak self] _ in
                    guard let self else { return }
                    self.pendingProgrammaticIndex = nil
                    self.displayedIndex = clampedIndex
                    if self.isZooming {
                        self.isZooming = false
                        self.onZoomingChanged?(false)
                    }
                    PagerDiagnostics.log("external transition completed=\(clampedIndex)")
                    self.refreshPages(around: clampedIndex)
                }
            }
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            willTransitionTo pendingViewControllers: [UIViewController]
        ) {
            isManualTransitionInProgress = true
            onPagingChanged?(true)
            let target = (pendingViewControllers.first as? PhotoPagerPageController)?.index
            PagerDiagnostics.log(
                "transition began target=\(target.map(String.init) ?? "none")"
            )
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            guard !isZooming,
                  let photoPage = viewController as? PhotoPagerPageController
            else { return nil }
            PagerDiagnostics.log(
                "data source before page=\(photoPage.index) target=\(photoPage.index - 1) zoom=\(isZooming)"
            )
            return page(at: photoPage.index - 1)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard !isZooming,
                  let photoPage = viewController as? PhotoPagerPageController
            else { return nil }
            PagerDiagnostics.log(
                "data source after page=\(photoPage.index) target=\(photoPage.index + 1) zoom=\(isZooming)"
            )
            return page(at: photoPage.index + 1)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            let visibleIndex = (pageViewController.viewControllers?.first as? PhotoPagerPageController)
                .map { String($0.index) } ?? "none"
            PagerDiagnostics.log(
                "transition finished=\(finished) completed=\(completed) visible=\(visibleIndex)"
            )
            isManualTransitionInProgress = false
            onPagingChanged?(false)

            if finished,
               completed,
               let visiblePage = pageViewController.viewControllers?
                .first as? PhotoPagerPageController {
                let newIndex = visiblePage.index
                pendingProgrammaticIndex = nil
                displayedIndex = newIndex
                lastPageContentSignature = makePageContentSignature(around: newIndex)
                if isZooming {
                    isZooming = false
                    onZoomingChanged?(false)
                }

                if currentIndexBinding.wrappedValue != newIndex {
                    currentIndexBinding.wrappedValue = newIndex
                }
            }

            if let stableIndex = displayedIndex {
                refreshPages(around: stableIndex)
            }
        }

        private func setInitialPage(to index: Int) {
            guard let pageController else { return }
            guard let initialPage = page(at: index) else { return }
            PagerDiagnostics.log("set initial page=\(index)")
            pageController.setViewControllers(
                [initialPage],
                direction: .forward,
                animated: false
            )
            displayedIndex = index
            lastPageContentSignature = makePageContentSignature(around: index)
            refreshPages(around: index)
            if isZooming {
                isZooming = false
                onZoomingChanged?(false)
            }
        }

        private func page(at index: Int) -> PhotoPagerPageController? {
            guard index >= 0, index < pageCount else { return nil }

            if let existing = pages[index] {
                return existing
            }

            PagerDiagnostics.log("create page=\(index)")
            let page = PhotoPagerPageController(
                index: index,
                rootView: makePageView(for: index)
            )
            pages[index] = page
            return page
        }

        private func makePageContentSignature(around index: Int) -> String {
            let assetIDs = ((index - 1)...(index + 1)).map { candidate -> String in
                guard candidate >= 0, candidate < pageCount else { return "edge" }
                return assetProvider(candidate)?.localIdentifier ?? "pending"
            }
            return [
                String(pageCount),
                String(Int(targetSize.width.rounded())),
                String(Int(targetSize.height.rounded())),
                String(contentMode.rawValue),
                String(neighborPriority.rawValue),
                assetIDs.joined(separator: ",")
            ].joined(separator: "|")
        }

        private func makePageView(for index: Int) -> AnyView {
            guard index >= 0, index < pageCount,
                  let asset = assetProvider(index)
            else {
                return AnyView(
                    ZStack {
                        Color.black
                        ProgressView("正在读取照片…")
                            .tint(.white)
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                )
            }

            return AnyView(
                ViewerMediaView(
                    asset: asset,
                    targetSize: targetSize,
                    contentMode: contentMode,
                    requestPriority: displayedIndex == index
                        ? .viewer
                        : neighborPriority,
                    initialImage: asset.localIdentifier == initialAssetIdentifier
                        ? initialPreviewImage
                        : nil,
                    transparentCanvas: true,
                    onReady: { [weak self] ready in
                        guard let self,
                              self.displayedIndex == index
                        else { return }
                        PagerDiagnostics.log(
                            "media ready index=\(index) ready=\(ready)"
                        )
                        self.onMediaReady?(ready)
                    },
                    onZoomingChanged: { [weak self] zooming in
                        guard let self,
                              self.displayedIndex == index
                        else { return }
                        self.isZooming = zooming
                        self.onZoomingChanged?(zooming)
                        PagerDiagnostics.log(
                            "zoom index=\(index) active=\(zooming)"
                        )
                    }
                )
                .id("native-viewer-\(asset.localIdentifier)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
        }

        private func refreshPages(around index: Int) {
            let nearbyIndexes = Set(
                [index - 1, index, index + 1]
                    .filter { $0 >= 0 && $0 < pageCount }
            )

            for nearbyIndex in nearbyIndexes {
                let identity = makePageIdentity(for: nearbyIndex)
                if let existing = pages[nearbyIndex] {
                    // Reassigning `rootView` replaces the hosting controller's
                    // whole SwiftUI tree and drops the decoded image state.
                    // Only do it when the page's actual content changed.
                    guard pageIdentities[nearbyIndex] != identity else { continue }
                    pageIdentities[nearbyIndex] = identity
                    existing.rootView = makePageView(for: nearbyIndex)
                } else {
                    pageIdentities[nearbyIndex] = identity
                    _ = page(at: nearbyIndex)
                }
            }

            // Remove evicted keys individually; rebuilding the whole dictionary
            // with `filter` on every filmstrip scrub step was pure churn.
            for key in pages.keys where !nearbyIndexes.contains(key) {
                pages.removeValue(forKey: key)
                pageIdentities.removeValue(forKey: key)
            }
        }

        /// Everything that must change a page's rendered content *except* the
        /// request priority. Priority flips on every swipe and is applied to
        /// new requests through the view struct; it is not worth rebuilding
        /// three full-screen pages for.
        private func makePageIdentity(for index: Int) -> String {
            let assetID = assetProvider(index)?.localIdentifier ?? "pending"
            return [
                assetID,
                String(Int(targetSize.width.rounded())),
                String(Int(targetSize.height.rounded())),
                String(contentMode.rawValue)
            ].joined(separator: "|")
        }
    }
}

@MainActor
private final class PhotoPagerPageController: UIHostingController<AnyView> {
    let index: Int

    init(index: Int, rootView: AnyView) {
        self.index = index
        super.init(rootView: rootView)
        // Clear: the zoom transition's dimming layer provides the black
        // backdrop, and an opaque page background would make the zoom-out
        // shrink a full-screen rectangle instead of the photo.
        view.backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private struct LivePhotoAssetViewer: View {
    let asset: PHAsset
    let targetSize: CGSize
    let contentMode: PHImageContentMode
    let requestPriority: PhotoRequestPriority
    let transparentCanvas: Bool
    let onReady: (Bool) -> Void

    @ObservedObject private var audioSession = MediaAudioSession.shared
    @State private var livePhoto: PHLivePhoto?
    @State private var requestHandle: PhotoRequestHandle?
    @State private var errorMessage: String?
    @State private var loadAttempt = 0

    var body: some View {
        ZStack {
            if transparentCanvas {
                Color.clear
            } else {
                Color.black
            }

            if let livePhoto {
                LivePhotoUIKitView(
                    livePhoto: livePhoto,
                    contentMode: contentMode,
                    isMuted: audioSession.isMuted
                )
            } else if let errorMessage {
                VStack(spacing: 10) {
                    Image(systemName: "icloud.slash")
                        .font(.title2)
                    Text(errorMessage)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                    Button("重试") {
                        loadAttempt &+= 1
                    }
                    .buttonStyle(.bordered)
                }
                .foregroundStyle(.white.opacity(0.8))
                .padding()
            } else {
                ProgressView("正在读取实况照片…")
                    .tint(.white)
                    .foregroundStyle(.white)
            }
        }
        .task(id: "\(asset.localIdentifier)-\(loadAttempt)") {
            requestLivePhoto()
        }
        .onDisappear {
            PhotoImageManager.shared.cancel(requestHandle)
            requestHandle = nil
        }
    }

    private func requestLivePhoto() {
        PhotoImageManager.shared.cancel(requestHandle)
        livePhoto = nil
        errorMessage = nil
        onReady(false)
        requestHandle = PhotoImageManager.shared.requestLivePhoto(
            for: asset,
            targetSize: targetSize,
            contentMode: contentMode,
            priority: requestPriority,
            isNetworkAccessAllowed: true
        ) { livePhoto, info in
            let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            let error = info?[PHImageErrorKey] as? Error
            Task { @MainActor in
                guard !cancelled else { return }
                if let livePhoto {
                    self.livePhoto = livePhoto
                    self.onReady(true)
                } else if let error {
                    self.errorMessage = error.localizedDescription
                    self.onReady(false)
                } else {
                    self.errorMessage = "实况照片暂时无法读取"
                    self.onReady(false)
                }
            }
        }
    }
}

private struct LivePhotoUIKitView: UIViewRepresentable {
    let livePhoto: PHLivePhoto
    let contentMode: PHImageContentMode
    let isMuted: Bool

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = contentMode == .aspectFill ? .scaleAspectFill : .scaleAspectFit
        view.isMuted = isMuted
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        if view.livePhoto !== livePhoto {
            view.livePhoto = livePhoto
        }
        view.isMuted = isMuted
    }
}

private struct VideoAssetViewer: View {
    let asset: PHAsset
    let requestPriority: PhotoRequestPriority
    let transparentCanvas: Bool
    let onReady: (Bool) -> Void

    /// Not `@Environment(\.appScene.phase)`: this view lives inside the viewer,
    /// where that key is stuck at `.background` (see `AppSceneState`).
    @ObservedObject private var appScene = AppSceneState.shared
    @ObservedObject private var audioSession = MediaAudioSession.shared
    @State private var player: AVPlayer?
    @State private var requestHandle: PhotoRequestHandle?
    @State private var errorMessage: String?
    @State private var loadAttempt = 0

    var body: some View {
        ZStack {
            if transparentCanvas {
                Color.clear
            } else {
                Color.black
            }

            if let player {
                VideoPlayer(player: player)
                    .onAppear {
                        player.isMuted = audioSession.isMuted
                        if appScene.phase == .active {
                            player.play()
                        }
                    }
                    .onDisappear {
                        player.pause()
                    }
            } else if let errorMessage {
                VStack(spacing: 10) {
                    Image(systemName: "video.slash")
                        .font(.title2)
                    Text(errorMessage)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                    Button("重试") {
                        loadAttempt &+= 1
                    }
                    .buttonStyle(.bordered)
                }
                .foregroundStyle(.white.opacity(0.8))
                .padding()
            } else {
                ProgressView("正在准备视频…")
                    .tint(.white)
                    .foregroundStyle(.white)
            }
        }
        .task(id: "\(asset.localIdentifier)-\(loadAttempt)") {
            requestPlayerItem()
        }
        .onChange(of: audioSession.isMuted) { _, isMuted in
            player?.isMuted = isMuted
        }
        .onChange(of: appScene.phase) { _, phase in
            if phase == .active {
                audioSession.resumeAfterBackground()
                player?.play()
            } else {
                player?.pause()
                if phase == .background {
                    audioSession.suspendForBackground()
                }
            }
        }
        .onDisappear {
            PhotoImageManager.shared.cancel(requestHandle)
            requestHandle = nil
            player?.pause()
            player = nil
        }
    }

    private func requestPlayerItem() {
        PhotoImageManager.shared.cancel(requestHandle)
        player?.pause()
        player = nil
        errorMessage = nil
        onReady(false)
        requestHandle = PhotoImageManager.shared.requestPlayerItem(
            for: asset,
            priority: requestPriority,
            isNetworkAccessAllowed: true
        ) { item, info in
            let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            let error = info?[PHImageErrorKey] as? Error
            Task { @MainActor in
                guard !cancelled else { return }
                if let item {
                    let player = AVPlayer(playerItem: item)
                    player.isMuted = self.audioSession.isMuted
                    self.player = player
                    self.onReady(true)
                } else {
                    self.errorMessage = error?.localizedDescription ?? "视频暂时无法播放"
                    self.onReady(false)
                }
            }
        }
    }
}

private struct AssetPager: View {
    let assets: ViewerAssets
    @Binding var currentIndex: Int
    let targetSize: CGSize
    let contentMode: PHImageContentMode
    let neighborPriority: PhotoRequestPriority
    /// First-frame seed, applied only to the asset the viewer opened on.
    let initialPreviewImage: UIImage?
    let initialAssetIdentifier: String?
    let onMediaReady: ((Bool) -> Void)?
    let onZoomingChanged: ((Bool) -> Void)?
    let onPagingChanged: ((Bool) -> Void)?
    // Custom swipe styles only: reports a finished vertical drag so the
    // viewer can decide whether it clears the dismiss threshold. The default
    // system style hands pull-down to the zoom transition instead.
    let onDismissDragEnded: ((ViewerDismissDrag, Bool) -> Void)?
    // True while the user is scrubbing the filmstrip: transitions become
    // instant swaps so the main photo tracks the strip in real time.
    let isScrubbing: Bool
    /// Live dismissal state, forwarded to the pager's arbitration recognizer.
    let transitionState: PhotoViewerTransitionState?

    @State private var isZooming = false
    @State private var customDirection = 1
    @State private var customDragAxis = ViewerDragAxis.undecided
    @AppStorage(PhotoSwipeStyle.storageKey)
    private var swipeStyleRawValue = PhotoSwipeStyle.system.rawValue

    init(
        assets: ViewerAssets,
        currentIndex: Binding<Int>,
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFit,
        neighborPriority: PhotoRequestPriority = .slideshow,
        initialPreviewImage: UIImage? = nil,
        initialAssetIdentifier: String? = nil,
        onMediaReady: ((Bool) -> Void)? = nil,
        onZoomingChanged: ((Bool) -> Void)? = nil,
        onPagingChanged: ((Bool) -> Void)? = nil,
        onDismissDragEnded: ((ViewerDismissDrag, Bool) -> Void)? = nil,
        isScrubbing: Bool = false,
        transitionState: PhotoViewerTransitionState? = nil
    ) {
        self.assets = assets
        _currentIndex = currentIndex
        self.targetSize = targetSize
        self.contentMode = contentMode
        self.neighborPriority = neighborPriority
        self.initialPreviewImage = initialPreviewImage
        self.initialAssetIdentifier = initialAssetIdentifier
        self.onMediaReady = onMediaReady
        self.onZoomingChanged = onZoomingChanged
        self.onPagingChanged = onPagingChanged
        self.onDismissDragEnded = onDismissDragEnded
        self.isScrubbing = isScrubbing
        self.transitionState = transitionState
    }

    private var swipeStyle: PhotoSwipeStyle {
        PhotoSwipeStyle(rawValue: swipeStyleRawValue) ?? .system
    }

    var body: some View {
        Group {
            if assets.count == 0 {
                ContentUnavailableView(
                    "没有可显示的照片",
                    systemImage: "photo",
                    description: Text("这个相册暂时为空。")
                )
                .foregroundStyle(.white)
            } else {
                if swipeStyle == .system {
                    nativePager
                } else {
                    customPager
                }
            }
        }
        .onAppear {
            PagerDiagnostics.beginSession()
            PagerDiagnostics.log(
                "AssetPager appear style=\(swipeStyle.rawValue) count=\(assets.count) index=\(currentIndex)"
            )
        }
        .onChange(of: currentIndex) { oldValue, newValue in
            customDirection = newValue >= oldValue ? 1 : -1
            PagerDiagnostics.log(
                "AssetPager binding index \(oldValue)->\(newValue)"
            )
        }
    }

    private var nativePager: some View {
        NativePhotoPager(
            pageCount: assets.count,
            currentIndex: $currentIndex,
            isScrubbing: isScrubbing,
            transitionState: transitionState,
            assetProvider: { index in
                guard index >= 0, index < assets.count else { return nil }
                return assets.object(at: index)
            },
            targetSize: targetSize,
            contentMode: contentMode,
            neighborPriority: neighborPriority,
            initialPreviewImage: initialPreviewImage,
            initialAssetIdentifier: initialAssetIdentifier,
            onMediaReady: onMediaReady,
            onZoomingChanged: onZoomingChanged,
            onPagingChanged: onPagingChanged
        )
    }

    private var customPager: some View {
        ZStack {
            ViewerMediaView(
                asset: assets.object(at: currentIndex),
                targetSize: targetSize,
                contentMode: contentMode,
                requestPriority: .viewer,
                initialImage: assets.object(at: currentIndex).localIdentifier
                    == initialAssetIdentifier
                    ? initialPreviewImage
                    : nil,
                transparentCanvas: true,
                onReady: { ready in
                    onMediaReady?(ready)
                },
                onZoomingChanged: { zooming in
                    isZooming = zooming
                    onZoomingChanged?(zooming)
                }
            )
            .id("custom-viewer-\(assets.object(at: currentIndex).localIdentifier)")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(
                viewerPageTransition(style: swipeStyle, direction: customDirection)
            )
        }
        .contentShape(Rectangle())
        .simultaneousGesture(customSwipeGesture)
        .animation(isScrubbing ? nil : .easeInOut(duration: 0.32), value: currentIndex)
    }

    private var customSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !isZooming else { return }
                let horizontalDistance = abs(value.translation.width)
                let verticalDistance = value.translation.height

                if customDragAxis == .undecided {
                    guard max(horizontalDistance, abs(verticalDistance)) >= 14 else { return }
                    if verticalDistance >= 18,
                       verticalDistance > horizontalDistance * 1.3 {
                        customDragAxis = .vertical
                    } else if horizontalDistance > abs(verticalDistance) * 1.15
                                || verticalDistance <= 0 {
                        customDragAxis = .horizontal
                    } else {
                        return
                    }
                }
            }
            .onEnded { value in
                let resolvedAxis = customDragAxis
                customDragAxis = .undecided
                let sample = ViewerDismissDrag(
                    translation: value.translation,
                    predictedEndTranslation: value.predictedEndTranslation
                )
                guard !isZooming else { return }
                if resolvedAxis == .vertical {
                    let isStillVertical = value.translation.height
                        > abs(value.translation.width) * 1.2
                    onDismissDragEnded?(sample, !isStillVertical)
                    return
                }
                guard resolvedAxis == .horizontal else { return }
                let horizontalDistance = abs(value.translation.width)
                let verticalDistance = abs(value.translation.height)
                guard horizontalDistance > 72,
                      horizontalDistance > verticalDistance * 1.15
                else { return }

                let nextIndex = value.translation.width < 0
                    ? currentIndex + 1
                    : currentIndex - 1
                guard nextIndex >= 0, nextIndex < assets.count else { return }

                customDirection = nextIndex > currentIndex ? 1 : -1
                withAnimation(.easeInOut(duration: 0.32)) {
                    currentIndex = nextIndex
                }
            }
    }
}

/// What the viewer needs from a photo collection to page through it.
///
/// The viewer only ever asks two things -- how many, and give me the one at this
/// index -- and both `PHFetchResult` and an array answer them. Introducing the
/// abstraction is what lets AI search results page in *relevance* order.
///
/// Why that is needed: `SmartSearchScreen` hands the ranked identifiers to
/// `fetchAssets(withLocalIdentifiers:)`, and measurement on device-class iOS
/// (simulator, iOS 26.3) shows the returned order is unrelated to the order
/// passed in --
///
///     requested first: AA91AB0D, F80027A9
///     returned first:  106E99A1, 99D53A1F
///     input order kept: NO
///
/// -- which matches Apple documenting the order as unspecified. So a ranked
/// result set cannot be expressed as a `PHFetchResult`: opening the 5th search
/// hit would swipe onward in PhotoKit's order rather than the ranking.
///
/// Ordering is a property of the whole viewer, not just the pager: every
/// `assets.object(at:)` in this file resolves `currentIndex`, so the pager, the
/// filmstrip and the info panel must all read the same sequence or the indices
/// desynchronise. Routing them through one type makes that automatic.
enum ViewerAssets {
    case fetch(PHFetchResult<PHAsset>)
    case ordered([PHAsset])

    var count: Int {
        switch self {
        case .fetch(let result): return result.count
        case .ordered(let assets): return assets.count
        }
    }

    func object(at index: Int) -> PHAsset {
        switch self {
        case .fetch(let result): return result.object(at: index)
        case .ordered(let assets): return assets[index]
        }
    }
}

struct PhotoViewerView: View {
    let assets: ViewerAssets
    let initialIndex: Int
    /// First-frame seed handed over by the grid cell that was tapped. Used
    /// only for the opening asset; every other page loads through PhotoKit.
    let initialPreviewImage: UIImage?
    let initialAssetIdentifier: String?
    /// Kept in sync with the displayed photo so the system zoom transition can
    /// resolve the current grid cell at dismissal time.
    let transitionState: PhotoViewerTransitionState?
    @ObservedObject var store: PhotoLibraryStore
    let album: PhotoAlbum?
    let onDismissRequested: (() -> Void)?

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var currentIndex: Int
    @State private var controlsVisible = true
    @State private var isShowingInfo = false
    @State private var isPreparingShare = false
    @State private var isFavorite: Bool
    @State private var filmstripPosition: Int?
    @State private var isScrubbingFilmstrip = false
    @State private var isZooming = false
    @State private var isPaging = false
    @State private var isDismissing = false
    @State private var viewportHeight: CGFloat = 844
    @State private var viewportSize = CGSize(width: 390, height: 844)
    @State private var isFullScreen = false
    @State private var isShowingAlbumPicker = false
    @State private var isShowingSlideshowOptions = false
    @State private var pendingSlideshow: SlideshowLaunch?
    @State private var slideshowLaunch: SlideshowLaunch?
    /// The photo the slideshow was showing when it was closed, so the viewer
    /// comes back on what the user actually last looked at instead of on the
    /// photo they started from.
    @State private var slideshowLastRetarget = 0
    @State private var alert: PhotoVaultAlert?
    @StateObject private var neighborPrefetch = ViewerNeighborPrefetch()

    init(
        assets: ViewerAssets,
        initialIndex: Int,
        store: PhotoLibraryStore,
        album: PhotoAlbum? = nil,
        initialPreviewImage: UIImage? = nil,
        initialAssetIdentifier: String? = nil,
        transitionState: PhotoViewerTransitionState? = nil,
        onDismissRequested: (() -> Void)? = nil
    ) {
        self.assets = assets
        self.initialIndex = min(max(0, initialIndex), max(0, assets.count - 1))
        self.store = store
        self.album = album
        self.initialPreviewImage = initialPreviewImage
        self.initialAssetIdentifier = initialAssetIdentifier
        self.transitionState = transitionState
        self.onDismissRequested = onDismissRequested
        _currentIndex = State(initialValue: self.initialIndex)
        _isFavorite = State(
            initialValue: assets.count > 0 ? assets.object(at: self.initialIndex).isFavorite : false
        )
    }

    var body: some View {
        GeometryReader { presentationProxy in
            ZStack {
                // Keep UIKit's page controller on its original stable layer.
                // Transforming a container around UIPageViewController during
                // an interactive scroll can invalidate UIKit's transition
                // bookkeeping. The page background is transparent: the zoom
                // transition's dimming layer provides the black backdrop, so
                // opening zooms the photo up out of its grid cell and closing
                // zooms it back instead of moving a full-screen page.
                GeometryReader { proxy in
                        AssetPager(
                            assets: assets,
                            currentIndex: $currentIndex,
                            targetSize: mediaTargetSize(for: proxy.size),
                            contentMode: viewerContentMode,
                            initialPreviewImage: initialPreviewImage,
                            initialAssetIdentifier: initialAssetIdentifier,
                            onZoomingChanged: { zooming in
                                isZooming = zooming
                            },
                            onPagingChanged: handlePagingChanged,
                            onDismissDragEnded: handleDismissDragEnded,
                            isScrubbing: isScrubbingFilmstrip,
                            transitionState: transitionState
                        )
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .contentShape(Rectangle())
                        .simultaneousGesture(
                            TapGesture().onEnded {
                                toggleControls()
                            }
                        )
                        .allowsHitTesting(!isDismissing)
                }
                // Only the media canvas is allowed to extend under the status bar
                // and home indicator. Keep the control layer in the cover's safe
                // area so its buttons remain tappable on iPhone and iPad.
                .ignoresSafeArea(.container, edges: .all)

                VStack(spacing: 0) {
                        topBar
                            .opacity(chromeOpacity)
                            .offset(y: controlsVisible ? 0 : -18)

                        Spacer()

                        VStack(spacing: 0) {
                            if assets.count > 0 {
                                ViewerFilmstrip(
                                    assets: assets,
                                    currentIndex: $currentIndex,
                                    position: $filmstripPosition,
                                    onScrubbingChanged: { scrubbing in
                                        isScrubbingFilmstrip = scrubbing
                                    }
                                )
                                .frame(height: 64)
                                .background(
                                    .ultraThinMaterial,
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .padding(.horizontal, 10)
                            }
                            bottomBar
                        }
                        .opacity(chromeOpacity)
                        .offset(y: controlsVisible ? 0 : 24)
                }
                .animation(chromeAnimation, value: controlsVisible)
                .allowsHitTesting(controlsVisible && !isDismissing)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                viewportHeight = max(1, presentationProxy.size.height)
                viewportSize = presentationProxy.size
                updateNeighborPrefetch()
            }
            .onChange(of: presentationProxy.size.height) { _, newHeight in
                viewportHeight = max(1, newHeight)
                viewportSize = presentationProxy.size
                updateNeighborPrefetch()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .statusBarHidden(!controlsVisible || isDismissing)
        .persistentSystemOverlays(.automatic)
        .sheet(isPresented: $isShowingInfo) {
            if assets.count > 0 {
                PhotoInfoView(asset: assets.object(at: currentIndex))
            }
        }
        .sheet(isPresented: $isShowingAlbumPicker) {
            if let currentAsset {
                AlbumPickerSheet(
                    albums: store.albums,
                    folders: store.albumFolders,
                    quickAlbumIDs: store.quickAlbumIDs,
                    onToggleQuickAlbum: { store.toggleQuickAlbum($0) },
                    onCreate: { name in
                        store.createAlbum(named: name, containing: [currentAsset]) { result in
                            handle(result)
                        }
                    },
                    onSelect: { targetAlbum in
                        store.addAssets([currentAsset], to: targetAlbum) { result in
                            handle(result)
                        }
                    }
                )
            }
        }
        .sheet(isPresented: $isShowingSlideshowOptions) {
            SlideshowOptionsSheet(
                title: "幻灯片",
                source: .sequence(assets, startingIndex: currentIndex),
                onStart: { launch in
                    pendingSlideshow = launch
                    isShowingSlideshowOptions = false
                }
            )
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { slideshowLaunch != nil },
                set: { if !$0 { slideshowLaunch = nil } }
            ),
            onDismiss: applySlideshowRetarget
        ) {
            if case .sequence(let assets, let indices, let start, _) = slideshowLaunch {
                SlideshowView(
                    title: titleForSlideshow,
                    assets: assets,
                    indices: indices,
                    initialIndex: start,
                    onSourceIndexChanged: { offset in
                        slideshowLastRetarget = offset
                    }
                )
            }
        }
        .onChange(of: isShowingSlideshowOptions) { _, isShowing in
            guard !isShowing, let launch = pendingSlideshow else { return }
            pendingSlideshow = nil
            slideshowLaunch = launch
        }
        .alert(item: $alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
        .onChange(of: currentIndex) { _, newIndex in
            guard assets.count > 0 else { return }
            isFavorite = assets.object(at: newIndex).isFavorite
            transitionState?.update(
                index: newIndex,
                assetIdentifier: assets.object(at: newIndex).localIdentifier
            )
            updateNeighborPrefetch()
        }
        .onAppear {
            isDismissing = false
            isPaging = false
            transitionState?.update(
                index: currentIndex,
                assetIdentifier: currentAsset?.localIdentifier
            )
            // The zoom transition consults these for the whole time the
            // viewer is on screen: the veto keeps pull-down from stealing
            // drags that belong to the zoomed photo or the pager, and the
            // alignment rect makes the morph land on the photo itself.
            transitionState?.interactiveDismissVeto = { [self] in
                isZooming || isPaging
            }
            transitionState?.zoomAlignmentRectProvider = { [self] containerSize in
                mediaAlignmentRect(in: containerSize)
            }
            PagerDiagnostics.log(
                "viewer appear kind=fetch count=\(assets.count) index=\(currentIndex)"
            )
            updateNeighborPrefetch()
        }
        .onDisappear {
            PagerDiagnostics.log(
                "viewer disappear kind=fetch index=\(currentIndex) dismissing=\(isDismissing)"
            )
            transitionState?.interactiveDismissVeto = nil
            transitionState?.zoomAlignmentRectProvider = nil
            neighborPrefetch.stop()
        }
    }

    /// The rect the photo currently occupies inside the full-screen viewer,
    /// used by the zoom transition to align the source grid cell with the
    /// image rather than the letterboxed view. nil (full-bleed mode, unknown
    /// media) falls back to the system's default whole-view alignment.
    private func mediaAlignmentRect(in containerSize: CGSize) -> CGRect? {
        guard !isFullScreen,
              containerSize.width > 0,
              containerSize.height > 0,
              let asset = currentAsset,
              asset.pixelWidth > 0,
              asset.pixelHeight > 0
        else { return nil }

        let scale = min(
            containerSize.width / CGFloat(asset.pixelWidth),
            containerSize.height / CGFloat(asset.pixelHeight)
        )
        let fittedSize = CGSize(
            width: CGFloat(asset.pixelWidth) * scale,
            height: CGFloat(asset.pixelHeight) * scale
        )
        return CGRect(
            x: (containerSize.width - fittedSize.width) / 2,
            y: (containerSize.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    /// Keep a bounded ring of warm neighbours around the current photo. The
    /// pager still renders only current ± 1 pages; this only asks PhotoKit to
    /// pre-cache the wider ring so a fast swipe lands on a warm frame.
    private func updateNeighborPrefetch() {
        neighborPrefetch.update(
            assets: assets,
            currentIndex: currentIndex,
            targetSize: mediaTargetSize(for: viewportSize),
            contentMode: viewerContentMode
        )
    }

    private var chromeOpacity: Double {
        ViewerMotion.chromeOpacity(isVisible: controlsVisible)
    }

    private var chromeAnimation: Animation {
        accessibilityReduceMotion
            ? ViewerMotion.reducedMotion
            : ViewerMotion.chrome
    }

    private var currentAsset: PHAsset? {
        guard assets.count > 0 else { return nil }
        return assets.object(at: currentIndex)
    }

    private var viewerContentMode: PHImageContentMode {
        isFullScreen ? .aspectFill : .aspectFit
    }

    private func toggleControls() {
        guard !isDismissing else { return }
        withAnimation(chromeAnimation) {
            controlsVisible.toggle()
        }
    }

    private func toggleFullScreen() {
        withAnimation(chromeAnimation) {
            isFullScreen.toggle()
            controlsVisible = !isFullScreen
        }
    }

    private func mediaTargetSize(for size: CGSize) -> CGSize {
        let scale = max(1, displayScale)
        return CGSize(
            width: max(1, size.width * scale),
            height: max(1, size.height * scale)
        )
    }

    /// Custom swipe styles only: the zoom transition's interactive dismissal
    /// never reaches them, so a finished vertical drag is checked against the
    /// commit threshold here. There is no custom trajectory either way — a
    /// commit simply triggers the same system zoom-out as the close button.
    private func handleDismissDragEnded(_ drag: ViewerDismissDrag, cancelled: Bool) {
        guard !cancelled, !isDismissing, !isZooming, !isPaging else { return }

        if ViewerMotion.shouldDismiss(
            translation: drag.translation.height,
            predictedTranslation: drag.predictedEndTranslation.height,
            viewportHeight: viewportHeight
        ) {
            requestDismiss(reason: "pull-down")
        }
    }

    /// Single dismissal entry point for the close button, the custom-style
    /// pull-down and every other exit path. The visual zoom-out itself is
    /// owned by the system transition; this only locks interaction and hands
    /// over to the presentation bridge immediately.
    private func requestDismiss(reason: String) {
        guard !isDismissing, !isPaging else {
            if isPaging {
                PagerDiagnostics.log(
                    "viewer dismiss ignored kind=fetch reason=\(reason) paging=true index=\(currentIndex)"
                )
            }
            return
        }
        isDismissing = true
        PagerDiagnostics.log(
            "viewer dismiss requested kind=fetch reason=\(reason) index=\(currentIndex)"
        )
        onDismissRequested?()
    }

    private func handlePagingChanged(_ paging: Bool) {
        isPaging = paging
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                requestDismiss(reason: "close-button")
            } label: {
                Image(systemName: "xmark")
                    .font(.headline.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .frame(width: 46, height: 46)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("viewer-close")

            Spacer()

            Text("\(currentIndex + 1) / \(assets.count)")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                // Lets a UI test assert *which* photo the viewer is showing,
                // not merely that some viewer opened.
                .accessibilityIdentifier("viewer-counter")

            if currentAsset?.hasPlayableAudio == true {
                MediaAudioButton()
            }

            Button {
                isShowingInfo = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.title3)
                    .frame(width: 36, height: 36)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .frame(width: 46, height: 46)
                    .contentShape(Rectangle())
            }

            Button(action: toggleFullScreen) {
                Image(systemName: isFullScreen
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right")
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 36, height: 36)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .frame(width: 46, height: 46)
                    .contentShape(Rectangle())
            }
            .animation(.snappy(duration: 0.22), value: isFullScreen)
            .accessibilityLabel(isFullScreen ? "退出全屏" : "全屏显示")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    /// Photos-style floating actions: each icon owns an independent liquid
    /// glass circle and a full 46pt hit target; the row itself stays clear.
    private var bottomBar: some View {
        HStack(spacing: 0) {
            viewerBarAction {
                guard assets.count > 0 else { return }
                store.toggleFavorite(assets.object(at: currentIndex))
                isFavorite.toggle()
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .symbolRenderingMode(.hierarchical)
                    .contentTransition(.symbolEffect(.replace))
            }
            .animation(.snappy(duration: 0.22), value: isFavorite)
            .disabled(assets.count == 0)
            .accessibilityLabel(isFavorite ? "取消收藏" : "收藏")

            Spacer()

            viewerBarAction {
                guard assets.count > 0 else { return }
                let asset = assets.object(at: currentIndex)
                if store.isInRecycleBin(asset) {
                    store.removeFromRecycleBin(asset)
                } else {
                    store.addToRecycleBin(asset)
                }
            } label: {
                Image(systemName: assets.count > 0
                    && store.isInRecycleBin(assets.object(at: currentIndex))
                    ? "trash.slash"
                    : "trash")
            }
            .disabled(assets.count == 0)
            .accessibilityLabel(assets.count > 0
                && store.isInRecycleBin(assets.object(at: currentIndex))
                ? "移出回收站"
                : "加入回收站")

            Spacer()

            Menu {
                Button {
                    isShowingAlbumPicker = true
                } label: {
                    Label("移入相册", systemImage: "folder.badge.plus")
                }

                if let album, album.kind == .user {
                    Button(role: .destructive) {
                        removeCurrentFromAlbum()
                    } label: {
                        Label("移出当前相册", systemImage: "folder.badge.minus")
                    }
                }
            } label: {
                Image(systemName: "folder.badge.plus")
                    .frame(width: 46, height: 46)
                    .contentShape(Rectangle())
            }
            .disabled(currentAsset == nil)
            .accessibilityLabel("管理相册")
            .glassEffect(.regular.interactive(), in: Circle())

            Spacer()

            viewerBarAction {
                isShowingSlideshowOptions = true
            } label: {
                Image(systemName: "play.rectangle")
            }
            .disabled(assets.count == 0)
            .accessibilityLabel("播放幻灯片")
            .accessibilityIdentifier("viewer-slideshow")

            Spacer()

            viewerBarAction {
                guard !isPreparingShare, assets.count > 0 else { return }
                isPreparingShare = true
                store.requestShareItems(for: [assets.object(at: currentIndex)]) { items, temporaryURLs in
                    isPreparingShare = false
                    guard !items.isEmpty else { return }
                    ActivityPresenter.present(items: items) {
                        removeTemporaryURLs(temporaryURLs)
                    }
                }
            } label: {
                // Swap the glyph for a spinner inside the same 46pt frame so
                // preparing iCloud data never shifts the bar's layout.
                if isPreparingShare {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            .disabled(isPreparingShare || assets.count == 0)
        }
        .font(.title3.weight(.medium))
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .padding(.horizontal, 26)
        .padding(.bottom, 8)
    }

    private func viewerBarAction<Label: View>(
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label()
                .frame(width: 46, height: 46)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
    }

    private func removeTemporaryURLs(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private var titleForSlideshow: String {
        album?.title ?? "幻灯片"
    }

    /// Follow the slideshow: closing it returns to the photo it was showing,
    /// not to the one it started from.
    private func applySlideshowRetarget() {
        guard assets.count > 0 else { return }
        currentIndex = min(max(0, slideshowLastRetarget), assets.count - 1)
    }

    private func removeCurrentFromAlbum() {
        guard let currentAsset,
              let album,
              album.kind == .user
        else { return }

        store.removeAssets([currentAsset], from: album) { result in
            switch result {
            case .success:
                requestDismiss(reason: "remove-from-album")
            case .failure:
                handle(result)
            }
        }
    }

    private func handle(_ result: Result<Void, Error>) {
        if case .failure(let error) = result {
            alert = PhotoVaultAlert(title: "操作失败", message: error.localizedDescription)
        }
    }
}

private struct ViewerFilmstrip: UIViewRepresentable {
    let assets: ViewerAssets
    @Binding var currentIndex: Int
    @Binding var position: Int?
    var onScrubbingChanged: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            assets: assets,
            currentIndex: $currentIndex,
            position: $position,
            onScrubbingChanged: onScrubbingChanged
        )
    }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: 48, height: 48)
        layout.minimumLineSpacing = 3
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)

        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.alwaysBounceHorizontal = true
        collectionView.decelerationRate = .fast
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.register(
            ViewerFilmstripCell.self,
            forCellWithReuseIdentifier: ViewerFilmstripCell.reuseIdentifier
        )
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.prefetchDataSource = context.coordinator
        context.coordinator.attach(collectionView)
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.update(
            collectionView: collectionView,
            assets: assets,
            currentIndex: currentIndex
        )
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate,
        UICollectionViewDataSourcePrefetching, UIScrollViewDelegate {
        private let thumbnailSize = CGSize(width: 128, height: 128)
        private var assets: ViewerAssets
        private var selectedIndex: Int
        private var collectionView: UICollectionView?
        private var isProgrammaticScroll = false
        private var isUserScrubbing = false
        private var needsInitialScroll = true
        private var currentIndexBinding: Binding<Int>
        private var positionBinding: Binding<Int?>
        private var onScrubbingChanged: (Bool) -> Void

        init(
            assets: ViewerAssets,
            currentIndex: Binding<Int>,
            position: Binding<Int?>,
            onScrubbingChanged: @escaping (Bool) -> Void
        ) {
            self.assets = assets
            selectedIndex = min(max(0, currentIndex.wrappedValue), max(0, assets.count - 1))
            currentIndexBinding = currentIndex
            positionBinding = position
            self.onScrubbingChanged = onScrubbingChanged
        }

        func attach(_ collectionView: UICollectionView) {
            self.collectionView = collectionView
            collectionView.reloadData()
            // SwiftUI creates the representable before its final frame is
            // assigned. Defer the first scroll so opening a photo from the
            // middle of a large library also centers its filmstrip item.
            DispatchQueue.main.async { [weak self] in
                self?.scrollToSelected(animated: false)
            }
        }

        func update(
            collectionView: UICollectionView,
            assets: ViewerAssets,
            currentIndex: Int
        ) {
            self.collectionView = collectionView

            if self.assets.count != assets.count {
                self.assets = assets
                collectionView.reloadData()
            } else {
                self.assets = assets
            }

            let clampedIndex = min(max(0, currentIndex), max(0, assets.count - 1))
            guard clampedIndex != selectedIndex else {
                updateVisibleSelection()
                if needsInitialScroll {
                    scrollToSelected(animated: false)
                }
                return
            }

            selectedIndex = clampedIndex
            updateVisibleSelection()
            scrollToSelected(animated: true)
        }

        func collectionView(
            _ collectionView: UICollectionView,
            numberOfItemsInSection section: Int
        ) -> Int {
            assets.count
        }

        func collectionView(
            _ collectionView: UICollectionView,
            cellForItemAt indexPath: IndexPath
        ) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ViewerFilmstripCell.reuseIdentifier,
                for: indexPath
            ) as! ViewerFilmstripCell
            cell.configure(asset: assets.object(at: indexPath.item), targetSize: thumbnailSize)
            cell.setSelected(indexPath.item == selectedIndex, animated: false)
            return cell
        }

        func collectionView(
            _ collectionView: UICollectionView,
            didSelectItemAt indexPath: IndexPath
        ) {
            // A tap can follow a barely-moved drag that already began a
            // scrub; treat the tap as authoritative and recenter normally.
            endScrubbing()
            select(index: indexPath.item, animated: true, notify: true)
        }

        func collectionView(
            _ collectionView: UICollectionView,
            prefetchItemsAt indexPaths: [IndexPath]
        ) {
            let prefetchAssets = indexPaths.compactMap { indexPath -> PHAsset? in
                guard indexPath.item >= 0, indexPath.item < assets.count else { return nil }
                return assets.object(at: indexPath.item)
            }
            guard !prefetchAssets.isEmpty else { return }
            PhotoImageManager.shared.startCaching(
                assets: prefetchAssets,
                targetSize: thumbnailSize
            )
        }

        func collectionView(
            _ collectionView: UICollectionView,
            cancelPrefetchingForItemsAt indexPaths: [IndexPath]
        ) {
            let prefetchedAssets = indexPaths.compactMap { indexPath -> PHAsset? in
                guard indexPath.item >= 0, indexPath.item < assets.count else { return nil }
                return assets.object(at: indexPath.item)
            }
            guard !prefetchedAssets.isEmpty else { return }
            PhotoImageManager.shared.stopCaching(
                assets: prefetchedAssets,
                targetSize: thumbnailSize
            )
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            // The user took over the strip; a programmatic settle animation
            // may still be running, but their finger wins from here on.
            isProgrammaticScroll = false
            isUserScrubbing = true
            onScrubbingChanged(true)
        }

        /// Photos-style live scrubbing: while the finger drags the strip (or
        /// it decelerates), the asset under the center marker becomes the
        /// current photo immediately instead of after the scroll settles.
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isProgrammaticScroll,
                  scrollView.isTracking || scrollView.isDecelerating
            else { return }
            guard let index = centeredIndex(in: scrollView),
                  index != selectedIndex
            else { return }
            select(index: index, animated: false, notify: true)
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            endScrubbing()
            reportCenteredIndex(in: scrollView)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                endScrubbing()
                reportCenteredIndex(in: scrollView)
            }
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            isProgrammaticScroll = false
        }

        private func endScrubbing() {
            guard isUserScrubbing else { return }
            isUserScrubbing = false
            onScrubbingChanged(false)
        }

        private func select(index: Int, animated: Bool, notify: Bool) {
            guard index >= 0, index < assets.count else { return }
            selectedIndex = index
            updateVisibleSelection()
            if notify {
                currentIndexBinding.wrappedValue = index
                // While the user scrubs, the finger owns the strip offset —
                // do not fight it with scrollToItem or per-frame position
                // writes; the settle happens when the scrub ends.
                if !isUserScrubbing {
                    positionBinding.wrappedValue = index
                    scrollToSelected(animated: animated)
                }
            } else {
                scrollToSelected(animated: animated)
            }
        }

        /// The item currently under the strip's center marker, computed from
        /// the layout geometry so per-frame scrubbing stays allocation-free.
        private func centeredIndex(in scrollView: UIScrollView) -> Int? {
            guard assets.count > 0,
                  scrollView.bounds.width > 0,
                  let layout = collectionView?.collectionViewLayout
                      as? UICollectionViewFlowLayout
            else { return nil }
            let strideLength = layout.itemSize.width + layout.minimumLineSpacing
            guard strideLength > 0 else { return nil }
            let centerContentX = scrollView.contentOffset.x + scrollView.bounds.midX
            let rawIndex = Int(
                floor((centerContentX - layout.sectionInset.left) / strideLength)
            )
            return min(max(0, rawIndex), assets.count - 1)
        }

        private func updateVisibleSelection() {
            guard let collectionView else { return }
            for cell in collectionView.visibleCells {
                guard let filmstripCell = cell as? ViewerFilmstripCell,
                      let indexPath = collectionView.indexPath(for: cell)
                else { continue }
                filmstripCell.setSelected(
                    indexPath.item == selectedIndex,
                    animated: !isUserScrubbing
                )
            }
        }

        private func scrollToSelected(animated: Bool) {
            guard let collectionView,
                  selectedIndex >= 0,
                  selectedIndex < assets.count,
                  collectionView.bounds.width > 0
            else { return }

            isProgrammaticScroll = true
            positionBinding.wrappedValue = selectedIndex
            collectionView.layoutIfNeeded()
            collectionView.scrollToItem(
                at: IndexPath(item: selectedIndex, section: 0),
                at: .centeredHorizontally,
                animated: animated
            )
            if !animated {
                isProgrammaticScroll = false
            }
            needsInitialScroll = false
        }

        private func reportCenteredIndex(in scrollView: UIScrollView) {
            guard !isProgrammaticScroll,
                  let collectionView = scrollView as? UICollectionView
            else { return }

            let center = CGPoint(
                x: scrollView.contentOffset.x + scrollView.bounds.midX,
                y: scrollView.contentOffset.y + scrollView.bounds.midY
            )
            let indexPath = collectionView.indexPathForItem(at: center)
                ?? collectionView.indexPathsForVisibleItems.min {
                    guard let lhs = collectionView.cellForItem(at: $0),
                          let rhs = collectionView.cellForItem(at: $1)
                    else { return false }
                    return abs(lhs.center.x - center.x) < abs(rhs.center.x - center.x)
                }

            guard let index = indexPath?.item,
                  index >= 0,
                  index < assets.count,
                  index != selectedIndex
            else { return }

            select(index: index, animated: false, notify: true)
        }
    }
}

private final class ViewerFilmstripCell: UICollectionViewCell {
    static let reuseIdentifier = "ViewerFilmstripCell"

    private let imageView = UIImageView()
    private var requestHandle: PhotoRequestHandle?
    private var representedIdentifier: String?
    private var representedAsset: PHAsset?
    private var representedTargetSize = CGSize.zero
    private var visualSelection: Bool?
    private var selectionAnimator: UIViewPropertyAnimator?

    override init(frame: CGRect) {
        super.init(frame: frame)

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = .secondarySystemBackground
        imageView.layer.cornerRadius = 8
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        layer.cornerRadius = 8
        layer.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelRequest()
        selectionAnimator?.stopAnimation(true)
        selectionAnimator = nil
        visualSelection = nil
        representedIdentifier = nil
        representedAsset = nil
        imageView.image = nil
        setSelected(false, animated: false)
    }

    func configure(asset: PHAsset, targetSize: CGSize) {
        cancelRequest()
        representedIdentifier = asset.localIdentifier
        representedAsset = asset
        representedTargetSize = targetSize

        // Filmstrip cells recycle constantly while scrubbing. Reuse a decoded
        // thumbnail instead of blanking the cell and waiting on PhotoKit.
        if let cachedImage = PhotoImageManager.shared.cachedImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            scope: .gridThumbnail
        ) {
            imageView.image = cachedImage
        } else {
            imageView.image = nil
        }

        // The strip's prefetch data source owns the PHCachingImageManager
        // cache window; per-cell caching would only add PhotoKit churn.
        requestHandle = PhotoImageManager.shared.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            deliveryMode: .opportunistic,
            resizeMode: .fast,
            priority: .nearGrid,
            isNetworkAccessAllowed: true,
            cacheResult: true,
            cacheScope: .gridThumbnail
        ) { [weak self] image, info in
            let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            guard !cancelled, let image else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      self.representedIdentifier == asset.localIdentifier,
                      self.representedTargetSize == targetSize
                else { return }
                self.imageView.image = image
            }
        }
    }

    func showPlaceholder() {
        cancelRequest()
        representedIdentifier = nil
        representedAsset = nil
        imageView.image = nil
    }

    func setSelected(_ selected: Bool, animated: Bool) {
        guard visualSelection != selected else { return }
        visualSelection = selected
        selectionAnimator?.stopAnimation(true)
        selectionAnimator = nil

        let changes = {
            self.contentView.transform = selected
                ? .identity
                : CGAffineTransform(scaleX: 0.84, y: 0.84)
            self.imageView.alpha = selected ? 1 : 0.72
            self.imageView.layer.borderWidth = selected ? 2 : 0
            self.imageView.layer.borderColor = selected
                ? UIColor.white.cgColor
                : UIColor.clear.cgColor
        }

        guard animated, window != nil else {
            UIView.performWithoutAnimation(changes)
            return
        }

        let animator = UIViewPropertyAnimator(
            duration: 0.22,
            dampingRatio: 0.86,
            animations: changes
        )
        selectionAnimator = animator
        animator.startAnimation()
    }

    private func cancelRequest() {
        PhotoImageManager.shared.cancel(requestHandle)
        requestHandle = nil
    }
}

/// The Unsorted screen is backed by an SQLite index rather than a
/// PHFetchResult containing every matching asset.  This pager keeps the
/// current item and its two neighbors available, then asks PhotoKit for the
/// next three only after a swipe reaches a new index.
private struct IndexedAssetPager: View {
    let totalCount: Int
    let store: PhotoLibraryStore
    @Binding var currentIndex: Int
    @Binding var assetsByIndex: [Int: PHAsset]
    let targetSize: CGSize
    let contentMode: PHImageContentMode
    let neighborPriority: PhotoRequestPriority
    /// First-frame seed for the opening asset only.
    let initialPreviewImage: UIImage?
    let initialAssetIdentifier: String?
    /// Index of the page the seed belongs to. The pager may jump elsewhere
    /// while the opening metadata page loads, and the seed must not follow.
    private let initialPreviewIndex: Int?
    let onMediaReady: ((Bool) -> Void)?
    let onZoomingChanged: ((Bool) -> Void)?
    let onPagingChanged: ((Bool) -> Void)?
    // Custom swipe styles only: reports a finished vertical drag so the
    // viewer can decide whether it clears the dismiss threshold.
    let onDismissDragEnded: ((ViewerDismissDrag, Bool) -> Void)?
    // True while the user is scrubbing the filmstrip: transitions become
    // instant swaps so the main photo tracks the strip in real time.
    let isScrubbing: Bool
    // Mirrors the store's indexing flag; when a sync finishes this pager
    // re-requests its window in case an in-flight page load was dropped.
    let isIndexingUnsorted: Bool
    /// Live dismissal state, forwarded to the pager's arbitration recognizer.
    let transitionState: PhotoViewerTransitionState?

    @State private var loadingOffsets = Set<Int>()
    @State private var loadedOffsets = Set<Int>()
    @State private var loadGeneration: UInt64 = 0
    @State private var isVisible = false
    @State private var loadError: String?
    @State private var isZooming = false
    @State private var customDirection = 1
    @State private var customDragAxis: ViewerDragAxis = .undecided
    @AppStorage(PhotoSwipeStyle.storageKey)
    private var swipeStyleRawValue = PhotoSwipeStyle.system.rawValue

    private let pageSize = 60

    init(
        totalCount: Int,
        store: PhotoLibraryStore,
        currentIndex: Binding<Int>,
        assetsByIndex: Binding<[Int: PHAsset]>,
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFit,
        neighborPriority: PhotoRequestPriority = .slideshow,
        initialPreviewImage: UIImage? = nil,
        initialAssetIdentifier: String? = nil,
        onMediaReady: ((Bool) -> Void)? = nil,
        onZoomingChanged: ((Bool) -> Void)? = nil,
        onPagingChanged: ((Bool) -> Void)? = nil,
        onDismissDragEnded: ((ViewerDismissDrag, Bool) -> Void)? = nil,
        isScrubbing: Bool = false,
        isIndexingUnsorted: Bool = false,
        transitionState: PhotoViewerTransitionState? = nil
    ) {
        self.totalCount = max(0, totalCount)
        self.store = store
        _currentIndex = currentIndex
        _assetsByIndex = assetsByIndex
        self.targetSize = targetSize
        self.contentMode = contentMode
        self.neighborPriority = neighborPriority
        self.initialPreviewImage = initialPreviewImage
        self.initialAssetIdentifier = initialAssetIdentifier
        self.initialPreviewIndex = initialPreviewImage == nil
            ? nil
            : currentIndex.wrappedValue
        self.onMediaReady = onMediaReady
        self.onZoomingChanged = onZoomingChanged
        self.onPagingChanged = onPagingChanged
        self.onDismissDragEnded = onDismissDragEnded
        self.isScrubbing = isScrubbing
        self.isIndexingUnsorted = isIndexingUnsorted
        self.transitionState = transitionState
    }

    private var swipeStyle: PhotoSwipeStyle {
        PhotoSwipeStyle(rawValue: swipeStyleRawValue) ?? .system
    }

    var body: some View {
        Group {
            if totalCount == 0 {
                ContentUnavailableView(
                    "没有可显示的照片",
                    systemImage: "photo",
                    description: Text("这个列表暂时为空。")
                )
                .foregroundStyle(.white)
            } else {
                if swipeStyle == .system {
                    nativePager
                } else {
                    customPager
                }
            }
        }
        .onAppear {
            isVisible = true
            loadGeneration &+= 1
            PagerDiagnostics.beginSession()
            PagerDiagnostics.log(
                "IndexedAssetPager appear style=\(swipeStyle.rawValue) count=\(totalCount) index=\(currentIndex)"
            )
            loadWindow(around: currentIndex)
        }
        .onDisappear {
            isVisible = false
            loadGeneration &+= 1
            loadingOffsets.removeAll()
            PagerDiagnostics.log(
                "IndexedAssetPager disappear generation=\(loadGeneration)"
            )
        }
        .onChange(of: currentIndex) { oldValue, newValue in
            customDirection = newValue >= oldValue ? 1 : -1
            PagerDiagnostics.log(
                "IndexedAssetPager binding index \(oldValue)->\(newValue)"
            )
            trimAssetCache(around: newValue)
            loadWindow(around: newValue)
        }
        .onChange(of: totalCount) { _, newValue in
            loadGeneration &+= 1
            loadingOffsets.removeAll()
            loadedOffsets.removeAll()
            assetsByIndex.removeAll()
            let clampedIndex = min(max(0, currentIndex), max(0, newValue - 1))
            if currentIndex != clampedIndex {
                currentIndex = clampedIndex
            }
            loadWindow(around: clampedIndex)
        }
        .onChange(of: isIndexingUnsorted) { _, indexing in
            // A page load can be dropped by the store's generation guard
            // while an index sync runs. Once the sync finishes, re-request
            // whatever window is still missing instead of leaving the
            // viewer on a placeholder forever.
            guard !indexing else { return }
            loadGeneration &+= 1
            loadingOffsets.removeAll()
            loadedOffsets.removeAll()
            assetsByIndex.removeAll()
            loadWindow(around: currentIndex)
        }
        .overlay {
            if let loadError {
                VStack(spacing: 10) {
                    Image(systemName: "icloud.slash")
                        .font(.title2)
                    Text(loadError)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                    Button("重试") {
                        self.loadError = nil
                        loadWindow(around: currentIndex)
                    }
                    .buttonStyle(.bordered)
                }
                .foregroundStyle(.white.opacity(0.86))
                .padding(20)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding()
            }
        }
        .task(id: "\(totalCount)-\(currentIndex)") {
            loadWindow(around: currentIndex)
        }
    }

    private var nativePager: some View {
        NativePhotoPager(
            pageCount: totalCount,
            currentIndex: $currentIndex,
            isScrubbing: isScrubbing,
            transitionState: transitionState,
            assetProvider: { index in
                assetsByIndex[index]
            },
            targetSize: targetSize,
            contentMode: contentMode,
            neighborPriority: neighborPriority,
            initialPreviewImage: initialPreviewImage,
            initialAssetIdentifier: initialAssetIdentifier,
            onMediaReady: onMediaReady,
            onZoomingChanged: onZoomingChanged,
            onPagingChanged: onPagingChanged
        )
    }

    @ViewBuilder
    private var customPager: some View {
        if let asset = assetsByIndex[currentIndex] {
            ZStack {
                ViewerMediaView(
                    asset: asset,
                    targetSize: targetSize,
                    contentMode: contentMode,
                    requestPriority: .viewer,
                    initialImage: asset.localIdentifier == initialAssetIdentifier
                        ? initialPreviewImage
                        : nil,
                    transparentCanvas: true,
                    onReady: { ready in
                        onMediaReady?(ready)
                    },
                    onZoomingChanged: { zooming in
                        isZooming = zooming
                        onZoomingChanged?(zooming)
                    }
                )
                .id("custom-indexed-viewer-\(asset.localIdentifier)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(
                    viewerPageTransition(style: swipeStyle, direction: customDirection)
                )
            }
            .contentShape(Rectangle())
            .simultaneousGesture(customSwipeGesture)
            .animation(isScrubbing ? nil : .easeInOut(duration: 0.32), value: currentIndex)
        } else if currentIndex == initialIndexForPreview,
                  let initialPreviewImage {
            // The unsorted pager loads metadata page by page, so the opening
            // asset may not have arrived yet. Show the tapped thumbnail
            // instead of a spinner while the page resolves.
            Color.clear
                .overlay {
                    Image(uiImage: initialPreviewImage)
                        .resizable()
                        .scaledToFit()
                }
                .clipped()
                .contentShape(Rectangle())
                .simultaneousGesture(customSwipeGesture)
        } else {
            ProgressView("正在读取照片…")
                .tint(.white)
                .foregroundStyle(.white)
                .contentShape(Rectangle())
                .simultaneousGesture(customSwipeGesture)
        }
    }

    /// Index the seeded preview belongs to. The pager may jump to other
    /// indexes while the opening page loads, and the seed must not follow it.
    private var initialIndexForPreview: Int? {
        guard initialPreviewImage != nil else { return nil }
        return initialPreviewIndex
    }

    private var customSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !isZooming else { return }
                let horizontalDistance = abs(value.translation.width)
                let verticalDistance = value.translation.height

                if customDragAxis == .undecided {
                    guard max(horizontalDistance, abs(verticalDistance)) >= 14 else { return }
                    if verticalDistance >= 18,
                       verticalDistance > horizontalDistance * 1.3 {
                        customDragAxis = .vertical
                    } else if horizontalDistance > abs(verticalDistance) * 1.15
                                || verticalDistance <= 0 {
                        customDragAxis = .horizontal
                    } else {
                        return
                    }
                }
            }
            .onEnded { value in
                let resolvedAxis = customDragAxis
                customDragAxis = .undecided
                let sample = ViewerDismissDrag(
                    translation: value.translation,
                    predictedEndTranslation: value.predictedEndTranslation
                )
                guard !isZooming else { return }
                if resolvedAxis == .vertical {
                    let isStillVertical = value.translation.height
                        > abs(value.translation.width) * 1.2
                    onDismissDragEnded?(sample, !isStillVertical)
                    return
                }
                guard resolvedAxis == .horizontal else { return }
                let horizontalDistance = abs(value.translation.width)
                let verticalDistance = abs(value.translation.height)
                guard horizontalDistance > 72,
                      horizontalDistance > verticalDistance * 1.15
                else { return }

                let nextIndex = value.translation.width < 0
                    ? currentIndex + 1
                    : currentIndex - 1
                guard nextIndex >= 0, nextIndex < totalCount else { return }

                customDirection = nextIndex > currentIndex ? 1 : -1
                withAnimation(.easeInOut(duration: 0.32)) {
                    currentIndex = nextIndex
                }
            }
    }

    private func loadWindow(around index: Int) {
        guard isVisible, totalCount > 0 else { return }
        let clampedIndex = min(max(0, index), totalCount - 1)
        let offset = (clampedIndex / pageSize) * pageSize
        var offsets = [offset]
        if offset > 0 {
            offsets.append(offset - pageSize)
        }
        if offset + pageSize < totalCount {
            offsets.append(offset + pageSize)
        }

        for pageOffset in offsets {
            loadPage(at: pageOffset)
        }
    }

    private func loadPage(at offset: Int) {
        guard offset >= 0, offset < totalCount,
              !loadedOffsets.contains(offset),
              loadingOffsets.insert(offset).inserted
        else { return }

        let limit = min(pageSize, totalCount - offset)
        let requestGeneration = loadGeneration
        store.fetchUnsortedAssets(offset: offset, limit: limit) { result in
            guard isVisible, loadGeneration == requestGeneration else {
                PagerDiagnostics.log(
                    "IndexedAssetPager drop page offset=\(offset) generation=\(requestGeneration)/\(loadGeneration)"
                )
                return
            }
            loadingOffsets.remove(offset)
            guard case .success(let pageAssets) = result else {
                if case .failure(let error) = result {
                    loadError = error.localizedDescription
                }
                return
            }

            loadError = nil
            loadedOffsets.insert(offset)
            var merged = assetsByIndex
            for (localIndex, asset) in pageAssets.enumerated() {
                merged[offset + localIndex] = asset
            }
            assetsByIndex = merged
            trimAssetCache(around: currentIndex)
        }
    }

    private func trimAssetCache(around index: Int) {
        guard totalCount > 0 else {
            assetsByIndex.removeAll()
            loadedOffsets.removeAll()
            return
        }

        let clampedIndex = min(max(0, index), totalCount - 1)
        let lowerBound = max(0, clampedIndex - pageSize)
        let upperBound = min(totalCount, clampedIndex + pageSize * 2)
        assetsByIndex = assetsByIndex.filter {
            $0.key >= lowerBound && $0.key < upperBound
        }
        loadedOffsets = loadedOffsets.filter {
            $0 < upperBound && $0 + pageSize > lowerBound
        }
    }
}

/// A horizontally scrolling, recycled filmstrip for the indexed viewer. It
/// reports the centered thumbnail after a drag and resolves only the page of
/// thumbnails currently visible, so a 100k-photo list does not become a
/// 100k-element in-memory array.
private struct IndexedViewerFilmstrip: UIViewRepresentable {
    let totalCount: Int
    let store: PhotoLibraryStore
    @Binding var currentIndex: Int
    var onScrubbingChanged: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            totalCount: totalCount,
            store: store,
            currentIndex: $currentIndex,
            onScrubbingChanged: onScrubbingChanged
        )
    }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: 48, height: 48)
        layout.minimumLineSpacing = 3
        layout.sectionInset = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)

        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.alwaysBounceHorizontal = true
        collectionView.decelerationRate = .fast
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.register(
            ViewerFilmstripCell.self,
            forCellWithReuseIdentifier: ViewerFilmstripCell.reuseIdentifier
        )
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.prefetchDataSource = context.coordinator
        context.coordinator.attach(collectionView)
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.update(
            collectionView: collectionView,
            totalCount: totalCount,
            currentIndex: currentIndex
        )
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate,
        UICollectionViewDataSourcePrefetching, UIScrollViewDelegate {
        private let pageSize = 180
        private let maxCachedPages = 10
        private var totalCount: Int
        private let store: PhotoLibraryStore
        private var selectedIndex: Int
        private var pages: [Int: [PHAsset]] = [:]
        private var pageOrder: [Int] = []
        private var loadingPages = Set<Int>()
        private weak var collectionView: UICollectionView?
        private var isProgrammaticScroll = false
        private var isUserScrubbing = false
        private var needsInitialScroll = true
        private var currentIndexBinding: Binding<Int>
        private let onScrubbingChanged: (Bool) -> Void

        init(
            totalCount: Int,
            store: PhotoLibraryStore,
            currentIndex: Binding<Int>,
            onScrubbingChanged: @escaping (Bool) -> Void
        ) {
            self.totalCount = max(0, totalCount)
            self.store = store
            selectedIndex = min(max(0, currentIndex.wrappedValue), max(0, totalCount - 1))
            currentIndexBinding = currentIndex
            self.onScrubbingChanged = onScrubbingChanged
        }

        func attach(_ collectionView: UICollectionView) {
            self.collectionView = collectionView
            collectionView.reloadData()
            loadPage(containing: selectedIndex, in: collectionView)
            DispatchQueue.main.async { [weak self] in
                self?.scrollToSelected(animated: false)
            }
        }

        func update(
            collectionView: UICollectionView,
            totalCount: Int,
            currentIndex: Int
        ) {
            self.collectionView = collectionView
            let newCount = max(0, totalCount)
            if newCount != self.totalCount {
                self.totalCount = newCount
                pages.removeAll(keepingCapacity: true)
                pageOrder.removeAll(keepingCapacity: true)
                loadingPages.removeAll()
                needsInitialScroll = true
                collectionView.reloadData()
            }

            let clampedIndex = min(max(0, currentIndex), max(0, self.totalCount - 1))
            guard clampedIndex != selectedIndex else {
                updateVisibleSelection()
                if needsInitialScroll {
                    scrollToSelected(animated: false)
                }
                return
            }

            selectedIndex = clampedIndex
            updateVisibleSelection()
            loadPage(containing: selectedIndex, in: collectionView)
            scrollToSelected(animated: true)
        }

        func collectionView(
            _ collectionView: UICollectionView,
            numberOfItemsInSection section: Int
        ) -> Int {
            totalCount
        }

        func collectionView(
            _ collectionView: UICollectionView,
            cellForItemAt indexPath: IndexPath
        ) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ViewerFilmstripCell.reuseIdentifier,
                for: indexPath
            ) as! ViewerFilmstripCell

            if let asset = asset(at: indexPath.item) {
                cell.configure(asset: asset, targetSize: CGSize(width: 128, height: 128))
            } else {
                cell.showPlaceholder()
                loadPage(containing: indexPath.item, in: collectionView)
            }
            cell.setSelected(indexPath.item == selectedIndex, animated: false)
            return cell
        }

        func collectionView(
            _ collectionView: UICollectionView,
            didSelectItemAt indexPath: IndexPath
        ) {
            guard indexPath.item < totalCount else { return }
            // A tap can follow a barely-moved drag that already began a
            // scrub; treat the tap as authoritative and recenter normally.
            endScrubbing()
            select(index: indexPath.item, animated: true, notify: true)
        }

        func collectionView(
            _ collectionView: UICollectionView,
            prefetchItemsAt indexPaths: [IndexPath]
        ) {
            for indexPath in indexPaths {
                loadPage(containing: indexPath.item, in: collectionView)
            }
        }

        func collectionView(
            _ collectionView: UICollectionView,
            cancelPrefetchingForItemsAt indexPaths: [IndexPath]
        ) {
            // Requests are page-sized and inexpensive compared with the
            // image requests. Let a page already in flight finish so a fast
            // drag does not repeatedly fetch the same metadata.
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isProgrammaticScroll = false
            isUserScrubbing = true
            onScrubbingChanged(true)
        }

        /// Photos-style live scrubbing for the indexed strip: the centered
        /// item becomes the current photo while the scroll is still moving.
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isProgrammaticScroll,
                  scrollView.isTracking || scrollView.isDecelerating
            else { return }
            guard let index = centeredIndex(in: scrollView),
                  index != selectedIndex
            else { return }
            select(index: index, animated: false, notify: true)
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            endScrubbing()
            reportCenteredIndex(in: scrollView)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                endScrubbing()
                reportCenteredIndex(in: scrollView)
            }
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            isProgrammaticScroll = false
        }

        private func endScrubbing() {
            guard isUserScrubbing else { return }
            isUserScrubbing = false
            onScrubbingChanged(false)
        }

        private func select(index: Int, animated: Bool, notify: Bool) {
            guard index >= 0, index < totalCount else { return }
            selectedIndex = index
            updateVisibleSelection()
            if notify { currentIndexBinding.wrappedValue = index }
            loadPage(containing: index, in: collectionView)
            // While the user scrubs, the finger owns the strip offset; do
            // not fight it with scrollToItem until the scrub ends.
            if !isUserScrubbing {
                scrollToSelected(animated: animated)
            }
        }

        /// The item currently under the strip's center marker, computed from
        /// the layout geometry so per-frame scrubbing stays allocation-free.
        private func centeredIndex(in scrollView: UIScrollView) -> Int? {
            guard totalCount > 0,
                  scrollView.bounds.width > 0,
                  let layout = collectionView?.collectionViewLayout
                      as? UICollectionViewFlowLayout
            else { return nil }
            let strideLength = layout.itemSize.width + layout.minimumLineSpacing
            guard strideLength > 0 else { return nil }
            let centerContentX = scrollView.contentOffset.x + scrollView.bounds.midX
            let rawIndex = Int(
                floor((centerContentX - layout.sectionInset.left) / strideLength)
            )
            return min(max(0, rawIndex), totalCount - 1)
        }

        private func updateVisibleSelection() {
            guard let collectionView else { return }
            for cell in collectionView.visibleCells {
                guard let filmstripCell = cell as? ViewerFilmstripCell,
                      let indexPath = collectionView.indexPath(for: cell)
                else { continue }
                filmstripCell.setSelected(
                    indexPath.item == selectedIndex,
                    animated: !isUserScrubbing
                )
            }
        }

        private func scrollToSelected(animated: Bool) {
            guard let collectionView,
                  selectedIndex >= 0,
                  selectedIndex < totalCount,
                  collectionView.bounds.width > 0
            else { return }

            isProgrammaticScroll = true
            collectionView.layoutIfNeeded()
            collectionView.scrollToItem(
                at: IndexPath(item: selectedIndex, section: 0),
                at: .centeredHorizontally,
                animated: animated
            )
            if !animated { isProgrammaticScroll = false }
            needsInitialScroll = false
        }

        private func reportCenteredIndex(in scrollView: UIScrollView) {
            guard !isProgrammaticScroll,
                  let collectionView = scrollView as? UICollectionView
            else { return }

            let center = CGPoint(
                x: scrollView.contentOffset.x + scrollView.bounds.midX,
                y: scrollView.contentOffset.y + scrollView.bounds.midY
            )
            let indexPath = collectionView.indexPathForItem(at: center)
                ?? collectionView.indexPathsForVisibleItems.min {
                    guard let lhs = collectionView.cellForItem(at: $0),
                          let rhs = collectionView.cellForItem(at: $1)
                    else { return false }
                    return abs(lhs.center.x - center.x) < abs(rhs.center.x - center.x)
                }
            guard let index = indexPath?.item,
                  index >= 0,
                  index < totalCount,
                  index != selectedIndex
            else { return }
            select(index: index, animated: false, notify: true)
        }

        private func pageStart(for index: Int) -> Int {
            (max(0, index) / pageSize) * pageSize
        }

        private func asset(at index: Int) -> PHAsset? {
            let start = pageStart(for: index)
            let localIndex = index - start
            return pages[start]?.indices.contains(localIndex) == true
                ? pages[start]?[localIndex]
                : nil
        }

        private func loadPage(containing index: Int, in collectionView: UICollectionView?) {
            guard totalCount > 0, index >= 0, index < totalCount else { return }
            let start = pageStart(for: index)
            guard pages[start] == nil,
                  loadingPages.insert(start).inserted
            else { return }

            let limit = min(pageSize, totalCount - start)
            store.fetchUnsortedAssets(offset: start, limit: limit) { [weak self, weak collectionView] result in
                guard let self else { return }
                self.loadingPages.remove(start)
                guard case .success(let assets) = result else { return }

                self.pages[start] = assets
                self.pageOrder.removeAll { $0 == start }
                self.pageOrder.append(start)
                while self.pageOrder.count > self.maxCachedPages {
                    let evicted = self.pageOrder.removeFirst()
                    self.pages.removeValue(forKey: evicted)
                }

                guard let collectionView else { return }
                let end = min(self.totalCount, start + assets.count)
                let visiblePaths = (start..<end).compactMap { item -> IndexPath? in
                    let path = IndexPath(item: item, section: 0)
                    return collectionView.indexPathsForVisibleItems.contains(path) ? path : nil
                }
                if !visiblePaths.isEmpty { collectionView.reloadItems(at: visiblePaths) }
            }
        }
    }
}

/// Full-screen viewer for the indexed Unsorted list. Its UI intentionally
/// mirrors PhotoViewerView, but its pager and filmstrip never materialize the
/// entire result set.
struct IndexedPhotoViewerView: View {
    let title: String
    let totalCount: Int
    let initialIndex: Int
    /// First-frame seed handed over by the unsorted grid cell that was tapped.
    let initialPreviewImage: UIImage?
    let initialAssetIdentifier: String?
    /// Kept in sync with the displayed photo so the system zoom transition can
    /// resolve the current grid cell at dismissal time.
    let transitionState: PhotoViewerTransitionState?
    @ObservedObject var store: PhotoLibraryStore
    let onDismissRequested: (() -> Void)?

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var currentIndex: Int
    @State private var assetsByIndex: [Int: PHAsset] = [:]
    @State private var controlsVisible = true
    @State private var isShowingInfo = false
    @State private var isPreparingShare = false
    @State private var isFavorite = false
    @State private var isScrubbingFilmstrip = false
    @State private var isZooming = false
    @State private var isPaging = false
    @State private var isDismissing = false
    @State private var viewportHeight: CGFloat = 844
    @State private var viewportSize = CGSize(width: 390, height: 844)
    @State private var isFullScreen = false
    @State private var isShowingAlbumPicker = false
    @State private var isShowingSlideshowOptions = false
    @State private var pendingSlideshow: SlideshowLaunch?
    @State private var slideshowLaunch: SlideshowLaunch?
    /// The photo the slideshow was showing when it was closed; the viewer
    /// returns to it instead of to the photo it started from.
    @State private var slideshowLastAsset: PHAsset?
    @State private var alert: PhotoVaultAlert?
    @StateObject private var neighborPrefetch = ViewerNeighborPrefetch()

    init(
        title: String,
        totalCount: Int,
        initialIndex: Int,
        store: PhotoLibraryStore,
        initialPreviewImage: UIImage? = nil,
        initialAssetIdentifier: String? = nil,
        transitionState: PhotoViewerTransitionState? = nil,
        onDismissRequested: (() -> Void)? = nil
    ) {
        self.title = title
        self.totalCount = max(0, totalCount)
        self.initialIndex = min(max(0, initialIndex), max(0, totalCount - 1))
        self.store = store
        self.initialPreviewImage = initialPreviewImage
        self.initialAssetIdentifier = initialAssetIdentifier
        self.transitionState = transitionState
        self.onDismissRequested = onDismissRequested
        _currentIndex = State(initialValue: self.initialIndex)
    }

    private var currentAsset: PHAsset? {
        assetsByIndex[currentIndex]
    }

    private var currentAssetID: String {
        currentAsset?.localIdentifier ?? "none-\(currentIndex)"
    }

    var body: some View {
        GeometryReader { presentationProxy in
            ZStack {
                // Same stable-layer rule as the regular viewer: never wrap
                // UIPageViewController in the continuously transformed chrome
                // container. Background stays transparent — the zoom
                // transition's dimming layer provides the black backdrop.
                GeometryReader { proxy in
                        IndexedAssetPager(
                            totalCount: totalCount,
                            store: store,
                            currentIndex: $currentIndex,
                            assetsByIndex: $assetsByIndex,
                            targetSize: mediaTargetSize(for: proxy.size),
                            contentMode: viewerContentMode,
                            initialPreviewImage: initialPreviewImage,
                            initialAssetIdentifier: initialAssetIdentifier,
                            onZoomingChanged: { zooming in
                                isZooming = zooming
                            },
                            onPagingChanged: handlePagingChanged,
                            onDismissDragEnded: handleDismissDragEnded,
                            isScrubbing: isScrubbingFilmstrip,
                            isIndexingUnsorted: store.isIndexingUnsorted,
                            transitionState: transitionState
                        )
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .contentShape(Rectangle())
                        .simultaneousGesture(
                            TapGesture().onEnded {
                                toggleControls()
                            }
                        )
                        .allowsHitTesting(!isDismissing)
                }
                .ignoresSafeArea(.container, edges: .all)

                VStack(spacing: 0) {
                        topBar
                            .opacity(chromeOpacity)
                            .offset(y: controlsVisible ? 0 : -18)

                        Spacer()

                        VStack(spacing: 0) {
                            if totalCount > 0 {
                                IndexedViewerFilmstrip(
                                    totalCount: totalCount,
                                    store: store,
                                    currentIndex: $currentIndex,
                                    onScrubbingChanged: { scrubbing in
                                        isScrubbingFilmstrip = scrubbing
                                    }
                                )
                                .frame(height: 64)
                                .background(
                                    .ultraThinMaterial,
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .padding(.horizontal, 10)
                            }
                            bottomBar
                        }
                        .opacity(chromeOpacity)
                        .offset(y: controlsVisible ? 0 : 24)
                }
                .animation(chromeAnimation, value: controlsVisible)
                .allowsHitTesting(controlsVisible && !isDismissing)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                viewportHeight = max(1, presentationProxy.size.height)
                viewportSize = presentationProxy.size
                updateNeighborPrefetch()
            }
            .onChange(of: presentationProxy.size.height) { _, newHeight in
                viewportHeight = max(1, newHeight)
                viewportSize = presentationProxy.size
                updateNeighborPrefetch()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .statusBarHidden(!controlsVisible || isDismissing)
        .persistentSystemOverlays(.automatic)
        .sheet(isPresented: $isShowingInfo) {
            if let currentAsset {
                PhotoInfoView(asset: currentAsset)
            }
        }
        .sheet(isPresented: $isShowingAlbumPicker) {
            if let currentAsset {
                AlbumPickerSheet(
                    albums: store.albums,
                    folders: store.albumFolders,
                    quickAlbumIDs: store.quickAlbumIDs,
                    onToggleQuickAlbum: { store.toggleQuickAlbum($0) },
                    onCreate: { name in
                        store.createAlbum(named: name, containing: [currentAsset]) { result in
                            handle(result)
                        }
                    },
                    onSelect: { targetAlbum in
                        store.addAssets([currentAsset], to: targetAlbum) { result in
                            handle(result)
                        }
                    }
                )
            }
        }
        .sheet(isPresented: $isShowingSlideshowOptions) {
            SlideshowOptionsSheet(
                title: "\(title)幻灯片",
                source: .indexed(
                    store,
                    startingOffset: currentIndex,
                    startingAssetID: currentAsset?.localIdentifier
                ),
                onStart: { launch in
                    pendingSlideshow = launch
                    isShowingSlideshowOptions = false
                }
            )
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { slideshowLaunch != nil },
                set: { if !$0 { slideshowLaunch = nil } }
            ),
            onDismiss: applySlideshowRetarget
        ) {
            if case .indexed(let store, let filter, let start, let count) = slideshowLaunch {
                IndexedSlideshowView(
                    title: title,
                    totalCount: count,
                    store: store,
                    filter: filter,
                    initialIndex: start,
                    onAssetChanged: { asset in
                        slideshowLastAsset = asset
                    }
                )
            }
        }
        .onChange(of: isShowingSlideshowOptions) { _, isShowing in
            guard !isShowing, let launch = pendingSlideshow else { return }
            pendingSlideshow = nil
            slideshowLaunch = launch
        }
        .alert(item: $alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
        .onChange(of: currentAssetID) { _, _ in
            isFavorite = currentAsset?.isFavorite ?? false
            transitionState?.update(
                index: currentIndex,
                assetIdentifier: currentAsset?.localIdentifier
            )
            updateNeighborPrefetch()
        }
        .onAppear {
            isDismissing = false
            isPaging = false
            transitionState?.update(
                index: currentIndex,
                assetIdentifier: currentAsset?.localIdentifier
            )
            transitionState?.interactiveDismissVeto = { [self] in
                isZooming || isPaging
            }
            transitionState?.zoomAlignmentRectProvider = { [self] containerSize in
                mediaAlignmentRect(in: containerSize)
            }
            PagerDiagnostics.log(
                "viewer appear kind=indexed count=\(totalCount) index=\(currentIndex)"
            )
            updateNeighborPrefetch()
        }
        .onDisappear {
            PagerDiagnostics.log(
                "viewer disappear kind=indexed index=\(currentIndex) dismissing=\(isDismissing)"
            )
            transitionState?.interactiveDismissVeto = nil
            transitionState?.zoomAlignmentRectProvider = nil
            neighborPrefetch.stop()
        }
    }

    /// Same contract as the regular viewer: report the fitted photo rect so
    /// the zoom-out morphs the image into its unsorted grid cell.
    private func mediaAlignmentRect(in containerSize: CGSize) -> CGRect? {
        guard !isFullScreen,
              containerSize.width > 0,
              containerSize.height > 0,
              let asset = currentAsset,
              asset.pixelWidth > 0,
              asset.pixelHeight > 0
        else { return nil }

        let scale = min(
            containerSize.width / CGFloat(asset.pixelWidth),
            containerSize.height / CGFloat(asset.pixelHeight)
        )
        let fittedSize = CGSize(
            width: CGFloat(asset.pixelWidth) * scale,
            height: CGFloat(asset.pixelHeight) * scale
        )
        return CGRect(
            x: (containerSize.width - fittedSize.width) / 2,
            y: (containerSize.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    /// The unsorted pager resolves assets page by page, so only the
    /// already-resolved neighbours can be warmed. Same adaptive radius as the
    /// regular viewer; the ring stays bounded by the 60-item metadata page.
    private func updateNeighborPrefetch() {
        var ring: [PHAsset] = []
        let radius = PhotoImageManager.viewerPrefetchRadius
        for offset in 1...max(1, radius) {
            for candidate in [currentIndex - offset, currentIndex + offset]
            where candidate >= 0 && candidate < totalCount {
                if let asset = assetsByIndex[candidate] {
                    ring.append(asset)
                }
            }
        }
        neighborPrefetch.update(
            assets: ring,
            targetSize: mediaTargetSize(for: viewportSize),
            contentMode: viewerContentMode
        )
    }

    private var chromeOpacity: Double {
        ViewerMotion.chromeOpacity(isVisible: controlsVisible)
    }

    private var chromeAnimation: Animation {
        accessibilityReduceMotion
            ? ViewerMotion.reducedMotion
            : ViewerMotion.chrome
    }

    private var viewerContentMode: PHImageContentMode {
        isFullScreen ? .aspectFill : .aspectFit
    }

    private func toggleControls() {
        guard !isDismissing else { return }
        withAnimation(chromeAnimation) {
            controlsVisible.toggle()
        }
    }

    private func toggleFullScreen() {
        withAnimation(chromeAnimation) {
            isFullScreen.toggle()
            controlsVisible = !isFullScreen
        }
    }

    private func mediaTargetSize(for size: CGSize) -> CGSize {
        let scale = max(1, displayScale)
        return CGSize(
            width: max(1, size.width * scale),
            height: max(1, size.height * scale)
        )
    }

    /// Custom swipe styles only; see the regular viewer for the contract.
    private func handleDismissDragEnded(_ drag: ViewerDismissDrag, cancelled: Bool) {
        guard !cancelled, !isDismissing, !isZooming, !isPaging else { return }

        if ViewerMotion.shouldDismiss(
            translation: drag.translation.height,
            predictedTranslation: drag.predictedEndTranslation.height,
            viewportHeight: viewportHeight
        ) {
            requestDismiss(reason: "pull-down")
        }
    }

    /// Single dismissal entry point; the system zoom transition owns the
    /// visual zoom-out.
    private func requestDismiss(reason: String) {
        guard !isDismissing, !isPaging else {
            if isPaging {
                PagerDiagnostics.log(
                    "viewer dismiss ignored kind=indexed reason=\(reason) paging=true index=\(currentIndex)"
                )
            }
            return
        }
        isDismissing = true
        PagerDiagnostics.log(
            "viewer dismiss requested kind=indexed reason=\(reason) index=\(currentIndex)"
        )
        onDismissRequested?()
    }

    private func handlePagingChanged(_ paging: Bool) {
        isPaging = paging
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button { requestDismiss(reason: "close-button") } label: {
                Image(systemName: "xmark")
                    .font(.headline.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .frame(width: 46, height: 46)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("viewer-close")

            Spacer()

            Text("\(min(currentIndex + 1, max(1, totalCount))) / \(totalCount)")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                // Lets a UI test assert *which* photo the viewer is showing,
                // not merely that some viewer opened.
                .accessibilityIdentifier("viewer-counter")

            if currentAsset?.hasPlayableAudio == true {
                MediaAudioButton()
            }

            Button { isShowingInfo = true } label: {
                Image(systemName: "info.circle")
                    .font(.title3)
                    .frame(width: 36, height: 36)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .frame(width: 46, height: 46)
                    .contentShape(Rectangle())
            }
            .disabled(currentAsset == nil)

            Button(action: toggleFullScreen) {
                Image(systemName: isFullScreen
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right")
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 36, height: 36)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .frame(width: 46, height: 46)
                    .contentShape(Rectangle())
            }
            .animation(.snappy(duration: 0.22), value: isFullScreen)
            .accessibilityLabel(isFullScreen ? "退出全屏" : "全屏显示")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    /// Photos-style floating actions: each icon owns an independent liquid
    /// glass circle and a full 46pt hit target; the row itself stays clear.
    private var bottomBar: some View {
        HStack(spacing: 0) {
            viewerBarAction {
                guard let currentAsset else { return }
                store.toggleFavorite(currentAsset)
                isFavorite.toggle()
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .symbolRenderingMode(.hierarchical)
                    .contentTransition(.symbolEffect(.replace))
            }
            .animation(.snappy(duration: 0.22), value: isFavorite)
            .disabled(currentAsset == nil)
            .accessibilityLabel(isFavorite ? "取消收藏" : "收藏")

            Spacer()

            viewerBarAction {
                guard let currentAsset else { return }
                if store.isInRecycleBin(currentAsset) {
                    store.removeFromRecycleBin(currentAsset)
                } else {
                    store.addToRecycleBin(currentAsset)
                }
            } label: {
                Image(systemName: currentAsset.map {
                    store.isInRecycleBin($0) ? "trash.slash" : "trash"
                } ?? "trash")
            }
            .disabled(currentAsset == nil)
            .accessibilityLabel(currentAsset.map {
                store.isInRecycleBin($0) ? "移出回收站" : "加入回收站"
            } ?? "加入回收站")

            Spacer()

            Menu {
                Button {
                    isShowingAlbumPicker = true
                } label: {
                    Label("移入相册", systemImage: "folder.badge.plus")
                }
            } label: {
                Image(systemName: "folder.badge.plus")
                    .frame(width: 46, height: 46)
                    .contentShape(Rectangle())
            }
            .disabled(currentAsset == nil)
            .accessibilityLabel("移入相册")
            .glassEffect(.regular.interactive(), in: Circle())

            Spacer()

            viewerBarAction {
                isShowingSlideshowOptions = true
            } label: {
                Image(systemName: "play.rectangle")
            }
            .disabled(currentAsset == nil || store.unsortedCount == 0)
            .accessibilityLabel("播放幻灯片")
            .accessibilityIdentifier("viewer-slideshow")

            Spacer()

            viewerBarAction {
                guard !isPreparingShare, let currentAsset else { return }
                isPreparingShare = true
                store.requestShareItems(for: [currentAsset]) { items, temporaryURLs in
                    isPreparingShare = false
                    guard !items.isEmpty else { return }
                    ActivityPresenter.present(items: items) {
                        removeTemporaryURLs(temporaryURLs)
                    }
                }
            } label: {
                if isPreparingShare {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            .disabled(isPreparingShare || currentAsset == nil)
        }
        .font(.title3.weight(.medium))
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .padding(.horizontal, 26)
        .padding(.bottom, 8)
    }

    private func viewerBarAction<Label: View>(
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label()
                .frame(width: 46, height: 46)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
    }

    private func removeTemporaryURLs(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Follow the slideshow back into the Unsorted sequence. A filtered
    /// slideshow plays in filtered positions, so the asset's *unfiltered*
    /// rank is what the grid and this viewer index by.
    private func applySlideshowRetarget() {
        guard let asset = slideshowLastAsset else { return }
        let identifier = asset.localIdentifier
        Task { @MainActor in
            guard let rank = try? await store.unsortedSlideshowRank(
                of: identifier,
                matching: SlideshowFilter()
            ) else { return }
            currentIndex = min(max(0, rank), max(0, totalCount - 1))
        }
    }

    private func handle(_ result: Result<Void, Error>) {
        if case .failure(let error) = result {
            alert = PhotoVaultAlert(title: "操作失败", message: error.localizedDescription)
        }
    }
}

/// A slideshow deliberately uses one visible page instead of a dynamically
/// rebuilt TabView window. TabView can restore its selection when that window
/// changes, which is what made autoplay bounce between the first two assets.
/// The current asset is still kept at full display size while only two small
/// neighbors are prefetched.
private struct SlideshowAssetPager: View {
    let assets: ViewerAssets
    /// `nil` plays `assets` as it is; otherwise `indices[position]` is the
    /// offset into `assets` of that playlist position. The content filter is
    /// the only thing that produces a map.
    let indices: [Int]?
    @Binding var currentIndex: Int
    let targetSize: CGSize
    let contentMode: PHImageContentMode
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onMediaReady: (Bool) -> Void
    let transitionStyle: SlideshowTransitionStyle

    @State private var prefetchHandles: [String: PhotoRequestHandle] = [:]
    @State private var isZooming = false
    @State private var transitionDirection = 1

    private var playlistCount: Int {
        indices?.count ?? assets.count
    }

    private var safeIndex: Int {
        min(max(0, currentIndex), max(0, playlistCount - 1))
    }

    /// The asset behind a *playlist* position, which is what every index in
    /// this view means. Playback order and the filter stay in one place, so
    /// the counter, the prefetch window and the swipe all agree.
    private func asset(at position: Int) -> PHAsset? {
        guard position >= 0, position < playlistCount else { return nil }
        let offset = indices.map { $0[position] } ?? position
        return assets.object(at: offset)
    }

    private var currentAsset: PHAsset? {
        asset(at: safeIndex)
    }

    private var currentAssetID: String {
        currentAsset?.localIdentifier ?? "empty"
    }

    var body: some View {
        ZStack {
            Color.black

            if let currentAsset {
                ViewerMediaView(
                    asset: currentAsset,
                    targetSize: targetSize,
                    contentMode: contentMode,
                    requestPriority: .viewer,
                    onReady: onMediaReady,
                    onZoomingChanged: { zooming in
                        if zooming {
                            isZooming = true
                        } else {
                            DispatchQueue.main.async {
                                isZooming = false
                            }
                        }
                    }
                )
                .id("slideshow-\(currentAsset.localIdentifier)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(
                    slideshowPageTransition(
                        style: transitionStyle,
                        direction: transitionDirection
                    )
                )
            } else {
                ContentUnavailableView(
                    "没有可显示的照片",
                    systemImage: "photo",
                    description: Text("这个相册暂时为空。")
                )
                .foregroundStyle(.white)
            }
        }
        .animation(.easeInOut(duration: 0.32), value: currentAssetID)
        .contentShape(Rectangle())
        .simultaneousGesture(swipeGesture)
        .onAppear(perform: updatePrefetch)
        .onChange(of: currentIndex) { oldValue, newValue in
            transitionDirection = newValue >= oldValue ? 1 : -1
            updatePrefetch()
        }
        .onChange(of: targetSize) { _, _ in
            updatePrefetch()
        }
        .onChange(of: contentMode.rawValue) { _, _ in
            updatePrefetch()
        }
        .onDisappear(perform: stopPrefetch)
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard !isZooming else { return }
                let horizontal = abs(value.translation.width)
                let vertical = abs(value.translation.height)
                guard horizontal > 72, horizontal > vertical * 1.15 else { return }
                if value.translation.width < 0 {
                    onNext()
                } else {
                    onPrevious()
                }
            }
    }

    private var prefetchTargetSize: CGSize {
        let longestSide = max(targetSize.width, targetSize.height)
        let factor = longestSide > 900 ? 900 / longestSide : 1
        return CGSize(
            width: max(1, targetSize.width * factor),
            height: max(1, targetSize.height * factor)
        )
    }

    private var fullPrefetchTargetSize: CGSize {
        CGSize(
            width: max(1, targetSize.width),
            height: max(1, targetSize.height)
        )
    }

    private func prefetchKey(for asset: PHAsset) -> String {
        "\(asset.localIdentifier)-\(Int(fullPrefetchTargetSize.width.rounded()))-\(Int(fullPrefetchTargetSize.height.rounded()))-\(contentMode.rawValue)"
    }

    private func updatePrefetch() {
        guard playlistCount > 0 else { return }
        let neighborIndexes = [safeIndex - 1, safeIndex + 1]
            .filter { $0 >= 0 && $0 < playlistCount }
        let neighbors = neighborIndexes.compactMap { asset(at: $0) }

        let desiredPrefetchKeys = Set(
            neighbors.map { prefetchKey(for: $0) }
        )
        let stalePrefetchKeys = prefetchHandles.keys.filter {
            !desiredPrefetchKeys.contains($0)
        }
        for key in stalePrefetchKeys {
            if let handle = prefetchHandles.removeValue(forKey: key) {
                PhotoImageManager.shared.cancel(handle)
            }
        }

        for neighbor in neighbors {
            let key = prefetchKey(for: neighbor)
            if prefetchHandles[key] == nil {
                prefetchHandles[key] = PhotoImageManager.shared.prefetchImage(
                    for: neighbor,
                    targetSize: fullPrefetchTargetSize,
                    contentMode: contentMode,
                    priority: .slideshow
                )
            }
        }
    }

    private func stopPrefetch() {
        for handle in prefetchHandles.values {
            PhotoImageManager.shared.cancel(handle)
        }
        prefetchHandles.removeAll()
    }
}

/// The unsorted list has no PHFetchResult containing all assets. This pager
/// resolves only the current 60-item metadata page and the next page, while
/// playback itself remains independent from iCloud image delivery.
private struct IndexedSlideshowAssetPager: View {
    let totalCount: Int
    let store: PhotoLibraryStore
    /// Pages are LIMIT/OFFSET over the *filtered* order, so the page offsets
    /// here are playlist positions and the SQL does the filtering.
    let filter: SlideshowFilter
    @Binding var currentIndex: Int
    @Binding var assetsByIndex: [Int: PHAsset]
    let targetSize: CGSize
    let contentMode: PHImageContentMode
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onMediaReady: (Bool) -> Void
    let transitionStyle: SlideshowTransitionStyle

    @State private var loadingOffsets = Set<Int>()
    @State private var loadedOffsets = Set<Int>()
    @State private var loadError: String?
    @State private var prefetchHandles: [String: PhotoRequestHandle] = [:]
    @State private var isZooming = false
    @State private var transitionDirection = 1
    /// Page loads are asynchronous. Without a visibility + generation guard a
    /// completion that lands after the slideshow was dismissed still ran
    /// `updatePrefetch()`, which started brand-new network-allowed full-size
    /// requests that nothing would ever cancel.
    @State private var isVisible = false
    @State private var loadGeneration: UInt64 = 0

    private let pageSize = 60

    private var safeIndex: Int {
        min(max(0, currentIndex), max(0, totalCount - 1))
    }

    private var currentAsset: PHAsset? {
        assetsByIndex[safeIndex]
    }

    private var currentAssetID: String {
        currentAsset?.localIdentifier ?? "loading-\(safeIndex)"
    }

    var body: some View {
        ZStack {
            Color.black

            if let currentAsset {
                ViewerMediaView(
                    asset: currentAsset,
                    targetSize: targetSize,
                    contentMode: contentMode,
                    requestPriority: .viewer,
                    onReady: onMediaReady,
                    onZoomingChanged: { zooming in
                        if zooming {
                            isZooming = true
                        } else {
                            DispatchQueue.main.async {
                                isZooming = false
                            }
                        }
                    }
                )
                .id("indexed-slideshow-\(currentAsset.localIdentifier)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(
                    slideshowPageTransition(
                        style: transitionStyle,
                        direction: transitionDirection
                    )
                )
            } else {
                ProgressView("正在读取照片…")
                    .tint(.white)
                    .foregroundStyle(.white)
            }
        }
        .animation(.easeInOut(duration: 0.32), value: currentAssetID)
        .contentShape(Rectangle())
        .simultaneousGesture(swipeGesture)
        .overlay {
            if let loadError {
                VStack(spacing: 10) {
                    Image(systemName: "icloud.slash")
                        .font(.title2)
                    Text(loadError)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                    Button("重试") {
                        self.loadError = nil
                        loadWindow(around: currentIndex)
                    }
                    .buttonStyle(.bordered)
                }
                .foregroundStyle(.white.opacity(0.86))
                .padding(20)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding()
            }
        }
        .onAppear {
            isVisible = true
            loadGeneration &+= 1
            loadWindow(around: currentIndex)
            updatePrefetch()
        }
        .onChange(of: currentIndex) { oldValue, newValue in
            transitionDirection = newValue >= oldValue ? 1 : -1
            loadWindow(around: newValue)
            trimAssetCache(around: newValue)
            updatePrefetch()
        }
        .onChange(of: targetSize) { _, _ in
            updatePrefetch()
        }
        .onChange(of: contentMode.rawValue) { _, _ in
            updatePrefetch()
        }
        .onDisappear {
            // Invalidate in-flight page loads before tearing the prefetch
            // window down, so a late completion cannot restart it.
            isVisible = false
            loadGeneration &+= 1
            stopPrefetch()
        }
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard !isZooming else { return }
                let horizontal = abs(value.translation.width)
                let vertical = abs(value.translation.height)
                guard horizontal > 72, horizontal > vertical * 1.15 else { return }
                if value.translation.width < 0 {
                    onNext()
                } else {
                    onPrevious()
                }
            }
    }

    private var prefetchTargetSize: CGSize {
        let longestSide = max(targetSize.width, targetSize.height)
        let factor = longestSide > 900 ? 900 / longestSide : 1
        return CGSize(
            width: max(1, targetSize.width * factor),
            height: max(1, targetSize.height * factor)
        )
    }

    private var fullPrefetchTargetSize: CGSize {
        CGSize(
            width: max(1, targetSize.width),
            height: max(1, targetSize.height)
        )
    }

    private func prefetchKey(for asset: PHAsset) -> String {
        "\(asset.localIdentifier)-\(Int(fullPrefetchTargetSize.width.rounded()))-\(Int(fullPrefetchTargetSize.height.rounded()))-\(contentMode.rawValue)"
    }

    private func loadWindow(around index: Int) {
        guard totalCount > 0 else { return }
        let offset = (min(max(0, index), totalCount - 1) / pageSize) * pageSize
        loadPage(at: offset)
        if offset + pageSize < totalCount {
            loadPage(at: offset + pageSize)
        }
    }

    private func loadPage(at offset: Int) {
        guard offset >= 0, offset < totalCount,
              !loadedOffsets.contains(offset),
              loadingOffsets.insert(offset).inserted
        else { return }

        let limit = min(pageSize, totalCount - offset)
        let generation = loadGeneration
        store.fetchUnsortedAssets(matching: filter, offset: offset, limit: limit) { result in
            loadingOffsets.remove(offset)
            guard isVisible, loadGeneration == generation else { return }
            switch result {
            case .failure(let error):
                loadError = error.localizedDescription
            case .success(let pageAssets):
                loadError = nil
                loadedOffsets.insert(offset)
                // Batch the binding write: assigning 60 dictionary entries
                // one at a time fired the parent's `@State` 60 times, which
                // re-rendered the whole slideshow per element.
                var updated = assetsByIndex
                for (localIndex, asset) in pageAssets.enumerated() {
                    updated[offset + localIndex] = asset
                }
                assetsByIndex = updated
                trimAssetCache(around: currentIndex)
                updatePrefetch()
            }
        }
    }

    private func trimAssetCache(around index: Int) {
        guard totalCount > 0 else {
            assetsByIndex.removeAll()
            loadedOffsets.removeAll()
            return
        }
        let clampedIndex = min(max(0, index), totalCount - 1)
        let lowerBound = max(0, clampedIndex - pageSize)
        let upperBound = min(totalCount, clampedIndex + pageSize * 2)
        assetsByIndex = assetsByIndex.filter {
            $0.key >= lowerBound && $0.key < upperBound
        }
        loadedOffsets = loadedOffsets.filter {
            $0 < upperBound && $0 + pageSize > lowerBound
        }
    }

    private func updatePrefetch() {
        let neighborAssets = [safeIndex - 1, safeIndex + 1]
            .compactMap { assetsByIndex[$0] }
        let desiredPrefetchKeys = Set(
            neighborAssets.map { prefetchKey(for: $0) }
        )
        let stalePrefetchKeys = prefetchHandles.keys.filter {
            !desiredPrefetchKeys.contains($0)
        }
        for key in stalePrefetchKeys {
            if let handle = prefetchHandles.removeValue(forKey: key) {
                PhotoImageManager.shared.cancel(handle)
            }
        }

        for neighbor in neighborAssets {
            let key = prefetchKey(for: neighbor)
            if prefetchHandles[key] == nil {
                prefetchHandles[key] = PhotoImageManager.shared.prefetchImage(
                    for: neighbor,
                    targetSize: fullPrefetchTargetSize,
                    contentMode: contentMode,
                    priority: .slideshow
                )
            }
        }
    }

    private func stopPrefetch() {
        for handle in prefetchHandles.values {
            PhotoImageManager.shared.cancel(handle)
        }
        prefetchHandles.removeAll()
    }
}

struct SlideshowView: View {
    let title: String
    let assets: ViewerAssets
    /// `nil` plays `assets` as it is; otherwise `indices[position]` is the
    /// offset into `assets` of that playlist position (the content filter's
    /// result). Playback, the counter and the neighbor prefetch all count
    /// *positions*, never raw offsets.
    let indices: [Int]?
    /// Reports the *source* offset (into `assets`) of the photo currently on
    /// screen, so a viewer that launched the slideshow can follow along and
    /// come back on the last photo the user actually saw.
    var onSourceIndexChanged: ((Int) -> Void)?

    @Environment(\.dismiss) private var dismiss
    /// Not `@Environment(\.appScene.phase)`: a slideshow opened from a detail page
    /// inherits the viewer's environment, where that key reads `.background`
    /// and the autoplay task below would never run (see `AppSceneState`).
    @ObservedObject private var appScene = AppSceneState.shared
    @Environment(\.displayScale) private var displayScale
    @State private var currentIndex: Int
    @State private var controlsVisible = true
    @State private var isPaused = false
    @AppStorage(SlideshowSettings.intervalStorageKey)
    private var interval: TimeInterval = SlideshowSettings.defaultInterval
    @AppStorage(SlideshowPlaybackSettings.shufflesKey)
    private var isShuffled = SlideshowPlaybackSettings.defaultShuffles
    @AppStorage(SlideshowSettings.loopsStorageKey)
    private var loops = SlideshowSettings.defaultLoops
    @State private var stoppedAtEnd = false
    @State private var mediaReady = false
    @State private var previousIdleTimerDisabled = false
    /// Backed by the same preference the launch sheet writes, so "填充满画面"
    /// chosen before starting and the in-player full-screen button are one
    /// state instead of two that disagree.
    @AppStorage(SlideshowPlaybackSettings.fillsScreenKey)
    private var isFullScreen = SlideshowPlaybackSettings.defaultFillsScreen
    @AppStorage(SlideshowTransitionStyle.storageKey)
    private var transitionStyleRawValue = SlideshowTransitionStyle.fade.rawValue

    init(
        title: String,
        assets: ViewerAssets,
        indices: [Int]? = nil,
        initialIndex: Int = 0,
        onSourceIndexChanged: ((Int) -> Void)? = nil
    ) {
        self.title = title
        self.assets = assets
        self.indices = indices
        self.onSourceIndexChanged = onSourceIndexChanged
        let count = indices?.count ?? assets.count
        _currentIndex = State(
            initialValue: min(max(0, initialIndex), max(0, count - 1))
        )
    }

    private var transitionStyle: SlideshowTransitionStyle {
        SlideshowTransitionStyle(rawValue: transitionStyleRawValue) ?? .fade
    }

    private var playlistCount: Int {
        indices?.count ?? assets.count
    }

    private func asset(at position: Int) -> PHAsset? {
        guard position >= 0, position < playlistCount else { return nil }
        let offset = indices.map { $0[position] } ?? position
        return assets.object(at: offset)
    }

    private var currentAsset: PHAsset? {
        asset(at: currentIndex)
    }

    /// Playlist position -> offset into the source sequence.
    private func sourceOffset(forPosition position: Int) -> Int? {
        guard position >= 0, position < playlistCount else { return nil }
        return indices.map { $0[position] } ?? position
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            GeometryReader { proxy in
                SlideshowAssetPager(
                    assets: assets,
                    indices: indices,
                    currentIndex: $currentIndex,
                    targetSize: slideshowTargetSize(for: proxy.size),
                    contentMode: slideshowContentMode,
                    onNext: showNext,
                    onPrevious: showPrevious,
                    onMediaReady: { ready in
                        mediaReady = ready
                    },
                    transitionStyle: transitionStyle
                )
            }
            .ignoresSafeArea(.container, edges: .all)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) {
                    controlsVisible.toggle()
                }
            }

            if controlsVisible {
                VStack(spacing: 0) {
                    HStack {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.headline.weight(.semibold))
                                .frame(width: 36, height: 36)
                                .glassEffect(.regular.interactive(), in: Circle())
                        }
                        .accessibilityLabel("关闭幻灯片")
                        .accessibilityIdentifier("slideshow-close")

                        Text(title)
                            .font(.headline)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)

                        if currentAsset?.hasPlayableAudio == true {
                            MediaAudioButton()
                        }

                        Button {
                            isPaused.toggle()
                        } label: {
                            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                                .font(.headline)
                                .frame(width: 36, height: 36)
                                .glassEffect(.regular.interactive(), in: Circle())
                        }

                        Button(action: toggleFullScreen) {
                            Image(systemName: isFullScreen
                                ? "arrow.down.right.and.arrow.up.left"
                                : "arrow.up.left.and.arrow.down.right")
                                .font(.headline)
                                .frame(width: 36, height: 36)
                                .glassEffect(.regular.interactive(), in: Circle())
                        }
                        .accessibilityLabel(isFullScreen ? "退出全屏" : "全屏显示")
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.top, 12)

                    Spacer()

                    VStack(spacing: 12) {
                        HStack(spacing: 22) {
                            Button {
                                showPrevious()
                            } label: {
                                Image(systemName: "backward.fill")
                            }

                            Button {
                                isShuffled.toggle()
                            } label: {
                                Image(systemName: isShuffled ? "shuffle.circle.fill" : "shuffle")
                            }
                            .accessibilityLabel(isShuffled ? "关闭随机播放" : "随机播放")

                            Menu {
                                ForEach(SlideshowSettings.intervalValues, id: \.self) { value in
                                    Button("每 \(Int(value)) 秒") {
                                        interval = value
                                    }
                                }
                            } label: {
                                Label("\(Int(interval)) 秒", systemImage: "speedometer")
                            }

                            Button {
                                toggleLooping()
                            } label: {
                                Image(systemName: loops ? "repeat.circle.fill" : "repeat.circle")
                            }
                            .accessibilityLabel(loops ? "循环播放" : "播放到末尾停止")

                            Button {
                                showNext()
                            } label: {
                                Image(systemName: "forward.fill")
                            }
                        }
                        .font(.title3)

                        HStack {
                            Text(isPaused ? "已暂停" : "每 \(Int(interval)) 秒切换")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.76))
                            Spacer()
                            Text("\(currentIndex + 1) / \(playlistCount)")
                                .font(.caption.weight(.medium))
                                .monospacedDigit()
                                .accessibilityIdentifier("slideshow-counter")
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .presentationBackground(.black)
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(.automatic)
        .onAppear {
            previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
        }
        .onChange(of: currentIndex) { _, position in
            guard let offset = sourceOffset(forPosition: position) else { return }
            onSourceIndexChanged?(offset)
        }
        .onChange(of: appScene.phase) { _, phase in
            if phase == .active {
                UIApplication.shared.isIdleTimerDisabled = true
            } else {
                UIApplication.shared.isIdleTimerDisabled = false
                PhotoImageManager.shared.cancelRequests(exactly: .slideshow)
            }
        }
        .onChange(of: currentIndex) { _, _ in
            mediaReady = false
        }
        .task(id: slideshowTaskID) {
            guard appScene.phase == .active,
                  !isPaused,
                  playlistCount > 1
            else {
                return
            }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    return
                }

                guard !Task.isCancelled,
                      appScene.phase == .active,
                      !isPaused
                else { return }
                // iCloud delivery must never stop the sequence. The new
                // page shows a progress state if needed and the next tick
                // still advances in the requested asset order.
                showNext()
            }
        }
    }

    private var slideshowTaskID: String {
        "\(appScene.phase)-\(isPaused)-\(interval)-\(currentIndex)-\(isShuffled)-\(loops)"
    }

    private var slideshowContentMode: PHImageContentMode {
        isFullScreen ? .aspectFill : .aspectFit
    }

    private func toggleFullScreen() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isFullScreen.toggle()
            controlsVisible = !isFullScreen
        }
    }

    private func showPrevious() {
        guard playlistCount > 1 else { return }
        stoppedAtEnd = false
        currentIndex = currentIndex == 0 ? playlistCount - 1 : currentIndex - 1
    }

    private func showNext() {
        guard playlistCount > 1 else { return }
        if isShuffled {
            stoppedAtEnd = false
            var nextIndex = currentIndex
            while nextIndex == currentIndex {
                nextIndex = Int.random(in: 0..<playlistCount)
            }
            currentIndex = nextIndex
        } else if currentIndex == playlistCount - 1 {
            if loops {
                stoppedAtEnd = false
                isPaused = false
                currentIndex = 0
            } else {
                stoppedAtEnd = true
                isPaused = true
            }
        } else {
            stoppedAtEnd = false
            currentIndex += 1
        }
    }

    private func toggleLooping() {
        loops.toggle()
        if loops && stoppedAtEnd {
            stoppedAtEnd = false
            isPaused = false
        }
    }

    private func slideshowTargetSize(for size: CGSize) -> CGSize {
        let scale = max(1, displayScale)
        return CGSize(
            width: max(1, size.width * scale),
            height: max(1, size.height * scale)
        )
    }
}

/// Slideshow backed by the SQLite unsorted index. It requests only the small
/// window around the current offset and never materializes the complete
/// unassigned result.
struct IndexedSlideshowView: View {
    let title: String
    /// The number of photos *after* filtering: this is the playlist length,
    /// not `store.unsortedCount`, because the pages below are read from the
    /// filtered order.
    let totalCount: Int
    @ObservedObject var store: PhotoLibraryStore
    /// Applied in SQL against the index, so a filtered Unsorted slideshow
    /// pages straight through its matches instead of enumerating the library.
    let filter: SlideshowFilter
    /// Reports the photo on screen so a viewer that launched the slideshow can
    /// come back on the last photo the user actually saw.
    var onAssetChanged: ((PHAsset) -> Void)?

    @Environment(\.dismiss) private var dismiss
    /// Not `@Environment(\.appScene.phase)`: a slideshow opened from a detail page
    /// inherits the viewer's environment, where that key reads `.background`
    /// and the autoplay task below would never run (see `AppSceneState`).
    @ObservedObject private var appScene = AppSceneState.shared
    @Environment(\.displayScale) private var displayScale
    @State private var currentIndex: Int
    @State private var assetsByIndex: [Int: PHAsset] = [:]
    @State private var mediaReady = false
    @State private var controlsVisible = true
    @State private var isPaused = false
    @AppStorage(SlideshowSettings.intervalStorageKey)
    private var interval: TimeInterval = SlideshowSettings.defaultInterval
    @AppStorage(SlideshowPlaybackSettings.shufflesKey)
    private var isShuffled = SlideshowPlaybackSettings.defaultShuffles
    @AppStorage(SlideshowSettings.loopsStorageKey)
    private var loops = SlideshowSettings.defaultLoops
    @State private var stoppedAtEnd = false
    @State private var previousIdleTimerDisabled = false
    /// Same preference the launch sheet writes; see `SlideshowView`.
    @AppStorage(SlideshowPlaybackSettings.fillsScreenKey)
    private var isFullScreen = SlideshowPlaybackSettings.defaultFillsScreen
    @AppStorage(SlideshowTransitionStyle.storageKey)
    private var transitionStyleRawValue = SlideshowTransitionStyle.fade.rawValue

    init(
        title: String,
        totalCount: Int,
        store: PhotoLibraryStore,
        filter: SlideshowFilter = SlideshowFilter(),
        initialIndex: Int = 0,
        onAssetChanged: ((PHAsset) -> Void)? = nil
    ) {
        self.title = title
        self.totalCount = totalCount
        self.store = store
        self.filter = filter
        self.onAssetChanged = onAssetChanged
        _currentIndex = State(
            initialValue: min(max(0, initialIndex), max(0, totalCount - 1))
        )
    }

    private var transitionStyle: SlideshowTransitionStyle {
        SlideshowTransitionStyle(rawValue: transitionStyleRawValue) ?? .fade
    }

    private var currentAsset: PHAsset? {
        assetsByIndex[currentIndex]
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { proxy in
                IndexedSlideshowAssetPager(
                    totalCount: totalCount,
                    store: store,
                    filter: filter,
                    currentIndex: $currentIndex,
                    assetsByIndex: $assetsByIndex,
                    targetSize: slideshowTargetSize(for: proxy.size),
                    contentMode: slideshowContentMode,
                    onNext: showNext,
                    onPrevious: showPrevious,
                    onMediaReady: { ready in mediaReady = ready },
                    transitionStyle: transitionStyle
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        controlsVisible.toggle()
                    }
                }
            }
            .ignoresSafeArea(.container, edges: .all)

            if controlsVisible {
                VStack(spacing: 0) {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.headline.weight(.semibold))
                                .frame(width: 36, height: 36)
                                .glassEffect(.regular.interactive(), in: Circle())
                        }
                        .accessibilityLabel("关闭幻灯片")
                        .accessibilityIdentifier("slideshow-close")

                        Text(title)
                            .font(.headline)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)

                        if currentAsset?.hasPlayableAudio == true {
                            MediaAudioButton()
                        }

                        Button { isPaused.toggle() } label: {
                            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                                .font(.headline)
                                .frame(width: 36, height: 36)
                                .glassEffect(.regular.interactive(), in: Circle())
                        }

                        Button(action: toggleFullScreen) {
                            Image(systemName: isFullScreen
                                ? "arrow.down.right.and.arrow.up.left"
                                : "arrow.up.left.and.arrow.down.right")
                                .font(.headline)
                                .frame(width: 36, height: 36)
                                .glassEffect(.regular.interactive(), in: Circle())
                        }
                        .accessibilityLabel(isFullScreen ? "退出全屏" : "全屏显示")
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.top, 12)

                    Spacer()

                    VStack(spacing: 12) {
                        HStack(spacing: 22) {
                            Button { showPrevious() } label: {
                                Image(systemName: "backward.fill")
                            }

                            Button { isShuffled.toggle() } label: {
                                Image(systemName: isShuffled ? "shuffle.circle.fill" : "shuffle")
                            }

                            Menu {
                                ForEach(SlideshowSettings.intervalValues, id: \.self) { value in
                                    Button("每 \(Int(value)) 秒") { interval = value }
                                }
                            } label: {
                                Label("\(Int(interval)) 秒", systemImage: "speedometer")
                            }

                            Button { toggleLooping() } label: {
                                Image(systemName: loops ? "repeat.circle.fill" : "repeat.circle")
                            }

                            Button { showNext() } label: {
                                Image(systemName: "forward.fill")
                            }
                        }
                        .font(.title3)

                        HStack {
                            Text(isPaused ? "已暂停" : "每 \(Int(interval)) 秒切换")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.76))
                            Spacer()
                            Text("\(min(currentIndex + 1, max(1, totalCount))) / \(totalCount)")
                                .font(.caption.weight(.medium))
                                .monospacedDigit()
                                .accessibilityIdentifier("slideshow-counter")
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .presentationBackground(.black)
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(.automatic)
        .onAppear {
            previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
        }
        .onChange(of: appScene.phase) { _, phase in
            UIApplication.shared.isIdleTimerDisabled = phase == .active
            if phase != .active {
                PhotoImageManager.shared.cancelRequests(exactly: .slideshow)
            }
        }
        .onChange(of: currentIndex) { _, _ in
            mediaReady = false
            if let currentAsset {
                onAssetChanged?(currentAsset)
            }
        }
        .task(id: timerTaskID) {
            guard appScene.phase == .active,
                  !isPaused,
                  totalCount > 1
            else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      appScene.phase == .active,
                      !isPaused
                else { return }
                showNext()
            }
        }
    }

    private var timerTaskID: String {
        "\(appScene.phase)-\(currentIndex)-\(isPaused)-\(interval)-\(isShuffled)-\(loops)"
    }

    private var slideshowContentMode: PHImageContentMode {
        isFullScreen ? .aspectFill : .aspectFit
    }

    private func toggleFullScreen() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isFullScreen.toggle()
            controlsVisible = !isFullScreen
        }
    }

    private func showPrevious() {
        guard totalCount > 1 else { return }
        stoppedAtEnd = false
        currentIndex = currentIndex == 0 ? totalCount - 1 : currentIndex - 1
    }

    private func showNext() {
        guard totalCount > 1 else { return }
        if isShuffled {
            stoppedAtEnd = false
            var nextIndex = currentIndex
            while nextIndex == currentIndex {
                nextIndex = Int.random(in: 0..<totalCount)
            }
            currentIndex = nextIndex
        } else if currentIndex == totalCount - 1 {
            if loops {
                stoppedAtEnd = false
                isPaused = false
                currentIndex = 0
            } else {
                stoppedAtEnd = true
                isPaused = true
            }
        } else {
            stoppedAtEnd = false
            currentIndex += 1
        }
    }

    private func toggleLooping() {
        loops.toggle()
        if loops && stoppedAtEnd {
            stoppedAtEnd = false
            isPaused = false
        }
    }

    private func slideshowTargetSize(for size: CGSize) -> CGSize {
        let scale = max(1, displayScale)
        return CGSize(
            width: max(1, size.width * scale),
            height: max(1, size.height * scale)
        )
    }
}

struct PhotoInfoView: View {
    let asset: PHAsset

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                LabeledContent("尺寸") {
                    Text("\(asset.pixelWidth) × \(asset.pixelHeight)")
                }

                if let creationDate = asset.creationDate {
                    LabeledContent("拍摄时间") {
                        Text(creationDate.formatted(date: .long, time: .shortened))
                    }
                }

                if let location = asset.location {
                    LabeledContent("位置") {
                        Text(
                            String(
                                format: "%.4f, %.4f",
                                location.coordinate.latitude,
                                location.coordinate.longitude
                            )
                        )
                    }
                }

                LabeledContent("标识符") {
                    Text(asset.localIdentifier)
                        .font(.caption)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
            }
            .navigationTitle("照片信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
