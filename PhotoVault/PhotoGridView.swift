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
    private var initialPreferredSide = PhotoGridMetrics.defaultCellSide

    init(
        currentPreferredSide: @escaping () -> CGFloat,
        onZoom: @escaping (CGFloat, CGPoint) -> Void
    ) {
        self.currentPreferredSide = currentPreferredSide
        self.onZoom = onZoom
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
        case .changed, .ended, .cancelled:
            let preferredSide = PhotoGridMetrics.clampedPreferredSide(
                initialPreferredSide * gestureRecognizer.scale
            )
            onZoom(
                preferredSide,
                gestureRecognizer.location(in: collectionView)
            )
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

/// The large-library grid is backed by UICollectionView so PhotoKit assets
/// and cells are both viewport-bound. SwiftUI still owns the screen and
/// callbacks, while UIKit provides recycling, prefetching and fast scrolling.
struct PhotoGridView: UIViewRepresentable {
    let assets: PHFetchResult<PHAsset>
    let selectionMode: Bool
    let selectedIDs: Set<String>
    let onOpen: (Int) -> Void
    let onToggleSelection: (PHAsset) -> Void
    let onFavorite: (PHAsset) -> Void
    let onShare: (PHAsset) -> Void
    let onDelete: (PHAsset) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            assets: assets,
            selectionMode: selectionMode,
            selectedIDs: selectedIDs,
            onOpen: onOpen,
            onToggleSelection: onToggleSelection,
            onFavorite: onFavorite,
            onShare: onShare,
            onDelete: onDelete
        )
    }

    func makeUIView(context: Context) -> UICollectionView {
        context.coordinator.makeCollectionView()
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.update(
            collectionView: collectionView,
            assets: assets,
            selectionMode: selectionMode,
            selectedIDs: selectedIDs,
            onOpen: onOpen,
            onToggleSelection: onToggleSelection,
            onFavorite: onFavorite,
            onShare: onShare,
            onDelete: onDelete
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
        private var selectionMode: Bool
        private var selectedIDs: Set<String>
        private var thumbnailSize = CGSize(width: 160, height: 160)
        private var preferredCellSide = PhotoGridMetrics.defaultCellSide
        private var isFastScrolling = false
        private var selectionPanDriver: PhotoSelectionPanDriver?
        private var pinchDriver: PhotoGridPinchDriver?
        private weak var collectionView: UICollectionView?

        private var onOpen: (Int) -> Void
        private var onToggleSelection: (PHAsset) -> Void
        private var onFavorite: (PHAsset) -> Void
        private var onShare: (PHAsset) -> Void
        private var onDelete: (PHAsset) -> Void

        init(
            assets: PHFetchResult<PHAsset>,
            selectionMode: Bool,
            selectedIDs: Set<String>,
            onOpen: @escaping (Int) -> Void,
            onToggleSelection: @escaping (PHAsset) -> Void,
            onFavorite: @escaping (PHAsset) -> Void,
            onShare: @escaping (PHAsset) -> Void,
            onDelete: @escaping (PHAsset) -> Void
        ) {
            self.assets = assets
            signature = Self.signature(for: assets)
            self.selectionMode = selectionMode
            self.selectedIDs = selectedIDs
            self.onOpen = onOpen
            self.onToggleSelection = onToggleSelection
            self.onFavorite = onFavorite
            self.onShare = onShare
            self.onDelete = onDelete
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
            selectionMode: Bool,
            selectedIDs: Set<String>,
            onOpen: @escaping (Int) -> Void,
            onToggleSelection: @escaping (PHAsset) -> Void,
            onFavorite: @escaping (PHAsset) -> Void,
            onShare: @escaping (PHAsset) -> Void,
            onDelete: @escaping (PHAsset) -> Void
        ) {
            self.collectionView = collectionView
            self.selectionMode = selectionMode
            self.selectedIDs = selectedIDs
            self.onOpen = onOpen
            self.onToggleSelection = onToggleSelection
            self.onFavorite = onFavorite
            self.onShare = onShare
            self.onDelete = onDelete
            selectionPanDriver?.isEnabled = selectionMode

            let newSignature = Self.signature(for: assets)
            let dataSourceChanged = newSignature != signature
            self.assets = assets
            signature = newSignature

            if dataSourceChanged {
                collectionView.reloadData()
            }

            updateLayout(for: collectionView)
            updateVisibleSelection(in: collectionView)
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
            guard indexPath.item < assets.count else { return }
            let asset = assets.object(at: indexPath.item)
            if selectionMode {
                onToggleSelection(asset)
            } else {
                onOpen(indexPath.item)
            }
            collectionView.deselectItem(at: indexPath, animated: false)
        }

        func collectionView(
            _ collectionView: UICollectionView,
            prefetchItemsAt indexPaths: [IndexPath]
        ) {
            guard !isFastScrolling else { return }
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

                let favoriteAction = UIAction(
                    title: asset.isFavorite ? "取消收藏" : "收藏",
                    image: UIImage(systemName: asset.isFavorite ? "heart.slash" : "heart")
                ) { [weak self] _ in
                    self?.onFavorite(asset)
                }
                let shareAction = UIAction(
                    title: "分享",
                    image: UIImage(systemName: "square.and.arrow.up")
                ) { [weak self] _ in
                    self?.onShare(asset)
                }
                let deleteAction = UIAction(
                    title: "删除",
                    image: UIImage(systemName: "trash"),
                    attributes: .destructive
                ) { [weak self] _ in
                    self?.onDelete(asset)
                }
                return UIMenu(title: "", children: [favoriteAction, shareAction, deleteAction])
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
        imageView.image = nil
        loadingIndicator.startAnimating()

        liveBadge.isHidden = !asset.mediaSubtypes.contains(.photoLive)
        videoDurationLabel.isHidden = asset.mediaType != .video
        if asset.mediaType == .video {
            videoDurationLabel.text = durationText(for: asset.duration)
        }
        setSelection(selectionMode: selectionMode, isSelected: isSelected)
        accessibilityLabel = asset.mediaType == .video ? "视频" : "照片"

        PhotoImageManager.shared.startCaching(asset: asset, targetSize: targetSize)
        requestHandle = PhotoImageManager.shared.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            deliveryMode: .opportunistic,
            resizeMode: .fast,
            priority: .visibleGrid,
            isNetworkAccessAllowed: true,
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
            guard !cancelled else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      self.representedIdentifier == asset.localIdentifier
                else { return }
                self.loadingIndicator.stopAnimating()
                self.imageView.image = image
            }
        }
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
        PhotoImageManager.shared.cancel(requestHandle)
        if let representedAsset {
            PhotoImageManager.shared.stopCaching(
                asset: representedAsset,
                targetSize: representedTargetSize
            )
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
    let selectionMode: Bool
    let selectedIDs: Set<String>
    let onOpen: (PHAsset, Int) -> Void
    let onToggleSelection: (PHAsset) -> Void
    let onFavorite: (PHAsset) -> Void
    let onShare: (PHAsset) -> Void
    let onDelete: (PHAsset) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            totalCount: totalCount,
            store: store,
            selectionMode: selectionMode,
            selectedIDs: selectedIDs,
            onOpen: onOpen,
            onToggleSelection: onToggleSelection,
            onFavorite: onFavorite,
            onShare: onShare,
            onDelete: onDelete
        )
    }

    func makeUIView(context: Context) -> UICollectionView {
        context.coordinator.makeCollectionView()
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.update(
            collectionView: collectionView,
            totalCount: totalCount,
            selectionMode: selectionMode,
            selectedIDs: selectedIDs,
            onOpen: onOpen,
            onToggleSelection: onToggleSelection,
            onFavorite: onFavorite,
            onShare: onShare,
            onDelete: onDelete
        )
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate,
        UICollectionViewDataSourcePrefetching, UICollectionViewDelegateFlowLayout {
        private let pageSize = 240
        private var totalCount: Int
        private let store: PhotoLibraryStore
        private var selectionMode: Bool
        private var selectedIDs: Set<String>
        private var assetsByIndex: [Int: PHAsset] = [:]
        private var loadingPages = Set<Int>()
        private var pageOrder: [Int] = []
        private let maxCachedPages = 8
        private var thumbnailSize = CGSize(width: 160, height: 160)
        private var preferredCellSide = PhotoGridMetrics.defaultCellSide
        private var selectionPanDriver: PhotoSelectionPanDriver?
        private var pinchDriver: PhotoGridPinchDriver?
        private weak var collectionView: UICollectionView?

        private var onOpen: (PHAsset, Int) -> Void
        private var onToggleSelection: (PHAsset) -> Void
        private var onFavorite: (PHAsset) -> Void
        private var onShare: (PHAsset) -> Void
        private var onDelete: (PHAsset) -> Void

        init(
            totalCount: Int,
            store: PhotoLibraryStore,
            selectionMode: Bool,
            selectedIDs: Set<String>,
            onOpen: @escaping (PHAsset, Int) -> Void,
            onToggleSelection: @escaping (PHAsset) -> Void,
            onFavorite: @escaping (PHAsset) -> Void,
            onShare: @escaping (PHAsset) -> Void,
            onDelete: @escaping (PHAsset) -> Void
        ) {
            self.totalCount = max(0, totalCount)
            self.store = store
            self.selectionMode = selectionMode
            self.selectedIDs = selectedIDs
            self.onOpen = onOpen
            self.onToggleSelection = onToggleSelection
            self.onFavorite = onFavorite
            self.onShare = onShare
            self.onDelete = onDelete
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
                }
            )
            pinchDriver.attach(to: collectionView)
            self.pinchDriver = pinchDriver

            DispatchQueue.main.async { [weak self, weak collectionView] in
                guard let self, let collectionView else { return }
                self.updateLayout(for: collectionView)
            }
            return collectionView
        }

        func update(
            collectionView: UICollectionView,
            totalCount: Int,
            selectionMode: Bool,
            selectedIDs: Set<String>,
            onOpen: @escaping (PHAsset, Int) -> Void,
            onToggleSelection: @escaping (PHAsset) -> Void,
            onFavorite: @escaping (PHAsset) -> Void,
            onShare: @escaping (PHAsset) -> Void,
            onDelete: @escaping (PHAsset) -> Void
        ) {
            self.collectionView = collectionView
            self.selectionMode = selectionMode
            self.selectedIDs = selectedIDs
            self.onOpen = onOpen
            self.onToggleSelection = onToggleSelection
            self.onFavorite = onFavorite
            self.onShare = onShare
            self.onDelete = onDelete
            selectionPanDriver?.isEnabled = selectionMode

            let newCount = max(0, totalCount)
            if newCount != self.totalCount {
                self.totalCount = newCount
                assetsByIndex.removeAll(keepingCapacity: true)
                loadingPages.removeAll()
                pageOrder.removeAll(keepingCapacity: true)
                collectionView.reloadData()
            } else {
                self.totalCount = newCount
            }

            updateLayout(for: collectionView)
            updateVisibleSelection(in: collectionView)
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
                loadPage(containing: indexPath.item, in: collectionView)
            }
            return cell
        }

        func collectionView(
            _ collectionView: UICollectionView,
            didSelectItemAt indexPath: IndexPath
        ) {
            guard let asset = assetsByIndex[indexPath.item] else {
                loadPage(containing: indexPath.item, in: collectionView)
                collectionView.deselectItem(at: indexPath, animated: false)
                return
            }
            touchPage(containing: indexPath.item)
            if selectionMode {
                onToggleSelection(asset)
            } else {
                onOpen(asset, indexPath.item)
            }
            collectionView.deselectItem(at: indexPath, animated: false)
        }

        func collectionView(
            _ collectionView: UICollectionView,
            prefetchItemsAt indexPaths: [IndexPath]
        ) {
            for indexPath in indexPaths {
                touchPage(containing: indexPath.item)
                loadPage(containing: indexPath.item, in: collectionView)
            }
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
                let favorite = UIAction(
                    title: asset.isFavorite ? "取消收藏" : "收藏",
                    image: UIImage(systemName: asset.isFavorite ? "heart.slash" : "heart")
                ) { [weak self] _ in self?.onFavorite(asset) }
                let share = UIAction(
                    title: "分享",
                    image: UIImage(systemName: "square.and.arrow.up")
                ) { [weak self] _ in self?.onShare(asset) }
                let delete = UIAction(
                    title: "删除",
                    image: UIImage(systemName: "trash"),
                    attributes: .destructive
                ) { [weak self] _ in self?.onDelete(asset) }
                return UIMenu(title: "", children: [favorite, share, delete])
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

        private func loadPage(containing index: Int, in collectionView: UICollectionView) {
            guard index >= 0, index < totalCount else { return }
            let page = index / pageSize
            guard loadingPages.insert(page).inserted else { return }

            let offset = page * pageSize
            store.fetchUnsortedAssets(offset: offset, limit: pageSize) { [weak self, weak collectionView] result in
                guard let self, let collectionView else { return }
                self.loadingPages.remove(page)
                guard case .success(let pageAssets) = result else { return }

                for (localIndex, asset) in pageAssets.enumerated() {
                    self.assetsByIndex[offset + localIndex] = asset
                }
                self.pageOrder.removeAll { $0 == page }
                self.pageOrder.append(page)
                self.trimCachedPages(around: self.firstVisibleIndex(in: collectionView))

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
                }
            }
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
