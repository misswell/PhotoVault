import Photos
import SwiftUI
import UIKit

// MARK: - Gesture ownership

/// A paging collection view that only claims a touch when the drag is
/// *clearly* horizontal.
///
/// This one override is the whole direction arbitration. `UIPageViewController`
/// paged through an internal `UIScrollView` whose pan recognised a
/// predominantly vertical drag, so the app needed a custom recognizer
/// (`ViewerDownwardIntentGesture`) plus phase bookkeeping to take the downward
/// direction back from it, and the system zoom dismissal was the third
/// recognizer on the same finger. Rejecting the pan at its own beginning means:
///
/// - clearly horizontal → the collection view pages, and nothing else reacts;
/// - clearly vertical → this pan never begins, so the finger is left entirely
///   to UIKit's `ZoomInteractiveDismissSwipeDown`;
/// - zoomed photo or filmstrip scrub → no paging at all.
@MainActor
final class ViewerPagingCollectionView: UICollectionView {
    /// Set while the visible photo is magnified: a drag then belongs to the
    /// photo pan, never to paging.
    var isMediaZoomed = false
    /// Set while the filmstrip is being scrubbed: the main photo follows the
    /// strip, so a stray drag must not start a page turn.
    var isFilmstripScrubbing = false

    override func gestureRecognizerShouldBegin(
        _ gestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === panGestureRecognizer else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        let translation = panGestureRecognizer.translation(in: self)
        let velocity = panGestureRecognizer.velocity(in: self)
        let result = Self.pagerShouldBegin(
            translation: translation,
            velocity: velocity,
            isMediaZoomed: isMediaZoomed,
            isFilmstripScrubbing: isFilmstripScrubbing
        )
        photoVaultTrace(
            "viewer_pager_direction shouldBegin=\(result) tx=\(Int(translation.x)) "
                + "ty=\(Int(translation.y)) vx=\(Int(velocity.x)) vy=\(Int(velocity.y)) "
                + "zoomed=\(isMediaZoomed) scrubbing=\(isFilmstripScrubbing)"
        )
        return result
    }

    /// Pure direction policy, asserted by `debugVerifyDirectionArbitration`.
    ///
    /// Uses the accumulated **translation** rather than the instantaneous
    /// velocity. `gestureRecognizerShouldBegin` runs the moment the touch has
    /// moved far enough to be a pan at all, and at that instant a slow or
    /// briefly-held drag still reports a near-zero, noise-dominated velocity —
    /// measured on device, a deliberate diagonal swipe (`app.swipeLeft()`'s fast
    /// flick pages fine, a held drag does not) was rejected by a
    /// velocity-only ratio. Translation is the same signal without the noise.
    ///
    /// The `1.05` factor is deliberately shallow: a slightly diagonal drag still
    /// pages, a drag that is even a bit more vertical than horizontal does not.
    static func pagerShouldBegin(
        translation: CGPoint,
        velocity: CGPoint,
        isMediaZoomed: Bool,
        isFilmstripScrubbing: Bool
    ) -> Bool {
        guard !isMediaZoomed, !isFilmstripScrubbing else { return false }
        let moved = abs(translation.x) + abs(translation.y)
        // UIKit can ask after only 2–3 points. Even then accumulated movement
        // is reliable; an instantaneous velocity can point the opposite way.
        let (horizontal, vertical) = moved > 0
            ? (abs(translation.x), abs(translation.y))
            : (abs(velocity.x), abs(velocity.y))
        return horizontal > vertical * 1.05
    }

    /// The velocity-only form from the design table, kept for the probe.
    static func pagerShouldBegin(
        velocity: CGPoint,
        isMediaZoomed: Bool,
        isFilmstripScrubbing: Bool
    ) -> Bool {
        pagerShouldBegin(
            translation: .zero,
            velocity: velocity,
            isMediaZoomed: isMediaZoomed,
            isFilmstripScrubbing: isFilmstripScrubbing
        )
    }

    #if DEBUG
    /// Runs the direction table from the design doc. Asserted in debug builds
    /// when the first pager is created, so a regression in the policy is a
    /// crash in tests rather than "下拉偶尔没反应" on device.
    static func debugVerifyDirectionArbitration() {
        func shouldBegin(_ x: CGFloat, _ y: CGFloat) -> Bool {
            pagerShouldBegin(
                velocity: CGPoint(x: x, y: y),
                isMediaZoomed: false,
                isFilmstripScrubbing: false
            )
        }
        assert(shouldBegin(500, 20), "明显横向必须翻页")
        assert(!shouldBegin(100, 300), "明显纵向必须留给系统退出手势")
        assert(!shouldBegin(0, 300), "纯纵向不是翻页")
        assert(shouldBegin(300, 100), "横向占优的斜拖仍是翻页")
        assert(!shouldBegin(100, 100), "均势不归 Pager")

        // Slow / held drags: the translation decides, because a velocity read
        // the instant the pan is recognised is mostly noise.
        func slowDrag(tx: CGFloat, ty: CGFloat) -> Bool {
            pagerShouldBegin(
                translation: CGPoint(x: tx, y: ty),
                velocity: CGPoint(x: 3, y: -2),
                isMediaZoomed: false,
                isFilmstripScrubbing: false
            )
        }
        assert(slowDrag(tx: -60, ty: 12), "缓慢斜拖只要横向占优就必须翻页")
        assert(!slowDrag(tx: 8, ty: 60), "缓慢纵拖必须留给系统退出手势")
        assert(!pagerShouldBegin(translation: CGPoint(x: 1, y: 3),
                                 velocity: CGPoint(x: 500, y: 0),
                                 isMediaZoomed: false, isFilmstripScrubbing: false),
               "起手只有几像素的纵拖也不能被横向速度噪声抢走")
        assert(pagerShouldBegin(translation: CGPoint(x: 3, y: 1),
                                velocity: CGPoint(x: 0, y: 500),
                                isMediaZoomed: false, isFilmstripScrubbing: false),
               "起手只有几像素的横拖也必须按累计位移翻页")
        assert(
            !pagerShouldBegin(
                velocity: CGPoint(x: 500, y: 20),
                isMediaZoomed: true,
                isFilmstripScrubbing: false
            ),
            "照片放大后 Pager 不得拿走手势"
        )
        assert(
            !pagerShouldBegin(
                velocity: CGPoint(x: 500, y: 20),
                isMediaZoomed: false,
                isFilmstripScrubbing: true
            ),
            "胶片条 scrub 期间 Pager 不得拿走手势"
        )
        photoVaultTraceLaunch("viewer_pager_direction_probe passed=true")
    }
    #endif
}

// MARK: - Page cell

/// One full-viewport page. The cell owns a child hosting controller and only
/// rebuilds its SwiftUI tree when the page's *content identity* changes, so a
/// recycled cell keeps whatever the decoder already produced.
@MainActor
final class ViewerPageCell: UICollectionViewCell {
    static let reuseIdentifier = "viewer-page-cell"

    private(set) var pageIndex = -1
    private var host: UIHostingController<AnyView>?
    private var contentIdentity = ""

    func configure(
        pageIndex: Int,
        identity: String,
        rootView: AnyView,
        parent: UIViewController?
    ) {
        if host == nil {
            let host = UIHostingController(rootView: rootView)
            // Clear: the viewer's own black backing is what shows through the
            // letterbox, and the zoom transition morphs the photo itself.
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false
            if let parent {
                parent.addChild(host)
            }
            contentView.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: contentView.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])
            host.didMove(toParent: parent)
            self.host = host
            self.pageIndex = pageIndex
            contentIdentity = identity
            return
        }

        if pageIndex != self.pageIndex {
            self.pageIndex = pageIndex
            // A different page occupies this cell: nothing may be reused.
            contentIdentity = ""
        }
        guard contentIdentity != identity else { return }
        contentIdentity = identity
        // Reassigning `rootView` replaces the page's SwiftUI tree, so it only
        // happens when the page's content actually changed (asset, size,
        // content mode) — not on every index change.
        host?.rootView = rootView
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        pageIndex = -1
        contentIdentity = ""
    }
}

// MARK: - Paging controller

/// Horizontal, viewport-sized pager on `UICollectionView`.
///
/// `UIPageViewController` was replaced because it gave the app a scroll view it
/// could not configure: its pan grabbed vertical drags, and taking them back
/// required a second recognizer plus dismissal-phase arbitration. Here the
/// collection view owns exactly one pan, decides direction once, in one place,
/// and UIKit's zoom dismissal keeps the vertical direction to itself.
///
/// Cells are recycled by UIKit, so a 100k-photo album still creates only the
/// pages around the viewport.
@MainActor
final class ViewerPagingCollectionController: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
    /// Builds one page. `isSeedPage` is true only for the page the viewer was
    /// opened on, which is the only one allowed to show the tapped thumbnail.
    /// The pager decides that from the seed **it captured when it was created**:
    /// resolving it from SwiftUI's live `currentIndex` would let the thumbnail
    /// follow the user to whatever page they swiped to.
    typealias PageRootView = (
        _ index: Int,
        _ isCurrent: Bool,
        _ isSeedPage: Bool,
        _ onReady: @escaping (Bool) -> Void,
        _ onZooming: @escaping (Bool) -> Void
    ) -> AnyView

    let collectionView: ViewerPagingCollectionView
    private let layout = UICollectionViewFlowLayout()

    private(set) var pageCount = 0
    private(set) var currentIndex = 0
    private var isScrubbing = false
    private var assetProvider: (Int) -> PHAsset? = { _ in nil }
    private var pageRootView: PageRootView?
    private var pageIdentity: ((Int) -> String)?
    private var targetSize = CGSize.zero
    private var contentMode: PHImageContentMode = .aspectFit
    private var neighborPriority: PhotoRequestPriority = .slideshow
    private var initialPreviewImage: UIImage?
    private var initialAssetIdentifier: String?
    /// Index the seed belongs to, captured with it. Nil until the first update
    /// (which is the update that carries the opening request).
    private var seedIndex: Int?
    private var isZooming = false
    private var hasReportedPaging = false
    private var lastContentSignature = ""
    private var hasInstalledDirectionProbe = false

    var onIndexChanged: ((Int) -> Void)?
    var onMediaReady: ((Bool) -> Void)?
    var onZoomingChanged: ((Bool) -> Void)?
    var onPagingChanged: ((Bool) -> Void)?

    override init() {
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = .zero
        layout.itemSize = CGSize(width: 320, height: 480)
        collectionView = ViewerPagingCollectionView(
            frame: .zero,
            collectionViewLayout: layout
        )
        super.init()
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isPagingEnabled = true
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.showsVerticalScrollIndicator = false
        collectionView.alwaysBounceHorizontal = false
        collectionView.alwaysBounceVertical = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.backgroundColor = .black
        collectionView.accessibilityIdentifier = "viewer-pager"
        collectionView.register(
            ViewerPageCell.self,
            forCellWithReuseIdentifier: ViewerPageCell.reuseIdentifier
        )
        #if DEBUG
        if !hasInstalledDirectionProbe {
            hasInstalledDirectionProbe = true
            ViewerPagingCollectionView.debugVerifyDirectionArbitration()
        }
        #endif
    }

    // MARK: Configuration

    func update(
        pageCount: Int,
        currentIndex: Int,
        isScrubbing: Bool,
        assetProvider: @escaping (Int) -> PHAsset?,
        pageRootView: @escaping PageRootView,
        pageIdentity: @escaping (Int) -> String,
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        neighborPriority: PhotoRequestPriority,
        initialPreviewImage: UIImage?,
        initialAssetIdentifier: String?
    ) {
        let previousCount = self.pageCount
        self.pageCount = max(0, pageCount)
        self.assetProvider = assetProvider
        self.pageRootView = pageRootView
        self.pageIdentity = pageIdentity
        self.targetSize = targetSize
        self.contentMode = contentMode
        self.neighborPriority = neighborPriority
        // Seeded once, from the opening request: the grid thumbnail belongs to
        // the asset the viewer was opened on and must not follow the user.
        if self.initialAssetIdentifier == nil {
            self.initialPreviewImage = initialPreviewImage
            self.initialAssetIdentifier = initialAssetIdentifier
            self.seedIndex = initialPreviewImage == nil ? nil : currentIndex
        }
        self.isScrubbing = isScrubbing
        collectionView.isFilmstripScrubbing = isScrubbing

        guard self.pageCount > 0 else { return }

        if previousCount != self.pageCount {
            collectionView.reloadData()
            collectionView.contentOffset = .zero
            self.currentIndex = 0
            lastContentSignature = ""
        }

        let clamped = min(max(0, currentIndex), self.pageCount - 1)
        if clamped != self.currentIndex {
            // External jump (filmstrip scrub or tap, slideshow retarget):
            // follow it instantly while scrubbing so the main photo tracks the
            // strip, otherwise animate.
            setCurrentIndex(clamped, animated: !isScrubbing)
        }

        let signature = makeContentSignature()
        if signature != lastContentSignature {
            lastContentSignature = signature
            refreshVisiblePages()
        }
    }

    /// Programmatic page change from the filmstrip or a retarget after the
    /// slideshow closes.
    func setCurrentIndex(_ index: Int, animated: Bool) {
        let clamped = min(max(0, index), max(0, pageCount - 1))
        if clamped != currentIndex {
            currentIndex = clamped
            resetZoomState()
        }
        guard pageCount > 0, collectionView.bounds.width > 0 else { return }
        let target = CGPoint(x: CGFloat(clamped) * collectionView.bounds.width, y: 0)
        guard abs(collectionView.contentOffset.x - target.x) > 0.5 else { return }
        collectionView.setContentOffset(target, animated: animated)
    }

    func viewportDidChange(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        if layout.itemSize != size {
            layout.itemSize = size
            layout.invalidateLayout()
            collectionView.layoutIfNeeded()
        }
        guard pageCount > 0 else { return }
        let target = CGPoint(x: CGFloat(currentIndex) * size.width, y: 0)
        guard abs(collectionView.contentOffset.x - target.x) > 0.5 else { return }
        collectionView.setContentOffset(target, animated: false)
    }

    func invalidate() {
        collectionView.dataSource = nil
        collectionView.delegate = nil
        onIndexChanged = nil
        onMediaReady = nil
        onZoomingChanged = nil
        onPagingChanged = nil
    }

    // MARK: Data source

    func collectionView(
        _ collectionView: UICollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        pageCount
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: ViewerPageCell.reuseIdentifier,
            for: indexPath
        ) as! ViewerPageCell
        configure(cell, at: indexPath.item)
        return cell
    }

    private func configure(_ cell: ViewerPageCell, at index: Int) {
        guard let pageRootView, index >= 0, index < pageCount else { return }
        let identity = pageIdentity?(index) ?? "\(index)"
        cell.configure(
            pageIndex: index,
            identity: identity,
            rootView: pageRootView(
                index,
                index == currentIndex,
                index == seedIndex,
                { [weak self] ready in self?.handleReady(ready, index: index) },
                { [weak self] zooming in self?.handleZooming(zooming, index: index) }
            ),
            parent: parentController
        )
    }

    /// Kept so the child hosting controllers join the right parent.
    weak var parentController: UIViewController?

    private func refreshVisiblePages() {
        guard !collectionView.isDragging,
              !collectionView.isDecelerating,
              !isZooming
        else { return }
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let cell = collectionView.cellForItem(at: indexPath) as? ViewerPageCell
            else { continue }
            configure(cell, at: indexPath.item)
        }
    }

    /// Everything that must change a page's rendered content, minus the request
    /// priority (which flips on every swipe and is not worth rebuilding three
    /// full-screen pages for).
    private func makeContentSignature() -> String {
        guard pageCount > 0 else { return "empty" }
        var parts = [
            String(pageCount),
            String(Int(targetSize.width.rounded())),
            String(Int(targetSize.height.rounded())),
            String(contentMode.rawValue)
        ]
        let lower = max(0, currentIndex - 1)
        let upper = min(pageCount - 1, currentIndex + 1)
        if lower <= upper {
            for index in lower...upper {
                parts.append(assetProvider(index)?.localIdentifier ?? "pending")
            }
        }
        return parts.joined(separator: "|")
    }

    // MARK: Media callbacks

    private func handleReady(_ ready: Bool, index: Int) {
        guard index == currentIndex else { return }
        onMediaReady?(ready)
    }

    private func handleZooming(_ zooming: Bool, index: Int) {
        guard index == currentIndex else { return }
        isZooming = zooming
        collectionView.isMediaZoomed = zooming
        onZoomingChanged?(zooming)
    }

    private func resetZoomState() {
        guard isZooming else {
            collectionView.isMediaZoomed = false
            return
        }
        isZooming = false
        collectionView.isMediaZoomed = false
        onZoomingChanged?(false)
    }

    // MARK: Paging

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        photoVaultTrace(
            "viewer_pager_drag_begin offset=\(Int(scrollView.contentOffset.x)) "
                + "size=\(Int(scrollView.contentSize.width)) bounds=\(Int(scrollView.bounds.width)) "
                + "pages=\(pageCount)"
        )
        guard !hasReportedPaging else { return }
        hasReportedPaging = true
        onPagingChanged?(true)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        photoVaultTrace(
            "viewer_pager_drag_end offset=\(Int(scrollView.contentOffset.x)) "
                + "decelerate=\(decelerate)"
        )
        guard !decelerate else { return }
        finishPaging()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        photoVaultTrace("viewer_pager_decelerate_end offset=\(Int(scrollView.contentOffset.x))")
        finishPaging()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        finishPaging()
    }

    /// Native-like commitment for a page turn.
    ///
    /// Left to itself, a paging scroll view needs either more than half a page
    /// of travel or a release velocity. The system photo viewer instead commits
    /// on a moderate drag (around a third of the width) and on a directional
    /// flick. Measured on device-class iOS: a deliberate 70%-of-width diagonal
    /// drag reached the scroll view as only ~129 of its 281 points (recognition
    /// starts after the competing system gesture yields), i.e. 32% — under the
    /// default threshold, so a clearly horizontal drag snapped back and read as
    /// "翻不动".
    ///
    /// This decides the *target index*; UIKit still animates the snap, so no
    /// paging animation is reimplemented here.
    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        let width = scrollView.bounds.width
        guard width > 0, pageCount > 1 else { return }
        let current = scrollView.contentOffset.x / width
        let dragged = scrollView.panGestureRecognizer.translation(in: scrollView).x
        let page: CGFloat
        if abs(velocity.x) > 200 {
            // A flick advances exactly one page in its own direction: never
            // skip a photo because the release was fast.
            page = velocity.x < 0 ? floor(current) + 1 : ceil(current) - 1
        } else if abs(dragged) > width * Self.pagingCommitFraction {
            page = dragged < 0 ? floor(current) + 1 : ceil(current) - 1
        } else {
            page = current.rounded()
        }
        let clamped = min(max(0, page), CGFloat(pageCount - 1))
        targetContentOffset.pointee.x = clamped * width
        photoVaultTrace(
            "viewer_pager_target from=\(String(format: "%.2f", current)) "
                + "dragged=\(Int(dragged)) vx=\(Int(velocity.x)) target=\(Int(clamped))"
        )
    }

    /// Fraction of the viewport a slow drag must cover before the page turns.
    /// Keep this short so a deliberate swipe commits without requiring the
    /// long travel of UIScrollView's default half-page threshold.
    static let pagingCommitFraction: CGFloat = 0.06

    private func finishPaging() {
        if hasReportedPaging {
            hasReportedPaging = false
            onPagingChanged?(false)
        }
        settleIndex()
        refreshVisiblePages()
    }

    /// The page the pager came to rest on. `pagingEnabled` guarantees the
    /// offset is a whole number of viewport widths, so this is exact.
    private func settleIndex() {
        guard pageCount > 0, collectionView.bounds.width > 0 else { return }
        let raw = collectionView.contentOffset.x / collectionView.bounds.width
        let index = min(max(0, Int(raw.rounded())), pageCount - 1)
        photoVaultTrace(
            "viewer_pager_settle raw=\(String(format: "%.2f", raw)) index=\(index) "
                + "current=\(currentIndex)"
        )
        guard index != currentIndex else { return }
        currentIndex = index
        resetZoomState()
        onIndexChanged?(index)
    }
}

// MARK: - Container

/// Hosts the pager and keeps the page size glued to the viewport.
@MainActor
final class ViewerPagingContainerController: UIViewController {
    private let pager: ViewerPagingCollectionController

    init(pager: ViewerPagingCollectionController) {
        self.pager = pager
        super.init(nibName: nil, bundle: nil)
        pager.parentController = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func loadView() {
        let view = UIView()
        view.backgroundColor = .black
        let collectionView = pager.collectionView
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        self.view = view
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        pager.viewportDidChange(to: view.bounds.size)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
}

// MARK: - SwiftUI bridge

/// The SwiftUI-facing pager. Both viewers (library/album and unsorted) drive it
/// through this, so the paging, direction arbitration and index reporting exist
/// in exactly one place.
struct ViewerPagingCollectionRepresentable: UIViewControllerRepresentable {
    let pageCount: Int
    /// Live index from SwiftUI. Programmatic changes (filmstrip, slideshow
    /// retarget) arrive here; user swipes report back through `onIndexChanged`.
    let currentIndex: Int
    let isScrubbing: Bool
    let assetProvider: (Int) -> PHAsset?
    let pageIdentity: (Int) -> String
    let pageRootView: ViewerPagingCollectionController.PageRootView
    let targetSize: CGSize
    let contentMode: PHImageContentMode
    let neighborPriority: PhotoRequestPriority
    let initialPreviewImage: UIImage?
    let initialAssetIdentifier: String?
    let onIndexChanged: (Int) -> Void
    let onMediaReady: ((Bool) -> Void)?
    let onZoomingChanged: ((Bool) -> Void)?
    let onPagingChanged: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> ViewerPagingContainerController {
        let container = ViewerPagingContainerController(pager: context.coordinator.controller)
        apply(to: context.coordinator.controller)
        return container
    }

    func updateUIViewController(
        _ container: ViewerPagingContainerController,
        context: Context
    ) {
        apply(to: context.coordinator.controller)
    }

    static func dismantleUIViewController(
        _ container: ViewerPagingContainerController,
        coordinator: Coordinator
    ) {
        coordinator.controller.invalidate()
    }

    private func apply(to controller: ViewerPagingCollectionController) {
        // Callbacks are re-installed on every update: SwiftUI structs are
        // immutable snapshots, so the closures captured at creation time would
        // otherwise go stale as soon as the screen re-renders.
        controller.onIndexChanged = onIndexChanged
        controller.onMediaReady = onMediaReady
        controller.onZoomingChanged = onZoomingChanged
        controller.onPagingChanged = onPagingChanged
        controller.update(
            pageCount: pageCount,
            currentIndex: currentIndex,
            isScrubbing: isScrubbing,
            assetProvider: assetProvider,
            pageRootView: pageRootView,
            pageIdentity: pageIdentity,
            targetSize: targetSize,
            contentMode: contentMode,
            neighborPriority: neighborPriority,
            initialPreviewImage: initialPreviewImage,
            initialAssetIdentifier: initialAssetIdentifier
        )
    }

    @MainActor
    final class Coordinator {
        let controller = ViewerPagingCollectionController()
    }
}
