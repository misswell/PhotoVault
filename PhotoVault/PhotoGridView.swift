import Photos
import SwiftUI
import UIKit

private enum PhotoGridMetrics {
    static let spacing: CGFloat = 2
    static let inset: CGFloat = 2
    // Photos uses a dense, edge-to-edge thumbnail grid. The default is only
    // the starting zoom level: the pinch driver below changes the preferred
    // side and the flow layout chooses the matching number of columns.
    static let defaultCellSide: CGFloat = 50
    static let minimumPreferredCellSide: CGFloat = 38
    static let maximumPreferredCellSide: CGFloat = 180

    static func clampedPreferredSide(_ side: CGFloat) -> CGFloat {
        min(max(side, minimumPreferredCellSide), maximumPreferredCellSide)
    }

    static func restoredPreferredCellSide() -> CGFloat {
        let storedSide = (UserDefaults.standard.object(
            forKey: PhotoGridPreferences.preferredCellSideKey
        ) as? NSNumber)?.doubleValue
        return clampedPreferredSide(
            CGFloat(storedSide ?? PhotoGridPreferences.defaultPreferredCellSide)
        )
    }

    static func persistPreferredCellSide(_ side: CGFloat) {
        UserDefaults.standard.set(
            Double(clampedPreferredSide(side)),
            forKey: PhotoGridPreferences.preferredCellSideKey
        )
    }

    static func itemSide(
        for width: CGFloat,
        preferredSide: CGFloat = defaultCellSide
    ) -> CGFloat {
        let availableWidth = max(1, width - inset * 2)
        let clampedSide = clampedPreferredSide(preferredSide)
        let columnCount = max(
            1,
            Int((availableWidth + spacing) / (clampedSide + spacing))
        )
        return floor(
            (availableWidth - CGFloat(columnCount - 1) * spacing)
                / CGFloat(columnCount)
        )
    }

    static func thumbnailSize(for side: CGFloat, displayScale: CGFloat) -> CGSize {
        let pixels = side * max(1, displayScale)
        let bucket: CGFloat
        switch pixels {
        case ..<160:
            bucket = 160
        case ..<256:
            bucket = 256
        case ..<384:
            bucket = 384
        default:
            bucket = 512
        }
        return CGSize(width: bucket, height: bucket)
    }
}

/// Adds Photos-style pinch zoom to a recycled collection view. The driver
/// only reports the requested cell side; the coordinator remains responsible
/// for changing the flow layout and preserving the pinch focal point.
private final class PhotoGridPinchDriver: NSObject, UIGestureRecognizerDelegate {
    private weak var collectionView: UICollectionView?
    private let currentPreferredSide: () -> CGFloat
    private let onZoom: (CGFloat, CGPoint) -> Void
    private let onZoomEnded: (CGFloat) -> Void
    private var initialPreferredSide = PhotoGridMetrics.defaultCellSide

    init(
        currentPreferredSide: @escaping () -> CGFloat,
        onZoom: @escaping (CGFloat, CGPoint) -> Void,
        onZoomEnded: @escaping (CGFloat) -> Void
    ) {
        self.currentPreferredSide = currentPreferredSide
        self.onZoom = onZoom
        self.onZoomEnded = onZoomEnded
    }

    func attach(to collectionView: UICollectionView) {
        self.collectionView = collectionView

        let pinch = UIPinchGestureRecognizer(
            target: self,
            action: #selector(handlePinch(_:))
        )
        pinch.cancelsTouchesInView = false
        pinch.delegate = self
        collectionView.addGestureRecognizer(pinch)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let collectionView,
              let pinch = gestureRecognizer as? UIPinchGestureRecognizer
        else { return false }
        return pinch.numberOfTouches >= 2 && collectionView.bounds.width > 0
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    @objc private func handlePinch(_ gestureRecognizer: UIPinchGestureRecognizer) {
        guard let collectionView else { return }

        switch gestureRecognizer.state {
        case .began:
            initialPreferredSide = PhotoGridMetrics.clampedPreferredSide(
                currentPreferredSide()
            )
            onZoom(
                initialPreferredSide,
                gestureRecognizer.location(in: collectionView)
            )
        case .changed:
            let preferredSide = PhotoGridMetrics.clampedPreferredSide(
                initialPreferredSide * gestureRecognizer.scale
            )
            onZoom(
                preferredSide,
                gestureRecognizer.location(in: collectionView)
            )
        case .ended, .cancelled:
            let preferredSide = PhotoGridMetrics.clampedPreferredSide(
                initialPreferredSide * gestureRecognizer.scale
            )
            onZoom(
                preferredSide,
                gestureRecognizer.location(in: collectionView)
            )
            onZoomEnded(preferredSide)
        default:
            break
        }
    }
}

/// Adds Photos-style drag selection without replacing UICollectionView's own
/// scrolling gesture. The first touched asset determines whether the drag is
/// selecting or deselecting; each asset is visited at most once per drag.
private final class PhotoSelectionPanDriver: NSObject, UIGestureRecognizerDelegate {
    private weak var collectionView: UICollectionView?
    private let assetAtIndex: (Int) -> PHAsset?
    private let selectedIDs: () -> Set<String>
    private let onToggle: (PHAsset) -> Void
    private var visitedIdentifiers = Set<String>()
    private var shouldSelect = true
    private var isDraggingSelection = false

    var isEnabled = false

    init(
        assetAtIndex: @escaping (Int) -> PHAsset?,
        selectedIDs: @escaping () -> Set<String>,
        onToggle: @escaping (PHAsset) -> Void
    ) {
        self.assetAtIndex = assetAtIndex
        self.selectedIDs = selectedIDs
        self.onToggle = onToggle
    }

    func attach(to collectionView: UICollectionView) {
        self.collectionView = collectionView
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.cancelsTouchesInView = false
        pan.delegate = self
        collectionView.addGestureRecognizer(pan)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard isEnabled,
              let collectionView,
              let pan = gestureRecognizer as? UIPanGestureRecognizer
        else { return false }
        guard pan.numberOfTouches <= 1 else { return false }
        let location = pan.location(in: collectionView)
        return collectionView.indexPathForItem(at: location) != nil
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    @objc private func handlePan(_ gestureRecognizer: UIPanGestureRecognizer) {
        guard isEnabled, let collectionView else { return }

        switch gestureRecognizer.state {
        case .began:
            visitedIdentifiers.removeAll(keepingCapacity: true)
            isDraggingSelection = true
            apply(at: gestureRecognizer.location(in: collectionView))
        case .changed:
            guard isDraggingSelection else { return }
            apply(at: gestureRecognizer.location(in: collectionView))
        case .ended, .cancelled, .failed:
            visitedIdentifiers.removeAll(keepingCapacity: true)
            isDraggingSelection = false
        default:
            break
        }
    }

    private func apply(at location: CGPoint) {
        guard let collectionView,
              let indexPath = collectionView.indexPathForItem(at: location),
              let asset = assetAtIndex(indexPath.item),
              visitedIdentifiers.insert(asset.localIdentifier).inserted
        else { return }

        if visitedIdentifiers.count == 1 {
            shouldSelect = !selectedIDs().contains(asset.localIdentifier)
        }

        let currentlySelected = selectedIDs().contains(asset.localIdentifier)
        if shouldSelect != currentlySelected {
            onToggle(asset)
        }
    }
}

/// Builds the shared long-press menu for both grid variants. The quick-add
/// submenu lists the albums the user pinned in the album picker, so a photo
/// can be filed into frequently used albums without opening the picker. The
/// remove entry only appears when the asset is in at least one user album;
/// with a single membership it becomes a direct action, otherwise a submenu
/// lists the albums one by one.
@MainActor
private func photoGridContextMenu(
    asset: PHAsset,
    containingAlbums: [PhotoAlbum],
    quickAlbums: [PhotoAlbum],
    onFavorite: @escaping (PHAsset) -> Void,
    onAddToQuickAlbum: @escaping (PHAsset, PhotoAlbum) -> Void,
    onAddToAlbum: @escaping (PHAsset) -> Void,
    onRemoveFromAlbum: @escaping (PHAsset, PhotoAlbum) -> Void,
    onShare: @escaping (PHAsset) -> Void,
    onDelete: @escaping (PHAsset) -> Void
) -> UIMenu {
    let favoriteAction = UIAction(
        title: asset.isFavorite ? "取消收藏" : "收藏",
        image: UIImage(systemName: asset.isFavorite ? "heart.slash" : "heart")
    ) { _ in onFavorite(asset) }

    let addToAlbumAction = UIAction(
        title: "添加到相册",
        image: UIImage(systemName: "folder.badge.plus")
    ) { _ in onAddToAlbum(asset) }

    var removeElement: UIMenuElement?
    if let singleAlbum = containingAlbums.first, containingAlbums.count == 1 {
        removeElement = UIAction(
            title: "从「\(singleAlbum.title)」移除",
            image: UIImage(systemName: "folder.badge.minus")
        ) { _ in onRemoveFromAlbum(asset, singleAlbum) }
    } else if !containingAlbums.isEmpty {
        removeElement = UIMenu(
            title: "移除相册",
            image: UIImage(systemName: "folder.badge.minus"),
            children: containingAlbums.map { album in
                UIAction(title: album.title) { _ in onRemoveFromAlbum(asset, album) }
            }
        )
    }

    let shareAction = UIAction(
        title: "分享",
        image: UIImage(systemName: "square.and.arrow.up")
    ) { _ in onShare(asset) }

    let deleteAction = UIAction(
        title: "删除",
        image: UIImage(systemName: "trash"),
        attributes: .destructive
    ) { _ in onDelete(asset) }

    var children: [UIMenuElement] = [favoriteAction]
    if !quickAlbums.isEmpty {
        // One tap files the asset into a pinned album. Actions already in
        // that album show a checkmark; re-adding is harmless either way.
        let containingIDs = Set(containingAlbums.map(\.id))
        let quickAlbumsMenu = UIMenu(
            title: "快速收藏夹",
            image: UIImage(systemName: "star"),
            children: quickAlbums.map { album in
                UIAction(
                    title: album.title,
                    state: containingIDs.contains(album.id) ? .on : .off
                ) { _ in onAddToQuickAlbum(asset, album) }
            }
        )
        children.append(quickAlbumsMenu)
    }
    children.append(addToAlbumAction)
    if let removeElement {
        children.append(removeElement)
    }
    children.append(contentsOf: [shareAction, deleteAction])
    return UIMenu(title: "", children: children)
}

/// The large-library grid is backed by UICollectionView so PhotoKit assets
/// and cells are both viewport-bound. SwiftUI still owns the screen and
/// callbacks, while UIKit provides recycling, prefetching and fast scrolling.
struct PhotoGridView: UIViewRepresentable {
    let assets: PHFetchResult<PHAsset>
    let isActive: Bool
    let selectionMode: Bool
    let selectedIDs: Set<String>
    let onOpen: (PhotoOpenContext) -> Void
    let onToggleSelection: (PHAsset) -> Void
    let onFavorite: (PHAsset) -> Void
    let onShare: (PHAsset) -> Void
    let onDelete: (PHAsset) -> Void
    let onAddToAlbum: (PHAsset) -> Void
    let onRemoveFromAlbum: (PHAsset, PhotoAlbum) -> Void
    let containingUserAlbums: (PHAsset) -> [PhotoAlbum]
    let onAddToQuickAlbum: (PHAsset, PhotoAlbum) -> Void
    let quickAlbums: () -> [PhotoAlbum]

    func makeCoordinator() -> Coordinator {
        Coordinator(
            assets: assets,
            isActive: isActive,
            selectionMode: selectionMode,
            selectedIDs: selectedIDs,
            onOpen: onOpen,
            onToggleSelection: onToggleSelection,
            onFavorite: onFavorite,
            onShare: onShare,
            onDelete: onDelete,
            onAddToAlbum: onAddToAlbum,
            onRemoveFromAlbum: onRemoveFromAlbum,
            containingUserAlbums: containingUserAlbums,
            onAddToQuickAlbum: onAddToQuickAlbum,
            quickAlbums: quickAlbums
        )
    }

    func makeUIView(context: Context) -> UICollectionView {
        context.coordinator.makeCollectionView()
    }

    static func dismantleUIView(_ uiView: UICollectionView, coordinator: Coordinator) {
        coordinator.dismantle(uiView)
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.update(
            collectionView: collectionView,
            assets: assets,
            isActive: isActive,
            selectionMode: selectionMode,
            selectedIDs: selectedIDs,
            onOpen: onOpen,
            onToggleSelection: onToggleSelection,
            onFavorite: onFavorite,
            onShare: onShare,
            onDelete: onDelete,
            onAddToAlbum: onAddToAlbum,
            onRemoveFromAlbum: onRemoveFromAlbum,
            containingUserAlbums: containingUserAlbums,
            onAddToQuickAlbum: onAddToQuickAlbum,
            quickAlbums: quickAlbums
        )
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate,
        UICollectionViewDataSourcePrefetching, UICollectionViewDelegateFlowLayout {
        private struct AssetSignature: Equatable {
            let count: Int
            let firstIdentifier: String?
            let lastIdentifier: String?
        }

        private var assets: PHFetchResult<PHAsset>
        private var signature: AssetSignature
        private var isActive: Bool
        private var selectionMode: Bool
        private var selectedIDs: Set<String>
        private var thumbnailSize = CGSize(width: 160, height: 160)
        private var preferredCellSide = PhotoGridMetrics.restoredPreferredCellSide()
        private var isFastScrolling = false
        private var needsReloadOnActivation = false
        private var selectionPanDriver: PhotoSelectionPanDriver?
        private var pinchDriver: PhotoGridPinchDriver?
        private weak var collectionView: UICollectionView?

        private var onOpen: (PhotoOpenContext) -> Void
        private var onToggleSelection: (PHAsset) -> Void
        private var onFavorite: (PHAsset) -> Void
        private var onShare: (PHAsset) -> Void
        private var onDelete: (PHAsset) -> Void
        private var onAddToAlbum: (PHAsset) -> Void
        private var onRemoveFromAlbum: (PHAsset, PhotoAlbum) -> Void
        private var containingUserAlbums: (PHAsset) -> [PhotoAlbum]
        private var onAddToQuickAlbum: (PHAsset, PhotoAlbum) -> Void
        private var quickAlbums: () -> [PhotoAlbum]

        init(
            assets: PHFetchResult<PHAsset>,
            isActive: Bool,
            selectionMode: Bool,
            selectedIDs: Set<String>,
            onOpen: @escaping (PhotoOpenContext) -> Void,
            onToggleSelection: @escaping (PHAsset) -> Void,
            onFavorite: @escaping (PHAsset) -> Void,
            onShare: @escaping (PHAsset) -> Void,
            onDelete: @escaping (PHAsset) -> Void,
            onAddToAlbum: @escaping (PHAsset) -> Void,
            onRemoveFromAlbum: @escaping (PHAsset, PhotoAlbum) -> Void,
            containingUserAlbums: @escaping (PHAsset) -> [PhotoAlbum],
            onAddToQuickAlbum: @escaping (PHAsset, PhotoAlbum) -> Void,
            quickAlbums: @escaping () -> [PhotoAlbum]
        ) {
            self.assets = assets
            signature = Self.signature(for: assets)
            self.isActive = isActive
            needsReloadOnActivation = !isActive
            self.selectionMode = selectionMode
            self.selectedIDs = selectedIDs
            self.onOpen = onOpen
            self.onToggleSelection = onToggleSelection
            self.onFavorite = onFavorite
            self.onShare = onShare
            self.onDelete = onDelete
            self.onAddToAlbum = onAddToAlbum
            self.onRemoveFromAlbum = onRemoveFromAlbum
            self.containingUserAlbums = containingUserAlbums
            self.onAddToQuickAlbum = onAddToQuickAlbum
            self.quickAlbums = quickAlbums
        }

        func dismantle(_ collectionView: UICollectionView) {
            cancelVisibleRequests(in: collectionView)
            collectionView.isUserInteractionEnabled = false
            collectionView.dataSource = nil
            collectionView.delegate = nil
            collectionView.prefetchDataSource = nil
            self.collectionView = nil
            NotificationCenter.default.removeObserver(self)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func makeCollectionView() -> UICollectionView {
            let layout = UICollectionViewFlowLayout()
            layout.minimumLineSpacing = 2
            layout.minimumInteritemSpacing = 2
            layout.sectionInset = UIEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
            layout.itemSize = CGSize(width: 80, height: 80)

            let collectionView = UICollectionView(
                frame: .zero,
                collectionViewLayout: layout
            )
            collectionView.backgroundColor = .systemGroupedBackground
            collectionView.alwaysBounceVertical = true
            collectionView.showsVerticalScrollIndicator = false
            collectionView.contentInsetAdjustmentBehavior = .automatic
            collectionView.register(
                PhotoGridCell.self,
                forCellWithReuseIdentifier: PhotoGridCell.reuseIdentifier
            )
            collectionView.dataSource = self
            collectionView.delegate = self
            collectionView.prefetchDataSource = self
            collectionView.accessibilityIdentifier = "photo-grid"
            self.collectionView = collectionView

            let selectionPanDriver = PhotoSelectionPanDriver(
                assetAtIndex: { [weak self] index in
                    guard let self, index >= 0, index < self.assets.count else { return nil }
                    return self.assets.object(at: index)
                },
                selectedIDs: { [weak self] in self?.selectedIDs ?? [] },
                onToggle: { [weak self] asset in self?.onToggleSelection(asset) }
            )
            selectionPanDriver.isEnabled = selectionMode
            selectionPanDriver.attach(to: collectionView)
            self.selectionPanDriver = selectionPanDriver

            let pinchDriver = PhotoGridPinchDriver(
                currentPreferredSide: { [weak self] in
                    self?.preferredCellSide ?? PhotoGridMetrics.defaultCellSide
                },
                onZoom: { [weak self, weak collectionView] preferredSide, focusPoint in
                    guard let self, let collectionView else { return }
                    self.applyZoom(
                        preferredSide: preferredSide,
                        focusPoint: focusPoint,
                        in: collectionView
                    )
                },
                onZoomEnded: { preferredSide in
                    PhotoGridMetrics.persistPreferredCellSide(preferredSide)
                }
            )
            pinchDriver.attach(to: collectionView)
            self.pinchDriver = pinchDriver

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleMemoryWarning),
                name: UIApplication.didReceiveMemoryWarningNotification,
                object: nil
            )

            DispatchQueue.main.async { [weak self, weak collectionView] in
                guard let self, let collectionView else { return }
                self.updateLayout(for: collectionView)
            }
            return collectionView
        }

        func update(
            collectionView: UICollectionView,
            assets: PHFetchResult<PHAsset>,
            isActive: Bool,
            selectionMode: Bool,
            selectedIDs: Set<String>,
            onOpen: @escaping (PhotoOpenContext) -> Void,
            onToggleSelection: @escaping (PHAsset) -> Void,
            onFavorite: @escaping (PHAsset) -> Void,
            onShare: @escaping (PHAsset) -> Void,
            onDelete: @escaping (PHAsset) -> Void,
            onAddToAlbum: @escaping (PHAsset) -> Void,
            onRemoveFromAlbum: @escaping (PHAsset, PhotoAlbum) -> Void,
            containingUserAlbums: @escaping (PHAsset) -> [PhotoAlbum],
            onAddToQuickAlbum: @escaping (PHAsset, PhotoAlbum) -> Void,
            quickAlbums: @escaping () -> [PhotoAlbum]
        ) {
            self.collectionView = collectionView
            let wasActive = self.isActive
            let didReactivate = !wasActive && isActive
            var shouldResumeVisibleCells = false
            self.isActive = isActive
            collectionView.isUserInteractionEnabled = isActive
            self.selectionMode = selectionMode
            self.selectedIDs = selectedIDs
            self.onOpen = onOpen
            self.onToggleSelection = onToggleSelection
            self.onFavorite = onFavorite
            self.onShare = onShare
            self.onDelete = onDelete
            self.onAddToAlbum = onAddToAlbum
            self.onRemoveFromAlbum = onRemoveFromAlbum
            self.containingUserAlbums = containingUserAlbums
            self.onAddToQuickAlbum = onAddToQuickAlbum
            self.quickAlbums = quickAlbums
            selectionPanDriver?.isEnabled = selectionMode

            let newSignature = Self.signature(for: assets)
            let dataSourceChanged = newSignature != signature
            self.assets = assets
            signature = newSignature

            if dataSourceChanged {
                cancelVisibleRequests(in: collectionView)
                if isActive {
                    collectionView.reloadData()
                    needsReloadOnActivation = false
                } else {
                    needsReloadOnActivation = true
                }
            } else if didReactivate, needsReloadOnActivation {
                // A data-source change while the viewer was presented still
                // requires a reload. The unchanged case is intentionally
                // handled below without reloadData so the cover can finish
                // dismissing over the already-rendered album.
                collectionView.reloadData()
                needsReloadOnActivation = false
            } else if didReactivate {
                shouldResumeVisibleCells = true
            }

            if wasActive, !isActive {
                cancelVisibleRequests(in: collectionView)
            }

            updateLayout(for: collectionView)
            updateVisibleSelection(in: collectionView)

            if shouldResumeVisibleCells {
                resumeVisibleCells(in: collectionView)
            }
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
                withReuseIdentifier: PhotoGridCell.reuseIdentifier,
                for: indexPath
            ) as! PhotoGridCell
            guard isActive else {
                cell.showPlaceholder(
                    selectionMode: selectionMode,
                    isSelected: false
                )
                return cell
            }
            let asset = assets.object(at: indexPath.item)
            cell.configure(
                asset: asset,
                targetSize: thumbnailSize,
                selectionMode: selectionMode,
                isSelected: selectedIDs.contains(asset.localIdentifier)
            )
            return cell
        }

        func collectionView(
            _ collectionView: UICollectionView,
            didSelectItemAt indexPath: IndexPath
        ) {
            guard isActive, indexPath.item < assets.count else { return }
            let asset = assets.object(at: indexPath.item)
            if selectionMode {
                onToggleSelection(asset)
            } else {
                // Hand the already-decoded frame to the viewer so it can paint
                // its first frame without a PhotoKit round trip. This is a
                // snapshot copy of the image, never a reference to the cell.
                let previewImage = (
                    collectionView.cellForItem(at: indexPath) as? PhotoGridCell
                )?.previewImage
                onOpen(
                    PhotoOpenContext(
                        index: indexPath.item,
                        assetIdentifier: asset.localIdentifier,
                        previewImage: previewImage
                    )
                )
            }
            collectionView.deselectItem(at: indexPath, animated: false)
        }

        func collectionView(
            _ collectionView: UICollectionView,
            prefetchItemsAt indexPaths: [IndexPath]
        ) {
            guard isActive, !isFastScrolling else { return }
            let assetsToCache = indexPaths.compactMap { indexPath -> PHAsset? in
                guard indexPath.item >= 0, indexPath.item < assets.count else { return nil }
                return assets.object(at: indexPath.item)
            }
            PhotoImageManager.shared.startCaching(
                assets: assetsToCache,
                targetSize: thumbnailSize
            )
        }

        func collectionView(
            _ collectionView: UICollectionView,
            cancelPrefetchingForItemsAt indexPaths: [IndexPath]
        ) {
            let assetsToStop = indexPaths.compactMap { indexPath -> PHAsset? in
                guard indexPath.item >= 0, indexPath.item < assets.count else { return nil }
                return assets.object(at: indexPath.item)
            }
            PhotoImageManager.shared.stopCaching(
                assets: assetsToStop,
                targetSize: thumbnailSize
            )
        }

        func collectionView(
            _ collectionView: UICollectionView,
            didEndDisplaying cell: UICollectionViewCell,
            forItemAt indexPath: IndexPath
        ) {
            (cell as? PhotoGridCell)?.cancelLoading()
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isFastScrolling = false
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let velocity = abs(scrollView.panGestureRecognizer.velocity(in: scrollView).y)
            isFastScrolling = velocity > 1_800
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            isFastScrolling = false
        }

        func scrollViewDidEndDragging(
            _ scrollView: UIScrollView,
            willDecelerate decelerate: Bool
        ) {
            if !decelerate { isFastScrolling = false }
        }

        func collectionView(
            _ collectionView: UICollectionView,
            contextMenuConfigurationForItemAt indexPath: IndexPath,
            point: CGPoint
        ) -> UIContextMenuConfiguration? {
            guard !selectionMode, indexPath.item < assets.count else { return nil }
            let asset = assets.object(at: indexPath.item)
            return UIContextMenuConfiguration(
                identifier: asset.localIdentifier as NSString,
                previewProvider: nil
            ) { [weak self] _ in
                guard let self else { return UIMenu() }
                // Resolve album membership only when the menu is about to
                // appear; the query is a single PhotoKit containment fetch.
                return photoGridContextMenu(
                    asset: asset,
                    containingAlbums: self.containingUserAlbums(asset),
                    quickAlbums: self.quickAlbums(),
                    onFavorite: self.onFavorite,
                    onAddToQuickAlbum: self.onAddToQuickAlbum,
                    onAddToAlbum: self.onAddToAlbum,
                    onRemoveFromAlbum: self.onRemoveFromAlbum,
                    onShare: self.onShare,
                    onDelete: self.onDelete
                )
            }
        }

        func collectionView(
            _ collectionView: UICollectionView,
            layout collectionViewLayout: UICollectionViewLayout,
            sizeForItemAt indexPath: IndexPath
        ) -> CGSize {
            guard let layout = collectionViewLayout as? UICollectionViewFlowLayout else {
                return CGSize(width: 80, height: 80)
            }
            return layout.itemSize
        }

        @objc private func handleMemoryWarning() {
            PhotoImageManager.shared.stopCachingAll()
            guard let collectionView else { return }
            for case let cell as PhotoGridCell in collectionView.visibleCells {
                cell.releaseDecodedImage()
            }
        }

        private func updateVisibleSelection(in collectionView: UICollectionView) {
            for cell in collectionView.visibleCells {
                guard let photoCell = cell as? PhotoGridCell,
                      let indexPath = collectionView.indexPath(for: cell),
                      indexPath.item < assets.count
                else { continue }
                let asset = assets.object(at: indexPath.item)
                photoCell.setSelection(
                    selectionMode: selectionMode,
                    isSelected: selectedIDs.contains(asset.localIdentifier)
                )
            }
        }

        private func cancelVisibleRequests(in collectionView: UICollectionView) {
            for cell in collectionView.visibleCells {
                (cell as? PhotoGridCell)?.cancelLoading()
            }
        }

        private func resumeVisibleCells(in collectionView: UICollectionView) {
            for cell in collectionView.visibleCells {
                guard let photoCell = cell as? PhotoGridCell,
                      let indexPath = collectionView.indexPath(for: cell),
                      indexPath.item < assets.count
                else { continue }

                let asset = assets.object(at: indexPath.item)
                photoCell.resumeLoadingIfNeeded(
                    asset: asset,
                    targetSize: thumbnailSize,
                    selectionMode: selectionMode,
                    isSelected: selectedIDs.contains(asset.localIdentifier)
                )
            }
        }

        private func applyZoom(
            preferredSide: CGFloat,
            focusPoint: CGPoint,
            in collectionView: UICollectionView
        ) {
            preferredCellSide = PhotoGridMetrics.clampedPreferredSide(preferredSide)
            updateLayout(for: collectionView, preservingFocusAt: focusPoint)
        }

        private func updateLayout(
            for collectionView: UICollectionView,
            preservingFocusAt focusPoint: CGPoint? = nil
        ) {
            guard collectionView.bounds.width > 0,
                  let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout
            else { return }

            let spacing = PhotoGridMetrics.spacing
            let horizontalInset = PhotoGridMetrics.inset
            let focusIndexPath = focusPoint.flatMap {
                collectionView.indexPathForItem(at: $0)
            }
            let oldFocusFrame = focusIndexPath.flatMap {
                layout.layoutAttributesForItem(at: $0)?.frame
            }
            let cellSide = PhotoGridMetrics.itemSide(
                for: collectionView.bounds.width,
                preferredSide: preferredCellSide
            )
            let sizeChanged = abs(layout.itemSize.width - cellSide) > 0.5
            layout.sectionInset = UIEdgeInsets(
                top: 2,
                left: horizontalInset,
                bottom: 2,
                right: horizontalInset
            )
            layout.minimumLineSpacing = spacing
            layout.minimumInteritemSpacing = spacing
            if sizeChanged {
                layout.itemSize = CGSize(width: cellSide, height: cellSide)
                thumbnailSize = PhotoGridMetrics.thumbnailSize(
                    for: cellSide,
                    displayScale: collectionView.traitCollection.displayScale
                )
                layout.invalidateLayout()
                UIView.performWithoutAnimation {
                    collectionView.layoutIfNeeded()
                }

                if let focusPoint,
                   let focusIndexPath,
                   let oldFocusFrame,
                   let newFocusFrame = layout.layoutAttributesForItem(at: focusIndexPath)?.frame {
                    preserveFocus(
                        at: focusPoint,
                        oldFrame: oldFocusFrame,
                        newFrame: newFocusFrame,
                        in: collectionView
                    )
                }

                let visible = collectionView.indexPathsForVisibleItems
                if !visible.isEmpty {
                    collectionView.reloadItems(at: visible)
                }
            }
        }

        private func preserveFocus(
            at focusPoint: CGPoint,
            oldFrame: CGRect,
            newFrame: CGRect,
            in collectionView: UICollectionView
        ) {
            guard oldFrame.width > 0,
                  oldFrame.height > 0,
                  newFrame.width > 0,
                  newFrame.height > 0
            else { return }

            let oldContentPoint = CGPoint(
                x: focusPoint.x + collectionView.contentOffset.x,
                y: focusPoint.y + collectionView.contentOffset.y
            )
            let xRatio = (oldContentPoint.x - oldFrame.minX) / oldFrame.width
            let yRatio = (oldContentPoint.y - oldFrame.minY) / oldFrame.height
            let newContentPoint = CGPoint(
                x: newFrame.minX + newFrame.width * xRatio,
                y: newFrame.minY + newFrame.height * yRatio
            )

            var offset = CGPoint(
                x: newContentPoint.x - focusPoint.x,
                y: newContentPoint.y - focusPoint.y
            )
            let minimumX = -collectionView.adjustedContentInset.left
            let maximumX = max(
                minimumX,
                collectionView.contentSize.width
                    - collectionView.bounds.width
                    + collectionView.adjustedContentInset.right
            )
            let minimumY = -collectionView.adjustedContentInset.top
            let maximumY = max(
                minimumY,
                collectionView.contentSize.height
                    - collectionView.bounds.height
                    + collectionView.adjustedContentInset.bottom
            )
            offset.x = min(max(offset.x, minimumX), maximumX)
            offset.y = min(max(offset.y, minimumY), maximumY)
            collectionView.setContentOffset(offset, animated: false)
        }

        private static func signature(for assets: PHFetchResult<PHAsset>) -> AssetSignature {
            AssetSignature(
                count: assets.count,
                firstIdentifier: assets.firstObject?.localIdentifier,
                lastIdentifier: assets.count > 0
                    ? assets.object(at: assets.count - 1).localIdentifier
                    : nil
            )
        }
    }
}

final class PhotoGridCell: UICollectionViewCell {
    static let reuseIdentifier = "PhotoGridCell"

    private let imageView = UIImageView()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private let selectionImageView = UIImageView()
    private let liveBadge = UIImageView()
    private let videoDurationLabel = UILabel()

    private var requestHandle: PhotoRequestHandle?
    private var representedAsset: PHAsset?
    private var representedIdentifier: String?
    private var representedTargetSize = CGSize.zero

    /// The frame currently painted by this cell, if any. The viewer uses this
    /// to render an instant first frame; it never retains the cell itself.
    var previewImage: UIImage? {
        imageView.image
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        contentView.backgroundColor = .secondarySystemGroupedBackground
        contentView.clipsToBounds = true

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)

        loadingIndicator.color = .secondaryLabel
        loadingIndicator.hidesWhenStopped = true
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(loadingIndicator)

        selectionImageView.contentMode = .scaleAspectFit
        selectionImageView.tintColor = .white
        selectionImageView.layer.shadowColor = UIColor.black.cgColor
        selectionImageView.layer.shadowOpacity = 0.6
        selectionImageView.layer.shadowRadius = 2
        selectionImageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(selectionImageView)

        liveBadge.image = UIImage(systemName: "livephoto")
        liveBadge.tintColor = .white
        liveBadge.contentMode = .scaleAspectFit
        liveBadge.layer.shadowColor = UIColor.black.cgColor
        liveBadge.layer.shadowOpacity = 0.7
        liveBadge.layer.shadowRadius = 2
        liveBadge.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(liveBadge)

        videoDurationLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        videoDurationLabel.textColor = .white
        videoDurationLabel.shadowColor = .black
        videoDurationLabel.layer.shadowOpacity = 0.8
        videoDurationLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(videoDurationLabel)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            loadingIndicator.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            selectionImageView.widthAnchor.constraint(equalToConstant: 21),
            selectionImageView.heightAnchor.constraint(equalToConstant: 21),
            selectionImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            selectionImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            liveBadge.widthAnchor.constraint(equalToConstant: 15),
            liveBadge.heightAnchor.constraint(equalToConstant: 15),
            liveBadge.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            liveBadge.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            videoDurationLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            videoDurationLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4)
        ])

        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelRequest()
        representedAsset = nil
        representedIdentifier = nil
        imageView.image = nil
        imageView.alpha = 1
        liveBadge.isHidden = true
        videoDurationLabel.isHidden = true
        loadingIndicator.stopAnimating()
        selectionImageView.isHidden = true
    }

    func configure(
        asset: PHAsset,
        targetSize: CGSize,
        selectionMode: Bool,
        isSelected: Bool
    ) {
        cancelRequest()
        representedAsset = asset
        representedIdentifier = asset.localIdentifier
        representedTargetSize = targetSize

        // Serve an already-decoded thumbnail in the same frame. Without this
        // probe every recycle blanked the cell and spun an indicator even for
        // photos that had been on screen moments earlier.
        if let cachedImage = PhotoImageManager.shared.cachedImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            scope: .gridThumbnail
        ) {
            imageView.image = cachedImage
            loadingIndicator.stopAnimating()
        } else {
            imageView.image = nil
            loadingIndicator.startAnimating()
        }

        liveBadge.isHidden = !asset.mediaSubtypes.contains(.photoLive)
        videoDurationLabel.isHidden = asset.mediaType != .video
        if asset.mediaType == .video {
            videoDurationLabel.text = durationText(for: asset.duration)
        }
        setSelection(selectionMode: selectionMode, isSelected: isSelected)
        accessibilityLabel = asset.mediaType == .video ? "视频" : "照片"

        photoVaultTrace(
            "grid cell configure asset=\(photoVaultShortAssetID(asset.localIdentifier)) "
                + "target=\(Int(targetSize.width))x\(Int(targetSize.height))"
        )

        // The prefetch data source owns the PHCachingImageManager window
        // (visible range plus the incoming edge). Caching here again per
        // cell recycle only adds PhotoKit churn and evicts entries the
        // prefetcher just established. The decoded-result cache below is a
        // separate, cost-bounded store owned by PhotoImageManager.
        requestHandle = PhotoImageManager.shared.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            deliveryMode: .opportunistic,
            resizeMode: .fast,
            priority: .photoGrid,
            isNetworkAccessAllowed: true,
            cacheResult: true,
            cacheScope: .gridThumbnail,
            progressHandler: { [weak self] progress, error, _, _ in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.representedIdentifier == asset.localIdentifier
                    else { return }
                    if error != nil || progress >= 1 {
                        self.loadingIndicator.stopAnimating()
                    }
                }
            }
        ) { [weak self] image, info in
            let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            let hasError = info?[PHImageErrorKey] != nil
            photoVaultTrace(
                "grid cell callback asset=\(photoVaultShortAssetID(asset.localIdentifier)) "
                    + "degraded=\(degraded) cancelled=\(cancelled) "
                    + "error=\(hasError) hasImage=\(image != nil)"
            )
            guard !cancelled else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      self.representedIdentifier == asset.localIdentifier,
                      self.representedTargetSize == targetSize
                else { return }
                self.loadingIndicator.stopAnimating()
                // A degraded frame is still a valid displayable image; never
                // replace an already-shown thumbnail with nothing.
                if let image {
                    self.imageView.image = image
                }
            }
        }
    }

    func resumeLoadingIfNeeded(
        asset: PHAsset,
        targetSize: CGSize,
        selectionMode: Bool,
        isSelected: Bool
    ) {
        let sameAsset = representedIdentifier == asset.localIdentifier
        let sameTargetSize = representedTargetSize == targetSize

        if sameAsset, sameTargetSize, imageView.image != nil {
            loadingIndicator.stopAnimating()
            setSelection(selectionMode: selectionMode, isSelected: isSelected)
            return
        }

        configure(
            asset: asset,
            targetSize: targetSize,
            selectionMode: selectionMode,
            isSelected: isSelected
        )
    }

    func setSelection(selectionMode: Bool, isSelected: Bool) {
        selectionImageView.isHidden = !selectionMode
        guard selectionMode else {
            imageView.alpha = 1
            return
        }
        selectionImageView.image = UIImage(
            systemName: isSelected ? "checkmark.circle.fill" : "circle"
        )
        selectionImageView.tintColor = isSelected ? .systemBlue : .white
        imageView.alpha = isSelected ? 0.78 : 1
    }

    func releaseDecodedImage() {
        imageView.image = nil
        loadingIndicator.stopAnimating()
        cancelRequest()
    }

    func cancelLoading() {
        cancelRequest()
    }

    func showPlaceholder(selectionMode: Bool, isSelected: Bool) {
        cancelRequest()
        representedAsset = nil
        representedIdentifier = nil
        imageView.image = nil
        imageView.alpha = 1
        liveBadge.isHidden = true
        videoDurationLabel.isHidden = true
        loadingIndicator.startAnimating()
        setSelection(selectionMode: selectionMode, isSelected: isSelected)
    }

    private func cancelRequest() {
        if let requestHandle,
           let representedIdentifier {
            photoVaultTrace(
                "grid cell cancel asset=\(photoVaultShortAssetID(representedIdentifier))"
                    + " target=\(Int(representedTargetSize.width))x\(Int(representedTargetSize.height))"
            )
            PhotoImageManager.shared.cancel(requestHandle)
        }
        requestHandle = nil
    }

    private func durationText(for duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }
}

/// A paged PhotoIndex-backed grid used by the Unsorted screen. It exposes a
/// UICollectionView-sized item count immediately, then resolves only the
/// identifier page needed by visible/prefetched cells.
struct IndexedPhotoGridView: UIViewRepresentable {
    let totalCount: Int
    let store: PhotoLibraryStore
    let isActive: Bool
    let selectionMode: Bool
    let selectedIDs: Set<String>
    let onOpen: (PHAsset, Int, UIImage?) -> Void
    let onToggleSelection: (PHAsset) -> Void
    let onFavorite: (PHAsset) -> Void
    let onShare: (PHAsset) -> Void
    let onDelete: (PHAsset) -> Void
    let onAddToAlbum: (PHAsset) -> Void
    let onRemoveFromAlbum: (PHAsset, PhotoAlbum) -> Void
    let containingUserAlbums: (PHAsset) -> [PhotoAlbum]
    let onAddToQuickAlbum: (PHAsset, PhotoAlbum) -> Void
    let quickAlbums: () -> [PhotoAlbum]

    func makeCoordinator() -> Coordinator {
        Coordinator(
            totalCount: totalCount,
            store: store,
            isActive: isActive,
            selectionMode: selectionMode,
            selectedIDs: selectedIDs,
            onOpen: onOpen,
            onToggleSelection: onToggleSelection,
            onFavorite: onFavorite,
            onShare: onShare,
            onDelete: onDelete,
            onAddToAlbum: onAddToAlbum,
            onRemoveFromAlbum: onRemoveFromAlbum,
            containingUserAlbums: containingUserAlbums,
            onAddToQuickAlbum: onAddToQuickAlbum,
            quickAlbums: quickAlbums
        )
    }

    func makeUIView(context: Context) -> UICollectionView {
        context.coordinator.makeCollectionView()
    }

    static func dismantleUIView(_ uiView: UICollectionView, coordinator: Coordinator) {
        coordinator.dismantle(uiView)
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.update(
            collectionView: collectionView,
            totalCount: totalCount,
            isActive: isActive,
            selectionMode: selectionMode,
            selectedIDs: selectedIDs,
            onOpen: onOpen,
            onToggleSelection: onToggleSelection,
            onFavorite: onFavorite,
            onShare: onShare,
            onDelete: onDelete,
            onAddToAlbum: onAddToAlbum,
            onRemoveFromAlbum: onRemoveFromAlbum,
            containingUserAlbums: containingUserAlbums,
            onAddToQuickAlbum: onAddToQuickAlbum,
            quickAlbums: quickAlbums
        )
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate,
        UICollectionViewDataSourcePrefetching, UICollectionViewDelegateFlowLayout {
        private let pageSize = 240
        private var totalCount: Int
        private let store: PhotoLibraryStore
        private var isActive: Bool
        private var selectionMode: Bool
        private var selectedIDs: Set<String>
        private var assetsByIndex: [Int: PHAsset] = [:]
        private var loadingPages = Set<Int>()
        private var loadGeneration: UInt64 = 0
        private var pageOrder: [Int] = []
        private let maxCachedPages = 8
        /// Indexes UIKit asked us to prepare, plus the assets whose PhotoKit
        /// caching registration is currently live.
        private var prefetchIndices = Set<Int>()
        private var cachingWindow: [String: PHAsset] = [:]
        private var thumbnailSize = CGSize(width: 160, height: 160)
        private var preferredCellSide = PhotoGridMetrics.restoredPreferredCellSide()
        private var needsReloadOnActivation = false
        private var selectionPanDriver: PhotoSelectionPanDriver?
        private var pinchDriver: PhotoGridPinchDriver?
        private weak var collectionView: UICollectionView?

        private var onOpen: (PHAsset, Int, UIImage?) -> Void
        private var onToggleSelection: (PHAsset) -> Void
        private var onFavorite: (PHAsset) -> Void
        private var onShare: (PHAsset) -> Void
        private var onDelete: (PHAsset) -> Void
        private var onAddToAlbum: (PHAsset) -> Void
        private var onRemoveFromAlbum: (PHAsset, PhotoAlbum) -> Void
        private var containingUserAlbums: (PHAsset) -> [PhotoAlbum]
        private var onAddToQuickAlbum: (PHAsset, PhotoAlbum) -> Void
        private var quickAlbums: () -> [PhotoAlbum]

        init(
            totalCount: Int,
            store: PhotoLibraryStore,
            isActive: Bool,
            selectionMode: Bool,
            selectedIDs: Set<String>,
            onOpen: @escaping (PHAsset, Int, UIImage?) -> Void,
            onToggleSelection: @escaping (PHAsset) -> Void,
            onFavorite: @escaping (PHAsset) -> Void,
            onShare: @escaping (PHAsset) -> Void,
            onDelete: @escaping (PHAsset) -> Void,
            onAddToAlbum: @escaping (PHAsset) -> Void,
            onRemoveFromAlbum: @escaping (PHAsset, PhotoAlbum) -> Void,
            containingUserAlbums: @escaping (PHAsset) -> [PhotoAlbum],
            onAddToQuickAlbum: @escaping (PHAsset, PhotoAlbum) -> Void,
            quickAlbums: @escaping () -> [PhotoAlbum]
        ) {
            self.totalCount = max(0, totalCount)
            self.store = store
            self.isActive = isActive
            needsReloadOnActivation = !isActive
            self.selectionMode = selectionMode
            self.selectedIDs = selectedIDs
            self.onOpen = onOpen
            self.onToggleSelection = onToggleSelection
            self.onFavorite = onFavorite
            self.onShare = onShare
            self.onDelete = onDelete
            self.onAddToAlbum = onAddToAlbum
            self.onRemoveFromAlbum = onRemoveFromAlbum
            self.containingUserAlbums = containingUserAlbums
            self.onAddToQuickAlbum = onAddToQuickAlbum
            self.quickAlbums = quickAlbums
            photoVaultTrace(
                "unsorted grid init count=\(self.totalCount) active=\(isActive)"
            )
        }

        func dismantle(_ collectionView: UICollectionView) {
            photoVaultTrace(
                "unsorted grid dismantle count=\(totalCount) "
                    + "active=\(isActive) generation=\(loadGeneration)"
            )
            isActive = false
            invalidatePageLoads()
            resetCachingWindow()
            prefetchIndices.removeAll(keepingCapacity: false)
            cancelVisibleRequests(in: collectionView)
            collectionView.isUserInteractionEnabled = false
            collectionView.dataSource = nil
            collectionView.delegate = nil
            collectionView.prefetchDataSource = nil
            self.collectionView = nil
            NotificationCenter.default.removeObserver(self)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func makeCollectionView() -> UICollectionView {
            let layout = UICollectionViewFlowLayout()
            layout.minimumLineSpacing = 2
            layout.minimumInteritemSpacing = 2
            layout.sectionInset = UIEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
            layout.itemSize = CGSize(width: 80, height: 80)

            let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
            collectionView.backgroundColor = .systemGroupedBackground
            collectionView.alwaysBounceVertical = true
            collectionView.showsVerticalScrollIndicator = false
            collectionView.contentInsetAdjustmentBehavior = .automatic
            collectionView.register(
                PhotoGridCell.self,
                forCellWithReuseIdentifier: PhotoGridCell.reuseIdentifier
            )
            collectionView.dataSource = self
            collectionView.delegate = self
            collectionView.prefetchDataSource = self
            collectionView.accessibilityIdentifier = "unsorted-photo-grid"
            self.collectionView = collectionView

            let selectionPanDriver = PhotoSelectionPanDriver(
                assetAtIndex: { [weak self] index in self?.assetsByIndex[index] },
                selectedIDs: { [weak self] in self?.selectedIDs ?? [] },
                onToggle: { [weak self] asset in self?.onToggleSelection(asset) }
            )
            selectionPanDriver.isEnabled = selectionMode
            selectionPanDriver.attach(to: collectionView)
            self.selectionPanDriver = selectionPanDriver

            let pinchDriver = PhotoGridPinchDriver(
                currentPreferredSide: { [weak self] in
                    self?.preferredCellSide ?? PhotoGridMetrics.defaultCellSide
                },
                onZoom: { [weak self, weak collectionView] preferredSide, focusPoint in
                    guard let self, let collectionView else { return }
                    self.applyZoom(
                        preferredSide: preferredSide,
                        focusPoint: focusPoint,
                        in: collectionView
                    )
                },
                onZoomEnded: { preferredSide in
                    PhotoGridMetrics.persistPreferredCellSide(preferredSide)
                }
            )
            pinchDriver.attach(to: collectionView)
            self.pinchDriver = pinchDriver

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleMemoryWarning),
                name: UIApplication.didReceiveMemoryWarningNotification,
                object: nil
            )

            DispatchQueue.main.async { [weak self, weak collectionView] in
                guard let self, let collectionView else { return }
                self.updateLayout(for: collectionView)
            }
            return collectionView
        }

        func update(
            collectionView: UICollectionView,
            totalCount: Int,
            isActive: Bool,
            selectionMode: Bool,
            selectedIDs: Set<String>,
            onOpen: @escaping (PHAsset, Int, UIImage?) -> Void,
            onToggleSelection: @escaping (PHAsset) -> Void,
            onFavorite: @escaping (PHAsset) -> Void,
            onShare: @escaping (PHAsset) -> Void,
            onDelete: @escaping (PHAsset) -> Void,
            onAddToAlbum: @escaping (PHAsset) -> Void,
            onRemoveFromAlbum: @escaping (PHAsset, PhotoAlbum) -> Void,
            containingUserAlbums: @escaping (PHAsset) -> [PhotoAlbum],
            onAddToQuickAlbum: @escaping (PHAsset, PhotoAlbum) -> Void,
            quickAlbums: @escaping () -> [PhotoAlbum]
        ) {
            self.collectionView = collectionView
            let wasActive = self.isActive
            let oldCount = self.totalCount
            self.isActive = isActive
            collectionView.isUserInteractionEnabled = isActive
            self.selectionMode = selectionMode
            self.selectedIDs = selectedIDs
            self.onOpen = onOpen
            self.onToggleSelection = onToggleSelection
            self.onFavorite = onFavorite
            self.onShare = onShare
            self.onDelete = onDelete
            self.onAddToAlbum = onAddToAlbum
            self.onRemoveFromAlbum = onRemoveFromAlbum
            self.containingUserAlbums = containingUserAlbums
            self.onAddToQuickAlbum = onAddToQuickAlbum
            self.quickAlbums = quickAlbums
            selectionPanDriver?.isEnabled = selectionMode

            let newCount = max(0, totalCount)
            let didReactivate = !wasActive && isActive
            if oldCount != newCount || wasActive != isActive {
                photoVaultTrace(
                    "unsorted grid update count=\(oldCount)->\(newCount) "
                        + "active=\(wasActive)->\(isActive) "
                        + "generation=\(loadGeneration)"
                )
            }
            if wasActive, !isActive {
                invalidatePageLoads()
                resetCachingWindow()
            }
            if newCount != self.totalCount {
                invalidatePageLoads()
                resetCachingWindow()
                prefetchIndices.removeAll(keepingCapacity: true)
                cancelVisibleRequests(in: collectionView)
                self.totalCount = newCount
                assetsByIndex.removeAll(keepingCapacity: true)
                loadingPages.removeAll()
                pageOrder.removeAll(keepingCapacity: true)
                if isActive {
                    collectionView.reloadData()
                    needsReloadOnActivation = false
                } else {
                    needsReloadOnActivation = true
                }
            } else if didReactivate, needsReloadOnActivation {
                // A count change while inactive must be reflected when the
                // screen returns. For the common unchanged case, keep the
                // existing cells so the cover can reveal the album without a
                // blank/loading reload frame.
                collectionView.reloadData()
                needsReloadOnActivation = false
            } else {
                self.totalCount = newCount
            }

            if wasActive, !isActive { cancelVisibleRequests(in: collectionView) }

            updateLayout(for: collectionView)
            updateVisibleSelection(in: collectionView)

            if didReactivate {
                DispatchQueue.main.async { [weak self, weak collectionView] in
                    guard let self,
                          let collectionView,
                          self.isActive,
                          self.totalCount == newCount,
                          self.collectionView === collectionView
                    else { return }
                    self.resumeVisibleCells(in: collectionView)
                }
            }
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
                withReuseIdentifier: PhotoGridCell.reuseIdentifier,
                for: indexPath
            ) as! PhotoGridCell
            guard isActive else {
                cell.showPlaceholder(
                    selectionMode: selectionMode,
                    isSelected: false
                )
                return cell
            }
            if let asset = assetsByIndex[indexPath.item] {
                touchPage(containing: indexPath.item)
                cell.configure(
                    asset: asset,
                    targetSize: thumbnailSize,
                    selectionMode: selectionMode,
                    isSelected: selectedIDs.contains(asset.localIdentifier)
                )
            } else {
                cell.showPlaceholder(
                    selectionMode: selectionMode,
                    isSelected: false
                )
                photoVaultTrace(
                    "unsorted grid cell missing index=\(indexPath.item) "
                        + "total=\(totalCount) generation=\(loadGeneration)"
                )
                loadPage(containing: indexPath.item, in: collectionView)
            }
            return cell
        }

        func collectionView(
            _ collectionView: UICollectionView,
            didSelectItemAt indexPath: IndexPath
        ) {
            guard isActive else {
                collectionView.deselectItem(at: indexPath, animated: false)
                return
            }
            guard let asset = assetsByIndex[indexPath.item] else {
                loadPage(containing: indexPath.item, in: collectionView)
                collectionView.deselectItem(at: indexPath, animated: false)
                return
            }
            touchPage(containing: indexPath.item)
            if selectionMode {
                onToggleSelection(asset)
            } else {
                // Same first-frame handoff as the full library grid: the
                // thumbnail already painted by this cell travels with the tap.
                let previewImage = (
                    collectionView.cellForItem(at: indexPath) as? PhotoGridCell
                )?.previewImage
                onOpen(
                    asset,
                    indexPath.item,
                    previewImage
                )
            }
            collectionView.deselectItem(at: indexPath, animated: false)
        }

        func collectionView(
            _ collectionView: UICollectionView,
            prefetchItemsAt indexPaths: [IndexPath]
        ) {
            guard isActive else { return }
            for indexPath in indexPaths {
                prefetchIndices.insert(indexPath.item)
                touchPage(containing: indexPath.item)
                loadPage(containing: indexPath.item, in: collectionView)
            }
            updateCachingWindow(in: collectionView)
        }

        func collectionView(
            _ collectionView: UICollectionView,
            cancelPrefetchingForItemsAt indexPaths: [IndexPath]
        ) {
            for indexPath in indexPaths {
                prefetchIndices.remove(indexPath.item)
            }
            updateCachingWindow(in: collectionView)
        }

        /// The library grid leans on UIKit's prefetch data source to keep a
        /// PHCachingImageManager window warm. The unsorted grid resolves its
        /// assets from SQLite pages, so the window has to be recomputed here
        /// once a page lands and whenever prefetch hints change.
        private func updateCachingWindow(in collectionView: UICollectionView?) {
            guard let collectionView, isActive else { return }
            var wantedIndices = prefetchIndices
            for indexPath in collectionView.indexPathsForVisibleItems {
                wantedIndices.insert(indexPath.item)
            }

            var wanted = [String: PHAsset](minimumCapacity: wantedIndices.count)
            for index in wantedIndices {
                guard let asset = assetsByIndex[index] else { continue }
                wanted[asset.localIdentifier] = asset
            }

            let stale = cachingWindow.filter { wanted[$0.key] == nil }.map(\.value)
            if !stale.isEmpty {
                PhotoImageManager.shared.stopCaching(
                    assets: stale,
                    targetSize: thumbnailSize
                )
            }
            let added = wanted.filter { cachingWindow[$0.key] == nil }.map(\.value)
            if !added.isEmpty {
                PhotoImageManager.shared.startCaching(
                    assets: added,
                    targetSize: thumbnailSize
                )
            }
            cachingWindow = wanted
        }

        /// Releases the whole window using the size it was registered with, so
        /// a layout change cannot leave a stale registration behind.
        private func resetCachingWindow() {
            guard !cachingWindow.isEmpty else { return }
            PhotoImageManager.shared.stopCaching(
                assets: Array(cachingWindow.values),
                targetSize: thumbnailSize
            )
            cachingWindow.removeAll()
        }

        func collectionView(
            _ collectionView: UICollectionView,
            didEndDisplaying cell: UICollectionViewCell,
            forItemAt indexPath: IndexPath
        ) {
            (cell as? PhotoGridCell)?.cancelLoading()
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            trimCachedPages(around: firstVisibleIndex(in: scrollView))
        }

        func scrollViewDidEndDragging(
            _ scrollView: UIScrollView,
            willDecelerate decelerate: Bool
        ) {
            guard !decelerate else { return }
            trimCachedPages(around: firstVisibleIndex(in: scrollView))
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            trimCachedPages(around: firstVisibleIndex(in: scrollView))
        }

        func collectionView(
            _ collectionView: UICollectionView,
            contextMenuConfigurationForItemAt indexPath: IndexPath,
            point: CGPoint
        ) -> UIContextMenuConfiguration? {
            guard !selectionMode,
                  let asset = assetsByIndex[indexPath.item]
            else { return nil }

            return UIContextMenuConfiguration(
                identifier: asset.localIdentifier as NSString,
                previewProvider: nil
            ) { [weak self] _ in
                guard let self else { return UIMenu() }
                return photoGridContextMenu(
                    asset: asset,
                    containingAlbums: self.containingUserAlbums(asset),
                    quickAlbums: self.quickAlbums(),
                    onFavorite: self.onFavorite,
                    onAddToQuickAlbum: self.onAddToQuickAlbum,
                    onAddToAlbum: self.onAddToAlbum,
                    onRemoveFromAlbum: self.onRemoveFromAlbum,
                    onShare: self.onShare,
                    onDelete: self.onDelete
                )
            }
        }

        func collectionView(
            _ collectionView: UICollectionView,
            layout collectionViewLayout: UICollectionViewLayout,
            sizeForItemAt indexPath: IndexPath
        ) -> CGSize {
            guard let layout = collectionViewLayout as? UICollectionViewFlowLayout else {
                return CGSize(width: 80, height: 80)
            }
            return layout.itemSize
        }

        private func resumeVisibleCells(in collectionView: UICollectionView) {
            for cell in collectionView.visibleCells {
                guard let photoCell = cell as? PhotoGridCell,
                      let indexPath = collectionView.indexPath(for: cell)
                else { continue }

                guard let asset = assetsByIndex[indexPath.item] else {
                    loadPage(containing: indexPath.item, in: collectionView)
                    continue
                }

                touchPage(containing: indexPath.item)
                photoCell.resumeLoadingIfNeeded(
                    asset: asset,
                    targetSize: thumbnailSize,
                    selectionMode: selectionMode,
                    isSelected: selectedIDs.contains(asset.localIdentifier)
                )
            }
        }

        @objc private func handleMemoryWarning() {
            PhotoImageManager.shared.stopCachingAll()
            guard let collectionView else {
                assetsByIndex.removeAll(keepingCapacity: false)
                pageOrder.removeAll(keepingCapacity: false)
                return
            }

            for case let cell as PhotoGridCell in collectionView.visibleCells {
                cell.releaseDecodedImage()
            }

            let visiblePages = Set(
                collectionView.indexPathsForVisibleItems.map { $0.item / pageSize }
            )
            let pagesToRelease = pageOrder.filter { !visiblePages.contains($0) }
            for page in pagesToRelease {
                let start = page * pageSize
                let end = min(totalCount, start + pageSize)
                for index in start..<end {
                    assetsByIndex.removeValue(forKey: index)
                }
            }
            pageOrder.removeAll { !visiblePages.contains($0) }
        }

        private func loadPage(containing index: Int, in collectionView: UICollectionView) {
            guard index >= 0, index < totalCount else { return }
            let page = index / pageSize
            guard loadingPages.insert(page).inserted else { return }

            let offset = page * pageSize
            let requestGeneration = loadGeneration
            photoVaultTrace(
                "unsorted page start page=\(page) offset=\(offset) "
                    + "limit=\(pageSize) generation=\(requestGeneration) "
                    + "total=\(totalCount)"
            )
            store.fetchUnsortedAssets(offset: offset, limit: pageSize) { [weak self, weak collectionView] result in
                guard let self else {
                    photoVaultTrace(
                        "unsorted page drop page=\(page) reason=coordinator-gone "
                            + "generation=\(requestGeneration)"
                    )
                    return
                }
                guard let collectionView else {
                    photoVaultTrace(
                        "unsorted page drop page=\(page) reason=collection-gone "
                            + "generation=\(requestGeneration)"
                    )
                    return
                }
                let sameGeneration = self.loadGeneration == requestGeneration
                let sameCollection = self.collectionView === collectionView
                photoVaultTrace(
                    "unsorted page callback page=\(page) "
                        + "generation=\(requestGeneration)/\(self.loadGeneration) "
                        + "active=\(self.isActive) sameCollection=\(sameCollection) "
                        + "result=\(Self.pageResultDescription(result))"
                )
                guard self.isActive,
                      sameGeneration,
                      sameCollection
                else {
                    return
                }
                self.loadingPages.remove(page)
                guard case .success(let pageAssets) = result else { return }

                for (localIndex, asset) in pageAssets.enumerated() {
                    self.assetsByIndex[offset + localIndex] = asset
                }
                self.pageOrder.removeAll { $0 == page }
                self.pageOrder.append(page)
                self.trimCachedPages(around: self.firstVisibleIndex(in: collectionView))
                self.updateCachingWindow(in: collectionView)

                let end = min(self.totalCount, offset + pageAssets.count)
                let visiblePaths = (offset..<end).compactMap { item -> IndexPath? in
                    guard collectionView.indexPathsForVisibleItems.contains(
                        IndexPath(item: item, section: 0)
                    ) else { return nil }
                    return IndexPath(item: item, section: 0)
                }
                if !visiblePaths.isEmpty {
                    collectionView.reloadItems(at: visiblePaths)
                }
            }
        }

        private func invalidatePageLoads() {
            photoVaultTrace(
                "unsorted page invalidate generation=\(loadGeneration)->\(loadGeneration &+ 1) "
                    + "loading=\(loadingPages.sorted())"
            )
            loadGeneration &+= 1
            loadingPages.removeAll()
        }

        private static func pageResultDescription(
            _ result: Result<[PHAsset], Error>
        ) -> String {
            switch result {
            case .success(let assets):
                return "success(\(assets.count))"
            case .failure(let error):
                return "failure(\(error.localizedDescription))"
            }
        }

        private func touchPage(containing index: Int) {
            let page = index / pageSize
            guard pageOrder.contains(page) else { return }
            pageOrder.removeAll { $0 == page }
            pageOrder.append(page)
        }

        private func firstVisibleIndex(in scrollView: UIScrollView) -> Int? {
            guard let collectionView = scrollView as? UICollectionView else { return nil }
            return collectionView.indexPathsForVisibleItems
                .map(\.item)
                .min()
        }

        private func trimCachedPages(around index: Int?) {
            guard pageOrder.count > maxCachedPages else { return }

            var protectedPages = Set<Int>()
            if let index {
                protectedPages.insert(index / pageSize)
            }
            if let collectionView {
                for indexPath in collectionView.indexPathsForVisibleItems {
                    protectedPages.insert(indexPath.item / pageSize)
                }
            }

            while pageOrder.count > maxCachedPages,
                  let evictionIndex = pageOrder.firstIndex(where: {
                      !protectedPages.contains($0)
                  }) {
                let page = pageOrder.remove(at: evictionIndex)
                let start = page * pageSize
                let end = min(totalCount, start + pageSize)
                for index in start..<end {
                    assetsByIndex.removeValue(forKey: index)
                    prefetchIndices.remove(index)
                }
            }
            updateCachingWindow(in: self.collectionView)
        }

        private func updateVisibleSelection(in collectionView: UICollectionView) {
            for cell in collectionView.visibleCells {
                guard let photoCell = cell as? PhotoGridCell,
                      let indexPath = collectionView.indexPath(for: cell),
                      let asset = assetsByIndex[indexPath.item]
                else { continue }
                photoCell.setSelection(
                    selectionMode: selectionMode,
                    isSelected: selectedIDs.contains(asset.localIdentifier)
                )
            }
        }

        private func cancelVisibleRequests(in collectionView: UICollectionView) {
            for cell in collectionView.visibleCells {
                (cell as? PhotoGridCell)?.cancelLoading()
            }
        }

        private func applyZoom(
            preferredSide: CGFloat,
            focusPoint: CGPoint,
            in collectionView: UICollectionView
        ) {
            preferredCellSide = PhotoGridMetrics.clampedPreferredSide(preferredSide)
            updateLayout(for: collectionView, preservingFocusAt: focusPoint)
        }

        private func updateLayout(
            for collectionView: UICollectionView,
            preservingFocusAt focusPoint: CGPoint? = nil
        ) {
            guard collectionView.bounds.width > 0,
                  let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout
            else { return }

            let focusIndexPath = focusPoint.flatMap {
                collectionView.indexPathForItem(at: $0)
            }
            let oldFocusFrame = focusIndexPath.flatMap {
                layout.layoutAttributesForItem(at: $0)?.frame
            }
            let side = PhotoGridMetrics.itemSide(
                for: collectionView.bounds.width,
                preferredSide: preferredCellSide
            )
            if abs(layout.itemSize.width - side) > 0.5 {
                layout.itemSize = CGSize(width: side, height: side)
                thumbnailSize = PhotoGridMetrics.thumbnailSize(
                    for: side,
                    displayScale: collectionView.traitCollection.displayScale
                )
                layout.invalidateLayout()
                UIView.performWithoutAnimation {
                    collectionView.layoutIfNeeded()
                }

                if let focusPoint,
                   let focusIndexPath,
                   let oldFocusFrame,
                   let newFocusFrame = layout.layoutAttributesForItem(at: focusIndexPath)?.frame {
                    preserveFocus(
                        at: focusPoint,
                        oldFrame: oldFocusFrame,
                        newFrame: newFocusFrame,
                        in: collectionView
                    )
                }

                let visible = collectionView.indexPathsForVisibleItems
                if !visible.isEmpty { collectionView.reloadItems(at: visible) }
            }
        }

        private func preserveFocus(
            at focusPoint: CGPoint,
            oldFrame: CGRect,
            newFrame: CGRect,
            in collectionView: UICollectionView
        ) {
            guard oldFrame.width > 0,
                  oldFrame.height > 0,
                  newFrame.width > 0,
                  newFrame.height > 0
            else { return }

            let oldContentPoint = CGPoint(
                x: focusPoint.x + collectionView.contentOffset.x,
                y: focusPoint.y + collectionView.contentOffset.y
            )
            let xRatio = (oldContentPoint.x - oldFrame.minX) / oldFrame.width
            let yRatio = (oldContentPoint.y - oldFrame.minY) / oldFrame.height
            let newContentPoint = CGPoint(
                x: newFrame.minX + newFrame.width * xRatio,
                y: newFrame.minY + newFrame.height * yRatio
            )

            var offset = CGPoint(
                x: newContentPoint.x - focusPoint.x,
                y: newContentPoint.y - focusPoint.y
            )
            let minimumX = -collectionView.adjustedContentInset.left
            let maximumX = max(
                minimumX,
                collectionView.contentSize.width
                    - collectionView.bounds.width
                    + collectionView.adjustedContentInset.right
            )
            let minimumY = -collectionView.adjustedContentInset.top
            let maximumY = max(
                minimumY,
                collectionView.contentSize.height
                    - collectionView.bounds.height
                    + collectionView.adjustedContentInset.bottom
            )
            offset.x = min(max(offset.x, minimumX), maximumX)
            offset.y = min(max(offset.y, minimumY), maximumY)
            collectionView.setContentOffset(offset, animated: false)
        }
    }
}
