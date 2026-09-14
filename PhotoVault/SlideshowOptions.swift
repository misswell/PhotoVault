import Foundation
import Photos
import SwiftUI

// MARK: - Matching

/// The content filter is evaluated two ways, because the app has two kinds of
/// slideshow source and only one of them can be walked as a `PHFetchResult`:
///
/// - `matches(_:)` runs against a `PHAsset`, for the library / album / search
///   sequences that the viewer already holds.
/// - `sqlWhere` / `sqlBindings` express the *same* predicate over the columns
///   of the Unsorted SQLite index, which has no `PHFetchResult` to walk.
///
/// Both are asserted against each other by `SlideshowFilterProbe`
/// (`--pv-slideshow-filter-probe`), because two implementations of one rule
/// drift apart silently otherwise.
extension SlideshowFilter {
    /// Squareness tolerance: a photo counts as square when its longer side is
    /// within 5% of its shorter side. Demanding exact equality would match
    /// almost nothing, since no camera writes a perfectly square file.
    private static let squareRatioDivisor: Int64 = 20

    func matches(_ asset: PHAsset) -> Bool {
        let width = Int64(asset.pixelWidth)
        let height = Int64(asset.pixelHeight)
        switch content {
        case .all:
            break
        case .landscape:
            guard width > height else { return false }
        case .portrait:
            guard height > width else { return false }
        case .square:
            guard Self.isSquare(width: width, height: height) else { return false }
        case .panorama:
            guard asset.mediaSubtypes.contains(.photoPanorama) else { return false }
        case .highQuality:
            guard isSharpEnough(width: width, height: height) else { return false }
        }
        if refinements.skipsScreenshots,
           asset.mediaSubtypes.contains(.photoScreenshot) {
            return false
        }
        if refinements.onlyFavorites, !asset.isFavorite {
            return false
        }
        if refinements.photosOnly, asset.mediaType != .image {
            return false
        }
        return true
    }

    static func isSquare(width: Int64, height: Int64) -> Bool {
        guard width > 0, height > 0 else { return false }
        return abs(width - height) * squareRatioDivisor <= max(width, height)
    }

    /// "Higher resolution than the screen" means exactly what it says: the
    /// photo would not have to be enlarged to fill the display, in either
    /// aspect-fit or aspect-fill mode. That is true as soon as *one* axis has
    /// enough pixels (a 1920×1080 photo on a 1206×2622 screen is downscaled to
    /// fit the width, so it is sharp and must not be filtered out).
    func isSharpEnough(width: Int64, height: Int64) -> Bool {
        guard screenPixelSize.width > 0, screenPixelSize.height > 0 else {
            // Without a concrete display there is nothing to compare against;
            // keeping the photo is the harmless choice.
            return true
        }
        return width >= Int64(screenPixelSize.width.rounded())
            || height >= Int64(screenPixelSize.height.rounded())
    }

    /// A complete SQL boolean expression over `asset_index`, so callers can
    /// drop it into a `WHERE` without special-casing the default filter.
    ///
    /// The bit values are PhotoKit's own: `photoPanorama = 1 << 0`,
    /// `photoScreenshot = 1 << 2`, and `PHAssetMediaType.image = 1`. They are
    /// written as numbers because SQLite cannot see the Swift constants.
    var sqlWhere: String {
        var clauses: [String] = []
        switch content {
        case .all:
            break
        case .landscape:
            clauses.append("pixel_width > pixel_height")
        case .portrait:
            clauses.append("pixel_height > pixel_width")
        case .square:
            clauses.append(
                "pixel_width > 0 AND pixel_height > 0 "
                    + "AND abs(pixel_width - pixel_height) * 20 "
                    + "<= max(pixel_width, pixel_height)"
            )
        case .panorama:
            clauses.append("(media_subtype & 1) != 0")
        case .highQuality:
            if screenPixelSize.width > 0, screenPixelSize.height > 0 {
                clauses.append("(pixel_width >= ? OR pixel_height >= ?)")
            }
        }
        if refinements.skipsScreenshots {
            clauses.append("(media_subtype & 4) = 0")
        }
        if refinements.onlyFavorites {
            clauses.append("favorite = 1")
        }
        if refinements.photosOnly {
            clauses.append("media_type = 1")
        }
        return clauses.isEmpty ? "1 = 1" : clauses.joined(separator: " AND ")
    }

    /// Bound in order for the `?` placeholders `sqlWhere` emits.
    var sqlBindings: [Int64] {
        guard content == .highQuality,
              screenPixelSize.width > 0,
              screenPixelSize.height > 0
        else { return [] }
        return [
            Int64(screenPixelSize.width.rounded()),
            Int64(screenPixelSize.height.rounded()),
        ]
    }
}

// MARK: - Display metrics

@MainActor
enum SlideshowDisplayMetrics {
    /// The active screen in *device pixels*, in its current orientation. The
    /// high quality filter compares against this, so it must be pixels and not
    /// points — comparing a 1206-pixel-wide photo against a 402-point screen
    /// would call every photo high resolution.
    static var screenPixelSize: CGSize {
        let scenes = UIApplication.shared.connectedScenes.compactMap {
            $0 as? UIWindowScene
        }
        let scene = scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first
        guard let screen = scene?.screen else {
            return CGSize(width: 1179, height: 2556)
        }
        let bounds = screen.bounds.size
        return CGSize(
            width: bounds.width * screen.scale,
            height: bounds.height * screen.scale
        )
    }

    /// The filter as the launch sheet and the slideshow should build it.
    @MainActor
    static func filter(
        content: SlideshowContentFilter,
        refinements: SlideshowRefinements
    ) -> SlideshowFilter {
        SlideshowFilter(
            content: content,
            refinements: refinements,
            screenPixelSize: screenPixelSize
        )
    }
}

// MARK: - Playlist resolution

/// What the options sheet decided to play, resolved and ready to present.
enum SlideshowLaunch {
    /// A sequence the viewer already holds. `indices` is `nil` when nothing
    /// was filtered out, which is what keeps pressing play on a 100k library
    /// from enumerating anything at all.
    case sequence(assets: ViewerAssets, indices: [Int]?, start: Int, count: Int)
    /// The Unsorted order, which has no `PHFetchResult`: pages are read from
    /// the SQLite index with the filter applied server-side.
    case indexed(
        store: PhotoLibraryStore,
        filter: SlideshowFilter,
        start: Int,
        count: Int
    )

    var count: Int {
        switch self {
        case .sequence(_, _, _, let count): return count
        case .indexed(_, _, _, let count): return count
        }
    }
}

/// Builds the concrete sequence behind a launch. Enumeration reads metadata
/// only — no image, video or iCloud request is issued — and runs off the main
/// actor, so a filtered 100k library cannot block the sheet.
enum SlideshowPlaylistBuilder {
    struct Resolution {
        var indices: [Int]?
        var start: Int
        var count: Int
    }

    /// `startingIndex` is an offset into `assets`, and the filtered start is
    /// the number of kept offsets below it. That is deliberately the same rule
    /// the Unsorted path implements in SQL (`unsortedRank`): "start at the
    /// first matching photo at or after the one the user was looking at".
    static func resolve(
        assets: ViewerAssets,
        filter: SlideshowFilter,
        startingIndex: Int
    ) async -> Resolution? {
        guard !filter.keepsEverything else {
            let count = assets.count
            let start = min(max(0, startingIndex), max(0, count - 1))
            return Resolution(indices: nil, start: start, count: count)
        }

        var indices: [Int] = []
        let total = assets.count
        indices.reserveCapacity(total)
        // Walking the sequence must not park the main thread: on a 100k library
        // this loop reads 100k `PHAsset`s, and the sheet is on screen while it
        // runs. Yielding every few hundred keeps the spinner and the cancel
        // path alive; `全部照片` never reaches here at all.
        for offset in 0..<total {
            if offset % 256 == 0 {
                if Task.isCancelled { return nil }
                await Task.yield()
            }
            let asset = assets.object(at: offset)
            if filter.matches(asset) {
                indices.append(offset)
            }
        }
        if Task.isCancelled { return nil }

        let clampedStart = min(max(0, startingIndex), total)
        let start = indices.prefix { $0 < clampedStart }.count
        return Resolution(indices: indices, start: start, count: indices.count)
    }
}

// MARK: - Sheet

/// Where the sheet's sequence comes from. The two cases exist because the
/// Unsorted list is paged out of SQLite and never materialised as a
/// `PHFetchResult`; both carry the raw index *and* the asset id of the photo
/// the user came from, so the unfiltered path can start instantly and the
/// filtered path can find the same photo's position in the filtered order.
enum SlideshowOptionsSource {
    /// `startingIndex` is the *unfiltered* offset of the photo the user came
    /// from, which is all the filtered start position needs (see
    /// `SlideshowPlaylistBuilder.resolve`).
    case sequence(ViewerAssets, startingIndex: Int)
    /// The Unsorted list adds the asset id: filtering happens in SQL, so the
    /// filtered position comes from the index rather than from an offset.
    case indexed(PhotoLibraryStore, startingOffset: Int, startingAssetID: String?)

    /// The source's size before filtering, for the sheet's footer.
    @MainActor
    var totalCount: Int {
        switch self {
        case .sequence(let assets, _): return assets.count
        case .indexed(let store, _, _): return store.unsortedCount
        }
    }
}

/// The launch sheet: what to play, how to play it, and a live count so an
/// over-narrow filter is visible *before* the slideshow starts. Preferences
/// live in `@AppStorage`, so the sheet opens on last time's choice and the
/// slideshow itself reads the same keys.
struct SlideshowOptionsSheet: View {
    let title: String
    /// `nil` for folder slideshows: they are `[URL]`-backed and cannot be
    /// filtered by picture metadata without decoding every file, so they only
    /// get the playback options. Nothing to count, nothing to resolve.
    let source: SlideshowOptionsSource?
    let onStart: (SlideshowLaunch?) -> Void

    /// Content filters only make sense when there is a sequence to filter.
    private var supportsContentFilters: Bool { source != nil }

    @Environment(\.dismiss) private var dismiss
    @AppStorage(SlideshowContentFilter.storageKey)
    private var contentRawValue = SlideshowContentFilter.all.rawValue
    @AppStorage(SlideshowRefinements.skipsScreenshotsKey)
    private var skipsScreenshots = false
    @AppStorage(SlideshowRefinements.onlyFavoritesKey)
    private var onlyFavorites = false
    @AppStorage(SlideshowRefinements.photosOnlyKey)
    private var photosOnly = false
    @AppStorage(SlideshowPlaybackSettings.fillsScreenKey)
    private var fillsScreen = SlideshowPlaybackSettings.defaultFillsScreen
    @AppStorage(SlideshowPlaybackSettings.shufflesKey)
    private var shuffles = SlideshowPlaybackSettings.defaultShuffles
    @AppStorage(SlideshowSettings.loopsStorageKey)
    private var loops = SlideshowSettings.defaultLoops
    @AppStorage(SlideshowSettings.intervalStorageKey)
    private var interval: TimeInterval = SlideshowSettings.defaultInterval

    @State private var resolution: SlideshowPlaylistBuilder.Resolution?
    @State private var indexedCount: Int?
    @State private var indexedStart = 0
    @State private var isResolving = false
    private var content: SlideshowContentFilter {
        SlideshowContentFilter(rawValue: contentRawValue) ?? .all
    }

    private var refinements: SlideshowRefinements {
        SlideshowRefinements(
            skipsScreenshots: skipsScreenshots,
            onlyFavorites: onlyFavorites,
            photosOnly: photosOnly
        )
    }

    private var filter: SlideshowFilter {
        SlideshowFilter(
            content: content,
            refinements: refinements,
            screenPixelSize: SlideshowDisplayMetrics.screenPixelSize
        )
    }

    /// Everything that changes what would be played. Re-resolving on any of
    /// it keeps the count honest; playback-only options stay out, since they
    /// cannot change the count.
    /// Changes whenever the answer would change: the filter itself, plus the
    /// Unsorted index finishing its (re)build — a filtered count read while the
    /// index is still being written is a partial number, and the sheet has to
    /// ask again once it settles.
    private var resolutionKey: String {
        "\(content.rawValue)|\(skipsScreenshots)|\(onlyFavorites)|"
            + "\(photosOnly)|\(Int(filter.screenPixelSize.width))|"
            + "\(Int(filter.screenPixelSize.height))|\(isIndexing)"
    }

    /// Only the Unsorted source reads a SQLite index that can be mid-rebuild.
    private var isIndexing: Bool {
        if case .indexed(let store, _, _) = source {
            return store.isIndexingUnsorted
        }
        return false
    }

    private var resolvedCount: Int? {
        switch source {
        case .none: return nil
        case .sequence: return resolution?.count
        case .indexed: return indexedCount
        }
    }

    private var statusText: String {
        guard source != nil else {
            return "文件夹相册按文件顺序播放，画幅筛选不适用。"
        }
        guard let count = resolvedCount else { return "正在统计…" }
        guard count > 0 else {
            // A zero here is not always an answer: while the Unsorted index is
            // being rebuilt the count really is 0, and saying "no photos match"
            // would blame the filter for it.
            return isIndexing
                ? "正在整理照片索引…"
                : "没有符合条件的照片，换一个条件试试。"
        }
        let base = "将播放 \(count.formatted()) 张"
        return filter.keepsEverything ? "\(base)（全部）" : "\(base) · \(filter.summary)"
    }

    var body: some View {
        NavigationStack {
            Form {
                if supportsContentFilters {
                    Section("播放内容") {
                        Picker("内容", selection: $contentRawValue) {
                            ForEach(SlideshowContentFilter.allCases) { filter in
                                Label(filter.title, systemImage: filter.symbol)
                                    .tag(filter.rawValue)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()

                        Text(content.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Section {
                        Toggle("排除截屏", isOn: $skipsScreenshots)
                        Toggle("仅收藏", isOn: $onlyFavorites)
                        Toggle("只播照片", isOn: $photosOnly)
                    } header: {
                        Text("进一步筛选")
                    } footer: {
                        Text("筛选只读取本地元数据，不会额外下载照片。")
                    }
                }

                Section {
                    Toggle("填充满画面", isOn: $fillsScreen)
                    Toggle("随机顺序", isOn: $shuffles)
                    Toggle("循环播放", isOn: $loops)

                    Picker("切换间隔", selection: $interval) {
                        ForEach(SlideshowSettings.intervalValues, id: \.self) { value in
                            Text("每 \(Int(value)) 秒").tag(value)
                        }
                    }
                } header: {
                    Text("播放方式")
                } footer: {
                    Text("填充满画面会把照片铺满屏幕，超出部分被裁掉。")
                }

            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            // Pinned instead of a trailing form row: on a phone the form is
            // longer than the screen, and "start" is not something the user
            // should have to scroll to find. The count travels with it so the
            // effect of a filter change is visible without scrolling either.
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        if source != nil, resolvedCount == nil, isResolving {
                            ProgressView().controlSize(.small)
                        }
                        Text(statusText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Button {
                        start()
                    } label: {
                        Label("开始播放", systemImage: "play.fill")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(source != nil && (resolvedCount == nil || resolvedCount == 0))
                    .accessibilityIdentifier("slideshow-start")
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 6)
                .background(.bar)
            }
        }
        .task(id: resolutionKey) {
            await resolvePlaylist()
        }
        .accessibilityIdentifier("slideshow-options")
    }

    private func start() {
        if source == nil {
            onStart(nil)
            return
        }
        guard let launch = makeLaunch() else { return }
        onStart(launch)
    }

    /// Resolves what would be played so the sheet can show the count. The
    /// result is reused verbatim when the user taps start, so the sequence is
    /// never built twice.
    private func resolvePlaylist() async {
        guard let source else { return }
        isResolving = true
        defer { isResolving = false }
        switch source {
        case .sequence(let assets, let startingIndex):
            let resolved = await SlideshowPlaylistBuilder.resolve(
                assets: assets,
                filter: filter,
                startingIndex: startingIndex
            )
            guard !Task.isCancelled else { return }
            resolution = resolved
        case .indexed(let store, let startingOffset, let startingAssetID):
            indexedCount = nil
            let filter = self.filter
            let count = try? await store.unsortedSlideshowCount(matching: filter)
            guard !Task.isCancelled else { return }
            indexedCount = count ?? 0
            // The filtered start position needs the index; the unfiltered one
            // is the offset the user was already on.
            if !filter.keepsEverything, let startingAssetID {
                let rank = try? await store.unsortedSlideshowRank(
                    of: startingAssetID,
                    matching: filter
                )
                guard !Task.isCancelled else { return }
                indexedStart = min(max(0, rank ?? 0), max(0, (count ?? 1) - 1))
            } else {
                indexedStart = min(
                    max(0, startingOffset),
                    max(0, (count ?? 1) - 1)
                )
            }
        }
    }

    private func makeLaunch() -> SlideshowLaunch? {
        switch source {
        case .none:
            return nil
        case .sequence(let assets, _):
            guard let resolution else { return nil }
            return .sequence(
                assets: assets,
                indices: resolution.indices,
                start: resolution.start,
                count: resolution.count
            )
        case .indexed(let store, _, _):
            guard let count = indexedCount, count > 0 else { return nil }
            return .indexed(
                store: store,
                filter: filter,
                start: indexedStart,
                count: count
            )
        }
    }
}
