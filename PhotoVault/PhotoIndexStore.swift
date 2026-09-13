import Foundation
import Photos
import SQLite3

struct PhotoIndexProgress: Equatable, Sendable {
    enum Phase: String, Sendable {
        case scanningAssets
        case scanningAlbums
        case finalizing
        case finished
    }

    let phase: Phase
    let completed: Int
    let total: Int

    var fraction: Double {
        guard total > 0 else { return phase == .finished ? 1 : 0 }
        return min(max(Double(completed) / Double(total), 0), 1)
    }
}

struct PhotoIndexStats: Equatable, Sendable {
    let assetCount: Int
    let albumCount: Int
    let unsortedCount: Int
}

enum PhotoIndexError: LocalizedError {
    case databaseUnavailable
    case database(String)

    var errorDescription: String? {
        switch self {
        case .databaseUnavailable:
            return "照片索引数据库暂时不可用。"
        case .database(let message):
            return "照片索引失败：\(message)"
        }
    }
}

/// A bounded metadata-only index for large Photos libraries.
///
/// This class owns its SQLite connection on a private serial queue. It never
/// requests image data, video resources, or Live Photos while indexing.
final class PhotoIndexStore: @unchecked Sendable {
    private static let databaseName = "PhotoIndex.sqlite"
    private static let schemaVersion = "2"
    private static func makeMediaOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )
        // No sort descriptor: membership enumeration only inserts IDs, and an
        // ORDER BY here made PhotoKit sort the whole album (for a smart album,
        // the entire library) on every membership pass for no benefit.
        return options
    }

    private let queue = DispatchQueue(
        label: "com.misswell.PhotoVault.photo-index",
        qos: .utility
    )
    private let readQueue = DispatchQueue(
        label: "com.misswell.PhotoVault.photo-index-read",
        qos: .userInitiated
    )
    private let generationLock = NSLock()
    private let databaseURL: URL
    private var database: OpaquePointer?
    private var readDatabase: OpaquePointer?
    private var activeGeneration = 0

    init() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        databaseURL = applicationSupport
            .appendingPathComponent("PhotoVault", isDirectory: true)
            .appendingPathComponent(Self.databaseName)
    }

    deinit {
        queue.sync {
            if let database {
                sqlite3_close(database)
                self.database = nil
            }
        }
        readQueue.sync {
            if let readDatabase {
                sqlite3_close(readDatabase)
                self.readDatabase = nil
            }
        }
    }

    /// Advances the generation synchronously so work that is already queued
    /// or scanning on the writer queue can stop before doing more stale work.
    func setActiveGeneration(_ generation: Int) {
        generationLock.lock()
        activeGeneration = generation
        generationLock.unlock()
    }

    private func isGenerationCurrent(_ generation: Int) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return activeGeneration == generation
    }

    private func checkGeneration(_ generation: Int) throws {
        guard isGenerationCurrent(generation) else {
            throw CancellationError()
        }
    }

    /// Transports a non-Sendable closure onto one of this store's serial
    /// queues. Every callback handed to the store is invoked from those
    /// queues, so the transfer is intentional; the box states that once here
    /// instead of leaving a Swift 6 concurrency warning at every dispatch.
    private struct Callback<Value>: @unchecked Sendable {
        let value: Value
    }


    /// Close the snapshot reader and truncate an already-checkpointed WAL
    /// after foreground work has stopped. Running this behind both serial
    /// queues avoids racing a page read and keeps crash/rebuild history from
    /// accumulating as persistent app-container storage.
    func checkpointForBackground() {
        readQueue.async { [weak self] in
            guard let self else { return }
            if let readDatabase {
                sqlite3_close(readDatabase)
                self.readDatabase = nil
            }
            queue.async { [weak self] in
                guard let self else { return }
                do {
                    try self.withDatabase {
                        try self.execute("PRAGMA incremental_vacuum(256)")
                        try self.execute("PRAGMA wal_checkpoint(TRUNCATE)")
                    }
                } catch {
                    photoVaultTrace(
                        "index background checkpoint skipped error=\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    /// Index usability no longer compares the library signature: a signature
    /// change is exactly what a single new screenshot looks like, and the
    /// persistent change token (whose validity PhotoKit itself enforces)
    /// applies that delta incrementally. The fallback for a stale or expired
    /// token remains the full rebuild in the caller.
    func hasUsableIndex(completion: @escaping (Bool) -> Void) {
        let completionBox = Callback(value: completion)
        readQueue.async { [weak self] in
            guard let self else { return }
            let usable = (try? self.withReadDatabase {
                try self.readMetaOnReadConnection("schema_version") == Self.schemaVersion
                    && self.readMetaOnReadConnection("index_ready") == "1"
            }) ?? false
            if usable {
                DispatchQueue.main.async { completionBox.value(true) }
                return
            }
            // A reader connection cannot run WAL recovery when the previous
            // process was killed mid-write; retry the verdict on the writer
            // connection instead of misreporting the index as unusable and
            // triggering a pointless full rebuild.
            photoVaultTrace("index usable-check falling back to writer connection")
            self.queue.async { [weak self] in
                guard let self else { return }
                let usable = (try? self.withDatabase {
                    try self.readMeta("schema_version") == Self.schemaVersion
                        && self.readMeta("index_ready") == "1"
                }) ?? false
                DispatchQueue.main.async { completionBox.value(usable) }
            }
        }
    }

    func rebuild(
        assets: PHFetchResult<PHAsset>,
        userAlbums: [PHAssetCollection],
        librarySignature: String,
        generation: Int,
        progress: @escaping (PhotoIndexProgress) -> Void,
        completion: @escaping (Result<PhotoIndexStats, Error>) -> Void
    ) {
        let completionBox = Callback(value: completion)
        let progressBox = Callback(value: progress)
        queue.async { [weak self] in
            guard let self else { return }

            do {
                try self.checkGeneration(generation)
                let stats = try self.rebuildSynchronously(
                    assets: assets,
                    userAlbums: userAlbums,
                    librarySignature: librarySignature,
                    generation: generation,
                    progress: progressBox.value
                )
                DispatchQueue.main.async {
                    completionBox.value(.success(stats))
                }
            } catch {
                DispatchQueue.main.async {
                    completionBox.value(.failure(error))
                }
            }
        }
    }

    func replaceAlbumMembership(
        userAlbums: [PHAssetCollection],
        librarySignature: String,
        generation: Int,
        progress: @escaping (PhotoIndexProgress) -> Void,
        completion: @escaping (Result<PhotoIndexStats, Error>) -> Void
    ) {
        let completionBox = Callback(value: completion)
        let progressBox = Callback(value: progress)
        queue.async { [weak self] in
            guard let self else { return }

            do {
                try self.checkGeneration(generation)
                let stats = try self.replaceAlbumMembershipSynchronously(
                    userAlbums: userAlbums,
                    librarySignature: librarySignature,
                    generation: generation,
                    progress: progressBox.value
                )
                DispatchQueue.main.async {
                    completionBox.value(.success(stats))
                }
            } catch {
                DispatchQueue.main.async {
                    completionBox.value(.failure(error))
                }
            }
        }
    }

    func upsertAssets(
        _ assets: [PHAsset],
        deletedIDs: Set<String>,
        librarySignature: String,
        generation: Int,
        completion: @escaping (Result<PhotoIndexStats, Error>) -> Void
    ) {
        let completionBox = Callback(value: completion)
        queue.async { [weak self] in
            guard let self else { return }

            do {
                try self.checkGeneration(generation)
                let stats = try self.upsertAssetsSynchronously(
                    assets,
                    deletedIDs: deletedIDs,
                    librarySignature: librarySignature,
                    generation: generation
                )
                DispatchQueue.main.async {
                    completionBox.value(.success(stats))
                }
            } catch {
                DispatchQueue.main.async {
                    completionBox.value(.failure(error))
                }
            }
        }
    }

    /// Replaces only the albums reported by PhotoKit's persistent change
    /// stream. The temporary table remembers both the old and new members so
    /// album_count is recomputed only for assets whose membership can change.
    func updateAlbumMemberships(
        userAlbums: [PHAssetCollection],
        deletedAlbumIDs: Set<String>,
        librarySignature: String,
        generation: Int,
        progress: @escaping (PhotoIndexProgress) -> Void,
        completion: @escaping (Result<PhotoIndexStats, Error>) -> Void
    ) {
        let completionBox = Callback(value: completion)
        let progressBox = Callback(value: progress)
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.checkGeneration(generation)
                let stats = try self.updateAlbumMembershipsSynchronously(
                    userAlbums: userAlbums,
                    deletedAlbumIDs: deletedAlbumIDs,
                    librarySignature: librarySignature,
                    generation: generation,
                    progress: progressBox.value
                )
                DispatchQueue.main.async { completionBox.value(.success(stats)) }
            } catch {
                DispatchQueue.main.async { completionBox.value(.failure(error)) }
            }
        }
    }

    /// Drops assets from the index immediately after a committed PhotoKit
    /// delete, so the Unsorted list reflects the deletion without waiting
    /// for the change-observer round trip. Album membership rows cascade
    /// via the foreign keys, and a later persistent-change sync deleting
    /// the same identifiers is an idempotent no-op.
    func removeAssets(
        assetIDs: [String],
        completion: @escaping (Result<PhotoIndexStats, Error>) -> Void
    ) {
        let completionBox = Callback(value: completion)
        queue.async { [weak self] in
            guard let self else { return }

            do {
                let stats = try self.removeAssetsSynchronously(assetIDs: assetIDs)
                DispatchQueue.main.async {
                    completionBox.value(.success(stats))
                }
            } catch {
                DispatchQueue.main.async {
                    completionBox.value(.failure(error))
                }
            }
        }
    }

    private func removeAssetsSynchronously(assetIDs: [String]) throws -> PhotoIndexStats {
        try withDatabase {
            try execute("BEGIN IMMEDIATE TRANSACTION")
            do {
                let statement = try prepare("DELETE FROM asset_index WHERE asset_id = ?")
                defer { sqlite3_finalize(statement) }
                for assetID in assetIDs {
                    try bindText(assetID, at: 1, to: statement)
                    try stepAndReset(statement)
                }
                try execute("UPDATE meta SET value = '1' WHERE key = 'index_ready'")
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }

            return try readStats()
        }
    }

    func addMembership(
        assetIDs: [String],
        albumID: String,
        albumTitle: String,
        librarySignature: String,
        completion: @escaping (Result<PhotoIndexStats, Error>) -> Void
    ) {
        let completionBox = Callback(value: completion)
        queue.async { [weak self] in
            guard let self else { return }

            do {
                let stats = try self.addMembershipSynchronously(
                    assetIDs: assetIDs,
                    albumID: albumID,
                    albumTitle: albumTitle,
                    librarySignature: librarySignature
                )
                DispatchQueue.main.async {
                    completionBox.value(.success(stats))
                }
            } catch {
                DispatchQueue.main.async {
                    completionBox.value(.failure(error))
                }
            }
        }
    }

    func stats(completion: @escaping (Result<PhotoIndexStats, Error>) -> Void) {
        let completionBox = Callback(value: completion)
        readQueue.async { [weak self] in
            guard let self else { return }

            do {
                let stats = try self.withReadDatabase {
                    try self.readStatsOnReadConnection()
                }
                DispatchQueue.main.async {
                    completionBox.value(.success(stats))
                }
            } catch {
                photoVaultTrace(
                    "index stats falling back to writer connection "
                        + "error=\(error.localizedDescription)"
                )
                self.queue.async { [weak self] in
                    guard let self else { return }
                    do {
                        let stats = try self.withDatabase { try self.readStats() }
                        DispatchQueue.main.async {
                            completionBox.value(.success(stats))
                        }
                    } catch {
                        DispatchQueue.main.async {
                            completionBox.value(.failure(error))
                        }
                    }
                }
            }
        }
    }

    /// Returns a bounded, newest-first launch window from the last committed
    /// index. This lets the library grid render immediately after a cold
    /// process launch without asking PhotoKit to resolve the complete library
    /// first. A rebuild never leaks a partial window because index_ready is
    /// checked in the same database snapshot as the identifier query.
    func recentAssetIdentifiers(
        limit: Int,
        completion: @escaping @MainActor (Result<[String], Error>) -> Void
    ) {
        let completionBox = Callback(value: completion)
        readQueue.async { [weak self] in
            guard let self else { return }

            do {
                let identifiers = try self.withReadDatabase {
                    try self.readRecentAssetIdentifiersOnReadConnection(limit: limit)
                }
                DispatchQueue.main.async {
                    completionBox.value(.success(identifiers))
                }
            } catch {
                // Match the paging read path: the writer connection can
                // recover a WAL left behind by a force-quit, while a failed
                // launch-cache read must never delay the fresh PhotoKit fetch.
                photoVaultTrace(
                    "index recent-read falling back to writer connection "
                        + "error=\(error.localizedDescription)"
                )
                self.queue.async { [weak self] in
                    guard let self else { return }
                    do {
                        let identifiers = try self.withDatabase {
                            try self.readRecentAssetIdentifiers(limit: limit)
                        }
                        DispatchQueue.main.async {
                            completionBox.value(.success(identifiers))
                        }
                    } catch {
                        DispatchQueue.main.async {
                            completionBox.value(.failure(error))
                        }
                    }
                }
            }
        }
    }

    func unsortedIdentifiers(
        limit: Int,
        offset: Int = 0,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        let completionBox = Callback(value: completion)
        readQueue.async { [weak self] in
            guard let self else { return }

            do {
                let identifiers = try self.withReadDatabase {
                    try self.readUnsortedIdentifiersOnReadConnection(
                        limit: limit,
                        offset: offset
                    )
                }
                DispatchQueue.main.async {
                    completionBox.value(.success(identifiers))
                }
            } catch {
                // WAL recovery edge case (previous process killed mid-write):
                // retry on the writer connection so Unsorted paging and the
                // detail viewer never stall on a reader-side failure.
                photoVaultTrace(
                    "index unsorted-read falling back to writer connection "
                        + "error=\(error.localizedDescription)"
                )
                self.queue.async { [weak self] in
                    guard let self else { return }
                    do {
                        let identifiers = try self.withDatabase {
                            try self.readUnsortedIdentifiers(limit: limit, offset: offset)
                        }
                        DispatchQueue.main.async {
                            completionBox.value(.success(identifiers))
                        }
                    } catch {
                        DispatchQueue.main.async {
                            completionBox.value(.failure(error))
                        }
                    }
                }
            }
        }
    }

    private func rebuildSynchronously(
        assets: PHFetchResult<PHAsset>,
        userAlbums: [PHAssetCollection],
        librarySignature: String,
        generation: Int,
        progress: @escaping (PhotoIndexProgress) -> Void
    ) throws -> PhotoIndexStats {
        let progressBox = Callback(value: progress)
        try checkGeneration(generation)
        return try withDatabase {
            try execute("BEGIN IMMEDIATE TRANSACTION")
            do {
                try execute("UPDATE meta SET value = '0' WHERE key = 'index_ready'")
                try setMeta("library_signature", value: librarySignature)
                try execute("DELETE FROM album_asset")
                try execute("DELETE FROM album_index")
                try execute("DELETE FROM asset_index")

                let assetStatement = try prepare("""
                    INSERT INTO asset_index
                        (asset_id, creation_date, modification_date, media_type, media_subtype, favorite, album_count)
                    VALUES (?, ?, ?, ?, ?, ?, 0)
                    ON CONFLICT(asset_id) DO UPDATE SET
                        creation_date = excluded.creation_date,
                        modification_date = excluded.modification_date,
                        media_type = excluded.media_type,
                        media_subtype = excluded.media_subtype,
                        favorite = excluded.favorite
                    """)
                defer { sqlite3_finalize(assetStatement) }

                var indexError: Error?
                let totalAssets = assets.count
                progressBox.value(PhotoIndexProgress(
                    phase: .scanningAssets,
                    completed: 0,
                    total: totalAssets
                ))

                assets.enumerateObjects { [weak self] asset, index, stop in
                    guard let self else { return }
                    do {
                        if index % 256 == 0 {
                            try self.checkGeneration(generation)
                        }
                        try self.bindAsset(asset, to: assetStatement)
                        try self.stepAndReset(assetStatement)
                    } catch {
                        indexError = error
                        stop.pointee = true
                    }

                    if index == 0 || index == totalAssets - 1 || index % 500 == 0 {
                        progressBox.value(PhotoIndexProgress(
                            phase: .scanningAssets,
                            completed: index + 1,
                            total: totalAssets
                        ))
                    }
                }
                if let indexError { throw indexError }

                try insertAlbumsAndMemberships(
                    userAlbums,
                    generation: generation,
                    progress: progressBox.value
                )
                try checkGeneration(generation)
                progressBox.value(PhotoIndexProgress(
                    phase: .finalizing,
                    completed: totalAssets,
                    total: totalAssets
                ))
                try execute("""
                    UPDATE asset_index
                    SET album_count = (
                        SELECT COUNT(*)
                        FROM album_asset
                        WHERE album_asset.asset_id = asset_index.asset_id
                    )
                    """)
                try execute("UPDATE meta SET value = '1' WHERE key = 'index_ready'")
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }

            return try readStats()
        }
    }

    private func replaceAlbumMembershipSynchronously(
        userAlbums: [PHAssetCollection],
        librarySignature: String,
        generation: Int,
        progress: @escaping (PhotoIndexProgress) -> Void
    ) throws -> PhotoIndexStats {
        let progressBox = Callback(value: progress)
        try checkGeneration(generation)
        return try withDatabase {
            try execute("BEGIN IMMEDIATE TRANSACTION")
            do {
                try execute("DELETE FROM album_asset")
                try execute("DELETE FROM album_index")
                try setMeta("library_signature", value: librarySignature)
                try insertAlbumsAndMemberships(
                    userAlbums,
                    generation: generation,
                    progress: progressBox.value
                )
                try checkGeneration(generation)
                try execute("""
                    UPDATE asset_index
                    SET album_count = (
                        SELECT COUNT(*)
                        FROM album_asset
                        WHERE album_asset.asset_id = asset_index.asset_id
                    )
                    """)
                try execute("UPDATE meta SET value = '1' WHERE key = 'index_ready'")
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }

            return try readStats()
        }
    }

    private func insertAlbumsAndMemberships(
        _ userAlbums: [PHAssetCollection],
        generation: Int,
        progress: @escaping (PhotoIndexProgress) -> Void
    ) throws {
        let progressBox = Callback(value: progress)
        let albumStatement = try prepare("""
            INSERT INTO album_index (album_id, title, type)
            VALUES (?, ?, 0)
            ON CONFLICT(album_id) DO UPDATE SET title = excluded.title, type = excluded.type
            """)
        let membershipStatement = try prepare("""
            INSERT OR IGNORE INTO album_asset (album_id, asset_id)
            SELECT ?, ?
            WHERE EXISTS (
                SELECT 1 FROM asset_index WHERE asset_id = ?
            )
            """)
        defer {
            sqlite3_finalize(albumStatement)
            sqlite3_finalize(membershipStatement)
        }

        let totalAlbums = userAlbums.count
        for (albumIndex, collection) in userAlbums.enumerated() {
            try checkGeneration(generation)
            try bindText(collection.localIdentifier, at: 1, to: albumStatement)
            try bindText(collection.localizedTitle ?? "未命名相册", at: 2, to: albumStatement)
            try stepAndReset(albumStatement)

            let albumAssets = PHAsset.fetchAssets(in: collection, options: Self.makeMediaOptions())
            var membershipError: Error?
            albumAssets.enumerateObjects { [weak self] asset, memberIndex, stop in
                guard let self else { return }
                do {
                    if memberIndex % 256 == 0 {
                        try self.checkGeneration(generation)
                    }
                    try self.bindText(collection.localIdentifier, at: 1, to: membershipStatement)
                    try self.bindText(asset.localIdentifier, at: 2, to: membershipStatement)
                    // Album fetches can briefly contain an asset that is no
                    // longer present in the library snapshot (for example
                    // while iCloud is reconciling changes).  The EXISTS
                    // guard keeps that stale relationship from violating the
                    // foreign key and aborting a full 100k-item index build.
                    try self.bindText(asset.localIdentifier, at: 3, to: membershipStatement)
                    try self.stepAndReset(membershipStatement)
                } catch {
                    membershipError = error
                    stop.pointee = true
                }
            }
            if let membershipError { throw membershipError }

            progressBox.value(PhotoIndexProgress(
                phase: .scanningAlbums,
                completed: albumIndex + 1,
                total: totalAlbums
            ))
        }
    }

    private func updateAlbumMembershipsSynchronously(
        userAlbums: [PHAssetCollection],
        deletedAlbumIDs: Set<String>,
        librarySignature: String,
        generation: Int,
        progress: @escaping (PhotoIndexProgress) -> Void
    ) throws -> PhotoIndexStats {
        let progressBox = Callback(value: progress)
        try checkGeneration(generation)
        return try withDatabase {
            try execute("BEGIN IMMEDIATE TRANSACTION")
            do {
                try execute("""
                    CREATE TEMP TABLE IF NOT EXISTS affected_asset_ids (
                        asset_id TEXT PRIMARY KEY NOT NULL
                    )
                    """)
                try execute("DELETE FROM affected_asset_ids")
                try setMeta("library_signature", value: librarySignature)

                let changedAlbumIDs = Set(userAlbums.map(\.localIdentifier))
                    .union(deletedAlbumIDs)
                let captureStatement = try prepare("""
                    INSERT OR IGNORE INTO affected_asset_ids (asset_id)
                    SELECT asset_id FROM album_asset WHERE album_id = ?
                    """)
                let deleteStatement = try prepare(
                    "DELETE FROM album_index WHERE album_id = ?"
                )
                defer {
                    sqlite3_finalize(captureStatement)
                    sqlite3_finalize(deleteStatement)
                }

                for albumID in changedAlbumIDs {
                    try checkGeneration(generation)
                    try bindText(albumID, at: 1, to: captureStatement)
                    try stepAndReset(captureStatement)
                    try bindText(albumID, at: 1, to: deleteStatement)
                    try stepAndReset(deleteStatement)
                }

                try insertAlbumsAndMemberships(
                    userAlbums,
                    generation: generation,
                    progress: progressBox.value
                )

                for albumID in userAlbums.map(\.localIdentifier) {
                    try checkGeneration(generation)
                    try bindText(albumID, at: 1, to: captureStatement)
                    try stepAndReset(captureStatement)
                }

                try execute("""
                    UPDATE asset_index
                    SET album_count = (
                        SELECT COUNT(*)
                        FROM album_asset
                        WHERE album_asset.asset_id = asset_index.asset_id
                    )
                    WHERE asset_id IN (SELECT asset_id FROM affected_asset_ids)
                    """)
                try checkGeneration(generation)
                try execute("UPDATE meta SET value = '1' WHERE key = 'index_ready'")
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
            return try readStats()
        }
    }

    private func upsertAssetsSynchronously(
        _ assets: [PHAsset],
        deletedIDs: Set<String>,
        librarySignature: String,
        generation: Int
    ) throws -> PhotoIndexStats {
        try checkGeneration(generation)
        return try withDatabase {
            try execute("BEGIN IMMEDIATE TRANSACTION")
            do {
                try setMeta("library_signature", value: librarySignature)
                let statement = try prepare("""
                    INSERT INTO asset_index
                        (asset_id, creation_date, modification_date, media_type, media_subtype, favorite, album_count)
                    VALUES (?, ?, ?, ?, ?, ?, COALESCE((SELECT album_count FROM asset_index WHERE asset_id = ?), 0))
                    ON CONFLICT(asset_id) DO UPDATE SET
                        creation_date = excluded.creation_date,
                        modification_date = excluded.modification_date,
                        media_type = excluded.media_type,
                        media_subtype = excluded.media_subtype,
                        favorite = excluded.favorite
                    """)
                defer { sqlite3_finalize(statement) }

                for (index, asset) in assets.enumerated() {
                    if index % 256 == 0 {
                        try checkGeneration(generation)
                    }
                    try bindAsset(asset, to: statement, includeExistingID: true)
                    try stepAndReset(statement)
                }

                if !deletedIDs.isEmpty {
                    let deleteStatement = try prepare("DELETE FROM asset_index WHERE asset_id = ?")
                    defer { sqlite3_finalize(deleteStatement) }
                    for identifier in deletedIDs {
                        try bindText(identifier, at: 1, to: deleteStatement)
                        try stepAndReset(deleteStatement)
                    }
                }

                try checkGeneration(generation)
                try execute("UPDATE meta SET value = '1' WHERE key = 'index_ready'")
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }

            return try readStats()
        }
    }

    private func addMembershipSynchronously(
        assetIDs: [String],
        albumID: String,
        albumTitle: String,
        librarySignature: String
    ) throws -> PhotoIndexStats {
        try withDatabase {
            try execute("BEGIN IMMEDIATE TRANSACTION")
            do {
                try setMeta("library_signature", value: librarySignature)

                let albumStatement = try prepare("""
                    INSERT INTO album_index (album_id, title, type)
                    VALUES (?, ?, 0)
                    ON CONFLICT(album_id) DO UPDATE SET title = excluded.title
                    """)
                defer { sqlite3_finalize(albumStatement) }
                try bindText(albumID, at: 1, to: albumStatement)
                try bindText(albumTitle, at: 2, to: albumStatement)
                try stepAndReset(albumStatement)

                let membershipStatement = try prepare("""
                    INSERT OR IGNORE INTO album_asset (album_id, asset_id)
                    SELECT ?, ?
                    WHERE EXISTS (
                        SELECT 1 FROM asset_index WHERE asset_id = ?
                    )
                    """)
                defer { sqlite3_finalize(membershipStatement) }
                for assetID in assetIDs {
                    try bindText(albumID, at: 1, to: membershipStatement)
                    try bindText(assetID, at: 2, to: membershipStatement)
                    try bindText(assetID, at: 3, to: membershipStatement)
                    try stepAndReset(membershipStatement)
                }

                let countStatement = try prepare("""
                    UPDATE asset_index
                    SET album_count = (
                        SELECT COUNT(*)
                        FROM album_asset
                        WHERE album_asset.asset_id = asset_index.asset_id
                    )
                    WHERE asset_id = ?
                    """)
                defer { sqlite3_finalize(countStatement) }
                for assetID in assetIDs {
                    try bindText(assetID, at: 1, to: countStatement)
                    try stepAndReset(countStatement)
                }
                try execute("UPDATE meta SET value = '1' WHERE key = 'index_ready'")
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
            return try readStats()
        }
    }

    private func readStats() throws -> PhotoIndexStats {
        PhotoIndexStats(
            assetCount: try scalarInt("SELECT COUNT(*) FROM asset_index"),
            albumCount: try scalarInt("SELECT COUNT(*) FROM album_index"),
            unsortedCount: try scalarInt("SELECT COUNT(*) FROM asset_index WHERE album_count = 0")
        )
    }

    private func readRecentAssetIdentifiers(limit: Int) throws -> [String] {
        let statement = try prepare("""
            SELECT asset_id
            FROM asset_index
            WHERE (SELECT value FROM meta WHERE key = 'index_ready') = '1'
            ORDER BY creation_date DESC, asset_id DESC
            LIMIT ?
            """)
        defer { sqlite3_finalize(statement) }
        try bindInt64(Int64(max(0, limit)), at: 1, to: statement)

        var identifiers = [String]()
        identifiers.reserveCapacity(min(max(0, limit), 4096))
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 0) {
                identifiers.append(String(cString: value))
            }
        }
        return identifiers
    }

    private func readUnsortedIdentifiers(limit: Int, offset: Int) throws -> [String] {
        let statement = try prepare("""
            SELECT asset_id
            FROM asset_index
            WHERE album_count = 0
            ORDER BY creation_date DESC, asset_id DESC
            LIMIT ? OFFSET ?
            """)
        defer { sqlite3_finalize(statement) }
        try bindInt64(Int64(max(0, limit)), at: 1, to: statement)
        try bindInt64(Int64(max(0, offset)), at: 2, to: statement)

        var identifiers = [String]()
        identifiers.reserveCapacity(min(max(0, limit), 4096))
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 0) {
                identifiers.append(String(cString: value))
            }
        }
        return identifiers
    }

    /// Readers use a dedicated connection so a long rebuild transaction never
    /// blocks paging. WAL lets this connection serve the last committed
    /// snapshot while the writer works. It is opened READWRITE on purpose: a
    /// READONLY connection cannot run WAL recovery when the previous process
    /// was killed mid-write, which failed every read. Nothing writes through
    /// it; if the file is missing the open fails and the caller's writer
    /// fallback creates and migrates the database.
    private func withReadDatabase<T>(_ body: () throws -> T) throws -> T {
        try openReadIfNeeded()
        return try body()
    }

    private func openReadIfNeeded() throws {
        guard readDatabase == nil else { return }
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let handle else {
            if let handle {
                sqlite3_close(handle)
            }
            throw PhotoIndexError.databaseUnavailable
        }
        readDatabase = handle
        // Without a busy timeout any transient SQLITE_BUSY (e.g. the writer is
        // mid-checkpoint) surfaced as a read failure and forced the slower
        // writer-connection fallback.
        sqlite3_busy_timeout(handle, 2_000)
    }

    private func prepareRead(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(readDatabase, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw databaseError()
        }
        return statement
    }

    private func readMetaOnReadConnection(_ key: String) throws -> String? {
        let statement = try prepareRead("SELECT value FROM meta WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        try bindText(key, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }

    private func scalarIntOnReadConnection(_ sql: String) throws -> Int {
        let statement = try prepareRead(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw databaseError()
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func readStatsOnReadConnection() throws -> PhotoIndexStats {
        PhotoIndexStats(
            assetCount: try scalarIntOnReadConnection("SELECT COUNT(*) FROM asset_index"),
            albumCount: try scalarIntOnReadConnection("SELECT COUNT(*) FROM album_index"),
            unsortedCount: try scalarIntOnReadConnection(
                "SELECT COUNT(*) FROM asset_index WHERE album_count = 0"
            )
        )
    }

    private func readRecentAssetIdentifiersOnReadConnection(limit: Int) throws -> [String] {
        let statement = try prepareRead("""
            SELECT asset_id
            FROM asset_index
            WHERE (SELECT value FROM meta WHERE key = 'index_ready') = '1'
            ORDER BY creation_date DESC, asset_id DESC
            LIMIT ?
            """)
        defer { sqlite3_finalize(statement) }
        try bindInt64(Int64(max(0, limit)), at: 1, to: statement)

        var identifiers = [String]()
        identifiers.reserveCapacity(min(max(0, limit), 4096))
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 0) {
                identifiers.append(String(cString: value))
            }
        }
        return identifiers
    }

    private func readUnsortedIdentifiersOnReadConnection(limit: Int, offset: Int) throws -> [String] {
        let statement = try prepareRead("""
            SELECT asset_id
            FROM asset_index
            WHERE album_count = 0
            ORDER BY creation_date DESC, asset_id DESC
            LIMIT ? OFFSET ?
            """)
        defer { sqlite3_finalize(statement) }
        try bindInt64(Int64(max(0, limit)), at: 1, to: statement)
        try bindInt64(Int64(max(0, offset)), at: 2, to: statement)

        var identifiers = [String]()
        identifiers.reserveCapacity(min(max(0, limit), 4096))
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 0) {
                identifiers.append(String(cString: value))
            }
        }
        return identifiers
    }

    private func withDatabase<T>(_ body: () throws -> T) throws -> T {
        try openIfNeeded()
        return try body()
    }

    private func openIfNeeded() throws {
        guard database == nil else { return }
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let handle else {
            if let handle {
                sqlite3_close(handle)
            }
            throw PhotoIndexError.databaseUnavailable
        }
        database = handle
        sqlite3_busy_timeout(handle, 2_000)
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA auto_vacuum = INCREMENTAL")
        // `quick_check` scans the whole index file. Running it on every open
        // added a full-file read to every launch; a leftover non-empty WAL is
        // the only signal that the previous process died mid-write, which is
        // the case where the scan earns its cost.
        if needsIntegrityCheck() {
            try repairIfNeeded()
        }
        do {
            try prepareSchema()
        } catch {
            // A statement failing here is the other signal of a damaged file
            // (the scan above is skipped after a clean shutdown). The index
            // holds only rebuildable metadata, so drop it and start over once
            // instead of leaving the app with a permanently broken index.
            try repairIfNeeded()
            try prepareSchema()
        }
    }

    private func prepareSchema() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            )
            """)
        try execute("""
            INSERT OR IGNORE INTO meta (key, value) VALUES ('index_ready', '0')
            """)
        let existingSchemaVersion = try readMeta("schema_version")
        if let existingSchemaVersion,
           existingSchemaVersion != Self.schemaVersion {
            try execute("DROP TABLE IF EXISTS album_asset")
            try execute("DROP TABLE IF EXISTS album_index")
            try execute("DROP TABLE IF EXISTS asset_index")
            try execute("DELETE FROM meta")
        }
        try setMeta("schema_version", value: Self.schemaVersion)
        try execute("""
            INSERT OR IGNORE INTO meta (key, value) VALUES ('index_ready', '0')
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS asset_index (
                asset_id TEXT PRIMARY KEY NOT NULL,
                creation_date REAL NOT NULL DEFAULT 0,
                modification_date REAL NOT NULL DEFAULT 0,
                media_type INTEGER NOT NULL DEFAULT 0,
                media_subtype INTEGER NOT NULL DEFAULT 0,
                favorite INTEGER NOT NULL DEFAULT 0,
                album_count INTEGER NOT NULL DEFAULT 0
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS album_index (
                album_id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                type INTEGER NOT NULL DEFAULT 0
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS album_asset (
                album_id TEXT NOT NULL REFERENCES album_index(album_id) ON DELETE CASCADE,
                asset_id TEXT NOT NULL REFERENCES asset_index(asset_id) ON DELETE CASCADE,
                PRIMARY KEY (album_id, asset_id)
            )
            """)
        // The ordered covering index fully subsumes the old two-column index;
        // keeping both doubles part of the write and disk cost for no query
        // benefit after the paging ORDER BY gained asset_id as a tie-breaker.
        try execute("DROP INDEX IF EXISTS asset_index_unassigned")
        try execute("CREATE INDEX IF NOT EXISTS asset_index_unassigned_ordered ON asset_index(album_count, creation_date DESC, asset_id DESC)")
        try execute("CREATE INDEX IF NOT EXISTS album_asset_asset ON album_asset(asset_id)")
        // The unassigned index leads with `album_count`, so the launch-preview
        // query ("newest N assets overall") could not use it and fell back to
        // a full covering scan plus a temporary B-tree sort. This index serves
        // that ORDER BY directly.
        try execute("CREATE INDEX IF NOT EXISTS asset_index_creation ON asset_index(creation_date DESC, asset_id DESC)")
    }

    private func readMeta(_ key: String) throws -> String? {
        let statement = try prepare("SELECT value FROM meta WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        try bindText(key, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }

    private func setMeta(_ key: String, value: String) throws {
        let statement = try prepare("""
            INSERT INTO meta (key, value)
            VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """)
        defer { sqlite3_finalize(statement) }
        try bindText(key, at: 1, to: statement)
        try bindText(value, at: 2, to: statement)
        try stepAndReset(statement)
    }

    /// True when the previous process did not shut down cleanly. Backgrounding
    /// runs `wal_checkpoint(TRUNCATE)`, so a non-empty `-wal` at open means
    /// the database was interrupted mid-write.
    private func needsIntegrityCheck() -> Bool {
        let walPath = databaseURL.path + "-wal"
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: walPath),
              let size = attributes[.size] as? NSNumber
        else { return false }
        return size.intValue > 0
    }

    private func repairIfNeeded() throws {
        let statement = try prepare("PRAGMA quick_check")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let result = sqlite3_column_text(statement, 0)
        else { return }
        guard String(cString: result) != "ok" else { return }

        // This file only contains rebuildable metadata. Drop its tables so a
        // corrupt index can recover without touching the user's Photos data.
        try execute("DROP TABLE IF EXISTS album_asset")
        try execute("DROP TABLE IF EXISTS album_index")
        try execute("DROP TABLE IF EXISTS asset_index")
        try execute("DELETE FROM meta")
    }

    private func scalarInt(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw databaseError()
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "未知数据库错误"
            sqlite3_free(errorMessage)
            throw PhotoIndexError.database(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw databaseError()
        }
        return statement
    }

    private func bindAsset(
        _ asset: PHAsset,
        to statement: OpaquePointer,
        includeExistingID: Bool = false
    ) throws {
        try bindText(asset.localIdentifier, at: 1, to: statement)
        try bindDouble(asset.creationDate?.timeIntervalSince1970 ?? 0, at: 2, to: statement)
        try bindDouble(asset.modificationDate?.timeIntervalSince1970 ?? 0, at: 3, to: statement)
        try bindInt64(Int64(asset.mediaType.rawValue), at: 4, to: statement)
        try bindInt64(Int64(asset.mediaSubtypes.rawValue), at: 5, to: statement)
        try bindInt64(asset.isFavorite ? 1 : 0, at: 6, to: statement)
        if includeExistingID {
            try bindText(asset.localIdentifier, at: 7, to: statement)
        }
    }

    private func bindText(_ value: String, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, index, value, -1, sqliteTransient) == SQLITE_OK else {
            throw databaseError()
        }
    }

    private func bindDouble(_ value: Double, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
            throw databaseError()
        }
    }

    private func bindInt64(_ value: Int64, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
            throw databaseError()
        }
    }

    private func stepAndReset(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            let error = databaseError()
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            throw error
        }
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    private func databaseError() -> PhotoIndexError {
        guard let database,
              let message = sqlite3_errmsg(database)
        else {
            return .databaseUnavailable
        }
        return .database(String(cString: message))
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
