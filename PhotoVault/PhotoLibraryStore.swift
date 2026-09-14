import Foundation
import Photos
import UIKit

/// Carries the fast-changing index progress on its own observable object.
///
/// The index scanner publishes progress up to four times per second. While
/// those writes lived on `PhotoLibraryStore` they invalidated every view that
/// observes the store — the sidebar, both grids and the settings panel — even
/// though only a small progress label reads the value. Splitting it out keeps
/// a long 100k-item scan from re-rendering the whole UI several times a second.
@MainActor
final class PhotoIndexProgressReporter: ObservableObject {
    @Published var progress: PhotoIndexProgress?
}

/// PhotoKit invokes change transactions and their completion handlers on
/// implementation-defined queues. Keep this bridge outside the @MainActor
/// store so Swift does not implicitly claim either callback as main-actor
/// isolated. Only the user-facing completion is hopped back to the actor.
private func performPhotoLibraryChange(
    _ changes: @escaping () -> Void,
    completion: @escaping @MainActor (Result<Void, Error>) -> Void
) {
    PHPhotoLibrary.shared().performChanges(changes) { success, error in
        let result: Result<Void, Error>
        if let error {
            result = .failure(error)
        } else if success {
            result = .success(())
        } else {
            result = .failure(PhotoVaultError.changeFailed)
        }

        Task { @MainActor in
            completion(result)
        }
    }
}

private func requestPhotoLibraryAuthorization(
    completion: @escaping @MainActor (PHAuthorizationStatus) -> Void
) {
    PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
        Task { @MainActor in
            completion(status)
        }
    }
}

private final class PhotoShareAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Any?]
    private var temporaryURLs: [URL] = []

    init(count: Int) {
        items = Array(repeating: nil, count: count)
    }

    func store(_ item: Any, at index: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard items.indices.contains(index) else { return }
        items[index] = item
        if let url = item as? URL {
            temporaryURLs.append(url)
        }
    }

    func result() -> ([Any], [URL]) {
        lock.lock()
        defer { lock.unlock() }
        return (items.compactMap { $0 }, temporaryURLs)
    }
}

private struct PhotoAlbumFetchResult {
    let albums: [PhotoAlbum]
    let folders: [PhotoAlbumFolder]
}

/// Albums the user pinned for one-tap access from the grid's context menu.
/// The persisted list holds album local identifiers in pin order; a legacy
/// single-album key from the first iteration is migrated on first read.
enum PhotoQuickAlbums {
    static let storageKey = "PhotoVault.quickAlbumIDs"
    static let legacyStorageKey = "PhotoVault.quickCollectionAlbumID"
}

/// Photos queued by the app stay in this queue until the user explicitly
/// empties it. Keep the old organizer key as a migration source so photos
/// queued before the shared recycle bin was introduced are preserved.
enum PhotoRecycleBinStore {
    static let storageKey = "PhotoVault.recycleBinAssetIDs.v1"
    static let legacyOrganizerStorageKey = "PhotoVault.organizer.pendingTrashAssetIDs.v1"
}

/// Declining the system delete prompt surfaces as this PhotoKit error code.
/// It is a deliberate no-op, not a failure.
private func isUserCancelledPhotoChange(_ error: Error) -> Bool {
    let nsError = error as NSError
    return nsError.domain == PHPhotosErrorDomain
        && nsError.code == PHPhotosError.userCancelled.rawValue
}

/// Carries the launch window's continuation into the `@Sendable` fetch
/// closure. The continuation is invoked exactly once, on the main queue, so
/// the unchecked conformance only has to cover that single hand-off.
private struct LaunchWindowCompletion: @unchecked Sendable {
    let run: () -> Void
}

@MainActor
final class PhotoLibraryStore: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    /// Seeded from the last known value so the first render never has to wait
    /// for PhotoKit. `PHPhotoLibrary.authorizationStatus(for:)` is a
    /// synchronous XPC call, and this property is read during the first body
    /// evaluation of the root view — on a cold `photolibraryd` that call was
    /// sitting directly in front of the app's first frame.
    @Published private(set) var authorizationStatus: PHAuthorizationStatus
    @Published private(set) var allPhotos: PHFetchResult<PHAsset>?
    @Published private(set) var albums: [PhotoAlbum] = [] {
        didSet { albumStructureRevision &+= 1 }
    }
    @Published private(set) var albumFolders: [PhotoAlbumFolder] = [] {
        didSet {
            // `topLevelAlbums` is read several times per ContentView body
            // evaluation. Recomputing the flattened-ID set each time meant a
            // fresh array + Set allocation per read; the folder tree only
            // changes when this is assigned.
            nestedAlbumIDs = Set(albumFolders.flatMap { $0.allAlbums }.map(\.id))
            albumStructureRevision &+= 1
        }
    }
    /// Cheap change token for derived value-model projections (flattened
    /// folder rows, filtered album lists). Bumped whenever `albums` or
    /// `albumFolders` is reassigned, so views can memoize against it instead
    /// of re-deriving on every body evaluation.
    @Published private(set) var albumStructureRevision = 0
    @Published private(set) var isIndexingUnsorted = false
    @Published private(set) var isLoadingAlbums = false
    @Published private(set) var lastIndexedAt: Date?
    @Published private(set) var unsortedCount = 0
    /// Index progress ticks up to four times per second while a 100k-item scan
    /// runs. It lives on its own observable object so those ticks invalidate
    /// only the views that actually display progress, instead of every view
    /// observing the library store (sidebar, grids, settings).
    let indexProgressReporter = PhotoIndexProgressReporter()
    var indexProgress: PhotoIndexProgress? { indexProgressReporter.progress }
    @Published private(set) var indexStats: PhotoIndexStats?
    @Published private(set) var indexErrorMessage: String?
    /// Album identifiers pinned by the user for the grid's quick-add menu.
    @Published private(set) var quickAlbumIDs: [String] = []
    /// Asset identifiers queued for deferred deletion. The assets remain in
    /// PhotoKit until the user explicitly empties the recycle bin. The
    /// parallel Set keeps `isInRecycleBin` O(1) for the viewer's per-render
    /// membership checks.
    @Published private(set) var recycleBinIDs: [String] = [] {
        didSet {
            recycleBinIDSet = Set(recycleBinIDs)
        }
    }

    private var hasStarted = false
    private var indexGeneration = 0
    private var needsUnsortedIndex = true
    private var unsortedScreenRequested = false
    private var lastProgressPublishAt = Date.distantPast
    /// Live per-album fetch results. `assets(in:)` runs on every ContentView
    /// body evaluation; recreating the fetch result each time is wasted
    /// main-thread work, and PHFetchResult stays accurate on its own.
    private var albumFetchResults: [String: PHFetchResult<PHAsset>] = [:]
    private let indexStore = PhotoIndexStore()
    private let changeTokenDefaultsKey = "PhotoVault.photoLibrary.changeToken.v1"
    private let albumCacheDefaultsKey = "PhotoVault.photoLibrary.albumSnapshot.v1"
    nonisolated private static let shareTemporaryFilePrefix = "PhotoVault-Share-"
    /// How many of the newest assets the launch window resolves. Enough to
    /// fill several screens at any grid density, cheap enough to fetch with a
    /// `fetchLimit` instead of resolving identifiers one at a time.
    nonisolated private static let launchWindowAssetLimit = 384
    private var hasLoadedAlbumCache = false
    private var hasPublishedFreshAlbums = false
    /// Cached projection of `albumFolders`; see the `albumFolders` observer.
    private var nestedAlbumIDs: Set<String> = []
    /// O(1) membership for `isInRecycleBin`, which the viewer evaluates a few
    /// times per body evaluation against a persisted, unbounded ID list.
    private var recycleBinIDSet: Set<String> = []
    /// A full-library fetch is already running; further change notifications
    /// only mark it dirty instead of cancelling and restarting it.
    private var isFullRefreshInFlight = false
    private var pendingRefreshAfterFetch = false
    /// Burst-coalescing for library change notifications.
    private var pendingChanges: [PHChange] = []
    private var albumRescanWorkItem: DispatchWorkItem?
    nonisolated private static let changeCoalesceInterval: TimeInterval = 0.4
    /// Distinguishes the complete PhotoKit result from the bounded launch
    /// window. Index synchronization must never treat those 512 cached rows
    /// as the whole library if startup is interrupted by backgrounding.
    private var hasFreshLibraryFetch = false

    override init() {
        photoVaultTraceLaunch("store init begin")
        // Seed from the persisted value so the first render never waits on
        // PhotoKit: `PHPhotoLibrary.authorizationStatus(for:)` is a
        // synchronous XPC call and `canReadPhotos` gates the whole root view.
        // `start()` re-reads the real status and corrects this if it changed.
        let cachedStatus = PhotoLibraryStore.cachedAuthorizationStatus()
        authorizationStatus = cachedStatus ?? .notDetermined
        super.init()
        loadQuickAlbumIDs()
        loadRecycleBinIDs()
        photoVaultTraceLaunch(
            "store init done seeded=\(cachedStatus != nil) "
                + "status=\(authorizationStatus.rawValue)"
        )
    }

    private static let authorizationDefaultsKey =
        "PhotoVault.photoLibrary.authorizationStatus.v1"

    private static func cachedAuthorizationStatus() -> PHAuthorizationStatus? {
        guard UserDefaults.standard.object(forKey: authorizationDefaultsKey) != nil else {
            return nil
        }
        return PHAuthorizationStatus(
            rawValue: UserDefaults.standard.integer(forKey: authorizationDefaultsKey)
        )
    }

    private func persistAuthorizationStatus(_ status: PHAuthorizationStatus) {
        UserDefaults.standard.set(status.rawValue, forKey: Self.authorizationDefaultsKey)
    }

    var canReadPhotos: Bool {
        authorizationStatus == .authorized || authorizationStatus == .limited
    }

    /// Smart albums and user albums that are not inside a folder. Shared
    /// albums are deliberately kept out of this projection so the sidebar
    /// can give them their own Photos-style section.
    var topLevelAlbums: [PhotoAlbum] {
        albums.filter {
            $0.kind != .shared && !nestedAlbumIDs.contains($0.id)
        }
    }

    /// Shared albums are shown in one dedicated section, including albums
    /// that PhotoKit reports as children of a folder.
    var topLevelSharedAlbums: [PhotoAlbum] {
        albums.filter { $0.kind == .shared }
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        photoVaultTraceLaunch("store start begin")
        DispatchQueue.global(qos: .utility).async {
            Self.removeAbandonedShareFiles(olderThan: nil)
        }

        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        persistAuthorizationStatus(authorizationStatus)
        photoVaultTraceLaunch(
            "store start authorization resolved reading=\(canReadPhotos) "
                + "status=\(authorizationStatus.rawValue)"
        )

        guard canReadPhotos else {
            if authorizationStatus == .notDetermined {
                requestAccess()
            }
            return
        }

        // Only the bounded launch window is issued here. `refresh()` starts
        // the full library fetch, album metadata scan and change-observer
        // registration once that window has been resolved, so the first grid
        // never queues behind work it does not need in order to draw.
        refresh()
        photoVaultTraceLaunch("store start refresh issued")
    }

    func suspendForBackground() {
        albumFetchResults.removeAll(keepingCapacity: true)

        if isIndexingUnsorted || isLoadingAlbums {
            needsUnsortedIndex = true
            indexGeneration &+= 1
            indexStore.setActiveGeneration(indexGeneration)
            isIndexingUnsorted = false
            isLoadingAlbums = false
            indexProgressReporter.progress = nil
        }

        indexStore.checkpointForBackground()
        DispatchQueue.global(qos: .utility).async {
            Self.removeAbandonedShareFiles(
                olderThan: Date().addingTimeInterval(-60 * 60)
            )
        }
    }

    func resumeAfterBackground() {
        guard canReadPhotos,
              needsUnsortedIndex,
              !isIndexingUnsorted,
              !isLoadingAlbums
        else { return }
        if hasFreshLibraryFetch {
            retryUnsortedIndex()
        } else {
            refresh()
        }
    }

    func requestAccess() {
        requestPhotoLibraryAuthorization { [weak self] status in
                guard let self else { return }
                self.authorizationStatus = status
                self.persistAuthorizationStatus(status)
                if self.canReadPhotos {
                    self.refresh()
                }
        }
    }

    func refresh() {
        guard canReadPhotos else { return }

        // Keep the previous asset fetch results on screen while refreshing.
        // The grids continue showing the cached content while the fresh
        // PhotoKit scan runs in the background; a small toolbar spinner
        // reports progress instead of a blocking full-screen loader.
        needsUnsortedIndex = true
        indexGeneration &+= 1
        let generation = indexGeneration
        indexStore.setActiveGeneration(generation)

        photoVaultTraceLaunch(
            "store refresh generation=\(generation) cachedAlbums=\(albums.count)"
        )

        isLoadingAlbums = true
        isFullRefreshInFlight = true

        // Time-to-first-pixels is the bounded launch window and nothing else.
        // Nothing else may touch PhotoKit until it resolves: on a cold
        // `photolibraryd` the requests queue behind each other, so starting
        // the full sorted library fetch alongside the window delayed the
        // first painted grid to ~2.9s when the window alone was far cheaper.
        openLaunchWindow(generation: generation) { [weak self] in
            guard let self else { return }
            self.beginBulkRefresh(generation: generation)
        }
    }

    private var hasRegisteredChangeObserver = false

    /// Everything that is not needed for the first painted grid: the full
    /// sorted library fetch, album metadata, and the change observer. Starts
    /// only once the launch window has been resolved or skipped.
    private func beginBulkRefresh(generation: Int) {
        guard indexGeneration == generation else { return }
        loadCachedAlbumsIfNeeded()
        if !hasRegisteredChangeObserver {
            hasRegisteredChangeObserver = true
            PHPhotoLibrary.shared().register(self)
            photoVaultTraceLaunch("store change observer registered")
        }

        photoVaultTraceLaunch("store bulk refresh begin generation=\(generation)")
        DispatchQueue.global(qos: .userInitiated).async {
            photoVaultTraceLaunch("store full fetch begin")
            let fetchedPhotos = PHAsset.fetchAssets(with: Self.makeLibraryFetchOptions())
            // Force the sorted list to materialize exactly once, here, so the
            // grid can be handed the real result before album metadata is
            // enumerated. Publishing these together used to delay the full
            // grid by however long 163 album lookups took (2.6s measured).
            let fetchedCount = fetchedPhotos.count
            photoVaultTraceLaunch("store full fetch done count=\(fetchedCount)")

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.indexGeneration == generation else { return }
                self.hasFreshLibraryFetch = true
                self.albumFetchResults.removeAll(keepingCapacity: true)
                self.allPhotos = fetchedPhotos
                photoVaultTraceLaunch(
                    "store photos published generation=\(generation) count=\(fetchedCount)"
                )
            }

            // Encoding the snapshot is proportional to the album/folder count;
            // do it here rather than on the main actor.
            let fetchedAlbums = Self.fetchAlbums()
            photoVaultTraceLaunch(
                "store albums fetched albums=\(fetchedAlbums.albums.count) "
                    + "folders=\(fetchedAlbums.folders.count)"
            )
            let snapshotData = Self.encodeAlbumCache(
                albums: fetchedAlbums.albums,
                folders: fetchedAlbums.folders
            )

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isFullRefreshInFlight = false
                // A change arrived while this fetch was running. Run one more
                // pass instead of having cancelled this one.
                let shouldRefreshAgain = self.pendingRefreshAfterFetch
                self.pendingRefreshAfterFetch = false

                guard self.indexGeneration == generation else {
                    if shouldRefreshAgain, !self.isFullRefreshInFlight {
                        self.refresh()
                    }
                    return
                }
                photoVaultTrace(
                    "store photos fetched generation=\(generation) count=\(fetchedCount)"
                )
                if let snapshotData {
                    UserDefaults.standard.set(
                        snapshotData,
                        forKey: self.albumCacheDefaultsKey
                    )
                }
                self.hasPublishedFreshAlbums = true
                self.albums = fetchedAlbums.albums
                self.albumFolders = fetchedAlbums.folders
                self.allPhotos = fetchedPhotos
                self.isLoadingAlbums = false
                self.synchronizeIndex(
                    allPhotos: fetchedPhotos,
                    userAlbums: fetchedAlbums.albums
                        .filter { $0.kind == .user }
                        .map(\.collection),
                    generation: generation
                )
                if shouldRefreshAgain {
                    self.refresh()
                }
            }
        }
    }

    func ensureUnsortedIndex() {
        guard canReadPhotos else {
            photoVaultTrace("store ensure-unsorted skipped reason=no-permission")
            return
        }
        if isLoadingAlbums {
            photoVaultTrace(
                "store ensure-unsorted deferred reason=albums-loading generation=\(indexGeneration)"
            )
            return
        }
        photoVaultTrace(
            "store ensure-unsorted requested generation=\(indexGeneration) "
                + "indexing=\(isIndexingUnsorted) count=\(unsortedCount)"
        )
        unsortedScreenRequested = true

        if !isIndexingUnsorted {
            loadUnsortedPhotosIfRequested(generation: indexGeneration)
        }
    }

    func retryUnsortedIndex() {
        guard canReadPhotos else { return }
        guard hasFreshLibraryFetch, let allPhotos else {
            refresh()
            return
        }

        indexGeneration &+= 1
        let generation = indexGeneration
        indexStore.setActiveGeneration(generation)
        let userAlbums = albums
            .filter { $0.kind == .user }
            .map(\.collection)
        synchronizeIndex(
            allPhotos: allPhotos,
            userAlbums: userAlbums,
            generation: generation
        )
    }

    /// Loads only one metadata page for the Unsorted screen. No image, video,
    /// or original resource is requested while resolving this page.
    func fetchUnsortedAssets(
        offset: Int,
        limit: Int,
        completion: @escaping @MainActor (Result<[PHAsset], Error>) -> Void
    ) {
        loadUnsortedAssets(
            matching: nil,
            offset: offset,
            limit: limit,
            completion: completion
        )
    }

    /// The same page, restricted to what a slideshow filter keeps. The
    /// filtering happens in SQLite against the index columns, so a filtered
    /// slideshow never has to enumerate the library to find its photos.
    func fetchUnsortedAssets(
        matching filter: SlideshowFilter,
        offset: Int,
        limit: Int,
        completion: @escaping @MainActor (Result<[PHAsset], Error>) -> Void
    ) {
        loadUnsortedAssets(
            matching: filter,
            offset: offset,
            limit: limit,
            completion: completion
        )
    }

    /// How many unsorted photos a slideshow filter keeps.
    func unsortedSlideshowCount(matching filter: SlideshowFilter) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            indexStore.unsortedCount(matching: filter) { result in
                continuation.resume(with: result)
            }
        }
    }

    /// The position `assetID` occupies in the filtered unsorted order, so
    /// "play from this photo" starts on the photo the user was looking at.
    func unsortedSlideshowRank(
        of assetID: String,
        matching filter: SlideshowFilter
    ) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            indexStore.unsortedRank(of: assetID, matching: filter) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func loadUnsortedAssets(
        matching filter: SlideshowFilter?,
        offset: Int,
        limit: Int,
        completion: @escaping @MainActor (Result<[PHAsset], Error>) -> Void
    ) {
        guard canReadPhotos else {
            photoVaultTrace(
                "store unsorted-fetch failed reason=no-permission offset=\(offset) limit=\(limit)"
            )
            completion(.failure(PhotoIndexError.databaseUnavailable))
            return
        }

        let generation = indexGeneration
        photoVaultTrace(
            "store unsorted-fetch start offset=\(offset) limit=\(limit) "
                + "filter=\(filter?.summary ?? "all") generation=\(generation)"
        )
        let handleIdentifiers: (Result<[String], Error>) -> Void = { [weak self] result in
            guard let self else {
                photoVaultTrace(
                    "store unsorted-fetch drop offset=\(offset) reason=store-gone "
                        + "generation=\(generation)"
                )
                return
            }
            guard self.indexGeneration == generation else {
                photoVaultTrace(
                    "store unsorted-fetch drop offset=\(offset) reason=stale-generation "
                        + "requested=\(generation) current=\(self.indexGeneration)"
                )
                return
            }
            switch result {
            case .failure(let error):
                photoVaultTrace(
                    "store unsorted-fetch identifiers-failed offset=\(offset) "
                        + "error=\(error.localizedDescription)"
                )
                completion(.failure(error))
            case .success(let identifiers):
                photoVaultTrace(
                    "store unsorted-fetch identifiers-ready offset=\(offset) "
                        + "count=\(identifiers.count) generation=\(generation)"
                )
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let fetched = PHAsset.fetchAssets(
                        withLocalIdentifiers: identifiers,
                        options: Self.makeLibraryFetchOptions()
                    )
                    var assetsByIdentifier = [String: PHAsset](
                        minimumCapacity: fetched.count
                    )
                    fetched.enumerateObjects { asset, _, _ in
                        assetsByIdentifier[asset.localIdentifier] = asset
                    }
                    let orderedAssets = identifiers.compactMap {
                        assetsByIdentifier[$0]
                    }
                    DispatchQueue.main.async {
                        guard let self else {
                            photoVaultTrace(
                                "store unsorted-fetch drop offset=\(offset) "
                                    + "reason=store-gone-after-fetch generation=\(generation)"
                            )
                            return
                        }
                        guard self.indexGeneration == generation else {
                            photoVaultTrace(
                                "store unsorted-fetch drop offset=\(offset) "
                                    + "reason=stale-generation-after-fetch "
                                    + "requested=\(generation) current=\(self.indexGeneration)"
                            )
                            return
                        }
                        photoVaultTrace(
                            "store unsorted-fetch assets-ready offset=\(offset) "
                                + "count=\(orderedAssets.count) generation=\(generation)"
                        )
                        completion(.success(orderedAssets))
                    }
                }
            }
        }

        if let filter {
            indexStore.unsortedIdentifiers(
                matching: filter,
                limit: max(0, limit),
                offset: max(0, offset),
                completion: handleIdentifiers
            )
        } else {
            indexStore.unsortedIdentifiers(
                limit: max(0, limit),
                offset: max(0, offset),
                completion: handleIdentifiers
            )
        }
    }

    func album(withID id: String) -> PhotoAlbum? {
        albums.first { $0.id == id }
    }

    func assets(in album: PhotoAlbum) -> PHFetchResult<PHAsset> {
        if let cached = albumFetchResults[album.id] {
            return cached
        }
        let result = PHAsset.fetchAssets(
            in: album.collection,
            options: Self.makeLibraryFetchOptions()
        )
        // Dozens of albums never approach this ceiling; it only guards
        // against unbounded growth during long folder exploration.
        if albumFetchResults.count >= 64 {
            albumFetchResults.removeAll(keepingCapacity: true)
        }
        albumFetchResults[album.id] = result
        return result
    }

    /// User albums that currently contain the asset, in the order the flat
    /// album list keeps them. Used by the grid context menu's remove option;
    /// runs a single PhotoKit containment query per call.
    func userAlbums(containing asset: PHAsset) -> [PhotoAlbum] {
        let containingResult = PHAssetCollection.fetchAssetCollectionsContaining(
            asset,
            with: .album,
            options: nil
        )
        var containingIDs = Set<String>()
        containingResult.enumerateObjects { collection, _, _ in
            containingIDs.insert(collection.localIdentifier)
        }
        return albums.filter { $0.kind == .user && containingIDs.contains($0.id) }
    }

    /// Pinned quick albums resolved against the current album list, in pin
    /// order. Identifier-only entries whose album was deleted are skipped.
    func quickAlbums() -> [PhotoAlbum] {
        let userAlbumsByID = Dictionary(
            uniqueKeysWithValues: albums.filter { $0.kind == .user }.map { ($0.id, $0) }
        )
        return quickAlbumIDs.compactMap { userAlbumsByID[$0] }
    }

    func isQuickAlbum(_ id: String) -> Bool {
        quickAlbumIDs.contains(id)
    }

    func toggleQuickAlbum(_ id: String) {
        if let index = quickAlbumIDs.firstIndex(of: id) {
            quickAlbumIDs.remove(at: index)
        } else {
            quickAlbumIDs.append(id)
        }
        UserDefaults.standard.set(quickAlbumIDs, forKey: PhotoQuickAlbums.storageKey)
    }

    var recycleBinCount: Int {
        recycleBinIDs.count
    }

    func isInRecycleBin(_ asset: PHAsset) -> Bool {
        recycleBinIDSet.contains(asset.localIdentifier)
    }

    func addToRecycleBin(_ asset: PHAsset) {
        guard !isInRecycleBin(asset) else { return }
        recycleBinIDs.append(asset.localIdentifier)
        persistRecycleBinIDs()
    }

    func removeFromRecycleBin(_ asset: PHAsset) {
        removeFromRecycleBin(ids: [asset.localIdentifier])
    }

    /// Resolves only the queued identifiers. This intentionally does not
    /// materialize the whole library and also prunes assets deleted elsewhere.
    func recycleBinAssets() -> [PHAsset] {
        guard !recycleBinIDs.isEmpty else { return [] }

        let result = PHAsset.fetchAssets(
            withLocalIdentifiers: recycleBinIDs,
            options: nil
        )
        var assetsByID: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in
            assetsByID[asset.localIdentifier] = asset
        }

        let resolvedIDs = recycleBinIDs.filter { assetsByID[$0] != nil }
        if resolvedIDs != recycleBinIDs {
            recycleBinIDs = resolvedIDs
            persistRecycleBinIDs()
        }
        return resolvedIDs.compactMap { assetsByID[$0] }
    }

    func deleteRecycleBinContents(
        completion: @escaping @MainActor (Result<Void, Error>) -> Void = { _ in }
    ) {
        let candidates = recycleBinAssets()
        guard !candidates.isEmpty else {
            recycleBinIDs = []
            persistRecycleBinIDs()
            completion(.success(()))
            return
        }
        deleteAssets(candidates, completion: completion)
    }

    private func removeFromRecycleBin(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let remaining = recycleBinIDs.filter { !ids.contains($0) }
        guard remaining.count != recycleBinIDs.count else { return }
        recycleBinIDs = remaining
        persistRecycleBinIDs()
    }

    private func removeFromRecycleBin(ids: [String]) {
        removeFromRecycleBin(ids: Set(ids))
    }

    private func persistRecycleBinIDs() {
        UserDefaults.standard.set(recycleBinIDs, forKey: PhotoRecycleBinStore.storageKey)
    }

    private func loadRecycleBinIDs() {
        let defaults = UserDefaults.standard
        let hasSharedQueue = defaults.object(forKey: PhotoRecycleBinStore.storageKey) != nil
        let storedIDs = defaults.stringArray(
            forKey: hasSharedQueue
                ? PhotoRecycleBinStore.storageKey
                : PhotoRecycleBinStore.legacyOrganizerStorageKey
        ) ?? []
        var seen = Set<String>()
        recycleBinIDs = storedIDs.filter { seen.insert($0).inserted }
        if !hasSharedQueue {
            persistRecycleBinIDs()
            defaults.removeObject(forKey: PhotoRecycleBinStore.legacyOrganizerStorageKey)
        }
    }

    private func loadQuickAlbumIDs() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: PhotoQuickAlbums.storageKey) != nil {
            quickAlbumIDs = defaults.stringArray(forKey: PhotoQuickAlbums.storageKey) ?? []
            return
        }
        // First launch after the single quick album shipped: carry it over
        // so an album pinned in the earlier build stays pinned.
        if let legacyID = defaults.string(forKey: PhotoQuickAlbums.legacyStorageKey) {
            quickAlbumIDs = [legacyID]
            defaults.set(quickAlbumIDs, forKey: PhotoQuickAlbums.storageKey)
            defaults.removeObject(forKey: PhotoQuickAlbums.legacyStorageKey)
        }
    }
    func addAssets(
        _ assets: [PHAsset],
        to album: PhotoAlbum,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void = { _ in }
    ) {
        guard !assets.isEmpty else {
            completion(.success(()))
            return
        }

        performPhotoLibraryChange({
            guard let request = PHAssetCollectionChangeRequest(for: album.collection) else { return }
            request.addAssets(assets as NSArray)
        }) { [weak self] result in
            if case .success = result {
                self?.optimisticallyAddMembership(assets, to: album)
            }
            completion(result)
        }
    }

    func removeAssets(
        _ assets: [PHAsset],
        from album: PhotoAlbum,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void = { _ in }
    ) {
        guard !assets.isEmpty else {
            completion(.success(()))
            return
        }

        performPhotoLibraryChange({
            guard let request = PHAssetCollectionChangeRequest(for: album.collection) else { return }
            request.removeAssets(assets as NSArray)
        }, completion: completion)
    }

    func createAlbum(
        named title: String,
        containing assets: [PHAsset],
        completion: @escaping @MainActor (Result<Void, Error>) -> Void = { _ in }
    ) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            completion(.failure(PhotoVaultError.changeFailed))
            return
        }

        performPhotoLibraryChange({
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(
                withTitle: trimmedTitle
            )
            if !assets.isEmpty {
                request.addAssets(assets as NSArray)
            }
        }) { result in
            completion(result)
        }
    }

    func deleteAssets(
        _ assets: [PHAsset],
        completion: @escaping @MainActor (Result<Void, Error>) -> Void = { _ in }
    ) {
        guard !assets.isEmpty else {
            completion(.success(()))
            return
        }

        performPhotoLibraryChange({
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }) { [weak self] result in
            switch result {
            case .success:
                self?.removeFromRecycleBin(ids: assets.map(\.localIdentifier))
                self?.optimisticallyRemoveAssets(assets)
                completion(result)
            case .failure(let error):
                // Declining the system delete prompt is a deliberate no-op:
                // no error is surfaced and the index stays exactly as it was.
                if isUserCancelledPhotoChange(error) {
                    completion(.success(()))
                } else {
                    completion(.failure(error))
                }
            }
        }
    }

    func toggleFavorite(
        _ asset: PHAsset,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void = { _ in }
    ) {
        performPhotoLibraryChange({
            let request = PHAssetChangeRequest(for: asset)
            request.isFavorite = !asset.isFavorite
        }) { result in
            completion(result)
        }
    }

    /// Builds system-shareable items without decoding a video into memory.
    /// Still images use the existing thumbnail-to-share path; videos are
    /// streamed by PHAssetResourceManager into temporary files only when the
    /// user explicitly invokes Share.
    func requestShareItems(
        for assets: [PHAsset],
        completion: @escaping @MainActor ([Any], [URL]) -> Void
    ) {
        guard !assets.isEmpty else {
            completion([], [])
            return
        }

        let group = DispatchGroup()
        let accumulator = PhotoShareAccumulator(count: assets.count)

        for (index, asset) in assets.enumerated() {
            if asset.mediaType == .video,
               let resource = PHAssetResource.assetResources(for: asset).first(where: {
                   $0.type == .video || $0.type == .fullSizeVideo
               }) {
                group.enter()
                let originalURL = URL(fileURLWithPath: resource.originalFilename)
                let extensionName = originalURL.pathExtension.isEmpty
                    ? "mov"
                    : originalURL.pathExtension
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "\(Self.shareTemporaryFilePrefix)\(UUID().uuidString)"
                    )
                    .appendingPathExtension(extensionName)
                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = true
                PHAssetResourceManager.default().writeData(
                    for: resource,
                    toFile: destination,
                    options: options
                ) { error in
                    if error == nil {
                        accumulator.store(destination, at: index)
                    } else {
                        try? FileManager.default.removeItem(at: destination)
                    }
                    group.leave()
                }
                continue
            }

            group.enter()
            let callbackLock = NSLock()
            var finished = false

            func finish(_ image: UIImage?) {
                callbackLock.lock()
                guard !finished else {
                    callbackLock.unlock()
                    return
                }
                finished = true
                callbackLock.unlock()

                if let image {
                    accumulator.store(image, at: index)
                }
                group.leave()
            }

            PhotoImageManager.shared.requestImage(
                for: asset,
                targetSize: CGSize(width: 2048, height: 2048),
                contentMode: .aspectFit,
                deliveryMode: .highQualityFormat,
                resizeMode: .exact,
                priority: .viewer
            ) { image, info in
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let hasError = info?[PHImageErrorKey] != nil
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if cancelled || hasError || !degraded {
                    finish(image)
                }
            }
        }

        group.notify(queue: .main) {
            let (finalItems, finalURLs) = accumulator.result()
            completion(finalItems, finalURLs)
        }
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            self?.enqueuePhotoLibraryChange(changeInstance)
        }
    }

    /// Coalesces change notifications. `photoLibraryDidChange` can fire in a
    /// burst — iCloud sync, a multi-select import, a screenshot landing while
    /// the index scans — and every notification used to trigger a full album
    /// metadata pass plus an index sync. Applying the cheap asset delta is
    /// immediate; the expensive metadata pass waits out the burst.
    private func enqueuePhotoLibraryChange(_ change: PHChange) {
        pendingChanges.append(change)
        albumRescanWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.drainPendingChanges()
        }
        albumRescanWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.changeCoalesceInterval,
            execute: work
        )
    }

    private func drainPendingChanges() {
        let changes = pendingChanges
        pendingChanges.removeAll(keepingCapacity: true)
        guard let last = changes.last else { return }
        // The asset delta has to be applied against the fetch result as it was
        // before the change, so only the newest instance is read; the album
        // metadata pass below re-reads the truth from PhotoKit anyway.
        applyPhotoLibraryChange(last)
    }

    /// Apply the fetch-result delta that PhotoKit already computed instead of
    /// fetching the complete 100k+ library again. Album metadata is refreshed
    /// by a coalesced pass, because this store keeps the album list as value
    /// models while the asset result itself remains incremental.
    private func applyPhotoLibraryChange(_ change: PHChange) {
        guard hasFreshLibraryFetch, let currentPhotos = allPhotos else {
            // A missing/non-incremental change detail means PhotoKit cannot
            // safely describe the delta. This is the exceptional full-refresh
            // path, not the normal change-observer path.
            scheduleFullRefresh()
            return
        }

        let details = change.changeDetails(for: currentPhotos)
        if let details,
           !details.hasIncrementalChanges {
            scheduleFullRefresh()
            return
        }

        // A nil detail means the change only affected collections (for
        // example, adding an asset to an album), so the existing asset fetch
        // result is still valid and can be reused without a full asset fetch.
        let updatedPhotos = details?.fetchResultAfterChanges ?? currentPhotos
        allPhotos = updatedPhotos
        needsUnsortedIndex = true
        indexGeneration &+= 1
        indexStore.setActiveGeneration(indexGeneration)

        isLoadingAlbums = true
        scheduleAlbumRescan()
    }

    /// A full library fetch is already running. Restarting it on every
    /// notification during the post-launch iCloud sync window repeatedly
    /// cancelled the single most expensive startup task, so later requests
    /// only raise a dirty flag that the running fetch drains.
    private func scheduleFullRefresh() {
        guard !isFullRefreshInFlight else {
            pendingRefreshAfterFetch = true
            return
        }
        refresh()
    }

    private func scheduleAlbumRescan() {
        albumRescanWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performAlbumRescan()
        }
        albumRescanWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.changeCoalesceInterval,
            execute: work
        )
    }

    /// The single album metadata + index sync pass. Runs once per burst of
    /// library changes instead of once per notification.
    private func performAlbumRescan() {
        guard let photos = allPhotos else { return }
        let generation = indexGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fetchedAlbums = Self.fetchAlbums()
            // Encoding the snapshot is proportional to the album/folder count
            // and used to run on the main actor on this hot path. It is pure
            // value work, so it belongs here.
            let snapshotData = Self.encodeAlbumCache(
                albums: fetchedAlbums.albums,
                folders: fetchedAlbums.folders
            )

            DispatchQueue.main.async {
                guard let self else { return }
                if let snapshotData {
                    UserDefaults.standard.set(
                        snapshotData,
                        forKey: self.albumCacheDefaultsKey
                    )
                }
                guard self.indexGeneration == generation else { return }
                self.hasPublishedFreshAlbums = true
                self.albumFetchResults.removeAll(keepingCapacity: true)
                self.albums = fetchedAlbums.albums
                self.albumFolders = fetchedAlbums.folders
                self.isLoadingAlbums = false
                self.synchronizeIndex(
                    allPhotos: photos,
                    userAlbums: fetchedAlbums.albums
                        .filter { $0.kind == .user }
                        .map(\.collection),
                    generation: generation
                )
            }
        }
    }

    /// Restore only album metadata and collection references. Even this
    /// bounded PhotoKit lookup can take noticeable time with many iCloud
    /// albums, so keep it off the main actor and never let it delay the
    /// cached library window or the fresh full-library fetch.
    private func loadCachedAlbumsIfNeeded() {
        guard !hasLoadedAlbumCache else { return }
        hasLoadedAlbumCache = true
        guard let data = UserDefaults.standard.data(forKey: albumCacheDefaultsKey) else {
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            photoVaultTraceLaunch("store album-cache restore begin")
            guard let cached = Self.restoreAlbumCache(from: data) else { return }
            photoVaultTraceLaunch(
                "store album-cache restore done albums=\(cached.albums.count) "
                    + "folders=\(cached.folders.count)"
            )
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.hasPublishedFreshAlbums else { return }
                self.albums = cached.albums
                self.albumFolders = cached.folders
                photoVaultTraceLaunch(
                    "store album cache restored albums=\(cached.albums.count) "
                        + "folders=\(cached.folders.count)"
                )
            }
        }
    }

    /// Opens the bounded launch window: the newest few hundred assets, which
    /// is all the first screenfuls of the grid need.
    ///
    /// This runs the *same* query as the full refresh with `fetchLimit` set,
    /// so it is one indexed range scan. The previous implementation resolved
    /// a persisted list of 512 local identifiers one by one instead, which
    /// measured 2.9-3.5s on a cold `photolibraryd` — and, while the library
    /// was still opening, could come back empty, leaving the grid on its
    /// spinner until the full fetch landed. PhotoKit serves a limited sorted
    /// query from the ordering index it already maintains.
    private func openLaunchWindow(
        generation: Int,
        then completion: @escaping () -> Void
    ) {
        // A previous refresh already has a result on screen. There is no
        // launch window to resolve, so the bulk pass may start immediately.
        guard allPhotos == nil else {
            completion()
            return
        }

        let completionBox = LaunchWindowCompletion(run: completion)
        DispatchQueue.global(qos: .userInitiated).async {
            let options = Self.makeLibraryFetchOptions()
            options.fetchLimit = Self.launchWindowAssetLimit
            photoVaultTraceLaunch(
                "store launch-window fetch begin limit=\(Self.launchWindowAssetLimit)"
            )
            let preview = PHAsset.fetchAssets(with: options)
            // `count` forces the limited range scan to materialize here rather
            // than on whichever thread first reads the result.
            let count = preview.count
            photoVaultTraceLaunch("store launch-window fetch done count=\(count)")

            DispatchQueue.main.async { [weak self] in
                if let self,
                   self.indexGeneration == generation,
                   self.allPhotos == nil,
                   count > 0 {
                    self.allPhotos = preview
                    photoVaultTraceLaunch(
                        "store launch window published generation=\(generation) "
                            + "count=\(count)"
                    )
                }
                // The bulk pass starts even when the launch window was
                // discarded; this result only ever gates the first paint.
                completionBox.run()
            }
        }

        // The cached count is presentation data too. Restoring it early keeps
        // the sidebar stable while the persistent-change delta is applied.
        indexStore.stats { [weak self] result in
            guard let self,
                  self.indexGeneration == generation,
                  self.indexStats == nil,
                  case .success(let stats) = result
            else { return }
            self.indexStats = stats
            self.unsortedCount = stats.unsortedCount
        }
    }

    nonisolated private static func restoreAlbumCache(
        from data: Data
    ) -> PhotoAlbumFetchResult? {
        guard let snapshot = try? JSONDecoder().decode(
            PhotoAlbumCacheSnapshot.self,
            from: data
        ), snapshot.version == PhotoAlbumCacheSnapshot.currentVersion else {
            return nil
        }

        let albumFetchResult = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: snapshot.albums.map(\.id),
            options: nil
        )
        var collectionsByID = [String: PHAssetCollection]()
        albumFetchResult.enumerateObjects { collection, _, _ in
            collectionsByID[collection.localIdentifier] = collection
        }

        let previewIDs = Array(Set(snapshot.albums.compactMap(\.previewAssetID)))
        let previewFetchResult = PHAsset.fetchAssets(
            withLocalIdentifiers: previewIDs,
            options: nil
        )
        var previewsByID = [String: PHAsset]()
        previewFetchResult.enumerateObjects { asset, _, _ in
            previewsByID[asset.localIdentifier] = asset
        }

        let cachedAlbums = snapshot.albums.compactMap { entry -> PhotoAlbum? in
            guard let collection = collectionsByID[entry.id] else { return nil }
            return PhotoAlbum(
                collection: collection,
                kind: entry.kind,
                title: entry.title,
                assetCount: max(0, entry.assetCount),
                previewAsset: entry.previewAssetID.flatMap { previewsByID[$0] }
            )
        }
        guard !cachedAlbums.isEmpty || snapshot.albums.isEmpty else { return nil }

        let albumsByID = Dictionary(
            uniqueKeysWithValues: cachedAlbums.map { ($0.id, $0) }
        )
        func collectFolderIDs(_ entry: PhotoAlbumFolderCacheEntry) -> [String] {
            [entry.id] + entry.subfolders.flatMap(collectFolderIDs)
        }

        let folderIDs = snapshot.folders.flatMap(collectFolderIDs)
        let folderFetchResult = PHCollectionList.fetchCollectionLists(
            withLocalIdentifiers: folderIDs,
            options: nil
        )
        var foldersByID = [String: PHCollectionList]()
        folderFetchResult.enumerateObjects { folder, _, _ in
            foldersByID[folder.localIdentifier] = folder
        }

        func makeFolder(_ entry: PhotoAlbumFolderCacheEntry) -> PhotoAlbumFolder? {
            guard let collection = foldersByID[entry.id] else { return nil }
            return PhotoAlbumFolder(
                collection: collection,
                title: entry.title,
                albums: entry.albumIDs.compactMap { albumsByID[$0] },
                subfolders: entry.subfolders.compactMap(makeFolder)
            )
        }

        return PhotoAlbumFetchResult(
            albums: cachedAlbums,
            folders: snapshot.folders.compactMap(makeFolder)
        )
    }

    /// Encodes the persisted album snapshot. Pure value work, so it runs on
    /// the background pass instead of the main actor; the previous version
    /// JSON-encoded every album and folder on the change hot path.
    nonisolated private static func encodeAlbumCache(
        albums: [PhotoAlbum],
        folders: [PhotoAlbumFolder]
    ) -> Data? {
        func makeFolderEntry(
            _ folder: PhotoAlbumFolder
        ) -> PhotoAlbumFolderCacheEntry {
            PhotoAlbumFolderCacheEntry(
                id: folder.id,
                title: folder.title,
                albumIDs: folder.albums.map(\.id),
                subfolders: folder.subfolders.map(makeFolderEntry)
            )
        }

        let snapshot = PhotoAlbumCacheSnapshot(
            version: PhotoAlbumCacheSnapshot.currentVersion,
            albums: albums.map {
                PhotoAlbumCacheEntry(
                    id: $0.id,
                    kind: $0.kind,
                    title: $0.title,
                    assetCount: $0.assetCount,
                    previewAssetID: $0.previewAsset?.localIdentifier
                )
            },
            folders: folders.map(makeFolderEntry)
        )
        return try? JSONEncoder().encode(snapshot)
    }

    nonisolated private static func makeLibraryFetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )
        return options
    }

    nonisolated private static func fetchAlbums() -> PhotoAlbumFetchResult {
        var albumsByID = [String: PhotoAlbum]()

        func makeAlbum(
            from collection: PHAssetCollection,
            kind: PhotoAlbumKind
        ) -> PhotoAlbum? {
            let id = collection.localIdentifier
            if let existing = albumsByID[id] {
                return existing
            }

            // Counting a 100k collection forces PhotoKit to resolve its full
            // membership on every library change. The estimated count is
            // served from PhotoKit's own cache and the preview needs only a
            // single-row fetch, so a whole-library album pass stays cheap.
            let estimatedCount = collection.estimatedAssetCount
            let assetCount: Int
            if estimatedCount != NSNotFound {
                assetCount = Int(estimatedCount)
            } else {
                assetCount = PHAsset.fetchAssets(
                    in: collection,
                    options: makeLibraryFetchOptions()
                ).count
            }
            if kind == .smart && assetCount == 0 {
                return nil
            }

            let previewOptions = makeLibraryFetchOptions()
            previewOptions.fetchLimit = 1
            let previewAsset = PHAsset.fetchAssets(
                in: collection,
                options: previewOptions
            ).firstObject

            let album = PhotoAlbum(
                collection: collection,
                kind: kind,
                title: collection.localizedTitle ?? "未命名相册",
                assetCount: assetCount,
                previewAsset: previewAsset
            )
            albumsByID[id] = album
            return album
        }

        func albumKind(for collection: PHAssetCollection) -> PhotoAlbumKind {
            if collection.assetCollectionSubtype == .albumCloudShared {
                return .shared
            }
            return .user
        }

        let userAlbums = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .any,
            options: nil
        )
        userAlbums.enumerateObjects { collection, _, _ in
            _ = makeAlbum(from: collection, kind: albumKind(for: collection))
        }

        // Build the folder tree from PHCollectionList instead of flattening
        // every album. Some PhotoKit versions return nested folders in the
        // folder fetch result as well, so first identify folders that are
        // children of another folder and use only the true roots initially.
        let folderFetchResult = PHCollectionList.fetchCollectionLists(
            with: .folder,
            subtype: .any,
            options: nil
        )
        var foldersByID = [String: PHCollectionList]()
        folderFetchResult.enumerateObjects { folder, _, _ in
            foldersByID[folder.localIdentifier] = folder
        }

        var childFolderIDs = Set<String>()
        // Each folder's children used to be fetched twice: once here to
        // identify subfolders and again inside `makeFolder`. On a foldered
        // library that doubled the PhotoKit round trips of every rescan.
        var childrenByFolderID = [String: [PHCollection]]()
        for folder in foldersByID.values {
            let children = PHCollection.fetchCollections(in: folder, options: nil)
            var collected = [PHCollection]()
            children.enumerateObjects { collection, _, _ in
                collected.append(collection)
                if let childFolder = collection as? PHCollectionList {
                    childFolderIDs.insert(childFolder.localIdentifier)
                }
            }
            childrenByFolderID[folder.localIdentifier] = collected
        }

        var visitedFolderIDs = Set<String>()

        func makeFolder(from folder: PHCollectionList) -> PhotoAlbumFolder? {
            guard visitedFolderIDs.insert(folder.localIdentifier).inserted else {
                return nil
            }

            var albums = [PhotoAlbum]()
            var subfolders = [PhotoAlbumFolder]()
            let children = childrenByFolderID[folder.localIdentifier] ?? []
            for collection in children {
                if let albumCollection = collection as? PHAssetCollection,
                   albumCollection.assetCollectionType == .album,
                   let album = makeAlbum(
                       from: albumCollection,
                       kind: albumKind(for: albumCollection)
                   ) {
                    // Shared albums always live in the dedicated section,
                    // even when PhotoKit exposes one inside a folder.
                    if album.kind != .shared {
                        albums.append(album)
                    }
                } else if let childFolder = collection as? PHCollectionList,
                          let childModel = makeFolder(from: childFolder) {
                    subfolders.append(childModel)
                }
            }

            albums.sort {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            subfolders.sort {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }

            return PhotoAlbumFolder(
                collection: folder,
                title: folder.localizedTitle ?? "未命名文件夹",
                albums: albums,
                subfolders: subfolders
            )
        }

        let sortedFolderCollections = foldersByID.values.sorted {
            ($0.localizedTitle ?? "未命名文件夹")
                .localizedStandardCompare($1.localizedTitle ?? "未命名文件夹")
                == .orderedAscending
        }
        let rootFolders = sortedFolderCollections.filter {
            !childFolderIDs.contains($0.localIdentifier)
        }

        var folderModels = rootFolders.compactMap { makeFolder(from: $0) }
        // If a PhotoKit implementation omits a parent from the folder fetch,
        // keep any still-unvisited folder visible instead of losing it.
        for folder in sortedFolderCollections where !visitedFolderIDs.contains(folder.localIdentifier) {
            if let model = makeFolder(from: folder) {
                folderModels.append(model)
            }
        }

        let smartAlbums = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .any,
            options: nil
        )
        smartAlbums.enumerateObjects { collection, _, _ in
            _ = makeAlbum(from: collection, kind: .smart)
        }

        let albums = albumsByID.values.sorted { lhs, rhs in
            if lhs.kind != rhs.kind {
                func sortOrder(_ kind: PhotoAlbumKind) -> Int {
                    switch kind {
                    case .user:
                        return 0
                    case .smart:
                        return 1
                    case .shared:
                        return 2
                    }
                }
                return sortOrder(lhs.kind) < sortOrder(rhs.kind)
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }

        return PhotoAlbumFetchResult(albums: albums, folders: folderModels)
    }

    private func synchronizeIndex(
        allPhotos: PHFetchResult<PHAsset>,
        userAlbums: [PHAssetCollection],
        generation: Int
    ) {
        guard generation == indexGeneration else { return }
        indexStore.setActiveGeneration(generation)
        photoVaultTrace(
            "store index start generation=\(generation) assets=\(allPhotos.count) "
                + "userAlbums=\(userAlbums.count)"
        )
        let librarySignature = makeLibrarySignature(for: allPhotos)
        isIndexingUnsorted = true
        indexErrorMessage = nil
        needsUnsortedIndex = false
        lastProgressPublishAt = .distantPast
        indexProgressReporter.progress = PhotoIndexProgress(
            phase: .scanningAssets,
            completed: 0,
            total: allPhotos.count
        )

        indexStore.hasUsableIndex { [weak self] hasUsableIndex in
            guard let self, self.indexGeneration == generation else { return }

            if hasUsableIndex,
               let token = self.restorePersistentChangeToken() {
                self.applyPersistentChanges(
                    since: token,
                    allPhotos: allPhotos,
                    userAlbums: userAlbums,
                    librarySignature: librarySignature,
                    generation: generation
                )
            } else {
                self.rebuildIndex(
                    allPhotos: allPhotos,
                    userAlbums: userAlbums,
                    librarySignature: librarySignature,
                    generation: generation
                )
            }
        }
    }

    private func rebuildIndex(
        allPhotos: PHFetchResult<PHAsset>,
        userAlbums: [PHAssetCollection],
        librarySignature: String,
        generation: Int
    ) {
        indexStore.rebuild(
            assets: allPhotos,
            userAlbums: userAlbums,
            librarySignature: librarySignature,
            generation: generation,
            progress: { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.indexGeneration == generation else { return }
                    self.publishIndexProgress(progress)
                }
            },
            completion: { [weak self] result in
                guard let self, self.indexGeneration == generation else { return }
                switch result {
                case .success(let stats):
                    self.finishIndexing(
                        stats: stats,
                        generation: generation,
                        token: PHPhotoLibrary.shared().currentChangeToken,
                        librarySignature: librarySignature
                    )
                case .failure(let error):
                    self.failIndexing(error)
                }
            }
        )
    }

    /// A 100k-library scan ticks hundreds of times; publishing every tick
    /// repaints the entire app and makes list scrolling janky. Coalesce the
    /// ticks into at most ~4 publications per second; phase changes and the
    /// finished tick always pass through so progress UI stays truthful at
    /// its boundaries.
    private func publishIndexProgress(_ progress: PhotoIndexProgress) {
        let isPhaseChange = indexProgress?.phase != progress.phase
        let isFinished = progress.completed >= progress.total
        let now = Date()
        guard isPhaseChange || isFinished
                || now.timeIntervalSince(lastProgressPublishAt) >= 0.25
        else { return }
        lastProgressPublishAt = now
        indexProgressReporter.progress = progress
    }

    private func applyPersistentChanges(
        since token: PHPersistentChangeToken,
        allPhotos: PHFetchResult<PHAsset>,
        userAlbums: [PHAssetCollection],
        librarySignature: String,
        generation: Int
    ) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let library = PHPhotoLibrary.shared()
            let changes: PHPersistentChangeFetchResult
            do {
                changes = try library.fetchPersistentChanges(since: token)
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.indexGeneration == generation else { return }
                    self.rebuildIndex(
                        allPhotos: allPhotos,
                        userAlbums: userAlbums,
                        librarySignature: self.makeLibrarySignature(for: allPhotos),
                        generation: generation
                    )
                }
                return
            }

            var insertedIDs = Set<String>()
            var updatedIDs = Set<String>()
            var deletedIDs = Set<String>()
            var changedCollectionIDs = Set<String>()
            var deletedCollectionIDs = Set<String>()

            for change in changes {
                if let details = try? change.changeDetails(for: .asset) {
                    insertedIDs.formUnion(details.insertedLocalIdentifiers)
                    updatedIDs.formUnion(details.updatedLocalIdentifiers)
                    deletedIDs.formUnion(details.deletedLocalIdentifiers)
                }

                if let details = try? change.changeDetails(for: .assetCollection) {
                    changedCollectionIDs.formUnion(details.insertedLocalIdentifiers)
                    changedCollectionIDs.formUnion(details.updatedLocalIdentifiers)
                    deletedCollectionIDs.formUnion(details.deletedLocalIdentifiers)
                }
            }

            insertedIDs.subtract(deletedIDs)
            updatedIDs.subtract(deletedIDs)
            let changedIDs = Array(insertedIDs.union(updatedIDs))
            let changedFetchResult = PHAsset.fetchAssets(
                withLocalIdentifiers: changedIDs,
                options: Self.makeLibraryFetchOptions()
            )
            var changedAssets = [PHAsset]()
            changedAssets.reserveCapacity(changedFetchResult.count)
            changedFetchResult.enumerateObjects { asset, _, _ in
                changedAssets.append(asset)
            }
            let newToken = library.currentChangeToken

            DispatchQueue.main.async { [weak self] in
                guard let self, self.indexGeneration == generation else { return }
                self.removeFromRecycleBin(ids: deletedIDs)
                self.indexStore.upsertAssets(
                    changedAssets,
                    deletedIDs: deletedIDs,
                    librarySignature: librarySignature,
                    generation: generation
                ) { [weak self] result in
                    guard let self, self.indexGeneration == generation else { return }
                    switch result {
                    case .failure(let error):
                        self.failIndexing(error)
                    case .success:
                        let collectionIDsToRefresh = changedCollectionIDs
                            .subtracting(deletedCollectionIDs)
                        if !collectionIDsToRefresh.isEmpty || !deletedCollectionIDs.isEmpty {
                            let changedUserAlbums = userAlbums.filter {
                                collectionIDsToRefresh.contains($0.localIdentifier)
                            }
                            let currentUserAlbumIDs = Set(
                                changedUserAlbums.map(\.localIdentifier)
                            )
                            let removedOrNonUserAlbumIDs = deletedCollectionIDs.union(
                                collectionIDsToRefresh.subtracting(currentUserAlbumIDs)
                            )
                            self.indexStore.updateAlbumMemberships(
                                userAlbums: changedUserAlbums,
                                deletedAlbumIDs: removedOrNonUserAlbumIDs,
                                librarySignature: librarySignature,
                                generation: generation,
                                progress: { [weak self] progress in
                                    Task { @MainActor [weak self] in
                                        guard let self, self.indexGeneration == generation else { return }
                                        self.publishIndexProgress(progress)
                                    }
                                },
                                completion: { [weak self] membershipResult in
                                    guard let self, self.indexGeneration == generation else { return }
                                    switch membershipResult {
                                    case .success(let stats):
                                        self.finishIndexing(
                                            stats: stats,
                                            generation: generation,
                                            token: newToken,
                                            librarySignature: librarySignature
                                        )
                                    case .failure(let error):
                                        self.failIndexing(error)
                                    }
                                }
                            )
                        } else {
                            self.indexStore.stats { [weak self] statsResult in
                                guard let self, self.indexGeneration == generation else { return }
                                switch statsResult {
                                case .success(let stats):
                                    self.finishIndexing(
                                        stats: stats,
                                        generation: generation,
                                        token: newToken,
                                        librarySignature: librarySignature
                                    )
                                case .failure(let error):
                                    self.failIndexing(error)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func finishIndexing(
        stats: PhotoIndexStats,
        generation: Int,
        token: PHPersistentChangeToken,
        librarySignature: String
    ) {
        guard generation == indexGeneration else { return }
        photoVaultTrace(
            "store index finished generation=\(generation) "
                + "assets=\(stats.assetCount) unsorted=\(stats.unsortedCount)"
        )
        indexStats = stats
        unsortedCount = stats.unsortedCount
        isIndexingUnsorted = false
        lastIndexedAt = Date()
        indexProgressReporter.progress = PhotoIndexProgress(
            phase: .finished,
            completed: stats.assetCount,
            total: stats.assetCount
        )
        persistChangeToken(token)
        loadUnsortedPhotosIfRequested(generation: generation)
    }

    private func failIndexing(_ error: Error) {
        photoVaultTrace("store index failed error=\(error.localizedDescription)")
        isIndexingUnsorted = false
        indexProgressReporter.progress = nil
        indexErrorMessage = error.localizedDescription
    }

    private func loadUnsortedPhotosIfRequested(generation: Int) {
        guard unsortedScreenRequested,
              !isIndexingUnsorted,
              generation == indexGeneration
        else { return }

        photoVaultTrace(
            "store index ready for unsorted pages generation=\(generation) "
                + "count=\(unsortedCount)"
        )

        // Pages are requested by IndexedPhotoGridView as cells approach the
        // viewport. Keeping this hook empty is intentional: finishing the
        // index must never materialize the entire unsorted result.
    }

    /// The persisted PhotoKit change token. Its validity is enforced by
    /// PhotoKit itself: fetchPersistentChanges throws for an expired token
    /// and the caller falls back to a full rebuild. The old library-signature
    /// veto here is what made every new screenshot trigger a full reindex —
    /// an insert at position 0 always changed the signature.
    private func restorePersistentChangeToken() -> PHPersistentChangeToken? {
        guard let data = UserDefaults.standard.data(forKey: changeTokenDefaultsKey) else {
            return nil
        }
        return try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: PHPersistentChangeToken.self,
            from: data
        )
    }

    private func persistChangeToken(_ token: PHPersistentChangeToken) {
        guard let data = try? NSKeyedArchiver.archivedData(
            withRootObject: token,
            requiringSecureCoding: true
        ) else { return }
        // Only the token is persisted. The library signature the index keeps
        // in its own `meta` table was also being written to UserDefaults on
        // every sync and never read back — a dead main-thread write.
        UserDefaults.standard.set(data, forKey: changeTokenDefaultsKey)
    }

    private func makeLibrarySignature(for assets: PHFetchResult<PHAsset>) -> String {
        let firstIdentifier = assets.firstObject?.localIdentifier ?? ""
        let lastIdentifier: String
        if assets.count > 0 {
            lastIdentifier = assets.object(at: assets.count - 1).localIdentifier
        } else {
            lastIdentifier = ""
        }
        return "\(authorizationStatus.rawValue)|\(assets.count)|\(firstIdentifier)|\(lastIdentifier)"
    }

    private func optimisticallyAddMembership(_ assets: [PHAsset], to album: PhotoAlbum) {
        guard !assets.isEmpty,
              let allPhotos,
              indexStats != nil,
              !isIndexingUnsorted
        else { return }

        indexStore.addMembership(
            assetIDs: assets.map(\.localIdentifier),
            albumID: album.id,
            albumTitle: album.title,
            librarySignature: makeLibrarySignature(for: allPhotos)
        ) { [weak self] result in
            guard let self,
                  case .success(let stats) = result
            else { return }
            self.indexStats = stats
            self.unsortedCount = stats.unsortedCount
        }
    }

    /// Mirror of optimisticallyAddMembership for deletions. The PhotoKit
    /// change is committed at this point, so drop the index rows right away
    /// and republish the recomputed unsorted count instead of waiting for
    /// the change-observer round trip to reconcile them.
    private func optimisticallyRemoveAssets(_ assets: [PHAsset]) {
        guard !assets.isEmpty,
              indexStats != nil,
              !isIndexingUnsorted
        else { return }

        indexStore.removeAssets(assetIDs: assets.map(\.localIdentifier)) { [weak self] result in
            guard let self,
                  case .success(let stats) = result
            else { return }
            self.indexStats = stats
            self.unsortedCount = stats.unsortedCount
        }
    }

    nonisolated private static func removeAbandonedShareFiles(
        olderThan cutoff: Date?
    ) {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        // `PhotoVault-<UUID>` was used before the explicit Share prefix.
        // Both formats live in this app's private temporary directory.
        for url in urls where url.lastPathComponent.hasPrefix("PhotoVault-") {
            if let cutoff {
                let modifiedAt = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate
                guard let modifiedAt, modifiedAt < cutoff else { continue }
            }
            try? fileManager.removeItem(at: url)
        }
    }
}
