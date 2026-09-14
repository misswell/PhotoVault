import Photos
import UIKit

/// Warms a bounded ring of neighbours around the photo the viewer is showing.
///
/// The pager itself keeps only the pages it needs (current ± 1) so that
/// `UIPageViewController` stays cheap. This separate window asks PhotoKit to
/// pre-cache a slightly wider ring at the viewer's target size, which is what
/// makes a fast left/right swipe land on a warm frame.
///
/// The window is always ≤ 2 × `PhotoImageManager.viewerPrefetchRadius` photos
/// and is replaced (not grown) whenever the index changes, so the underlying
/// `NSCache` keeps its device-sized cost limit.
@MainActor
final class ViewerNeighborPrefetch: ObservableObject {
    private var cachedAssets: [PHAsset] = []
    private var targetSize = CGSize.zero
    private var contentMode: PHImageContentMode = .aspectFit

    /// Build the ring around `currentIndex` directly from the live fetch
    /// result. Only `2 × radius` photos are held at any time.
    func update(
        assets: ViewerAssets,
        currentIndex: Int,
        targetSize: CGSize,
        contentMode: PHImageContentMode
    ) {
        let radius = PhotoImageManager.viewerPrefetchRadius
        var neighbors: [PHAsset] = []
        if assets.count > 0 {
            for offset in 1...max(1, radius) {
                let before = currentIndex - offset
                let after = currentIndex + offset
                if before >= 0, before < assets.count {
                    neighbors.append(assets.object(at: before))
                }
                if after >= 0, after < assets.count {
                    neighbors.append(assets.object(at: after))
                }
            }
        }
        update(assets: neighbors, targetSize: targetSize, contentMode: contentMode)
    }

    /// Same window, for pagers that resolve assets one page at a time and can
    /// only hand over the neighbours they already hold.
    func update(
        assets neighbors: [PHAsset],
        targetSize: CGSize,
        contentMode: PHImageContentMode
    ) {
        guard !matchesCache(neighbors)
                || targetSize != self.targetSize
                || contentMode != self.contentMode
        else { return }

        stop()
        self.targetSize = targetSize
        self.contentMode = contentMode
        cachedAssets = neighbors
        guard !neighbors.isEmpty, targetSize.width > 0 else { return }
        PhotoImageManager.shared.startCaching(
            assets: neighbors,
            targetSize: targetSize,
            contentMode: contentMode,
            isNetworkAccessAllowed: true
        )
    }

    func stop() {
        guard !cachedAssets.isEmpty else { return }
        PhotoImageManager.shared.stopCaching(
            assets: cachedAssets,
            targetSize: targetSize,
            contentMode: contentMode,
            isNetworkAccessAllowed: true
        )
        cachedAssets.removeAll()
    }

    private func matchesCache(_ neighbors: [PHAsset]) -> Bool {
        guard neighbors.count == cachedAssets.count else { return false }
        for (lhs, rhs) in zip(neighbors, cachedAssets)
        where lhs.localIdentifier != rhs.localIdentifier {
            return false
        }
        return true
    }
}
