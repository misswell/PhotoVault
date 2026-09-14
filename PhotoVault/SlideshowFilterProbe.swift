#if DEBUG
import Foundation
import Photos

/// Launch-argument driven self-check for the slideshow content filters
/// (`--pv-slideshow-filter-probe`).
///
/// The filter exists twice on purpose: `SlideshowFilter.matches(_:)` runs over
/// `PHAsset`s for library / album / search sequences, while `sqlWhere` runs
/// over the Unsorted SQLite index, which has no `PHFetchResult` to walk. Two
/// implementations of one rule drift apart silently — "play only landscapes"
/// would quietly mean something slightly different in the Unsorted slideshow —
/// so this probe asserts they agree on the real library, on the device.
///
/// It also checks the *start position* rule, which is the other place the two
/// paths must line up: opening the slideshow from a photo has to begin on that
/// photo in the filtered order, and that position is computed by a SQL rank
/// query in one path and by scanning the filtered indices in the other.
@MainActor
enum SlideshowFilterProbe {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--pv-slideshow-filter-probe")
    }

    /// Beyond this the in-memory half of the comparison would be the slow part
    /// of a debug run on a real 100k library; the check is opt-in and the small
    /// simulator library is what it is normally run against.
    private static let maximumComparableAssets = 2_000

    private static var failures: [String] = []

    static func runIfRequested(store: PhotoLibraryStore) async {
        guard isRequested else { return }
        failures.removeAll()
        photoVaultTrace(
            "slideshow_filter_probe_begin unsorted=\(store.unsortedCount)"
        )

        // The index is rebuilt in the background at launch; comparing against a
        // half-written index would report failures that are not filter bugs.
        let ready = await waitUntil(timeout: 60) {
            store.unsortedCount > 0 && store.isIndexingUnsorted == false
        }
        guard ready else {
            photoVaultTrace(
                "slideshow_filter_probe_result skipped=index-not-ready "
                    + "unsorted=\(store.unsortedCount)"
            )
            return
        }
        guard store.unsortedCount <= maximumComparableAssets else {
            photoVaultTrace(
                "slideshow_filter_probe_result skipped=too-many "
                    + "unsorted=\(store.unsortedCount)"
            )
            return
        }

        let assets = await loadAllUnsorted(store: store)
        guard assets.count == store.unsortedCount else {
            photoVaultTrace(
                "slideshow_filter_probe_result failures=1 "
                    + "[loaded=\(assets.count) expected=\(store.unsortedCount)]"
            )
            return
        }
        photoVaultTrace("slideshow_filter_probe_loaded count=\(assets.count)")

        let screen = SlideshowDisplayMetrics.screenPixelSize
        var filters: [SlideshowFilter] = SlideshowContentFilter.allCases.map {
            SlideshowFilter(content: $0, screenPixelSize: screen)
        }
        for refinement in Self.refinementCases {
            filters.append(
                SlideshowFilter(
                    content: .all,
                    refinements: refinement,
                    screenPixelSize: screen
                )
            )
            filters.append(
                SlideshowFilter(
                    content: .landscape,
                    refinements: refinement,
                    screenPixelSize: screen
                )
            )
        }

        for filter in filters {
            let inMemory = assets.filter { filter.matches($0) }.count
            let sql = (try? await store.unsortedSlideshowCount(matching: filter))
                ?? -1
            check(
                inMemory == sql,
                "count \(filter.summary): memory=\(inMemory) sql=\(sql)"
            )

            // Where would "play from this photo" start? Compare the SQL rank
            // with the position in the in-memory filtered list for the first,
            // middle and last photo of the unsorted order.
            let samples = [0, assets.count / 2, assets.count - 1]
            for sample in samples where sample >= 0 && sample < assets.count {
                let asset = assets[sample]
                let sqlRank = (try? await store.unsortedSlideshowRank(
                    of: asset.localIdentifier,
                    matching: filter
                )) ?? -1
                // "Play from this photo" means "start at the first match at or
                // after it", i.e. the number of matching photos that sort
                // ahead of it — true whether or not the photo itself matches.
                let expected = assets.prefix(sample).filter { filter.matches($0) }.count
                check(
                    sqlRank == expected,
                    "rank \(filter.summary) #\(sample): sql=\(sqlRank) "
                        + "memory=\(expected)"
                )
            }
        }

        photoVaultTrace(
            "slideshow_filter_probe_result failures=\(failures.count) "
                + "[\(failures.joined(separator: ","))]"
        )
    }

    private static var refinementCases: [SlideshowRefinements] {
        [
            SlideshowRefinements(skipsScreenshots: true),
            SlideshowRefinements(onlyFavorites: true),
            SlideshowRefinements(photosOnly: true),
            SlideshowRefinements(
                skipsScreenshots: true,
                onlyFavorites: true,
                photosOnly: true
            ),
        ]
    }

    private static func loadAllUnsorted(store: PhotoLibraryStore) async -> [PHAsset] {
        var assets: [PHAsset] = []
        let pageSize = 500
        var offset = 0
        while offset < store.unsortedCount {
            let page = await withCheckedContinuation { continuation in
                store.fetchUnsortedAssets(offset: offset, limit: pageSize) { result in
                    continuation.resume(returning: (try? result.get()) ?? [])
                }
            }
            guard !page.isEmpty else { break }
            assets.append(contentsOf: page)
            offset += page.count
        }
        return assets
    }

    private static func check(_ condition: Bool, _ message: String) {
        if condition {
            photoVaultTrace("slideshow_filter_probe_check pass \(message)")
        } else {
            failures.append(message)
            photoVaultTrace("slideshow_filter_probe_check FAIL \(message)")
        }
    }

    private static func waitUntil(
        timeout: TimeInterval,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }
}
#endif
