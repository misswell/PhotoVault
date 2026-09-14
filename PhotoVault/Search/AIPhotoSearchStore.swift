//
//  AIPhotoSearchStore.swift
//  PhotoVault
//
//  Metadata index for on-device search: which assets are indexed, their
//  embedding slot, the PhotoKit metadata needed to filter without asking
//  PhotoKit again, and OCR text.
//
//  Deliberately a *separate* database (`AIPhotoSearch.sqlite`) from
//  `PhotoIndex.sqlite`. The existing index is verified, versioned and load
//  bearing for the 未整理 screens; the AI index can be dropped, rebuilt or
//  schema-bumped independently without touching it. Zero migration risk is worth
//  more than one fewer file.
//
//  Connection discipline (inherited from `PhotoIndexStore`, and load bearing)
//  ---------------------------------------------------------------------------
//  * Writes go through one connection on a serial queue. A rebuild transaction
//    can run for tens of seconds and must never block a read.
//  * Reads use a *second* connection so they see the last committed snapshot
//    under WAL instead of queueing behind the writer.
//  * That read connection is opened **READWRITE**, not READONLY. A READONLY
//    connection cannot perform WAL recovery, so after the previous process was
//    killed mid-write every read would fail -- which surfaces as a permanently
//    empty result set, not as an error anyone can act on.
//  * Reads additionally fall back to the write connection on any failure. A
//    read must not fail because the second connection is unhappy.
//

import Foundation
import SQLite3

/// Progress reported while indexing, throttled by the caller.
struct AISearchIndexProgress: Equatable, Sendable {
    enum Phase: String, Sendable {
        case idle, enumerating, embedding, opticalCharacterRecognition, finalizing
    }
    var phase: Phase = .idle
    var processed: Int = 0
    var total: Int = 0
    var failures: Int = 0

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(processed) / Double(total))
    }
}

struct AISearchIndexStats: Equatable, Sendable {
    var totalAssets = 0
    var embeddedAssets = 0
    var pendingAssets = 0
    var failedAssets = 0
    var assetsWithLocation = 0
    var assetsWithText = 0
}

/// Which assets a query is allowed to consider, before vector ranking.
///
/// This is the piece that keeps search honest: the vector index finds *similar*
/// photos, and these predicates remove the ones the user explicitly excluded.
/// A plan that cannot be expressed here would silently ignore part of the query.
struct AISearchCandidateFilter: Equatable, Sendable {
    var creationDateAfter: Date?
    var creationDateBefore: Date?
    var mediaType: Int?
    var favoritesOnly = false
    var requiresLocation = false
    /// Latitude/longitude box, already expanded by the caller to account for
    /// imprecision in both the photo's GPS and the place the user named.
    var latitudeRange: ClosedRange<Double>?
    var longitudeRange: ClosedRange<Double>?
    /// Substrings that must all appear in the OCR text (AND semantics).
    var requiredTextTerms: [String] = []
    /// Substrings that must not appear.
    var excludedTextTerms: [String] = []
    var limit: Int?
}

enum AISearchStoreError: LocalizedError {
    case databaseUnavailable
    case statementFailed(String)
    case schemaVersionMismatch(found: String, expected: String)
    case unsupportedFullTextSearch
    case embeddingSlotInconsistent(String)

    var errorDescription: String? {
        switch self {
        case .databaseUnavailable: "the search index database is unavailable"
        case .statementFailed(let detail): "search index statement failed: \(detail)"
        case .schemaVersionMismatch(let found, let expected):
            "search index schema is v\(found), this build needs v\(expected)"
        case .unsupportedFullTextSearch:
            "this SQLite build has no FTS5 trigram tokenizer"
        case .embeddingSlotInconsistent(let detail):
            "embedding slot bookkeeping is inconsistent: \(detail)"
        }
    }
}

/// One asset row, as read back from the index.
struct AIAssetRecord: Equatable, Sendable {
    var assetID: String
    var embeddingSlot: Int?
    var status: Int
    var creationDate: Date
    var mediaType: Int
    var isFavorite: Bool
    var latitude: Double?
    var longitude: Double?
    var ocrText: String?
}

final class AIPhotoSearchStore: @unchecked Sendable {

    static let schemaVersion = "1"
    /// Written into `ai_asset.model_version`; a mismatch means the stored
    /// vectors came from a different model and must not be compared with the
    /// current one's output.
    static let modelVersion = "siglip2-base-patch16-256/w8-v1"

    enum Status: Int, Sendable {
        case pending = 0
        case ready = 1
        case failed = 2
    }

    /// Exposed so a reopened store can be pointed at the same files -- the way a
    /// relaunched app resumes an interrupted index.
    let databaseURLForTesting: URL
    let embeddingURLForTesting: URL
    private var databaseURL: URL { databaseURLForTesting }
    private var embeddingURL: URL { embeddingURLForTesting }
    private let writeQueue = DispatchQueue(label: "com.misswell.PhotoVault.aiIndex.write")
    private let readQueue = DispatchQueue(label: "com.misswell.PhotoVault.aiIndex.read")

    private var database: OpaquePointer?
    private var readDatabase: OpaquePointer?
    private var embeddingWriter: EmbeddingMatrixWriter?

    /// Set from the indexing pipeline. Work checks this between assets and stops
    /// without committing partial state.
    private var activeGeneration = 0
    private let generationLock = NSLock()

    init(databaseURL: URL, embeddingURL: URL) {
        self.databaseURLForTesting = databaseURL
        self.embeddingURLForTesting = embeddingURL
    }

    deinit {
        if let database { sqlite3_close(database) }
        if let readDatabase { sqlite3_close(readDatabase) }
    }

    // MARK: - Generation guard

    /// Advances the generation. Anything already queued observes the change and
    /// abandons its work instead of writing stale results over newer ones.
    func invalidateInFlightWork() {
        generationLock.lock()
        activeGeneration += 1
        generationLock.unlock()
    }

    var currentGeneration: Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        return activeGeneration
    }

    func isGenerationCurrent(_ generation: Int) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation == activeGeneration
    }

    // MARK: - Opening

    /// Opens (creating if needed) and prepares the schema. `dimension` comes
    /// from the model manifest, never a literal.
    func open(dimension: Int, sourceModelSHA256: String) throws {
        try writeQueue.sync {
            try openIfNeeded(dimension: dimension, sourceModelSHA256: sourceModelSHA256)
        }
    }

    /// Opens the index, discarding it first when it was built by a different
    /// model or dimension.
    ///
    /// `open` rejects those on purpose -- silently rebuilding would hide a caller
    /// passing the wrong values -- and that stays true and tested. But at the app
    /// level a mismatch has a known cause: a build that ships a new model. The
    /// manifest name is the model fingerprint, so shipping any new conversion
    /// changes it, and `open` alone would leave every existing user with a search
    /// screen that can never recover.
    ///
    /// The index is derived data, so the policy here is to drop it and start
    /// clean. Kept as a separate entry point so callers choose the policy
    /// explicitly instead of `open` quietly changing meaning.
    func openRebuildingIfIncompatible(dimension: Int, sourceModelSHA256: String) throws {
        do {
            try open(dimension: dimension, sourceModelSHA256: sourceModelSHA256)
        } catch let error as EmbeddingStoreError where error.isIncompatible {
            // Only the *matrix* is replaced. Deleting the database as well would
            // work, but it would throw away metadata that has nothing to do with
            // the model -- capture dates, GPS, OCR text -- and force a full
            // PhotoKit re-enumeration of the whole library to get it back. The
            // embeddings do have to go, since vectors from two models are not
            // comparable, and `rebuildEmbeddingMatrix` already clears them.
            try writeQueue.sync {
                if database == nil { try openDatabases() }
                try rebuildEmbeddingMatrix(
                    dimension: dimension, sourceModelSHA256: sourceModelSHA256
                )
            }
        }
    }

    private func openIfNeeded(dimension: Int, sourceModelSHA256: String) throws {
        if database == nil {
            try openDatabases()
        }
        if embeddingWriter == nil {
            do {
                embeddingWriter = try EmbeddingMatrixWriter(
                    url: embeddingURL, dimension: dimension, sourceModelSHA256: sourceModelSHA256
                )
            } catch let error as EmbeddingStoreError where error.isRebuildable {
                // The matrix is derived data and this file is unusable -- corrupt,
                // a different version, or built by a different model. Rebuild it
                // instead of failing, because failing here is permanent: every
                // later launch reopens the same file and hits the same error.
                try rebuildEmbeddingMatrix(
                    dimension: dimension, sourceModelSHA256: sourceModelSHA256
                )
            }
        }
    }

    /// Replaces an unusable embedding matrix and re-queues everything that
    /// pointed into it. Used both for corruption and for a model change.
    ///
    /// Resetting the rows is not optional. Slot indices are assigned by the
    /// matrix, and a rebuilt matrix starts empty, so any row still carrying an
    /// old `embedding_slot` would resolve to the wrong vector -- or to none.
    /// Clearing the slot and returning the row to `pending` is what makes the
    /// index self-consistent again; the next indexing pass re-embeds it.
    ///
    /// Called from inside `openIfNeeded`, which already holds `writeQueue`.
    private func rebuildEmbeddingMatrix(dimension: Int, sourceModelSHA256: String) throws {
        // The file itself may be unreadable rather than absent, so removal can
        // fail for reasons other than "not there" -- a failure that matters,
        // because recreating over a file that is still present would throw the
        // same parse error again.
        try? FileManager.default.removeItem(at: embeddingURL)

        embeddingWriter = try EmbeddingMatrixWriter(
            url: embeddingURL, dimension: dimension, sourceModelSHA256: sourceModelSHA256
        )

        try withDatabase {
            let statement = try prepare("""
                UPDATE ai_asset
                SET embedding_slot = NULL, status = ?, failure_count = 0,
                    last_error = NULL, next_retry_at = NULL
                WHERE embedding_slot IS NOT NULL OR status = ?
            """)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(Status.pending.rawValue))
            sqlite3_bind_int(statement, 2, Int32(Status.ready.rawValue))
            try stepAndReset(statement)
        }
    }

    private func openDatabases() throws {
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var handle: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path, &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil
        )
        guard result == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw AISearchStoreError.databaseUnavailable
        }
        database = handle
        sqlite3_busy_timeout(handle, 2_000)
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA auto_vacuum = INCREMENTAL")
        try prepareSchema()
    }

    // MARK: - Schema

    private func prepareSchema() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            )
        """)

        let existing = try readMeta("schema_version")
        if let existing, existing != Self.schemaVersion {
            // The AI index is entirely derived, so the correct response to a
            // version bump is to rebuild, not to migrate. Refuse loudly here and
            // let the caller drop the file.
            throw AISearchStoreError.schemaVersionMismatch(
                found: existing, expected: Self.schemaVersion
            )
        }

        try execute("""
            CREATE TABLE IF NOT EXISTS ai_asset (
                asset_id TEXT PRIMARY KEY NOT NULL,
                embedding_slot INTEGER,
                model_version TEXT,
                status INTEGER NOT NULL DEFAULT 0,
                failure_count INTEGER NOT NULL DEFAULT 0,
                last_error TEXT,
                next_retry_at REAL,
                indexed_at REAL,
                creation_date REAL NOT NULL,
                modification_date REAL,
                media_type INTEGER NOT NULL DEFAULT 0,
                media_subtypes INTEGER NOT NULL DEFAULT 0,
                is_favorite INTEGER NOT NULL DEFAULT 0,
                is_hidden INTEGER NOT NULL DEFAULT 0,
                width INTEGER NOT NULL DEFAULT 0,
                height INTEGER NOT NULL DEFAULT 0,
                duration REAL NOT NULL DEFAULT 0,
                latitude REAL,
                longitude REAL,
                ocr_text TEXT,
                ocr_version INTEGER NOT NULL DEFAULT 0,
                ocr_attempted INTEGER NOT NULL DEFAULT 0
            )
        """)

        // Slot -> asset must be unique and fast: `removeEmbedding` has to find
        // the asset occupying the last slot on every deletion, and a duplicate
        // here would silently corrupt the swap-remove.
        try execute("""
            CREATE UNIQUE INDEX IF NOT EXISTS ai_asset_slot
                ON ai_asset(embedding_slot) WHERE embedding_slot IS NOT NULL
        """)
        try execute("""
            CREATE INDEX IF NOT EXISTS ai_asset_ready_ordered
                ON ai_asset(status, creation_date DESC, asset_id DESC)
        """)
        try execute("""
            CREATE INDEX IF NOT EXISTS ai_asset_pending
                ON ai_asset(status, next_retry_at)
        """)
        try execute("""
            CREATE INDEX IF NOT EXISTS ai_asset_geo
                ON ai_asset(latitude, longitude) WHERE latitude IS NOT NULL
        """)

        // Standalone FTS5 table rather than external-content, because both the
        // trigram MATCH and the `instr()` fallback read the same column, so the
        // normalized text is stored once and there is no trigger dance to keep
        // an external-content index in sync.
        //
        // trigram cannot match 1- or 2-character queries ("发票", "报销"), which
        // is a large fraction of real Chinese search. The fallback is not
        // optional.
        do {
            try execute("""
                CREATE VIRTUAL TABLE IF NOT EXISTS ocr_fts USING fts5(
                    asset_id UNINDEXED,
                    text,
                    tokenize='trigram'
                )
            """)
        } catch {
            throw AISearchStoreError.unsupportedFullTextSearch
        }

        try execute("""
            CREATE TABLE IF NOT EXISTS ai_run (
                run_id INTEGER PRIMARY KEY AUTOINCREMENT,
                kind TEXT NOT NULL,
                state TEXT NOT NULL,
                started_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                total INTEGER NOT NULL DEFAULT 0,
                processed INTEGER NOT NULL DEFAULT 0,
                cursor_asset_id TEXT,
                change_token BLOB
            )
        """)

        try setMeta("schema_version", value: Self.schemaVersion)
    }

    /// True when this SQLite build can do trigram full-text search. Callers use
    /// it to decide whether to plan FTS queries or fall back immediately.
    func supportsTrigramFullTextSearch() -> Bool {
        writeQueue.sync {
            guard let database else { return false }
            var statement: OpaquePointer?
            let sql = "SELECT 1 FROM pragma_compile_options WHERE compile_options LIKE '%ENABLE_FTS5%'"
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                return false
            }
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    // MARK: - Metadata upsert

    struct AssetMetadata: Equatable, Sendable {
        var assetID: String
        var creationDate: Date
        var modificationDate: Date?
        var mediaType: Int
        var mediaSubtypes: Int = 0
        var isFavorite: Bool = false
        var isHidden: Bool = false
        var width: Int = 0
        var height: Int = 0
        var duration: Double = 0
        var latitude: Double?
        var longitude: Double?
    }

    /// Inserts or refreshes metadata without disturbing embedding state.
    ///
    /// PhotoKit re-reports assets constantly (edits, favourite toggles), so this
    /// must never reset `status` or drop an existing `embedding_slot` -- doing so
    /// would re-embed the whole library on every metadata refresh.
    func upsertMetadata(_ records: [AssetMetadata]) throws {
        guard !records.isEmpty else { return }
        try writeQueue.sync {
            try withDatabase {
                try execute("BEGIN IMMEDIATE")
                do {
                    let statement = try prepare("""
                        INSERT INTO ai_asset (
                            asset_id, creation_date, modification_date, media_type,
                            media_subtypes, is_favorite, is_hidden, width, height,
                            duration, latitude, longitude, status
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                        ON CONFLICT(asset_id) DO UPDATE SET
                            creation_date = excluded.creation_date,
                            modification_date = excluded.modification_date,
                            media_type = excluded.media_type,
                            media_subtypes = excluded.media_subtypes,
                            is_favorite = excluded.is_favorite,
                            is_hidden = excluded.is_hidden,
                            width = excluded.width,
                            height = excluded.height,
                            duration = excluded.duration,
                            latitude = excluded.latitude,
                            longitude = excluded.longitude
                    """)
                    defer { sqlite3_finalize(statement) }
                    for record in records {
                        sqlite3_reset(statement)
                        sqlite3_clear_bindings(statement)
                        try bindText(record.assetID, at: 1, to: statement)
                        sqlite3_bind_double(statement, 2, record.creationDate.timeIntervalSince1970)
                        if let modified = record.modificationDate {
                            sqlite3_bind_double(statement, 3, modified.timeIntervalSince1970)
                        } else {
                            sqlite3_bind_null(statement, 3)
                        }
                        sqlite3_bind_int(statement, 4, Int32(record.mediaType))
                        sqlite3_bind_int(statement, 5, Int32(record.mediaSubtypes))
                        sqlite3_bind_int(statement, 6, record.isFavorite ? 1 : 0)
                        sqlite3_bind_int(statement, 7, record.isHidden ? 1 : 0)
                        sqlite3_bind_int(statement, 8, Int32(record.width))
                        sqlite3_bind_int(statement, 9, Int32(record.height))
                        sqlite3_bind_double(statement, 10, record.duration)
                        if let latitude = record.latitude {
                            sqlite3_bind_double(statement, 11, latitude)
                        } else {
                            sqlite3_bind_null(statement, 11)
                        }
                        if let longitude = record.longitude {
                            sqlite3_bind_double(statement, 12, longitude)
                        } else {
                            sqlite3_bind_null(statement, 12)
                        }
                        try stepAndReset(statement)
                    }
                    try execute("COMMIT")
                } catch {
                    try? execute("ROLLBACK")
                    throw error
                }
            }
        }
    }

    /// Asset ids still needing an embedding, oldest first so a partial run makes
    /// visible progress rather than repeatedly indexing recent photos.
    func pendingAssetIDs(limit: Int) throws -> [String] {
        try readQueue.sync {
            try withReadOrWriteDatabase {
                let statement = try prepareStatement("""
                    SELECT asset_id FROM ai_asset
                    -- `next_retry_at` applies to pending rows too, not just
                    -- failed ones. An asset that is merely not on this device
                    -- (an undownloaded iCloud original) stays *pending* while
                    -- being deferred, and honouring the retry time only for
                    -- failures made the deferral a no-op: the same asset was
                    -- selected again immediately, in a hot loop that would spin
                    -- forever on a fresh device.
                    WHERE status IN (\(Status.pending.rawValue), \(Status.failed.rawValue))
                      AND (next_retry_at IS NULL OR next_retry_at <= ?)
                    ORDER BY creation_date DESC, asset_id DESC
                    LIMIT ?
                """)
                defer { sqlite3_finalize(statement) }
                sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
                sqlite3_bind_int(statement, 2, Int32(limit))
                return try collectStrings(statement)
            }
        }
    }

    // MARK: - Embedding storage (the swap-remove contract)

    /// Stores `vector` for `assetID`, writing the matrix row and the SQLite
    /// bookkeeping in one atomic unit.
    ///
    /// Ordering matters. The matrix row is written first, then SQLite commits. A
    /// crash in between leaves a matrix row nothing points at -- wasted space
    /// that the next rebuild reclaims -- whereas the reverse order would leave a
    /// slot pointing at garbage, which is a *wrong search result*. Between
    /// "wastes space" and "returns wrong photos", always choose the former.
    @discardableResult
    func storeEmbedding(assetID: String, vector: [Float]) throws -> Int {
        try writeQueue.sync {
            try withDatabase {
                guard let writer = embeddingWriter else {
                    throw AISearchStoreError.databaseUnavailable
                }
                try execute("BEGIN IMMEDIATE")
                do {
                    let slot = try writer.append(vector)
                    let statement = try prepare("""
                        UPDATE ai_asset
                        SET embedding_slot = ?, model_version = ?, status = ?,
                            indexed_at = ?, failure_count = 0, last_error = NULL,
                            next_retry_at = NULL
                        WHERE asset_id = ?
                    """)
                    defer { sqlite3_finalize(statement) }
                    sqlite3_bind_int(statement, 1, Int32(slot))
                    try bindText(Self.modelVersion, at: 2, to: statement)
                    sqlite3_bind_int(statement, 3, Int32(Status.ready.rawValue))
                    sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
                    try bindText(assetID, at: 5, to: statement)
                    try stepAndReset(statement)
                    try execute("COMMIT")
                    return slot
                } catch {
                    try? execute("ROLLBACK")
                    throw error
                }
            }
        }
    }

    /// Removes an asset's embedding, repairing the matrix's density.
    ///
    /// This is the swap-remove contract: `swapRemove` moves the *last* row into
    /// the hole, so whichever asset owned that last slot now lives in `slot` and
    /// its SQLite row must be updated in the same transaction. Skipping that
    /// update is the bug this method exists to prevent -- it would leave two
    /// rows claiming different slots than the matrix holds, and search would
    /// attribute one photo's vector to another.
    /// Removes assets entirely: the matrix row, the FTS row and the metadata.
    ///
    /// Distinct from `removeEmbeddings`, which only releases the vector. A photo
    /// deleted from the library must leave no trace, or a search would return an
    /// asset ID PhotoKit can no longer resolve and the UI would show a gap.
    func removeAssets(assetIDs: [String]) throws {
        guard !assetIDs.isEmpty else { return }
        try removeEmbeddings(assetIDs: assetIDs)
        try writeQueue.sync {
            try withDatabase {
                try execute("BEGIN IMMEDIATE")
                do {
                    for chunk in stride(from: 0, to: assetIDs.count, by: 500).map({
                        Array(assetIDs[$0..<min($0 + 500, assetIDs.count)])
                    }) {
                        let placeholders = Array(repeating: "?", count: chunk.count)
                            .joined(separator: ",")
                        let deleteAsset = try prepare(
                            "DELETE FROM ai_asset WHERE asset_id IN (\(placeholders))"
                        )
                        defer { sqlite3_finalize(deleteAsset) }
                        for (offset, assetID) in chunk.enumerated() {
                            try bindText(assetID, at: Int32(offset + 1), to: deleteAsset)
                        }
                        try stepAndReset(deleteAsset)

                        // The FTS table is standalone rather than
                        // external-content, so it does not follow the delete.
                        let deleteText = try prepare(
                            "DELETE FROM ocr_fts WHERE asset_id IN (\(placeholders))"
                        )
                        defer { sqlite3_finalize(deleteText) }
                        for (offset, assetID) in chunk.enumerated() {
                            try bindText(assetID, at: Int32(offset + 1), to: deleteText)
                        }
                        try stepAndReset(deleteText)
                    }
                    try execute("COMMIT")
                } catch {
                    try? execute("ROLLBACK")
                    throw error
                }
            }
        }
    }

    func removeEmbeddings(assetIDs: [String]) throws {
        guard !assetIDs.isEmpty else { return }
        try writeQueue.sync {
            try withDatabase {
                guard let writer = embeddingWriter else {
                    throw AISearchStoreError.databaseUnavailable
                }
                try execute("BEGIN IMMEDIATE")
                do {
                    let lookup = try prepare(
                        "SELECT embedding_slot FROM ai_asset WHERE asset_id = ?"
                    )
                    defer { sqlite3_finalize(lookup) }
                    let relocate = try prepare(
                        "UPDATE ai_asset SET embedding_slot = ? WHERE asset_id = ?"
                    )
                    defer { sqlite3_finalize(relocate) }
                    let lastOwner = try prepare(
                        "SELECT asset_id FROM ai_asset WHERE embedding_slot = ?"
                    )
                    defer { sqlite3_finalize(lastOwner) }

                    // Deleting in descending slot order keeps every swap-remove
                    // independent: each one moves the current last row, and rows
                    // already processed sit below the shrinking boundary. Any
                    // other order can move a row that is itself awaiting removal,
                    // which is recoverable but wasteful.
                    var slots: [(assetID: String, slot: Int)] = []
                    for assetID in assetIDs {
                        sqlite3_reset(lookup)
                        sqlite3_clear_bindings(lookup)
                        try bindText(assetID, at: 1, to: lookup)
                        if sqlite3_step(lookup) == SQLITE_ROW,
                           sqlite3_column_type(lookup, 0) != SQLITE_NULL {
                            slots.append((assetID, Int(sqlite3_column_int(lookup, 0))))
                        }
                    }
                    slots.sort { $0.slot > $1.slot }

                    for entry in slots {
                        let last = writer.count - 1
                        guard entry.slot <= last else {
                            throw AISearchStoreError.embeddingSlotInconsistent(
                                "\(entry.assetID) claims slot \(entry.slot) but the matrix has \(writer.count) rows"
                            )
                        }

                        // Release the departing asset's slot *first*. The unique
                        // index on `embedding_slot` is what makes slot lookups
                        // trustworthy, and for one statement both rows would
                        // otherwise claim the same slot, so the relocation below
                        // would be rejected outright. (It was: this ordering is
                        // the bug the unique index caught on the first run.)
                        let release = try prepare("""
                            UPDATE ai_asset SET embedding_slot = NULL
                            WHERE asset_id = ?
                        """)
                        defer { sqlite3_finalize(release) }
                        try bindText(entry.assetID, at: 1, to: release)
                        try stepAndReset(release)

                        if entry.slot != last {
                            sqlite3_reset(lastOwner)
                            sqlite3_clear_bindings(lastOwner)
                            sqlite3_bind_int(lastOwner, 1, Int32(last))
                            var movedAssetID: String?
                            if sqlite3_step(lastOwner) == SQLITE_ROW,
                               let text = sqlite3_column_text(lastOwner, 0) {
                                movedAssetID = String(cString: text)
                            }
                            guard let movedAssetID else {
                                throw AISearchStoreError.embeddingSlotInconsistent(
                                    "no asset occupies the last slot \(last)"
                                )
                            }
                            sqlite3_reset(relocate)
                            sqlite3_clear_bindings(relocate)
                            sqlite3_bind_int(relocate, 1, Int32(entry.slot))
                            try bindText(movedAssetID, at: 2, to: relocate)
                            try stepAndReset(relocate)
                        }
                        try writer.swapRemove(slot: entry.slot)
                    }

                    let delete = try prepare("DELETE FROM ai_asset WHERE asset_id = ?")
                    defer { sqlite3_finalize(delete) }
                    let deleteText = try prepare("DELETE FROM ocr_fts WHERE asset_id = ?")
                    defer { sqlite3_finalize(deleteText) }
                    for assetID in assetIDs {
                        for statement in [delete, deleteText] {
                            sqlite3_reset(statement)
                            sqlite3_clear_bindings(statement)
                            try bindText(assetID, at: 1, to: statement)
                            try stepAndReset(statement)
                        }
                    }
                    try execute("COMMIT")
                } catch {
                    try? execute("ROLLBACK")
                    throw error
                }
            }
        }
    }

    func markFailed(assetID: String, error: String) throws {
        try writeQueue.sync {
            try withDatabase {
                // Exponential backoff capped at an hour: a photo that fails
                // because it is temporarily un-downloadable from iCloud should
                // be retried, but not in a tight loop.
                let statement = try prepare("""
                    UPDATE ai_asset
                    SET status = ?, failure_count = failure_count + 1,
                        last_error = ?,
                        next_retry_at = ? + MIN(3600, 30 * POWER(2, failure_count))
                    WHERE asset_id = ?
                """)
                defer { sqlite3_finalize(statement) }
                sqlite3_bind_int(statement, 1, Int32(Status.failed.rawValue))
                try bindText(String(error.prefix(500)), at: 2, to: statement)
                sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
                try bindText(assetID, at: 4, to: statement)
                try stepAndReset(statement)
            }
        }
    }

    // MARK: - OCR text

    func storeText(assetID: String, text: String?) throws {
        try writeQueue.sync {
            try withDatabase {
                try execute("BEGIN IMMEDIATE")
                do {
                    let normalized = Self.normalizeForSearch(text)
                    let update = try prepare("""
                        UPDATE ai_asset
                        SET ocr_text = ?, ocr_version = ocr_version + 1, ocr_attempted = 1
                        WHERE asset_id = ?
                    """)
                    defer { sqlite3_finalize(update) }
                    if let text {
                        try bindText(text, at: 1, to: update)
                    } else {
                        sqlite3_bind_null(update, 1)
                    }
                    try bindText(assetID, at: 2, to: update)
                    try stepAndReset(update)

                    let remove = try prepare("DELETE FROM ocr_fts WHERE asset_id = ?")
                    defer { sqlite3_finalize(remove) }
                    try bindText(assetID, at: 1, to: remove)
                    try stepAndReset(remove)

                    if let normalized, !normalized.isEmpty {
                        let insert = try prepare(
                            "INSERT INTO ocr_fts (asset_id, text) VALUES (?, ?)"
                        )
                        defer { sqlite3_finalize(insert) }
                        try bindText(assetID, at: 1, to: insert)
                        try bindText(normalized, at: 2, to: insert)
                        try stepAndReset(insert)
                    }
                    try execute("COMMIT")
                } catch {
                    try? execute("ROLLBACK")
                    throw error
                }
            }
        }
    }

    // MARK: - Resume state

    /// PhotoKit's opaque incremental-sync token.
    ///
    /// Stored so an interrupted index resumes from where it stopped instead of
    /// rescanning the library. PhotoKit owns the token's validity: when it
    /// expires `fetchPersistentChanges` throws and the caller rebuilds, which is
    /// why nothing here tries to guess whether the token is still good. A
    /// library signature (count, first and last id) looks like a cheaper check
    /// and is actively harmful -- a screenshot inserted at position 0 changes the
    /// signature, so every new screenshot would trigger a full rebuild of 100k
    /// assets.
    func changeToken() throws -> Data? {
        try readQueue.sync { try withReadOrWriteDatabase {
            guard let encoded = try readMeta("persistent_change_token") else { return nil }
            return Data(base64Encoded: encoded)
        } }
    }

    func setChangeToken(_ token: Data?) throws {
        try writeQueue.sync { try withDatabase {
            // Clearing the token is how a caller says "the token expired, do a
            // full rescan". Deleting the row rather than storing an empty string
            // keeps `changeToken()` returning nil for "no token", so the two
            // states cannot be confused.
            guard let token else {
                let statement = try prepare("DELETE FROM meta WHERE key = ?")
                defer { sqlite3_finalize(statement) }
                try bindText("persistent_change_token", at: 1, to: statement)
                try stepAndReset(statement)
                return
            }
            try setMeta("persistent_change_token", value: token.base64EncodedString())
        } }
    }

    /// Metadata for a set of assets, for a pipeline batch that already knows
    /// which ids it needs.
    ///
    /// Reads from this database rather than PhotoKit so a batch costs no
    /// framework calls beyond the image request, and so the pipeline can run
    /// with no PhotoKit involvement at all.
    func metadata(for assetIDs: [String]) throws -> [AssetMetadata] {
        guard !assetIDs.isEmpty else { return [] }
        return try readQueue.sync {
            try withReadOrWriteDatabase {
                var records: [AssetMetadata] = []
                for chunk in stride(from: 0, to: assetIDs.count, by: 500).map({
                    Array(assetIDs[$0..<min($0 + 500, assetIDs.count)])
                }) {
                    let placeholders = Array(repeating: "?", count: chunk.count)
                        .joined(separator: ",")
                    let statement = try prepareStatement("""
                        SELECT asset_id, creation_date, modification_date, media_type,
                               media_subtypes, is_favorite, is_hidden, width, height,
                               duration, latitude, longitude
                        FROM ai_asset WHERE asset_id IN (\(placeholders))
                    """)
                    defer { sqlite3_finalize(statement) }
                    for (offset, assetID) in chunk.enumerated() {
                        try bindText(assetID, at: Int32(offset + 1), to: statement)
                    }
                    while sqlite3_step(statement) == SQLITE_ROW {
                        records.append(AssetMetadata(
                            assetID: stringColumn(statement, 0) ?? "",
                            creationDate: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                            modificationDate: sqlite3_column_type(statement, 2) == SQLITE_NULL
                                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                            mediaType: Int(sqlite3_column_int(statement, 3)),
                            mediaSubtypes: Int(sqlite3_column_int(statement, 4)),
                            isFavorite: sqlite3_column_int(statement, 5) != 0,
                            isHidden: sqlite3_column_int(statement, 6) != 0,
                            width: Int(sqlite3_column_int(statement, 7)),
                            height: Int(sqlite3_column_int(statement, 8)),
                            duration: sqlite3_column_double(statement, 9),
                            latitude: sqlite3_column_type(statement, 10) == SQLITE_NULL
                                ? nil : sqlite3_column_double(statement, 10),
                            longitude: sqlite3_column_type(statement, 11) == SQLITE_NULL
                                ? nil : sqlite3_column_double(statement, 11)
                        ))
                    }
                }
                return records
            }
        }
    }

    /// Records that an asset could not be *attempted* -- an iCloud original that
    /// has not been downloaded, typically.
    ///
    /// Deliberately not `markFailed`: a failure count is a signal that something
    /// is wrong with the asset, and a photo that is merely not on this device yet
    /// is not broken. Incrementing it five times would park a perfectly good
    /// photo for hours. The asset stays pending with a retry time, so it is
    /// picked up again without ever being treated as broken.
    func deferAsset(assetID: String, until date: Date) throws {
        try writeQueue.sync { try withDatabase {
            let statement = try prepare("""
                UPDATE ai_asset SET next_retry_at = ?, last_error = ?
                WHERE asset_id = ?
            """)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            try bindText("not available on this device", at: 2, to: statement)
            try bindText(assetID, at: 3, to: statement)
            try stepAndReset(statement)
        } }
    }

    /// Folds text so that `instr()` fallback and trigram MATCH agree on what
    /// "contains" means.
    ///
    /// Delegates to `SearchTextNormalization`, which is the single definition:
    /// the two FTS paths disagreeing on whitespace or case is a bug that only
    /// shows up as a result appearing or vanishing with query length.
    static func normalizeForSearch(_ text: String?) -> String? {
        SearchTextNormalization.normalize(text)
    }

    /// Full-text search over OCR text.
    ///
    /// Tries trigram MATCH first and falls back to `instr()` for terms shorter
    /// than three characters, which the trigram tokenizer cannot match at all.
    /// Both paths are combined with AND semantics for `terms`.
    func assetIDsMatchingText(terms: [String], limit: Int) throws -> [String] {
        let normalized = terms.compactMap { Self.normalizeForSearch($0) }.filter { !$0.isEmpty }
        guard !normalized.isEmpty else { return [] }
        let useTrigram = normalized.allSatisfy { $0.count >= 3 }
        return try readQueue.sync {
            try withReadOrWriteDatabase {
                if useTrigram {
                    let match = normalized.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
                        .joined(separator: " AND ")
                    let statement = try prepareStatement(
                        "SELECT asset_id FROM ocr_fts WHERE ocr_fts MATCH ? LIMIT ?"
                    )
                    defer { sqlite3_finalize(statement) }
                    try bindText(match, at: 1, to: statement)
                    sqlite3_bind_int(statement, 2, Int32(limit))
                    return try collectStrings(statement)
                }
                // One `instr` per term, ANDed, so the plan is still a single
                // scan rather than a Swift-side intersection.
                let predicates = Array(repeating: "instr(text, ?) > 0", count: normalized.count)
                let statement = try prepareStatement("""
                    SELECT asset_id FROM ocr_fts
                    WHERE \(predicates.joined(separator: " AND "))
                    LIMIT ?
                """)
                defer { sqlite3_finalize(statement) }
                for (index, term) in normalized.enumerated() {
                    try bindText(term, at: Int32(index + 1), to: statement)
                }
                sqlite3_bind_int(statement, Int32(normalized.count + 1), Int32(limit))
                return try collectStrings(statement)
            }
        }
    }

    // MARK: - Candidate filtering

    /// Asset ids satisfying the structured half of a query plan.
    ///
    /// Text exclusions are applied here rather than left to the ranker, because
    /// "not a receipt" must remove photos, and a vector score cannot express
    /// absence.
    func candidateAssetIDs(filter: AISearchCandidateFilter) throws -> [String] {
        try readQueue.sync {
            try withReadOrWriteDatabase {
                // Candidacy is "has a vector", not "status == ready". An asset
                // that was embedded successfully and later failed a *re*-index
                // still holds a perfectly good vector; excluding it on status
                // would silently drop a searchable photo for no reason.
                //
                // The model_version guard is not cosmetic: comparing a query
                // vector against a vector from a different model produces
                // confidently wrong rankings, so rows from another model must be
                // excluded rather than ranked.
                var clauses: [String] = ["ai_asset.embedding_slot IS NOT NULL"]
                var bindings: [(Int32, SQLiteBinding)] = []
                var index: Int32 = 1
                clauses.append("ai_asset.model_version = ?")
                bindings.append((index, .text(Self.modelVersion))); index += 1

                if let after = filter.creationDateAfter {
                    clauses.append("ai_asset.creation_date >= ?")
                    bindings.append((index, .double(after.timeIntervalSince1970))); index += 1
                }
                if let before = filter.creationDateBefore {
                    clauses.append("ai_asset.creation_date < ?")
                    bindings.append((index, .double(before.timeIntervalSince1970))); index += 1
                }
                if let mediaType = filter.mediaType {
                    clauses.append("ai_asset.media_type = ?")
                    bindings.append((index, .int(Int32(mediaType)))); index += 1
                }
                if filter.favoritesOnly {
                    clauses.append("ai_asset.is_favorite = 1")
                }
                if filter.requiresLocation {
                    clauses.append("ai_asset.latitude IS NOT NULL")
                }
                if let latitude = filter.latitudeRange {
                    clauses.append("ai_asset.latitude BETWEEN ? AND ?")
                    bindings.append((index, .double(latitude.lowerBound))); index += 1
                    bindings.append((index, .double(latitude.upperBound))); index += 1
                }
                if let longitude = filter.longitudeRange {
                    clauses.append("ai_asset.longitude BETWEEN ? AND ?")
                    bindings.append((index, .double(longitude.lowerBound))); index += 1
                    bindings.append((index, .double(longitude.upperBound))); index += 1
                }

                var joins = ""
                if !filter.requiredTextTerms.isEmpty || !filter.excludedTextTerms.isEmpty {
                    joins = " JOIN ocr_fts ON ocr_fts.asset_id = ai_asset.asset_id"
                }
                for term in filter.requiredTextTerms {
                    guard let normalized = Self.normalizeForSearch(term) else { continue }
                    clauses.append("instr(ocr_fts.text, ?) > 0")
                    bindings.append((index, .text(normalized))); index += 1
                }
                for term in filter.excludedTextTerms {
                    guard let normalized = Self.normalizeForSearch(term) else { continue }
                    clauses.append("instr(ocr_fts.text, ?) = 0")
                    bindings.append((index, .text(normalized))); index += 1
                }

                let limitClause = filter.limit.map { "LIMIT \(max(1, $0))" } ?? ""
                let sql = """
                    SELECT ai_asset.asset_id FROM ai_asset\(joins)
                    WHERE \(clauses.joined(separator: " AND "))
                    ORDER BY ai_asset.creation_date DESC, ai_asset.asset_id DESC
                    \(limitClause)
                """
                let statement = try prepareStatement(sql)
                defer { sqlite3_finalize(statement) }
                for (position, binding) in bindings {
                    switch binding {
                    case .double(let value): sqlite3_bind_double(statement, position, value)
                    case .int(let value): sqlite3_bind_int(statement, position, value)
                    case .text(let value): try bindText(value, at: position, to: statement)
                    }
                }
                return try collectStrings(statement)
            }
        }
    }

    private enum SQLiteBinding {
        case double(Double)
        case int(Int32)
        case text(String)
    }

    /// Maps asset ids to their slots. Missing ids are simply absent.
    func embeddingSlots(for assetIDs: [String]) throws -> [String: Int] {
        guard !assetIDs.isEmpty else { return [:] }
        return try readQueue.sync {
            try withReadOrWriteDatabase {
                var result: [String: Int] = [:]
                // Chunked to stay under SQLite's variable limit (999 by default).
                for chunk in stride(from: 0, to: assetIDs.count, by: 500).map({
                    Array(assetIDs[$0..<min($0 + 500, assetIDs.count)])
                }) {
                    let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                    let statement = try prepareStatement("""
                        SELECT asset_id, embedding_slot FROM ai_asset
                        WHERE embedding_slot IS NOT NULL AND asset_id IN (\(placeholders))
                    """)
                    defer { sqlite3_finalize(statement) }
                    for (offset, assetID) in chunk.enumerated() {
                        try bindText(assetID, at: Int32(offset + 1), to: statement)
                    }
                    while sqlite3_step(statement) == SQLITE_ROW {
                        guard let text = sqlite3_column_text(statement, 0) else { continue }
                        result[String(cString: text)] = Int(sqlite3_column_int(statement, 1))
                    }
                }
                return result
            }
        }
    }

    // MARK: - Stats and maintenance

    func stats() throws -> AISearchIndexStats {
        try readQueue.sync {
            try withReadOrWriteDatabase {
                var stats = AISearchIndexStats()
                stats.totalAssets = try scalarInt("SELECT COUNT(*) FROM ai_asset")
                stats.embeddedAssets = try scalarInt(
                    "SELECT COUNT(*) FROM ai_asset WHERE embedding_slot IS NOT NULL"
                )
                stats.pendingAssets = try scalarInt(
                    "SELECT COUNT(*) FROM ai_asset WHERE status = \(Status.pending.rawValue)"
                )
                stats.failedAssets = try scalarInt(
                    "SELECT COUNT(*) FROM ai_asset WHERE status = \(Status.failed.rawValue)"
                )
                stats.assetsWithLocation = try scalarInt(
                    "SELECT COUNT(*) FROM ai_asset WHERE latitude IS NOT NULL"
                )
                stats.assetsWithText = try scalarInt(
                    "SELECT COUNT(*) FROM ai_asset WHERE ocr_attempted = 1 AND ocr_text IS NOT NULL"
                )
                return stats
            }
        }
    }

    /// Verifies the matrix and the SQLite slot bookkeeping agree. Cheap to run
    /// after a batch and catches the swap-remove bug class immediately instead
    /// of as a wrong photo in the UI.
    func validateSlotConsistency() throws {
        try writeQueue.sync {
            try withDatabase {
                guard let writer = embeddingWriter else {
                    throw AISearchStoreError.databaseUnavailable
                }
                let matrixCount = writer.count
                let sqliteCount = try scalarInt(
                    "SELECT COUNT(*) FROM ai_asset WHERE embedding_slot IS NOT NULL"
                )
                guard matrixCount == sqliteCount else {
                    throw AISearchStoreError.embeddingSlotInconsistent(
                        "matrix has \(matrixCount) rows, SQLite claims \(sqliteCount)"
                    )
                }
                let maxSlot = try scalarInt(
                    "SELECT COALESCE(MAX(embedding_slot), -1) FROM ai_asset"
                )
                guard maxSlot < matrixCount else {
                    throw AISearchStoreError.embeddingSlotInconsistent(
                        "highest slot \(maxSlot) is outside the matrix (\(matrixCount) rows)"
                    )
                }
            }
        }
    }

    func checkpointForBackground() {
        writeQueue.sync {
            try? execute("PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    /// Deletes the index files. Used when the schema version or model changes.
    func destroyIndexFiles() throws {
        writeQueue.sync {
            if let database { sqlite3_close(database); self.database = nil }
            if let readDatabase { sqlite3_close(readDatabase); self.readDatabase = nil }
            embeddingWriter = nil
            for url in [databaseURL,
                        URL(fileURLWithPath: databaseURL.path + "-wal"),
                        URL(fileURLWithPath: databaseURL.path + "-shm"),
                        embeddingURL] {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - SQLite plumbing

    private func withDatabase<T>(_ body: () throws -> T) throws -> T {
        if database == nil { try openDatabases() }
        return try body()
    }

    /// Read path: preferred read connection, falling back to the write
    /// connection if it cannot be used. A read must not fail merely because the
    /// second connection is unavailable.
    private func withReadOrWriteDatabase<T>(_ body: () throws -> T) throws -> T {
        if database == nil { try openDatabases() }
        do {
            try openReadIfNeeded()
            return try body()
        } catch {
            if readDatabase != nil {
                sqlite3_close(readDatabase)
                readDatabase = nil
            }
            return try body()
        }
    }

    /// Opened READWRITE on purpose: a READONLY connection cannot run WAL
    /// recovery, so after an unclean shutdown every read would fail and the
    /// screen would show an empty library rather than an error.
    private func openReadIfNeeded() throws {
        guard readDatabase == nil else { return }
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil
        )
        guard result == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw AISearchStoreError.databaseUnavailable
        }
        readDatabase = handle
        sqlite3_busy_timeout(handle, 2_000)
    }

    /// Prepares against the read connection when it exists, else the writer.
    private func prepareStatement(_ sql: String) throws -> OpaquePointer {
        let handle = readDatabase ?? database
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw AISearchStoreError.statementFailed(String(cString: sqlite3_errmsg(handle)))
        }
        return statement
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw AISearchStoreError.statementFailed(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let detail = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw AISearchStoreError.statementFailed(detail)
        }
    }

    private func scalarInt(_ sql: String) throws -> Int {
        let statement = try prepareStatement(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw AISearchStoreError.statementFailed(String(cString: sqlite3_errmsg(readDatabase ?? database)))
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func readMeta(_ key: String) throws -> String? {
        let statement = try prepare("SELECT value FROM meta WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        try bindText(key, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0)
        else { return nil }
        return String(cString: value)
    }

    private func setMeta(_ key: String, value: String) throws {
        let statement = try prepare("""
            INSERT INTO meta (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """)
        defer { sqlite3_finalize(statement) }
        try bindText(key, at: 1, to: statement)
        try bindText(value, at: 2, to: statement)
        try stepAndReset(statement)
    }

    private func bindText(_ value: String, at index: Int32, to statement: OpaquePointer) throws {
        // SQLITE_TRANSIENT: SQLite must copy, because the Swift string's buffer
        // does not outlive this call.
        guard sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK
        else { throw AISearchStoreError.statementFailed("bind failed") }
    }

    /// Steps a statement prepared on the **write** connection.
    ///
    /// The error text must come from that same connection: reading
    /// `sqlite3_errmsg` off the read connection reported a genuine UNIQUE
    /// constraint violation as "not an error", which is worse than no message.
    private func stepAndReset(_ statement: OpaquePointer) throws {
        defer { sqlite3_reset(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw AISearchStoreError.statementFailed(String(cString: sqlite3_errmsg(database)))
        }
    }

    /// A text column, or `nil` when the column is SQL NULL.
    private func stringColumn(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    private func collectStrings(_ statement: OpaquePointer) throws -> [String] {
        var values: [String] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                let handle = readDatabase ?? database
                throw AISearchStoreError.statementFailed(String(cString: sqlite3_errmsg(handle)))
            }
            if let text = sqlite3_column_text(statement, 0) {
                values.append(String(cString: text))
            }
        }
        return values
    }
}
