//
//  PhotoKitIndexSource.swift
//  PhotoVault
//
//  The PhotoKit side of indexing: keeps the search index's metadata in step with
//  the photo library, and supplies decoded images to the pipeline.
//
//  This file is deliberately the thinnest layer in the whole feature. Everything
//  that can be got wrong -- scheduling, retries, backoff, thermal policy,
//  supersession -- lives in `PhotoIndexPipeline`, which has no PhotoKit
//  dependency and is covered by tests. What is left here is framework glue that
//  cannot be tested without a device and a real library, so it is kept small
//  enough to read in one sitting.
//
//  The incremental rule
//  --------------------
//  Sync is driven by `PHPersistentChangeToken`, and PhotoKit alone decides
//  whether the token is still valid: when it has expired,
//  `fetchPersistentChanges` throws and this falls back to a full scan.
//
//  What must *not* be reintroduced is a library signature -- comparing counts or
//  first/last identifiers to decide whether a rescan is needed. It looks like a
//  cheaper validity check and is actively harmful: a screenshot inserted at
//  position 0 changes the signature, so every new screenshot would trigger a full
//  rebuild of 100k assets. That failure mode is invisible in a small test library
//  and obvious on a real one, which is exactly why it is written down here.
//

import Foundation
import Photos
import CoreGraphics
// `UIImage.cgImage` is the only reason this is here; without it the image
// request's completion type cannot be resolved at all.
import UIKit

enum PhotoKitIndexSourceError: LocalizedError {
    case accessDenied
    case assetFetchFailed

    var errorDescription: String? {
        switch self {
        case .accessDenied: "photo library access is not available"
        case .assetFetchFailed: "the photo library could not be read"
        }
    }
}

struct PhotoMetadataSyncResult: Equatable, Sendable {
    var inserted: Int = 0
    var updated: Int = 0
    var deleted: Int = 0
    /// `true` when the change token had expired and the library was rescanned.
    var didFullScan = false
    /// `true` when access is limited, so the index only covers the selection.
    var isLimited = false
}

// ---------------------------------------------------------------------------
// MARK: - Metadata sync

/// Brings the index's metadata into step with the library.
///
/// Metadata is synced separately from embedding on purpose. A metadata row is
/// cheap and always safe to refresh; an embedding costs a model evaluation. Doing
/// them together would mean a favourite toggle re-embeds the photo.
struct PhotoKitMetadataSync {

    private let store: AIPhotoSearchStore
    /// Inserted and updated assets are read back in chunks. PhotoKit's
    /// identifier fetch takes a list, and a 100k-element list is not a request
    /// anyone should make.
    let identifierChunkSize = 400

    init(store: AIPhotoSearchStore) {
        self.store = store
    }

    /// PhotoKit access level, so the caller can tell the user what is indexed.
    static var isLimited: Bool {
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited
    }

    /// Runs an incremental sync, falling back to a full scan when the token has
    /// expired.
    @discardableResult
    func sync() throws -> PhotoMetadataSyncResult {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw PhotoKitIndexSourceError.accessDenied
        }
        var result = PhotoMetadataSyncResult(isLimited: status == .limited)

        guard let storedData = try store.changeToken(),
              let storedToken = Self.unarchive(storedData)
        else {
            // Either there is no token yet, or it is present but unreadable.
            // Both mean a full scan is the only correct action.
            try fullScan(into: &result)
            return result
        }

        do {
            let fetch = try PHPhotoLibrary.shared().fetchPersistentChanges(since: storedToken)
            var isFirst = true
            // `PHPersistentChangeFetchResult` is enumerated incrementally; each
            // change carries its own token, so the newest one is kept rather
            // than the fetch result's.
            for change in fetch {
                try apply(change, into: &result)
                isFirst = false
            }
            if isFirst {
                // No changes: still record the token PhotoKit reports, which may
                // have advanced even with nothing to apply. Skipping this would
                // re-examine the same range on every launch.
                try store.setChangeToken(try currentToken())
            } else {
                try store.setChangeToken(try currentToken())
            }
        } catch {
            // An expired token is expected after a restore or a long gap, and is
            // the only correct trigger for a full rescan. Any other error is
            // reported rather than silently escalated into a rescan.
            try store.setChangeToken(nil)
            result = PhotoMetadataSyncResult(isLimited: Self.isLimited)
            try fullScan(into: &result)
        }
        return result
    }

    /// The token representing the library's current state, archived for storage.
    ///
    /// `PHPersistentChangeToken` is `NSSecureCoding` rather than `Data`, so it is
    /// archived instead of copied. Storing raw bits would work until the class
    /// changes its encoding, and then fail as an unreadable token rather than as
    /// an error.
    private func currentToken() throws -> Data? {
        try Self.archive(PHPhotoLibrary.shared().currentChangeToken)
    }

    static func archive(_ token: PHPersistentChangeToken) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    static func unarchive(_ data: Data) -> PHPersistentChangeToken? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: data)
    }

    private func apply(_ change: PHPersistentChange, into result: inout PhotoMetadataSyncResult) throws {
        let details = try change.changeDetails(for: .asset)
        // Deletions first: an asset deleted and re-created with the same
        // identifier would otherwise be removed *after* being re-added, leaving a
        // hole in the index that no later sync would fill.
        if !details.deletedLocalIdentifiers.isEmpty {
            try store.removeAssets(assetIDs: Array(details.deletedLocalIdentifiers))
            result.deleted += details.deletedLocalIdentifiers.count
        }
        result.inserted += try ingest(identifiers: Array(details.insertedLocalIdentifiers), into: &result)
        result.updated += try ingest(identifiers: Array(details.updatedLocalIdentifiers), into: &result)
        try store.setChangeToken(try Self.archive(change.changeToken))
    }

    /// Reads identifiers back as metadata, newest first, without materialising
    /// the whole library.
    @discardableResult
    private func ingest(identifiers: [String], into result: inout PhotoMetadataSyncResult) throws -> Int {
        guard !identifiers.isEmpty else { return 0 }
        var count = 0
        for chunk in stride(from: 0, to: identifiers.count, by: identifierChunkSize).map({
            Array(identifiers[$0..<min($0 + identifierChunkSize, identifiers.count)])
        }) {
            // A PHFetchResult, not an array: the result stays lazy even for a
            // large chunk, and this project never materialises the library.
            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: chunk, options: nil)
            var records: [AIPhotoSearchStore.AssetMetadata] = []
            records.reserveCapacity(fetch.count)
            fetch.enumerateObjects { asset, _, _ in
                records.append(Self.metadata(for: asset))
            }
            try store.upsertMetadata(records)
            count += records.count
        }
        return count
    }

    /// A full library scan, used only when the token has expired.
    private func fullScan(into result: inout PhotoMetadataSyncResult) throws {
        result.didFullScan = true
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let fetch = PHAsset.fetchAssets(with: options)
        result.inserted += fetch.count

        var records: [AIPhotoSearchStore.AssetMetadata] = []
        records.reserveCapacity(min(fetch.count, 2_000))
        fetch.enumerateObjects { asset, index, _ in
            records.append(Self.metadata(for: asset))
            // Written in chunks so a 100k library never exists as one array.
            if records.count >= 2_000 || index == fetch.count - 1 {
                try? self.store.upsertMetadata(records)
                records.removeAll(keepingCapacity: true)
            }
        }
        try store.setChangeToken(try currentToken())
    }

    static func metadata(for asset: PHAsset) -> AIPhotoSearchStore.AssetMetadata {
        AIPhotoSearchStore.AssetMetadata(
            assetID: asset.localIdentifier,
            creationDate: asset.creationDate ?? Date(),
            modificationDate: asset.modificationDate,
            mediaType: asset.mediaType == .video ? 2 : 1,
            mediaSubtypes: Int(asset.mediaSubtypes.rawValue),
            isFavorite: asset.isFavorite,
            isHidden: asset.isHidden,
            width: asset.pixelWidth,
            height: asset.pixelHeight,
            duration: asset.duration,
            latitude: asset.location?.coordinate.latitude,
            longitude: asset.location?.coordinate.longitude
        )
    }
}

// ---------------------------------------------------------------------------
// MARK: - Pending work

/// Supplies the pipeline with assets that still need work.
///
/// Reads the store rather than PhotoKit, which is what makes resume-after-kill
/// work: "what is left" survives a process death because it lives in SQLite, not
/// in memory.
struct PhotoKitPendingSource: PendingAssetProviding {
    let store: AIPhotoSearchStore

    func pendingAssets(limit: Int) throws -> [IndexableAsset] {
        let identifiers = try store.pendingAssetIDs(limit: limit)
        guard !identifiers.isEmpty else { return [] }
        // Metadata comes back from the store, so a batch needs no PhotoKit call
        // at all beyond the image request itself.
        let records = try store.metadata(for: identifiers)
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.assetID, $0) })
        return identifiers.compactMap { identifier in
            guard let metadata = byID[identifier] else { return nil }
            return IndexableAsset(metadata: metadata)
        }
    }

    func totalAssetCount() throws -> Int {
        try store.stats().totalAssets
    }
}

// ---------------------------------------------------------------------------
// MARK: - Image loading

/// Decodes an asset for embedding.
final class PhotoKitImageLoader: AssetImageLoading, @unchecked Sendable {

    private let manager: PHImageManager
    /// The model consumes 256x256, so there is no reason to materialise a 12 MP
    /// original: PhotoKit can deliver a correctly sized image far more cheaply,
    /// and on an iCloud library it avoids downloading the full asset.
    let targetSize: CGSize

    init(manager: PHImageManager = .default(), targetSize: CGSize = CGSize(width: 256, height: 256)) {
        self.manager = manager
        self.targetSize = targetSize
    }

    func image(for asset: IndexableAsset) throws -> CGImage? {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [asset.assetID], options: nil)
        guard let photo = fetch.firstObject else { return nil }

        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.isNetworkAccessAllowed = true
        // The model must see the unmodified photo. PhotoKit's automatic
        // adjustment would embed an edited image that does not match what the
        // user sees, and would differ between devices.
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact

        var result: CGImage?
        var isUnavailable = false
        manager.requestImage(
            for: photo, targetSize: targetSize, contentMode: .aspectFit, options: options
        ) { image, info in
            let details: [AnyHashable: Any] = info ?? [:]
            if details[PHImageResultIsDegradedKey] as? Bool == true { return }
            if details[PHImageResultIsInCloudKey] as? Bool == true, image == nil {
                isUnavailable = true
                return
            }
            result = image?.cgImage
        }
        if result == nil && isUnavailable { return nil }
        return result
    }
}

// ---------------------------------------------------------------------------
// MARK: - Conformances

extension SigLIP2VisionEncoder: AssetEmbedding {}

// `PhotoTextRecognizer` already declares exactly this method, so the conformance
// is empty by design: restating it here would call itself.
extension PhotoTextRecognizer: AssetTextRecognizing {}
