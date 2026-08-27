import Foundation
import Photos
import UIKit

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

@MainActor
final class PhotoLibraryStore: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published private(set) var authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var allPhotos: PHFetchResult<PHAsset>?
    @Published private(set) var albums: [PhotoAlbum] = []
    @Published private(set) var albumFolders: [PhotoAlbumFolder] = []
    @Published private(set) var unsortedPhotos: PHFetchResult<PHAsset>?
    @Published private(set) var isIndexingUnsorted = false
    @Published private(set) var isLoadingAlbums = false
    @Published private(set) var lastIndexedAt: Date?
    @Published private(set) var unsortedCount = 0
    @Published private(set) var indexProgress: PhotoIndexProgress?
    @Published private(set) var indexStats: PhotoIndexStats?
    @Published private(set) var indexErrorMessage: String?

    private var hasStarted = false
    private var indexGeneration = 0
    private var needsUnsortedIndex = true
    private var unsortedScreenRequested = false
    private let indexStore = PhotoIndexStore()
    private let changeTokenDefaultsKey = "PhotoVault.photoLibrary.changeToken.v1"
    private let changeTokenSignatureDefaultsKey = "PhotoVault.photoLibrary.changeTokenSignature.v1"
    private let albumCacheDefaultsKey = "PhotoVault.photoLibrary.albumSnapshot.v1"
    private var hasLoadedAlbumCache = false

    var canReadPhotos: Bool {
        authorizationStatus == .authorized || authorizationStatus == .limited
    }

    /// Smart albums and user albums that are not inside a folder. Shared
    /// albums are deliberately kept out of this projection so the sidebar
    /// can give them their own Photos-style section.
    var topLevelAlbums: [PhotoAlbum] {
        let nestedIDs = Set(
            albumFolders
                .flatMap { $0.allAlbums }
                .map(\.id)
        )
        return albums.filter {
            $0.kind != .shared && !nestedIDs.contains($0.id)
        }
    }

    /// Shared albums are shown in one dedicated section, including albums
    /// that PhotoKit reports as children of a folder.
    var topLevelSharedAlbums: [PhotoAlbum] {
        albums.filter { $0.kind == .shared }
    }

    override init() {
        super.init()
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        PHPhotoLibrary.shared().register(self)

        if canReadPhotos {
            loadCachedAlbumsIfNeeded()
            refresh()
        } else if authorizationStatus == .notDetermined {
            requestAccess()
        }
    }

    func requestAccess() {
        requestPhotoLibraryAuthorization { [weak self] status in
                guard let self else { return }
                self.authorizationStatus = status
                if self.canReadPhotos {
                    self.refresh()
                }
        }
    }

    func refresh() {
        guard canReadPhotos else { return }

        loadCachedAlbumsIfNeeded()
        if albums.isEmpty && albumFolders.isEmpty {
            albums = []
            albumFolders = []
        }
        allPhotos = nil
        unsortedPhotos = nil
        needsUnsortedIndex = true
        indexGeneration &+= 1
        let generation = indexGeneration

        photoVaultTrace(
            "store refresh generation=\(generation) cachedAlbums=\(albums.count)"
        )

        isLoadingAlbums = true
        DispatchQueue.global(qos: .userInitiated).async {
            let fetchedPhotos = PHAsset.fetchAssets(with: Self.makeLibraryFetchOptions())

            DispatchQueue.main.async { [weak self] in
                guard let self, self.indexGeneration == generation else { return }
                photoVaultTrace(
                    "store photos fetched generation=\(generation) count=\(fetchedPhotos.count)"
                )
                self.allPhotos = fetchedPhotos

                // Album enumeration also fetches collection membership and
                // can be expensive for a large iCloud library. Keep both
                // metadata passes away from the main actor and expose the
                // library fetch result as soon as it is available.
                DispatchQueue.global(qos: .userInitiated).async {
                    let fetchedAlbums = Self.fetchAlbums()

                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.indexGeneration == generation else { return }
                        photoVaultTrace(
                            "store albums fetched generation=\(generation) "
                                + "albums=\(fetchedAlbums.albums.count) "
                                + "folders=\(fetchedAlbums.folders.count)"
                        )
                        self.albums = fetchedAlbums.albums
                        self.albumFolders = fetchedAlbums.folders
                        self.saveAlbumCache(
                            albums: fetchedAlbums.albums,
                            folders: fetchedAlbums.folders
                        )
                        self.isLoadingAlbums = false
                        self.synchronizeIndex(
                            allPhotos: fetchedPhotos,
                            userAlbums: fetchedAlbums.albums
                                .filter { $0.kind == .user }
                                .map(\.collection),
                            generation: generation
                        )
                    }
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
        guard let allPhotos else {
            refresh()
            return
        }

        indexGeneration &+= 1
        let generation = indexGeneration
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
                + "generation=\(generation)"
        )
        indexStore.unsortedIdentifiers(
            limit: max(0, limit),
            offset: max(0, offset)
        ) { [weak self] result in
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
    }

    func album(withID id: String) -> PhotoAlbum? {
        albums.first { $0.id == id }
    }

    func assets(in album: PhotoAlbum) -> PHFetchResult<PHAsset> {
        PHAsset.fetchAssets(in: album.collection, options: Self.makeLibraryFetchOptions())
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
        }) { result in
            completion(result)
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
                    .appendingPathComponent("PhotoVault-\(UUID().uuidString)")
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
            self?.applyPhotoLibraryChange(changeInstance)
        }
    }

    /// Apply the fetch-result delta that PhotoKit already computed instead of
    /// fetching the complete 100k+ library again. Album metadata is refreshed
    /// separately because this store keeps the album list as value models,
    /// while the asset result itself remains incremental.
    private func applyPhotoLibraryChange(_ change: PHChange) {
        guard let currentPhotos = allPhotos else {
            // A missing/non-incremental change detail means PhotoKit cannot
            // safely describe the delta. This is the exceptional full-refresh
            // path, not the normal change-observer path.
            refresh()
            return
        }

        let details = change.changeDetails(for: currentPhotos)
        if let details,
           !details.hasIncrementalChanges {
            refresh()
            return
        }

        // A nil detail means the change only affected collections (for
        // example, adding an asset to an album), so the existing asset fetch
        // result is still valid and can be reused without a full asset fetch.
        let updatedPhotos = details?.fetchResultAfterChanges ?? currentPhotos
        allPhotos = updatedPhotos
        unsortedPhotos = nil
        needsUnsortedIndex = true
        indexGeneration &+= 1
        let generation = indexGeneration

        isLoadingAlbums = true
        DispatchQueue.global(qos: .userInitiated).async {
            let fetchedAlbums = Self.fetchAlbums()

            DispatchQueue.main.async { [weak self] in
                guard let self, self.indexGeneration == generation else { return }
                self.albums = fetchedAlbums.albums
                self.albumFolders = fetchedAlbums.folders
                self.saveAlbumCache(
                    albums: fetchedAlbums.albums,
                    folders: fetchedAlbums.folders
                )
                self.isLoadingAlbums = false
                self.synchronizeIndex(
                    allPhotos: updatedPhotos,
                    userAlbums: fetchedAlbums.albums
                        .filter { $0.kind == .user }
                        .map(\.collection),
                    generation: generation
                )
            }
        }
    }

    /// Restore only album metadata and collection references synchronously.
    /// No image request or per-album asset enumeration happens here, so the
    /// sidebar can render the last known hierarchy while the fresh PhotoKit
    /// scan runs in the background.
    private func loadCachedAlbumsIfNeeded() {
        guard !hasLoadedAlbumCache else { return }
        hasLoadedAlbumCache = true
        guard let data = UserDefaults.standard.data(forKey: albumCacheDefaultsKey),
              let snapshot = try? JSONDecoder().decode(
                  PhotoAlbumCacheSnapshot.self,
                  from: data
              ),
              snapshot.version == PhotoAlbumCacheSnapshot.currentVersion
        else {
            return
        }

        let albumFetchResult = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: snapshot.albums.map(\.id),
            options: nil
        )
        var collectionsByID = [String: PHAssetCollection]()
        albumFetchResult.enumerateObjects { collection, _, _ in
            collectionsByID[collection.localIdentifier] = collection
        }

        let previewIDs = Array(
            Set(snapshot.albums.compactMap(\.previewAssetID))
        )
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
        guard !cachedAlbums.isEmpty || snapshot.albums.isEmpty else { return }

        let albumsByID = Dictionary(
            uniqueKeysWithValues: cachedAlbums.map { ($0.id, $0) }
        )
        func collectFolderIDs(
            _ entry: PhotoAlbumFolderCacheEntry
        ) -> [String] {
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

        func makeFolder(
            _ entry: PhotoAlbumFolderCacheEntry
        ) -> PhotoAlbumFolder? {
            guard let collection = foldersByID[entry.id] else { return nil }
            let albums = entry.albumIDs.compactMap { albumsByID[$0] }
            let subfolders = entry.subfolders.compactMap(makeFolder)
            return PhotoAlbumFolder(
                collection: collection,
                title: entry.title,
                albums: albums,
                subfolders: subfolders
            )
        }

        albums = cachedAlbums
        albumFolders = snapshot.folders.compactMap(makeFolder)
    }

    private func saveAlbumCache(
        albums: [PhotoAlbum],
        folders: [PhotoAlbumFolder]
    ) {
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
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: albumCacheDefaultsKey)
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

            let assets = PHAsset.fetchAssets(
                in: collection,
                options: makeLibraryFetchOptions()
            )
            if kind == .smart && assets.count == 0 {
                return nil
            }

            let album = PhotoAlbum(
                collection: collection,
                kind: kind,
                title: collection.localizedTitle ?? "未命名相册",
                assetCount: assets.count,
                previewAsset: assets.firstObject
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
        for folder in foldersByID.values {
            let children = PHCollection.fetchCollections(in: folder, options: nil)
            children.enumerateObjects { collection, _, _ in
                if let childFolder = collection as? PHCollectionList {
                    childFolderIDs.insert(childFolder.localIdentifier)
                }
            }
        }

        var visitedFolderIDs = Set<String>()

        func makeFolder(from folder: PHCollectionList) -> PhotoAlbumFolder? {
            guard visitedFolderIDs.insert(folder.localIdentifier).inserted else {
                return nil
            }

            var albums = [PhotoAlbum]()
            var subfolders = [PhotoAlbumFolder]()
            let children = PHCollection.fetchCollections(in: folder, options: nil)
            children.enumerateObjects { collection, _, _ in
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
        photoVaultTrace(
            "store index start generation=\(generation) assets=\(allPhotos.count) "
                + "userAlbums=\(userAlbums.count)"
        )
        let librarySignature = makeLibrarySignature(for: allPhotos)
        isIndexingUnsorted = true
        indexErrorMessage = nil
        needsUnsortedIndex = false
        indexProgress = PhotoIndexProgress(
            phase: .scanningAssets,
            completed: 0,
            total: allPhotos.count
        )

        indexStore.hasUsableIndex(for: librarySignature) { [weak self] hasUsableIndex in
            guard let self, self.indexGeneration == generation else { return }

            if hasUsableIndex,
               let token = self.restorePersistentChangeToken(for: librarySignature) {
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
            progress: { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.indexGeneration == generation else { return }
                    self.indexProgress = progress
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
            var collectionsChanged = false

            for change in changes {
                if let details = try? change.changeDetails(for: .asset) {
                    insertedIDs.formUnion(details.insertedLocalIdentifiers)
                    updatedIDs.formUnion(details.updatedLocalIdentifiers)
                    deletedIDs.formUnion(details.deletedLocalIdentifiers)
                }

                if (try? change.changeDetails(for: .assetCollection)) != nil {
                    collectionsChanged = true
                }
                if (try? change.changeDetails(for: .collectionList)) != nil {
                    collectionsChanged = true
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
                self.indexStore.upsertAssets(
                    changedAssets,
                    deletedIDs: deletedIDs,
                    librarySignature: librarySignature
                ) { [weak self] result in
                    guard let self, self.indexGeneration == generation else { return }
                    switch result {
                    case .failure(let error):
                        self.failIndexing(error)
                    case .success:
                        if collectionsChanged {
                            self.indexStore.replaceAlbumMembership(
                                userAlbums: userAlbums,
                                librarySignature: librarySignature,
                                progress: { [weak self] progress in
                                    Task { @MainActor [weak self] in
                                        guard let self, self.indexGeneration == generation else { return }
                                        self.indexProgress = progress
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
        indexProgress = PhotoIndexProgress(
            phase: .finished,
            completed: stats.assetCount,
            total: stats.assetCount
        )
        persistChangeToken(token, for: librarySignature)
        loadUnsortedPhotosIfRequested(generation: generation)
    }

    private func failIndexing(_ error: Error) {
        photoVaultTrace("store index failed error=\(error.localizedDescription)")
        isIndexingUnsorted = false
        indexProgress = nil
        indexErrorMessage = error.localizedDescription
        print("PhotoVault index error: \(error.localizedDescription)")
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

    private func restorePersistentChangeToken(for librarySignature: String) -> PHPersistentChangeToken? {
        guard UserDefaults.standard.string(forKey: changeTokenSignatureDefaultsKey)
            == librarySignature
        else { return nil }
        guard let data = UserDefaults.standard.data(forKey: changeTokenDefaultsKey) else {
            return nil
        }
        return try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: PHPersistentChangeToken.self,
            from: data
        )
    }

    private func persistChangeToken(
        _ token: PHPersistentChangeToken,
        for librarySignature: String
    ) {
        guard let data = try? NSKeyedArchiver.archivedData(
            withRootObject: token,
            requiringSecureCoding: true
        ) else { return }
        UserDefaults.standard.set(data, forKey: changeTokenDefaultsKey)
        UserDefaults.standard.set(librarySignature, forKey: changeTokenSignatureDefaultsKey)
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
}
