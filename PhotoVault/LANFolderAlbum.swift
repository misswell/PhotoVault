import CryptoKit
import Foundation
import ImageIO
import os
import UIKit
import UniformTypeIdentifiers

/// DEBUG breadcrumbs for the folder access chain (resolve → scope →
/// enumerate): written to OSLog AND to a sandbox file
/// (Library/Caches/PhotoVault/lan-folder.log, size-capped) so a device run
/// can be pulled with devicectl and matched against the user's report.
enum LANFolderDiagnostics {
    #if DEBUG
    private static let logger = Logger(subsystem: "com.misswell.PhotoVault", category: "LANFolder")
    private static let lock = NSLock()
    private static let maxBytes = 256 * 1024
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func log(_ message: String) {
        logger.log("\(message, privacy: .public)")
        appendToFile(message)
    }

    private static func appendToFile(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return
        }
        let directory = caches.appendingPathComponent("PhotoVault", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("lan-folder.log")
        var data = (try? Data(contentsOf: fileURL)) ?? Data()
        if data.count > maxBytes {
            data = Data(data.suffix(maxBytes / 2))
            if let newline = data.range(of: Data("\n".utf8)) {
                data.removeSubrange(data.startIndex..<newline.lowerBound)
            }
        }
        data.append(Data("\(timestampFormatter.string(from: Date())) \(message)\n".utf8))
        try? data.write(to: fileURL, options: .atomic)
    }
    #else
    static func log(_ message: String) {}
    #endif
}

/// A folder the user picked through the Files app (an SMB/NAS share, a
/// network drive, iCloud, anything Files can reach) and wants treated as one
/// album. Access survives relaunches through a security-scoped bookmark; if
/// the underlying share is gone the bookmark fails to resolve and the folder
/// must be re-added.
struct LANFolderAlbum: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    var bookmark: Data
    var addedAt: Date
}

enum LANFolderLibrary {
    static let storageKey = "PhotoVault.lanFolders.v1"

    static func load() -> [LANFolderAlbum] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([LANFolderAlbum].self, from: data)) ?? []
    }

    static func save(_ folders: [LANFolderAlbum]) {
        guard let data = try? JSONEncoder().encode(folders) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    /// Outcome of an add: one physical folder keeps exactly one entry, so a
    /// re-pick of an already-registered folder refreshes that entry's
    /// bookmark (a fresh pick carries a fresh access grant) and prunes older
    /// duplicates instead of appending another row.
    struct AddResult: Sendable {
        enum Outcome: Sendable {
            case added
            case duplicate(LANFolderAlbum)
        }

        let outcome: Outcome
        /// The authoritative list after the add — the caller's state must be
        /// replaced with this, since pruning may have removed older rows.
        let folders: [LANFolderAlbum]
    }

    /// Creates a persisted security-scoped bookmark for the picked folder.
    /// Resolving stored bookmarks is a provider round trip each, so the
    /// matching runs off the main thread and a dead share cannot hang the
    /// picker callback.
    static func add(from pickedURL: URL) async -> AddResult? {
        guard let bookmark = try? pickedURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return nil }
        let candidate = LANFolderAlbum(
            id: UUID(),
            name: pickedURL.lastPathComponent,
            bookmark: bookmark,
            addedAt: .now
        )
        let pickedPath = pickedURL.standardizedFileURL.path

        return await Task.detached(priority: .userInitiated) {
            var kept: [LANFolderAlbum] = []
            var seenPaths = Set<String>()
            var duplicate: LANFolderAlbum?
            for folder in load() {
                guard let storedPath = resolve(folder)?.standardizedFileURL.path else {
                    kept.append(folder)
                    continue
                }
                if storedPath == pickedPath {
                    // The entry matching the pick is the one being reused —
                    // keep it; only later same-path rows get pruned below.
                    if duplicate == nil { duplicate = folder }
                    kept.append(folder)
                    seenPaths.insert(storedPath)
                    continue
                }
                // A stored entry resolving to an already-seen path is a
                // historical duplicate of an earlier row — drop it.
                guard seenPaths.insert(storedPath).inserted else { continue }
                kept.append(folder)
            }
            if let duplicate {
                // The fresh pick carries a fresh access grant: refresh the
                // stored bookmark so a folder whose scope restoration went
                // stale heals with one re-pick instead of delete + re-add.
                var healed = duplicate
                healed.bookmark = bookmark
                healed.name = candidate.name
                healed.addedAt = candidate.addedAt
                kept = kept.map { $0.id == healed.id ? healed : $0 }
                save(kept)
                return AddResult(outcome: .duplicate(healed), folders: kept)
            }
            kept.append(candidate)
            save(kept)
            return AddResult(outcome: .added, folders: kept)
        }.value
    }

    /// Launches the file-provider daemons for every registered folder in the
    /// background. Grant restoration can fail while a provider daemon is
    /// still coming up after a cold start, so touching them when the folder
    /// list opens keeps the first folder tap from racing the mount. This is
    /// fire-and-forget — a failed warm-up is silently retried by the next
    /// entry, and the entry flow itself falls back to re-authorization.
    static func warmScopes() async {
        let folders = load()
        guard !folders.isEmpty else { return }
        await Task.detached(priority: .utility) {
            for folder in folders {
                guard let url = resolve(folder) else { continue }
                LANFolderScopeManager.shared.activate(id: folder.id, url: url)
            }
        }.value
    }


    /// When the security scope is denied, this probes the remaining system
    /// access paths for the folder — a coordinated read through
    /// NSFileCoordinator is the provider-negotiation channel and can reach
    /// content that `startAccessingSecurityScopedResource` refused. Inside a
    /// successful coordinated read the scope is registered as held for the
    /// session, so the caller can enumerate and display content normally.
    /// Every step is logged for device-side diagnosis.
    static func coordinatedEnumerate(id: UUID, url: URL) -> [URL]? {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        let intent = NSFileAccessIntent.readingIntent(with: url, options: [])
        var result: [URL]?
        let queue = OperationQueue()
        let done = DispatchSemaphore(value: 0)

        coordinator.coordinate(with: [intent], queue: queue) { error in
            defer { done.signal() }
            if let error {
                LANFolderDiagnostics.log("coordinated read denied: \(error.localizedDescription)")
                return
            }
            LANFolderDiagnostics.log("coordinated read granted")
            // The coordination channel is what the provider honors here —
            // enumerate inside it regardless of the startAccessing BOOL
            // (this provider refuses startAccessing while granting
            // coordinated access; observed on device).
            let scope = url.startAccessingSecurityScopedResource()
            if scope {
                LANFolderScopeManager.shared.noteScopeHeld(id: id, url: url)
            }
            result = LANFolderImageLoader.enumerateImageFiles(under: url)
            LANFolderDiagnostics.log(
                "coordinated enumerated \(result?.count ?? 0) files (startAccessing=\(scope))"
            )
        }
        done.wait()
        return result
    }

    /// Resolves the bookmark back to a usable folder URL, or nil when the
    /// share is unreachable and the entry needs re-adding.
    static func resolve(_ album: LANFolderAlbum) -> URL? {
        var stale = false
        let url = try? URL(
            resolvingBookmarkData: album.bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        if url == nil {
            LANFolderDiagnostics.log("resolve failed for \(album.name)")
        } else if stale {
            LANFolderDiagnostics.log("resolved \(album.name): bookmark STALE")
        }
        return url
    }

    /// A stale bookmark still resolves, but providers sometimes stop
    /// serving that resolved path after a remount (share reconnect, USB
    /// re-plug). Re-anchoring the persisted bookmark while the security
    /// scope is held heals those entries; a refresh that fails leaves the
    /// stored bookmark untouched.
    static func refreshBookmarkIfStale(_ album: LANFolderAlbum, resolvedURL: URL) {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: album.bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ), stale,
        let refreshed = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }

        var folders = load()
        guard let index = folders.firstIndex(where: { $0.id == album.id }) else { return }
        var updated = album
        updated.bookmark = refreshed
        folders[index] = updated
        save(folders)
    }
}

/// Holds security-scoped access for picked folders for the whole app
/// session. Re-acquiring the scope on every screen visit means repeated
/// file-provider round trips against the share, which presented as a frozen
/// album on re-entry; the references are reclaimed when the process ends.
final class LANFolderScopeManager: @unchecked Sendable {
    static let shared = LANFolderScopeManager()

    private struct ActiveScope {
        let url: URL
        var started: Bool
    }

    private var active: [UUID: ActiveScope] = [:]
    private let lock = NSLock()

    /// Idempotent: activating an already-active folder is a no-op. Returns
    /// whether the security scope is held — a `false` means file-provider
    /// content is unreachable and the caller must not treat the folder as
    /// (or cache it as) empty, nor refresh its bookmark from this URL: a
    /// bookmark minted without a held scope carries no credentials and
    /// permanently downgrades the stored one.
    @discardableResult
    func activate(id: UUID, url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let existing = active[id] {
            guard existing.url != url || !existing.started else { return existing.started }
            if existing.started {
                existing.url.stopAccessingSecurityScopedResource()
            }
        }
        let started = url.startAccessingSecurityScopedResource()
        active[id] = ActiveScope(url: url, started: started)
        return started
    }

    /// Records a scope that was started through another path (e.g. inside an
    /// NSFileCoordinator accessor) so the session-held bookkeeping stays
    /// accurate without a second startAccessing call.
    func noteScopeHeld(id: UUID, url: URL) {
        lock.lock()
        defer { lock.unlock() }
        active[id] = ActiveScope(url: url, started: true)
    }
}

enum LANFolderImageLoader {
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "webp",
        "bmp", "tif", "tiff", "dng",
    ]

    /// Lists image files under the folder recursively, newest modification
    /// first. Runs off the main thread at the call site; the caller must
    /// hold the folder's security scope via `LANFolderScopeManager`. Each
    /// entry hits the provider over SMB, so the caller should wrap this in
    /// a timeout instead of letting a dead share spin forever.
    static func enumerateImageFiles(under folderURL: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .contentTypeKey,
                .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var files: [(url: URL, date: Date?)] = []
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            // Extension match first: querying the content type of every
            // entry on an SMB share is a network round trip per file.
            guard imageExtensions.contains(ext) else {
                let values = try? fileURL.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .contentTypeKey,
                    .contentModificationDateKey,
                ])
                guard values?.isRegularFile == true,
                      values?.contentType?.conforms(to: .image) == true
                else { continue }
                files.append((fileURL, values?.contentModificationDate))
                continue
            }
            let values = try? fileURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .contentModificationDateKey,
            ])
            // A failed per-file attribute fetch must not drop the file:
            // file providers hand out the directory listing but fail the
            // per-file queries while reconnecting, which used to enumerate
            // a folder full of images down to zero files. Only a confirmed
            // non-file (directory named "*.jpg") is skipped.
            guard values?.isRegularFile != false else { continue }
            files.append((fileURL, values?.contentModificationDate))
        }

        return files
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            .map(\.url)
    }

    /// Downscaled decode through ImageIO. A full-resolution decode of a 50MP
    /// file inside a grid cell is exactly the main-thread hitch we never
    /// allow; callers run this off the main actor. The read is wrapped in an
    /// NSFileCoordinator coordinated access — the channel file providers
    /// honor even where startAccessing-based scope is refused.
    static func image(at url: URL, maxPixelSize: CGFloat) -> UIImage? {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        let intent = NSFileAccessIntent.readingIntent(with: url, options: [])
        var decoded: UIImage?
        let done = DispatchSemaphore(value: 0)
        let queue = OperationQueue()

        coordinator.coordinate(with: [intent], queue: queue) { error in
            defer { done.signal() }
            if let error {
                LANFolderDiagnostics.log("image coordinated read denied: \(error.localizedDescription)")
                return
            }
            decoded = decodeImage(at: url, maxPixelSize: maxPixelSize)
        }
        done.wait()
        return decoded
    }

    private static func decodeImage(at url: URL, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            decodeOptions as CFDictionary
        ) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// NSCache-backed image access for LAN folder screens. NSCache is thread
/// safe and evicts automatically under memory pressure; the cost limit keeps
/// a few thousand decoded thumbnails from ever pinning hundreds of MB.
final class LANFolderImageCache: @unchecked Sendable {
    static let shared = LANFolderImageCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 400
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func image(forKey key: NSString) -> UIImage? {
        cache.object(forKey: key)
    }

    func store(_ image: UIImage, forKey key: NSString) {
        cache.setObject(image, forKey: key, cost: Self.decodedCost(image))
    }

    private static func decodedCost(_ image: UIImage) -> Int {
        let width = max(1, Int(image.size.width * image.scale))
        let height = max(1, Int(image.size.height * image.scale))
        return min(Int.max / 4, width * height * 4)
    }
}

/// On-disk thumbnail cache under Caches, keyed by the file's path relative
/// to its album root plus its modification date. A few thousand source
/// images must not be re-decoded on every visit: the first pass pays one
/// downscale per file, every later visit reads small JPEGs straight from
/// disk. Caches is purgeable, so this never counts against user data.
enum LANFolderThumbnailDiskCache {
    private static func directory(for folderID: UUID) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = caches
            .appendingPathComponent("PhotoVault", isDirectory: true)
            .appendingPathComponent("lan-thumbnails", isDirectory: true)
            .appendingPathComponent(folderID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private static func fileURL(
        for source: URL,
        folderID: UUID,
        rootURL: URL,
        modificationDate: Date?,
        maxPixelSize: CGFloat
    ) -> URL {
        let relativePath: String
        if source.path.hasPrefix(rootURL.path) {
            relativePath = String(source.path.dropFirst(rootURL.path.count))
        } else {
            relativePath = source.path
        }
        // Mount points of removable media can change between sessions, so
        // the stable identity is the path inside the album plus mtime.
        let digest = Insecure.MD5.hash(data: Data(relativePath.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let mtime = Int(modificationDate?.timeIntervalSince1970 ?? 0)
        return directory(for: folderID)
            .appendingPathComponent("\(digest)-\(mtime)-\(Int(maxPixelSize)).jpg")
    }

    static func image(
        for source: URL,
        folderID: UUID,
        rootURL: URL,
        maxPixelSize: CGFloat
    ) -> UIImage? {
        let modificationDate = try? source.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate
        let diskURL = fileURL(
            for: source,
            folderID: folderID,
            rootURL: rootURL,
            modificationDate: modificationDate,
            maxPixelSize: maxPixelSize
        )
        if let cached = UIImage(contentsOfFile: diskURL.path) {
            return cached
        }
        guard let decoded = LANFolderImageLoader.image(
            at: source,
            maxPixelSize: maxPixelSize
        ) else { return nil }
        let payload = decoded.jpegData(compressionQuality: 0.72)
        if let payload {
            try? payload.write(to: diskURL, options: .atomic)
        }
        return decoded
    }

    /// Drops a removed album's thumbnails from Caches.
    static func purge(folderID: UUID) {
        let directory = directory(for: folderID)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// A cancellation flag a detached queue job can poll: scrolling cells cancel
/// their tasks, and decode slots must not be spent on off-screen images.
final class LANFolderCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Bounded loader for LAN/local/USB folder images. Source files can be tens
/// of MB and reads may be SMB network round trips: unbounded concurrent
/// decodes once starved Swift's cooperative thread pool and froze the entire
/// app, and repeated screen visits queued duplicate work for the same files.
/// Loads are therefore coalesced per file, capped at three concurrent
/// decodes, fronted by a disk thumbnail cache, and the gate wait times out
/// so a poisoned slot can never back the queue up forever. Cancellation is
/// polled by the queue job so off-screen cells release their slots.
enum LANFolderImageLoaderQueue {
    private static let lock = NSLock()
    // Guarded by `lock`.
    nonisolated(unsafe) private static var waiters: [NSString: [(UIImage?) -> Void]] = [:]
    nonisolated(unsafe) private static var inFlight: Set<NSString> = []

    private static let queue = DispatchQueue(
        label: "com.misswell.PhotoVault.lan-image-load",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private static let loadGate = DispatchSemaphore(value: 3)
    private static let gateTimeout: TimeInterval = 45

    static func load(
        at url: URL,
        folderID: UUID,
        rootURL: URL,
        maxPixelSize: CGFloat
    ) async -> UIImage? {
        let flag = LANFolderCancellationFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
                let key: NSString = "\(url.path)#\(Int(maxPixelSize))" as NSString
                if let cached = LANFolderImageCache.shared.image(forKey: key) {
                    continuation.resume(returning: cached)
                    return
                }
                lock.lock()
                waiters[key, default: []].append { image in
                    continuation.resume(returning: image)
                }
                let shouldStart = inFlight.insert(key).inserted
                lock.unlock()

                guard shouldStart else { return }
                queue.async {
                    process(
                        key: key,
                        url: url,
                        folderID: folderID,
                        rootURL: rootURL,
                        maxPixelSize: maxPixelSize,
                        flag: flag
                    )
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }

    private static func process(
        key: NSString,
        url: URL,
        folderID: UUID,
        rootURL: URL,
        maxPixelSize: CGFloat,
        flag: LANFolderCancellationFlag
    ) {
        var image: UIImage?
        if !flag.isCancelled,
           loadGate.wait(timeout: .now() + gateTimeout) == .success {
            if flag.isCancelled {
                loadGate.signal()
            } else {
                image = LANFolderThumbnailDiskCache.image(
                    for: url,
                    folderID: folderID,
                    rootURL: rootURL,
                    maxPixelSize: maxPixelSize
                )
                loadGate.signal()
                if let image {
                    LANFolderImageCache.shared.store(image, forKey: key)
                }
            }
        }
        finish(key: key, image: image)
    }

    private static func finish(key: NSString, image: UIImage?) {
        lock.lock()
        let callbacks = waiters.removeValue(forKey: key) ?? []
        inFlight.remove(key)
        lock.unlock()
        if let image {
            LANFolderImageCache.shared.store(image, forKey: key)
        }
        callbacks.forEach { $0(image) }
    }
}

/// Races blocking work against a timeout entirely on GCD threads: the first
/// finisher wins and the caller resumes immediately. The loser's work keeps
/// running in the background (blocking SMB traversals ignore cancellation),
/// so the caller must not wait on it — a task-group implementation that
/// awaits both children would never return for a hung share.
enum LANFolderTimeout {
    private final class ResultBox<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T?
        private var finished = false

        /// Returns true when this call is the first finisher.
        func finish(_ newValue: T) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if finished { return false }
            value = newValue
            finished = true
            return true
        }

        /// Returns true when this call is the first finisher (a timeout).
        func markTimedOut() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if finished { return false }
            finished = true
            return true
        }

        func takeIfFinished() -> T? {
            lock.lock()
            defer { lock.unlock() }
            return finished ? value : nil
        }
    }

    static func run<T: Sendable>(
        seconds: Double,
        _ work: @escaping @Sendable () -> T
    ) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let box = ResultBox<T>()
            let semaphore = DispatchSemaphore(value: 0)

            DispatchQueue.global(qos: .userInitiated).async {
                let value = work()
                if box.finish(value) {
                    semaphore.signal()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if box.markTimedOut() {
                    semaphore.signal()
                }
            }
            DispatchQueue.global().async {
                semaphore.wait()
                continuation.resume(returning: box.takeIfFinished())
            }
        }
    }
}

/// Session-scoped enumeration results. Re-entering a folder replays the
/// cached list instead of traversing the SMB share again — the repeat-visit
/// freeze was overlapping full traversals stacked on a timeout that never
/// actually fired.
enum LANFolderSessionCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var filesByFolder: [UUID: [URL]] = [:]

    static func files(for id: UUID) -> [URL]? {
        lock.lock()
        defer { lock.unlock() }
        return filesByFolder[id]
    }

    static func store(files: [URL], for id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        filesByFolder[id] = files
    }
}
