import Photos
import AVFoundation
import UIKit

enum PhotoRequestPriority: Int, Comparable, Sendable {
    case viewer = 0
    case slideshow = 1
    case visibleGrid = 2
    case nearGrid = 3
    case background = 4

    static func < (lhs: PhotoRequestPriority, rhs: PhotoRequestPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A cancellable request that may be waiting for a PhotoKit slot or already
/// running.  The handle deliberately hides PHImageRequestID so callers cannot
/// accidentally bypass the scheduler when a cell is reused.
final class PhotoRequestHandle: @unchecked Sendable {
    fileprivate let identifier = UUID()
}

private final class PhotoRequestScheduler: @unchecked Sendable {
    private struct PendingRequest {
        let handle: PhotoRequestHandle
        let priority: PhotoRequestPriority
        let sequence: UInt64
        let start: (@escaping () -> Void) -> PHImageRequestID
    }

    private enum ActiveRequest {
        case starting(PhotoRequestPriority)
        case running(PhotoRequestPriority, PHImageRequestID)
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
        start: @escaping (@escaping () -> Void) -> PHImageRequestID
    ) -> PhotoRequestHandle {
        let handle = PhotoRequestHandle()
        stateQueue.async { [weak self] in
            guard let self else { return }
            sequence &+= 1
            pending.append(PendingRequest(
                handle: handle,
                priority: priority,
                sequence: sequence,
                start: start
            ))
            drain()
        }
        return handle
    }

    func cancel(_ handle: PhotoRequestHandle?) {
        guard let handle else { return }
        stateQueue.async { [weak self] in
            guard let self else { return }
            pending.removeAll { $0.handle.identifier == handle.identifier }
            if let activeRequest = active.removeValue(forKey: handle.identifier),
               case .running(_, let requestID) = activeRequest {
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
                case .running(let requestPriority, let requestID):
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
                case .running(let requestPriority, let requestID):
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

    private func complete(_ identifier: UUID) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            guard active.removeValue(forKey: identifier) != nil else { return }
            drain()
        }
    }

    private func drain() {
        while active.count < maximumConcurrentRequests,
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

            let requestID = request.start { [weak self] in
                self?.complete(request.handle.identifier)
            }

            guard requestID != PHInvalidImageRequestID else {
                active.removeValue(forKey: request.handle.identifier)
                continue
            }
            // The result handler is asynchronous because all callers use
            // isSynchronous = false, so the starting state is safe here.
            if active[request.handle.identifier] != nil {
                active[request.handle.identifier] = .running(request.priority, requestID)
            } else {
                imageManager.cancelImageRequest(requestID)
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
    private let imageCache = NSCache<NSString, UIImage>()

    private init() {
        // Only the small number of full-size slideshow look-ahead images are
        // retained here. Grid requests do not opt into this cache, so a
        // 100k-photo library cannot fill it while scrolling.
        imageCache.countLimit = 6
        imageCache.totalCostLimit = 96 * 1024 * 1024
        scheduler = PhotoRequestScheduler(imageManager: manager)
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
        progressHandler: ((Double, Error?, UnsafeMutablePointer<ObjCBool>, [AnyHashable: Any]?) -> Void)? = nil,
        completion: @escaping (UIImage?, [AnyHashable: Any]?) -> Void
    ) -> PhotoRequestHandle {
        let cacheKey = imageCacheKey(
            for: asset,
            targetSize: targetSize,
            contentMode: contentMode
        )
        if let cachedImage = imageCache.object(forKey: cacheKey) {
            let handle = PhotoRequestHandle()
            completion(cachedImage, [PHImageResultIsDegradedKey: false])
            return handle
        }

        return scheduler.submit(priority: priority) { [weak self] finish in
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
                completion(image, info)

                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let hasError = info?[PHImageErrorKey] != nil
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if cacheResult,
                   let image,
                   !cancelled,
                   !hasError,
                   !degraded {
                    self.imageCache.setObject(
                        image,
                        forKey: cacheKey,
                        cost: self.imageCacheCost(image)
                    )
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
        scheduler.cancelRequests(atOrBelow: .nearGrid)
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
        scheduler.submit(priority: priority) { [weak self] finish in
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
        scheduler.submit(priority: priority) { [weak self] finish in
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
