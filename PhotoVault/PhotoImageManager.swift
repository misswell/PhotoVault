import Foundation
import Photos
import AVFoundation
import UIKit

#if DEBUG
import os

private let photoVaultLogger = Logger(
    subsystem: "com.misswell.PhotoVault",
    category: "photo-pipeline"
)
private let photoVaultFileLogQueue = DispatchQueue(
    label: "com.misswell.PhotoVault.photo-diagnostics",
    qos: .utility
)

/// Debug-only diagnostics that are visible in the device console and retained
/// in the app container so the request lifecycle can be inspected after a
/// reproduction. The log intentionally contains no image data. OSLog and the
/// sandbox file are the retrieval paths; printing to stdout from the main
/// thread during scroll measurably janks the lists, so it is skipped.
func photoVaultTrace(_ message: @autoclosure () -> String) {
    let text = message()
    let line = "[PhotoVault] [\(Date().timeIntervalSince1970)] \(text)"
    photoVaultLogger.notice("\(text, privacy: .public)")

    photoVaultFileLogQueue.async {
        let fileManager = FileManager.default
        guard let cachesURL = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else { return }
        let logURL = cachesURL.appendingPathComponent(
            "PhotoVaultDiagnostics.log",
            isDirectory: false
        )

        if let attributes = try? fileManager.attributesOfItem(atPath: logURL.path),
           let size = attributes[.size] as? NSNumber,
           size.intValue > 512_000 {
            try? fileManager.removeItem(at: logURL)
        }

        let data = Data((line + "\n").utf8)
        if fileManager.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }
}
#else
@inline(__always)
func photoVaultTrace(_ message: @autoclosure () -> String) { }
#endif

#if DEBUG
/// Milliseconds since the first PhotoKit/Vault code ran in this process.
///
/// Launch-time work is a chain of PhotoKit XPC round trips, and the whole
/// point of measuring it is to find which one is slow on a cold `photolibraryd`.
/// Wall-clock `Date()` alone cannot answer that, so every launch trace carries
/// this offset.
enum PhotoVaultLaunchClock {
    private static let start = ProcessInfo.processInfo.systemUptime
    static var elapsedMilliseconds: Int {
        Int(((ProcessInfo.processInfo.systemUptime - start) * 1000).rounded())
    }
}

/// Launch-phase trace: same sink as `photoVaultTrace`, prefixed with the
/// elapsed time so a single grep reconstructs the startup timeline.
///
/// Launch traces also go to their own file, `Library/Caches/PhotoVaultLaunch.log`,
/// where each process appends one delimited block. The shared diagnostics log
/// is capped at 512 KB and a busy grid refills that in well under a minute, so
/// by the time a slow launch is worth investigating the timeline has usually
/// rotated away.
func photoVaultTraceLaunch(_ message: @autoclosure () -> String) {
    let text = "[launch pid=\(ProcessInfo.processInfo.processIdentifier) "
        + "+\(PhotoVaultLaunchClock.elapsedMilliseconds)ms] \(message())"
    photoVaultTrace(text)
    photoVaultLaunchLogQueue.async {
        guard let cachesURL = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else { return }
        let logURL = cachesURL.appendingPathComponent(
            "PhotoVaultLaunch.log",
            isDirectory: false
        )
        let fileManager = FileManager.default
        // Keep a handful of launches so a slow one can be compared against a
        // fast one without having to reproduce it on demand.
        if let attributes = try? fileManager.attributesOfItem(atPath: logURL.path),
           let size = attributes[.size] as? NSNumber,
           size.intValue > 256_000 {
            try? fileManager.removeItem(at: logURL)
        }

        let isFirstLine = photoVaultLaunchLogState.claimHeader()
        let header = isFirstLine
            ? "\n===== launch \(ISO8601DateFormatter().string(from: Date())) =====\n"
            : ""
        let data = Data((header + text + "\n").utf8)
        if fileManager.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }
}

private let photoVaultLaunchLogQueue = DispatchQueue(
    label: "com.misswell.PhotoVault.launchLog",
    qos: .utility
)

/// Lets the first write of each process emit the block header without racing
/// the other launch traces already queued behind it.
private final class PhotoVaultLaunchLogState: @unchecked Sendable {
    private let lock = NSLock()
    private var didWriteHeader = false

    func claimHeader() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if didWriteHeader { return false }
        didWriteHeader = true
        return true
    }
}

private let photoVaultLaunchLogState = PhotoVaultLaunchLogState()
#else
@inline(__always)
func photoVaultTraceLaunch(_ message: @autoclosure () -> String) { }
#endif

private func photoVaultShortID(_ identifier: UUID) -> String {
    String(identifier.uuidString.prefix(8))
}

func photoVaultShortAssetID(_ identifier: String) -> String {
    String(identifier.prefix(8))
}

enum PhotoRequestPriority: Int, Comparable, Sendable {
    case viewer = 0
    case slideshow = 1
    case photoGrid = 2
    case visibleGrid = 3
    case nearGrid = 4
    case background = 5

    static func < (lhs: PhotoRequestPriority, rhs: PhotoRequestPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum PhotoImageCacheScope: Sendable, Equatable {
    case standard
    case albumThumbnail
    /// Recycled grid / filmstrip thumbnails. Their target sizes are bucketed
    /// (160/256/384/512) so the same asset is asked for with the same key
    /// across zoom levels, and the cache is bounded by cost so a 100k-photo
    /// library can never grow it without limit.
    case gridThumbnail
}

/// PhotoKit may deliver image results on the main thread, so a decode performed
/// inside the result handler can block the UI. Decoding is therefore moved onto
/// a small set of serial lanes: requests that share an asset and size always
/// land on the same lane, which preserves the opportunistic (degraded → full
/// quality) delivery order while still decoding different assets in parallel.
private final class PhotoDecodeLanes: @unchecked Sendable {
    private let queues: [DispatchQueue]

    init() {
        let processorCount = ProcessInfo.processInfo.activeProcessorCount
        let laneCount = max(2, min(4, processorCount - 1))
        queues = (0..<laneCount).map { index in
            DispatchQueue(
                label: "com.misswell.PhotoVault.photo-decode.\(index)",
                qos: .userInitiated
            )
        }
    }

    /// Carries a non-Sendable closure across the decode-lane queue hop. The
    /// work only touches `NSCache` (internally synchronized) and the request's
    /// own captured values, so the transfer is intentional.
    private struct DecodeWork: @unchecked Sendable {
        let run: () -> Void
    }

    func enqueue(for key: NSString, _ work: @escaping () -> Void) {
        var hasher = Hasher()
        hasher.combine(key)
        let lane = abs(hasher.finalize()) % queues.count
        let box = DecodeWork(run: work)
        queues[lane].async { box.run() }
    }
}

/// A cancellable request that may be waiting for a PhotoKit slot or already
/// running.  The handle deliberately hides PHImageRequestID so callers cannot
/// accidentally bypass the scheduler when a cell is reused.
final class PhotoRequestHandle: @unchecked Sendable {
    fileprivate let identifier = UUID()
}

private final class PhotoRequestScheduler: @unchecked Sendable {
    /// Transports a captured function value into the scheduler's serial queue.
    /// The value is only ever invoked on `stateQueue`/the main actor, so the
    /// transfer is intentional and this box just makes it explicit.
    private struct SendableBox<Value>: @unchecked Sendable {
        let value: Value
    }

    private struct PendingRequest {
        let handle: PhotoRequestHandle
        let priority: PhotoRequestPriority
        let sequence: UInt64
        let start: (@escaping () -> Void, @escaping () -> Void) -> PHImageRequestID
    }

    private enum ActiveRequest {
        case starting(PhotoRequestPriority)
        case running(PhotoRequestPriority, PHImageRequestID, countsTowardLimit: Bool)
    }

    private let stateQueue = DispatchQueue(
        label: "com.misswell.PhotoVault.photo-request-scheduler",
        qos: .userInitiated
    )
    private let imageManager: PHCachingImageManager
    private let maximumConcurrentRequests = 6
    private var pending: [PendingRequest] = []
    private var active: [UUID: ActiveRequest] = [:]
    private var sequence: UInt64 = 0

    init(imageManager: PHCachingImageManager) {
        self.imageManager = imageManager
    }

    func submit(
        priority: PhotoRequestPriority,
        start: @escaping (@escaping () -> Void, @escaping () -> Void) -> PHImageRequestID
    ) -> PhotoRequestHandle {
        let handle = PhotoRequestHandle()
        let boxedStart = SendableBox(value: start)
        stateQueue.async { [weak self] in
            guard let self else { return }
            sequence &+= 1
            pending.append(PendingRequest(
                handle: handle,
                priority: priority,
                sequence: sequence,
                start: boxedStart.value
            ))
            photoVaultTrace(
                "scheduler enqueue id=\(photoVaultShortID(handle.identifier)) "
                    + "priority=\(priority) pending=\(pending.count) "
                    + "active=\(active.count) occupied=\(occupiedSlotCount)"
            )
            drain()
        }
        return handle
    }

    func cancel(_ handle: PhotoRequestHandle?) {
        guard let handle else { return }
        stateQueue.async { [weak self] in
            guard let self else { return }
            photoVaultTrace(
                "scheduler cancel id=\(photoVaultShortID(handle.identifier)) "
                    + "pending=\(pending.count) active=\(active.count)"
            )
            pending.removeAll { $0.handle.identifier == handle.identifier }
            if let activeRequest = active.removeValue(forKey: handle.identifier),
               case .running(_, let requestID, _) = activeRequest {
                imageManager.cancelImageRequest(requestID)
            }
            drain()
        }
    }

    func cancelRequests(atOrBelow priority: PhotoRequestPriority) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            pending.removeAll { $0.priority >= priority }

            let identifiersToCancel = active.compactMap { identifier, request -> UUID? in
                switch request {
                case .starting(let requestPriority):
                    return requestPriority >= priority ? identifier : nil
                case .running(let requestPriority, let requestID, _):
                    guard requestPriority >= priority else { return nil }
                    imageManager.cancelImageRequest(requestID)
                    return identifier
                }
            }
            for identifier in identifiersToCancel {
                active.removeValue(forKey: identifier)
            }
            drain()
        }
    }

    func cancelRequests(exactly priority: PhotoRequestPriority) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            pending.removeAll { $0.priority == priority }

            let identifiersToCancel = active.compactMap { identifier, request -> UUID? in
                switch request {
                case .starting(let requestPriority):
                    return requestPriority == priority ? identifier : nil
                case .running(let requestPriority, let requestID, _):
                    guard requestPriority == priority else { return nil }
                    imageManager.cancelImageRequest(requestID)
                    return identifier
                }
            }
            for identifier in identifiersToCancel {
                active.removeValue(forKey: identifier)
            }
            drain()
        }
    }

    var activeRequestCount: Int {
        stateQueue.sync { active.count }
    }

    /// A PhotoKit opportunistic request can deliver a usable degraded image
    /// and keep working on the cloud version for an unbounded amount of time.
    /// Keep that request in `active` so a cell can still cancel it, but stop
    /// counting it against the scheduler's short-lived start limit.
    private func releaseSlot(_ identifier: UUID) {
        stateQueue.async { [weak self] in
            guard let self,
                  let activeRequest = active[identifier]
            else { return }

            guard case .running(let priority, let requestID, let countsTowardLimit) = activeRequest,
                  countsTowardLimit
            else { return }

            active[identifier] = .running(
                priority,
                requestID,
                countsTowardLimit: false
            )
            photoVaultTrace(
                "scheduler release-slot id=\(photoVaultShortID(identifier)) "
                    + "priority=\(priority) active=\(active.count) "
                    + "occupied=\(occupiedSlotCount)"
            )
            drain()
        }
    }

    private func complete(_ identifier: UUID) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            guard active.removeValue(forKey: identifier) != nil else { return }
            photoVaultTrace(
                "scheduler complete id=\(photoVaultShortID(identifier)) "
                    + "active=\(active.count) occupied=\(occupiedSlotCount)"
            )
            drain()
        }
    }

    private func drain() {
        while occupiedSlotCount < maximumConcurrentRequests,
              !pending.isEmpty {
            let nextIndex = pending.indices.min { lhs, rhs in
                let left = pending[lhs]
                let right = pending[rhs]
                if left.priority != right.priority {
                    return left.priority < right.priority
                }
                return left.sequence < right.sequence
            }!
            let request = pending.remove(at: nextIndex)
            active[request.handle.identifier] = .starting(request.priority)
            photoVaultTrace(
                "scheduler start id=\(photoVaultShortID(request.handle.identifier)) "
                    + "priority=\(request.priority) pending=\(pending.count) "
                    + "active=\(active.count) occupied=\(occupiedSlotCount)"
            )

            let requestID = request.start(
                { [weak self] in
                    self?.complete(request.handle.identifier)
                },
                { [weak self] in
                    self?.releaseSlot(request.handle.identifier)
                }
            )

            guard requestID != PHInvalidImageRequestID else {
                active.removeValue(forKey: request.handle.identifier)
                photoVaultTrace(
                    "scheduler invalid-request id=\(photoVaultShortID(request.handle.identifier))"
                )
                continue
            }
            // The result handler is asynchronous because all callers use
            // isSynchronous = false, so the starting state is safe here.
            if active[request.handle.identifier] != nil {
                active[request.handle.identifier] = .running(
                    request.priority,
                    requestID,
                    countsTowardLimit: true
                )
            } else {
                imageManager.cancelImageRequest(requestID)
            }
        }
    }

    private var occupiedSlotCount: Int {
        active.values.reduce(into: 0) { count, request in
            switch request {
            case .starting:
                count += 1
            case .running(_, _, let countsTowardLimit):
                if countsTowardLimit {
                    count += 1
                }
            }
        }
    }
}

final class PhotoImageManager {
    // PHCachingImageManager is internally synchronized; all access here is
    // intentionally centralized through this one shared cache owner.
    nonisolated(unsafe) static let shared = PhotoImageManager()

    private let manager = PHCachingImageManager()
    private let scheduler: PhotoRequestScheduler
    private let decodeLanes = PhotoDecodeLanes()
    private let imageCache = NSCache<NSString, UIImage>()
    private let albumThumbnailCache = NSCache<NSString, UIImage>()
    private let gridThumbnailCache = NSCache<NSString, UIImage>()

    private init() {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        let gibibyte = UInt64(1_024 * 1_024 * 1_024)
        let standardCacheLimit: Int
        let albumCacheLimit: Int
        let gridCacheLimit: Int
        // The viewer keeps the current page plus its neighbors resident. The
        // cost limit is what actually bounds memory; the count limit only has
        // to be large enough that the ±1 window is never evicted by count
        // before the cost budget is reached.
        let standardCountLimit: Int
        let albumCountLimit: Int
        let gridCountLimit: Int
        if physicalMemory <= 4 * gibibyte {
            standardCacheLimit = 48 * 1_024 * 1_024
            albumCacheLimit = 16 * 1_024 * 1_024
            gridCacheLimit = 24 * 1_024 * 1_024
            standardCountLimit = 8
            albumCountLimit = 128
            gridCountLimit = 600
        } else if physicalMemory <= 6 * gibibyte {
            standardCacheLimit = 64 * 1_024 * 1_024
            albumCacheLimit = 16 * 1_024 * 1_024
            gridCacheLimit = 36 * 1_024 * 1_024
            standardCountLimit = 10
            albumCountLimit = 192
            gridCountLimit = 900
        } else {
            standardCacheLimit = 80 * 1_024 * 1_024
            albumCacheLimit = 16 * 1_024 * 1_024
            gridCacheLimit = 48 * 1_024 * 1_024
            standardCountLimit = 12
            albumCountLimit = 256
            gridCountLimit = 1_200
        }

        // Only the small number of full-size viewer and slideshow look-ahead
        // images are retained in the standard cache. Grid requests use the
        // separate grid cache below, so a 100k-photo library cannot fill this
        // one while scrolling.
        imageCache.countLimit = standardCountLimit
        imageCache.totalCostLimit = standardCacheLimit

        // Album rows display one small preview per album. Keep this cache
        // bounded independently from viewer images so revisiting a list does
        // not start a new PhotoKit request for every row, while still putting
        // a hard ceiling on memory for unusually large album collections.
        albumThumbnailCache.countLimit = albumCountLimit
        albumThumbnailCache.totalCostLimit = albumCacheLimit

        // Recycled grid and filmstrip thumbnails. Without this, every reuse
        // cleared the cell, spun an activity indicator and issued a fresh
        // PhotoKit request even for a photo the user had just scrolled past.
        // NSCache also evicts automatically under memory pressure.
        gridThumbnailCache.countLimit = gridCountLimit
        gridThumbnailCache.totalCostLimit = gridCacheLimit

        scheduler = PhotoRequestScheduler(imageManager: manager)
    }

    private func cache(for scope: PhotoImageCacheScope) -> NSCache<NSString, UIImage> {
        switch scope {
        case .standard:
            return imageCache
        case .albumThumbnail:
            return albumThumbnailCache
        case .gridThumbnail:
            return gridThumbnailCache
        }
    }

    /// Synchronous, request-free cache probe. Recycled cells call this before
    /// asking PhotoKit so an already-decoded thumbnail is shown in the same
    /// frame, with no placeholder and no activity indicator.
    func cachedImage(
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        scope: PhotoImageCacheScope
    ) -> UIImage? {
        cache(for: scope).object(
            forKey: imageCacheKey(
                for: asset,
                targetSize: targetSize,
                contentMode: contentMode
            )
        )
    }

    @discardableResult
    func requestImage(
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        deliveryMode: PHImageRequestOptionsDeliveryMode = .opportunistic,
        resizeMode: PHImageRequestOptionsResizeMode = .fast,
        priority: PhotoRequestPriority = .visibleGrid,
        isNetworkAccessAllowed: Bool = true,
        cacheResult: Bool = false,
        cacheScope: PhotoImageCacheScope = .standard,
        progressHandler: ((Double, Error?, UnsafeMutablePointer<ObjCBool>, [AnyHashable: Any]?) -> Void)? = nil,
        completion: @escaping (UIImage?, [AnyHashable: Any]?) -> Void
    ) -> PhotoRequestHandle {
        let cache = cache(for: cacheScope)

        let cacheKey = imageCacheKey(
            for: asset,
            targetSize: targetSize,
            contentMode: contentMode
        )
        if let cachedImage = cache.object(forKey: cacheKey) {
            photoVaultTrace(
                "image cache-hit asset=\(photoVaultShortAssetID(asset.localIdentifier)) "
                    + "priority=\(priority) scope=\(cacheScope)"
            )
            let handle = PhotoRequestHandle()
            completion(cachedImage, [PHImageResultIsDegradedKey: false])
            return handle
        }

        photoVaultTrace(
            "image request asset=\(photoVaultShortAssetID(asset.localIdentifier)) "
                + "priority=\(priority) delivery=\(deliveryMode) "
                + "network=\(isNetworkAccessAllowed) scope=\(cacheScope)"
        )

        return scheduler.submit(priority: priority) { [weak self] finish, releaseSlot in
            guard let self else { return PHInvalidImageRequestID }
            let options = PHImageRequestOptions()
            options.deliveryMode = deliveryMode
            options.resizeMode = resizeMode
            options.isNetworkAccessAllowed = isNetworkAccessAllowed
            options.isSynchronous = false
            options.progressHandler = progressHandler
            options.version = .current

            return self.manager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: contentMode,
                options: options
            ) { image, info in
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let hasError = info?[PHImageErrorKey] != nil
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                photoVaultTrace(
                    "image callback asset=\(photoVaultShortAssetID(asset.localIdentifier)) "
                        + "priority=\(priority) degraded=\(degraded) "
                        + "cancelled=\(cancelled) error=\(hasError) "
                        + "hasImage=\(image != nil)"
                )
                if deliveryMode == .opportunistic, degraded {
                    releaseSlot()
                }

                // Album and grid thumbnails are fixed-size buckets, so a
                // degraded frame is still worth keeping: the next recycle of
                // that cell can then render instantly instead of waiting for
                // PhotoKit. Full-size viewer images are only cached once the
                // high-quality frame arrives.
                let shouldCacheImage = cacheResult
                    && (cacheScope != .standard || !degraded)

                // PhotoKit can hand back a lazily-decoded UIImage and may call
                // this handler on the main thread. Decode on a lane so the UI
                // is never blocked, then deliver from there; callers already
                // hop to the main actor.
                self.decodeLanes.enqueue(for: cacheKey) {
                    let preparedImage = image?.preparingForDisplay() ?? image
                    if shouldCacheImage,
                       let preparedImage,
                       !cancelled,
                       !hasError {
                        cache.setObject(
                            preparedImage,
                            forKey: cacheKey,
                            cost: self.imageCacheCost(preparedImage)
                        )
                    }
                    completion(preparedImage, info)
                }

                if cancelled || hasError || !degraded {
                    finish()
                }
            }
        }
    }

    func cancel(_ handle: PhotoRequestHandle?) {
        scheduler.cancel(handle)
    }

    /// Stop queued and running work at or below the supplied priority. The
    /// app uses this when backgrounding so the current viewer page can remain
    /// responsive while grid and look-ahead work is released.
    func cancelRequests(atOrBelow priority: PhotoRequestPriority) {
        scheduler.cancelRequests(atOrBelow: priority)
    }

    func cancelRequests(exactly priority: PhotoRequestPriority) {
        scheduler.cancelRequests(exactly: priority)
    }

    /// Kept for the small number of legacy call sites while they migrate to
    /// handles. New image, Live Photo and video requests must use handles.
    func cancel(_ requestID: PHImageRequestID) {
        guard requestID != PHInvalidImageRequestID else { return }
        manager.cancelImageRequest(requestID)
    }

    var activeRequestCount: Int {
        scheduler.activeRequestCount
    }

    /// Ask PhotoKit for the actual display-sized image ahead of time. Unlike
    /// startCachingImages, this has a completion and explicitly waits for the
    /// high-quality iCloud result before putting it in the small image cache.
    @discardableResult
    func prefetchImage(
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        priority: PhotoRequestPriority = .slideshow,
        completion: ((UIImage?, [AnyHashable: Any]?) -> Void)? = nil
    ) -> PhotoRequestHandle {
        requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: contentMode,
            deliveryMode: .highQualityFormat,
            resizeMode: .exact,
            priority: priority,
            isNetworkAccessAllowed: true,
            cacheResult: true,
            completion: { image, info in
                completion?(image, info)
            }
        )
    }

    func startCaching(
        asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFill,
        isNetworkAccessAllowed: Bool = false
    ) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = isNetworkAccessAllowed
        manager.startCachingImages(
            for: [asset],
            targetSize: targetSize,
            contentMode: contentMode,
            options: options
        )
    }

    func startCaching(
        assets: [PHAsset],
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFill,
        isNetworkAccessAllowed: Bool = false
    ) {
        guard !assets.isEmpty else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = isNetworkAccessAllowed
        manager.startCachingImages(
            for: assets,
            targetSize: targetSize,
            contentMode: contentMode,
            options: options
        )
    }

    func stopCaching(
        asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFill,
        isNetworkAccessAllowed: Bool = false
    ) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = isNetworkAccessAllowed
        manager.stopCachingImages(
            for: [asset],
            targetSize: targetSize,
            contentMode: contentMode,
            options: options
        )
    }

    func stopCaching(
        assets: [PHAsset],
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFill,
        isNetworkAccessAllowed: Bool = false
    ) {
        guard !assets.isEmpty else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = isNetworkAccessAllowed
        manager.stopCachingImages(
            for: assets,
            targetSize: targetSize,
            contentMode: contentMode,
            options: options
        )
    }

    func stopCachingAll() {
        manager.stopCachingImagesForAllAssets()
        imageCache.removeAllObjects()
        albumThumbnailCache.removeAllObjects()
        gridThumbnailCache.removeAllObjects()
        scheduler.cancelRequests(atOrBelow: .viewer)
    }

    /// Frees viewer and grid decode caches when the app leaves the foreground.
    /// Only the album-thumbnail cache is kept, as the project's memory rule
    /// requires: it is capped at 16 MB so returning to the app shows the
    /// sidebar and album tiles without refetching, while the much larger grid
    /// cache is released so a backgrounded app never holds tens of megabytes
    /// of decoded thumbnails and risks a jetsam kill.
    /// Callers reach this only on a real .background transition, not on
    /// .inactive (Control Center, banners, app-switcher pass-throughs).
    func dropTransientCaches() {
        manager.stopCachingImagesForAllAssets()
        imageCache.removeAllObjects()
        gridThumbnailCache.removeAllObjects()
        scheduler.cancelRequests(atOrBelow: .viewer)
    }

    private func imageCacheKey(
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode
    ) -> NSString {
        "\(asset.localIdentifier)|\(Int(targetSize.width.rounded()))x\(Int(targetSize.height.rounded()))|\(contentMode.rawValue)" as NSString
    }

    private func imageCacheCost(_ image: UIImage) -> Int {
        let width = max(1, Int((image.size.width * image.scale).rounded()))
        let height = max(1, Int((image.size.height * image.scale).rounded()))
        return min(Int.max / 4, width * height * 4)
    }

    @discardableResult
    func requestLivePhoto(
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFit,
        priority: PhotoRequestPriority = .viewer,
        isNetworkAccessAllowed: Bool = true,
        completion: @escaping (PHLivePhoto?, [AnyHashable: Any]?) -> Void
    ) -> PhotoRequestHandle {
        scheduler.submit(priority: priority) { [weak self] finish, releaseSlot in
            guard let self else { return PHInvalidImageRequestID }
            let options = PHLivePhotoRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = isNetworkAccessAllowed

            return self.manager.requestLivePhoto(
                for: asset,
                targetSize: targetSize,
                contentMode: contentMode,
                options: options
            ) { livePhoto, info in
                completion(livePhoto, info)
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let hasError = info?[PHImageErrorKey] != nil
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if degraded {
                    releaseSlot()
                }
                if cancelled || hasError || livePhoto != nil || !degraded {
                    finish()
                }
            }
        }
    }

    @discardableResult
    func requestPlayerItem(
        for asset: PHAsset,
        priority: PhotoRequestPriority = .viewer,
        isNetworkAccessAllowed: Bool = true,
        completion: @escaping (AVPlayerItem?, [AnyHashable: Any]?) -> Void
    ) -> PhotoRequestHandle {
        scheduler.submit(priority: priority) { [weak self] finish, _ in
            guard let self else { return PHInvalidImageRequestID }
            let options = PHVideoRequestOptions()
            options.deliveryMode = .automatic
            options.isNetworkAccessAllowed = isNetworkAccessAllowed
            options.version = .current

            return self.manager.requestPlayerItem(
                forVideo: asset,
                options: options
            ) { item, info in
                completion(item, info)
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let hasError = info?[PHImageErrorKey] != nil
                if cancelled || hasError || item != nil {
                    finish()
                }
            }
        }
    }
}
