import Foundation
import OSLog

#if DEBUG
/// Minimal signposts for the timeline that matters: grid tap → first visible
/// viewer frame → high-quality frame. OSLog only; `print` is never used on the
/// main thread in this project.
enum ViewerPerformanceTrace {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.misswell.PhotoVault",
        category: "ViewerPerf"
    )
    private static let clock = ContinuousClock()
    private static let lock = NSLock()
    nonisolated(unsafe) private static var tapInstant: ContinuousClock.Instant?
    nonisolated(unsafe) private static var hasMarkedFirstFrame = false

    static func gridTap(assetIdentifier: String) {
        lock.lock()
        tapInstant = clock.now
        hasMarkedFirstFrame = false
        lock.unlock()
        logger.debug("grid_tap asset=\(photoVaultShortAssetID(assetIdentifier), privacy: .public)")
    }

    static func viewerPresentStart() {
        logger.debug("viewer_present_start")
    }

    /// Called once per viewer session, the first time a page has a frame the
    /// user can actually see.
    static func viewerFirstFrame() {
        lock.lock()
        guard !hasMarkedFirstFrame else {
            lock.unlock()
            return
        }
        hasMarkedFirstFrame = true
        let elapsed = tapInstant.map { clock.now - $0 }
        lock.unlock()
        if let elapsed {
            let milliseconds = Int(
                Double(elapsed.components.seconds) * 1_000
                    + Double(elapsed.components.attoseconds) / 1e15
            )
            logger.debug("viewer_first_frame latency_ms=\(milliseconds, privacy: .public)")
        } else {
            logger.debug("viewer_first_frame")
        }
    }

    static func viewerHighQualityReady() {
        logger.debug("viewer_high_quality_ready")
    }

    static func viewerDismissStart() {
        logger.debug("viewer_dismiss_start")
    }

    static func viewerDismissEnd() {
        logger.debug("viewer_dismiss_end")
    }
}
#else
enum ViewerPerformanceTrace {
    static func gridTap(assetIdentifier: String) {}
    static func viewerPresentStart() {}
    static func viewerFirstFrame() {}
    static func viewerHighQualityReady() {}
    static func viewerDismissStart() {}
    static func viewerDismissEnd() {}
}
#endif
