import Photos
import SwiftUI
import UIKit

// MARK: - Session scoped transition state

/// One viewer session's business state for the system zoom transition.
///
/// Scoped to a single `PhotoViewerHostingController`: the session id is minted
/// when the viewer is opened and dies with the controller. Nothing here
/// describes an animation — the push/pop *is* the animation, and UIKit owns it.
///
/// This is what makes overlapping transitions safe. When A is popping while B
/// is pushing, both viewers are alive at once, so both need their own answer to
/// "which photo am I showing, and where should I land?" — the previous
/// design kept a single mutable "current viewer state" on the grid and had to
/// invent generations to stop A's late callbacks from corrupting B. Two states
/// simply cannot collide.
@MainActor
final class PhotoViewerTransitionState {
    let sessionID: UUID
    private(set) var currentIndex: Int
    private(set) var currentAssetIdentifier: String?

    /// Set by the live viewer while it is on screen. Returns true when the
    /// system's interactive zoom dismissal must not engage (image zoomed in,
    /// horizontal page transition in flight, filmstrip being scrubbed), so the
    /// one-finger drag keeps panning the photo or the pager instead.
    var interactiveDismissVeto: (() -> Bool)?

    /// The rect inside the viewer that currently holds the photo itself
    /// (aspect-fit letterbox excluded). The zoom transition aligns the grid
    /// cell with this rect, so the photo — not a full-screen letterbox — is
    /// what morphs. nil means "no preference".
    var zoomAlignmentRectProvider: ((_ containerSize: CGSize) -> CGRect?)?

    init(sessionID: UUID, index: Int, assetIdentifier: String?) {
        self.sessionID = sessionID
        self.currentIndex = index
        self.currentAssetIdentifier = assetIdentifier
    }

    /// Follow the viewer: every page turn, filmstrip jump and deletion moves
    /// the photo the zoom-out must land on. Read at dismissal time, never
    /// cached, so "哪来的回哪" always resolves against what is on screen.
    func update(index: Int, assetIdentifier: String?) {
        currentIndex = index
        currentAssetIdentifier = assetIdentifier
    }

    var debugLabel: String {
        "session=\(sessionID.uuidString.prefix(8)) index=\(currentIndex) "
            + "asset=\(photoVaultShortAssetID(currentAssetIdentifier ?? "nil"))"
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
/// Deliberately knows nothing about viewers. It used to own a mutable
/// "current viewer transition state" plus a `beginViewerSession()` call that
/// replaced it, which is exactly what made an overlapping pop→push resolve one
/// session's source cell from the other's state. Each viewer now carries its
/// own state, and this type just answers the question it is asked.
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

    /// True when `view` is the registered grid or one of its ancestors.
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
    /// The question the fluid-transition work turns on: while the zoom-out is
    /// running, would a touch at a grid cell reach the grid? Asked with a real
    /// `hitTest` so the answer reflects the actual view stack.
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

    /// Test/probe-only input through the same delegate as a real grid
    /// selection, and only when a real touch at that cell would land on it.
    @discardableResult
    func debugSelectPhoto(at index: Int) -> Bool {
        guard let collectionView, index < collectionView.numberOfItems(inSection: 0) else {
            return false
        }
        let path = IndexPath(item: index, section: 0)
        guard let cell = collectionView.cellForItem(at: path),
              let window = cell.window else { return false }
        let point = cell.convert(CGPoint(x: cell.bounds.midX, y: cell.bounds.midY), to: window)
        let hit = window.hitTest(point, with: nil)
        let reached = hit === cell || hit?.isDescendant(of: cell) == true
        photoVaultTraceLaunch("grid_probe_hit=\(reached) index=\(index)")
        guard reached else { return false }
        collectionView.delegate?.collectionView?(collectionView, didSelectItemAt: path)
        return true
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
            // (it was deleted). Zooming into whatever took its slot would land
            // on the wrong photo, so report "no source" and let UIKit run its
            // plain fade-out instead.
            return nil
        }

        // No identifier yet (an unsorted page may still be resolving): use
        // the index only if valid.
        return (index >= 0 && index < count) ? index : nil
    }
}
