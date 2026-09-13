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
    private static let fileURL: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches
            .appendingPathComponent("PhotoVault", isDirectory: true)
            .appendingPathComponent("lan-folder.log")
    }()
    /// Held open for append. The previous implementation read the whole file
    /// (up to 256 KB) and rewrote it atomically under the lock on *every* log
    /// line, which could stall whichever thread happened to log — including
    /// the main thread.
    nonisolated(unsafe) private static var handle: FileHandle?
    nonisolated(unsafe) private static var currentSize = 0

    static func log(_ message: @autoclosure () -> String) {
        let message = message()
        logger.log("\(message, privacy: .public)")
        appendToFile(message)
    }

    private static func openHandle() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        currentSize = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size])
            .flatMap { $0 as? NSNumber }?
            .intValue ?? 0
        _ = try? handle?.seekToEnd()
    }

    private static func appendToFile(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        if handle == nil {
            openHandle()
        }

        let line = Data("\(timestampFormatter.string(from: Date())) \(message)\n".utf8)
        if currentSize + line.count > maxBytes {
            // Trim once per cap crossing (keeping the tail) instead of on
            // every line.
            try? handle?.close()
            handle = nil
            if let existing = try? Data(contentsOf: fileURL) {
                var trimmed = Data(existing.suffix(maxBytes / 2))
                if let newline = trimmed.range(of: Data("\n".utf8)) {
                    trimmed.removeSubrange(trimmed.startIndex..<newline.lowerBound)
                }
                try? trimmed.write(to: fileURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: fileURL)
            }
            openHandle()
        }

        guard let handle else { return }
        do {
            try handle.write(contentsOf: line)
            currentSize += line.count
        } catch {
            try? handle.close()
            self.handle = nil
        }
    }
    #else
    static func log(_ message: @autoclosure () -> String) {}
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
        let result = LANFolderImageLoader.CoordinatedResult<[URL]>()
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
            let enumerated = LANFolderImageLoader.enumerateImageFiles(under: url)
            LANFolderDiagnostics.log(
                "coordinated enumerated \(enumerated.count) files (startAccessing=\(scope))"
            )
            result.store(enumerated)
        }
        _ = done.wait(timeout: .now() + LANFolderImageLoader.coordinatedReadTimeout)
        return result.load()
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
    ///
    /// `startAccessingSecurityScopedResource` is a provider round trip, so it
    /// deliberately runs outside the lock: holding it made a folder tap while
    /// `warmScopes` was running block until the whole warm-up finished, and
    /// that wait sat inside the enumeration timeout.
    @discardableResult
    func activate(id: UUID, url: URL) -> Bool {
        lock.lock()
        if let existing = active[id] {
            if existing.url == url, existing.started {
                lock.unlock()
                return true
            }
        }
        lock.unlock()

        let started = url.startAccessingSecurityScopedResource()

        lock.lock()
        if let existing = active[id],
           existing.started,
           existing.url != url {
            // A different URL replaced this entry while we were starting;
            // release the previous grant (it belongs to the same folder).
            existing.url.stopAccessingSecurityScopedResource()
        }
        active[id] = ActiveScope(url: url, started: started)
        lock.unlock()
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
    /// Carries a value out of an `NSFileCoordinator` accessor. The accessor
    /// runs on the coordinator's own queue while the caller waits on a
    /// semaphore; a plain captured `var` there is a data race as far as the
    /// compiler is concerned, so the hand-off goes through this box.
    final class CoordinatedResult<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value?

        func store(_ newValue: Value?) {
            lock.lock()
            value = newValue
            lock.unlock()
        }

        func load() -> Value? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "webp",
        "bmp", "tif", "tiff", "dng",
    ]

    /// A coordinated read that has not handed back its block in this long is
    /// treated as a wedged provider. Waiting forever used to burn one of the
    /// three decode slots for the lifetime of the process.
    static let coordinatedReadTimeout: TimeInterval = 20

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
                LANFolderThumbnailDiskCache.recordModificationDate(
                    values?.contentModificationDate,
                    for: fileURL
                )
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
            // Hand the mtime we already paid for to the thumbnail cache, so a
            // disk-cache lookup never has to ask the provider again.
            LANFolderThumbnailDiskCache.recordModificationDate(
                values?.contentModificationDate,
                for: fileURL
            )
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
    /// honor even where startAccessing-based scope is refused. The wait is
    /// bounded: a wedged provider must not pin a decode slot for the rest of
    /// the process, which used to starve every later image load.
    static func image(at url: URL, maxPixelSize: CGFloat) -> UIImage? {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        let intent = NSFileAccessIntent.readingIntent(with: url, options: [])
        let decoded = CoordinatedResult<UIImage>()
        let done = DispatchSemaphore(value: 0)
        let queue = OperationQueue()

        coordinator.coordinate(with: [intent], queue: queue) { error in
            defer { done.signal() }
            if let error {
                LANFolderDiagnostics.log("image coordinated read denied: \(error.localizedDescription)")
                return
            }
            decoded.store(decodeImage(at: url, maxPixelSize: maxPixelSize))
        }
        // NSFileCoordinator guarantees the block eventually runs; if the
        // provider is wedged it may take much longer than a user will wait.
        _ = done.wait(timeout: .now() + coordinatedReadTimeout)
        return decoded.load()
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
///
/// Grid thumbnails (512px, ~1 MB) and viewer/slideshow frames (2048px,
/// ~12 MB) live in separate caches. Sharing one budget let a viewer's
/// current+2 prefetch evict the entire grid working set, so returning from
/// the viewer re-decoded every visible thumbnail over SMB.
final class LANFolderImageCache: @unchecked Sendable {
    static let shared = LANFolderImageCache()

    private let thumbnailCache = NSCache<NSString, UIImage>()
    private let fullSizeCache = NSCache<NSString, UIImage>()

    private init() {
        thumbnailCache.countLimit = 400
        thumbnailCache.totalCostLimit = 64 * 1024 * 1024
        // Room for the viewer's current page and its two neighbours, plus a
        // little slack; full-screen frames are the expensive ones.
        fullSizeCache.countLimit = 6
        fullSizeCache.totalCostLimit = 72 * 1024 * 1024
    }

    func image(forKey key: NSString, isFullSize: Bool = false) -> UIImage? {
        (isFullSize ? fullSizeCache : thumbnailCache).object(forKey: key)
    }

    func store(_ image: UIImage, forKey key: NSString, isFullSize: Bool = false) {
        (isFullSize ? fullSizeCache : thumbnailCache).setObject(
            image,
            forKey: key,
            cost: Self.decodedCost(image)
        )
    }

    /// Drops decoded LAN images. Called when the app backgrounds: unlike the
    /// PhotoKit caches there is no PHCachingImageManager backing this, and
    /// the budget is large enough to matter under memory pressure.
    func removeAll() {
        thumbnailCache.removeAllObjects()
        fullSizeCache.removeAllObjects()
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
    /// Modification dates observed during enumeration. Enumeration already
    /// pays one provider round trip per file for these values; re-asking on
    /// every thumbnail lookup made even a fully disk-cached folder wait on
    /// three concurrent SMB stat calls.
    private static let mtimeLock = NSLock()
    nonisolated(unsafe) private static var knownModificationDates: [String: Date] = [:]
    private static let knownModificationDateLimit = 32_768

    static func recordModificationDate(_ date: Date?, for source: URL) {
        guard let date else { return }
        mtimeLock.lock()
        if knownModificationDates.count >= knownModificationDateLimit {
            knownModificationDates.removeAll(keepingCapacity: true)
        }
        knownModificationDates[source.path] = date
        mtimeLock.unlock()
    }

    private static func knownModificationDate(for source: URL) -> Date? {
        mtimeLock.lock()
        defer { mtimeLock.unlock() }
        return knownModificationDates[source.path]
    }

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
        // Prefer the mtime enumeration already resolved; fall back to one
        // provider query only when this file was never enumerated.
        let modificationDate = knownModificationDate(for: source) ?? (try? source.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate)
        let diskURL = fileURL(
            for: source,
            folderID: folderID,
            rootURL: rootURL,
            modificationDate: modificationDate,
            maxPixelSize: maxPixelSize
        )
        if let cached = UIImage(contentsOfFile: diskURL.path) {
            // UIImage(contentsOfFile:) is lazy; decode here, on the loader's
            // queue, instead of at first draw on the main thread.
            return cached.preparingForDisplay() ?? cached
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

/// One `load` call's slot in the coalesced job. Resuming is idempotent, so a
/// cancelled task and the finishing job can never resume the continuation
/// twice.
private final class LANFolderLoadWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UIImage?, Never>?

    init(_ continuation: CheckedContinuation<UIImage?, Never>) {
        self.continuation = continuation
    }

    func resume(with image: UIImage?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: image)
    }
}

/// Bounded loader for LAN/local/USB folder images. Source files can be tens
/// of MB and reads may be SMB network round trips: unbounded concurrent
/// decodes once starved Swift's cooperative thread pool and froze the entire
/// app, and repeated screen visits queued duplicate work for the same files.
/// Loads are therefore coalesced per file, capped at three concurrent
/// decodes, fronted by a disk thumbnail cache, and the gate wait times out
/// so a poisoned slot can never back the queue up forever.
///
/// Cancelling one cell only detaches that cell's waiter; it must never abort
/// the job the other waiters are still attached to.
enum LANFolderImageLoaderQueue {
    private static let lock = NSLock()
    // Guarded by `lock`.
    nonisolated(unsafe) private static var waiters: [NSString: [LANFolderLoadWaiter]] = [:]
    nonisolated(unsafe) private static var inFlight: Set<NSString> = []

    private static let queue = DispatchQueue(
        label: "com.misswell.PhotoVault.lan-image-load",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private static let loadGate = DispatchSemaphore(value: 3)
    private static let gateTimeout: TimeInterval = 45

    /// Bridges a cancelled Swift task to the waiter it registered inside the
    /// continuation body, which is not otherwise reachable from `onCancel`.
    private final class WaiterBox: @unchecked Sendable {
        private let lock = NSLock()
        private var waiter: LANFolderLoadWaiter?
        private var key: NSString?

        func set(waiter: LANFolderLoadWaiter, key: NSString) {
            lock.lock()
            self.waiter = waiter
            self.key = key
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            let waiter = self.waiter
            let key = self.key
            lock.unlock()
            guard let waiter, let key else { return }
            LANFolderImageLoaderQueue.detach(waiter, key: key)
            waiter.resume(with: nil)
        }
    }

    private static func detach(_ waiter: LANFolderLoadWaiter, key: NSString) {
        lock.lock()
        if var remaining = waiters[key] {
            remaining.removeAll { $0 === waiter }
            if remaining.isEmpty {
                waiters.removeValue(forKey: key)
            } else {
                waiters[key] = remaining
            }
        }
        lock.unlock()
    }

    private static func hasWaiters(for key: NSString) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return waiters[key]?.isEmpty == false
    }

    /// Display-sized frames (viewer, slideshow) are an order of magnitude
    /// larger than grid thumbnails and get their own cache budget.
    static let fullSizeThreshold: CGFloat = 1_024

    static func load(
        at url: URL,
        folderID: UUID,
        rootURL: URL,
        maxPixelSize: CGFloat
    ) async -> UIImage? {
        let isFullSize = maxPixelSize > fullSizeThreshold
        let box = WaiterBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
                let key: NSString = "\(url.path)#\(Int(maxPixelSize))" as NSString
                if let cached = LANFolderImageCache.shared.image(
                    forKey: key,
                    isFullSize: isFullSize
                ) {
                    continuation.resume(returning: cached)
                    return
                }
                let waiter = LANFolderLoadWaiter(continuation)
                box.set(waiter: waiter, key: key)
                lock.lock()
                waiters[key, default: []].append(waiter)
                let shouldStart = inFlight.insert(key).inserted
                lock.unlock()

                guard shouldStart else { return }
                // Capture the value type, not the NSString reference: the
                // queue hop is a @Sendable closure.
                let keyValue = key as String
                queue.async {
                    process(
                        key: keyValue as NSString,
                        url: url,
                        folderID: folderID,
                        rootURL: rootURL,
                        maxPixelSize: maxPixelSize
                    )
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    private static func process(
        key: NSString,
        url: URL,
        folderID: UUID,
        rootURL: URL,
        maxPixelSize: CGFloat
    ) {
        let isFullSize = maxPixelSize > fullSizeThreshold
        // Every waiter went away while this job was queued: keep the gate for
        // work someone is still waiting on.
        guard hasWaiters(for: key) else {
            finish(key: key, image: nil, isFullSize: isFullSize)
            return
        }

        var image: UIImage?
        if loadGate.wait(timeout: .now() + gateTimeout) == .success {
            if hasWaiters(for: key) {
                image = LANFolderThumbnailDiskCache.image(
                    for: url,
                    folderID: folderID,
                    rootURL: rootURL,
                    maxPixelSize: maxPixelSize
                )
            }
            loadGate.signal()
        }
        finish(key: key, image: image, isFullSize: isFullSize)
    }

    private static func finish(key: NSString, image: UIImage?, isFullSize: Bool) {
        lock.lock()
        let callbacks = waiters.removeValue(forKey: key) ?? []
        inFlight.remove(key)
        lock.unlock()
        if let image {
            LANFolderImageCache.shared.store(image, forKey: key, isFullSize: isFullSize)
        }
        callbacks.forEach { $0.resume(with: image) }
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
///
/// The resolved root URL travels with the file list: thumbnail cache keys are
/// relative to that root, and a replay that lost it fell back to each file's
/// own absolute path, which collapsed every key in the folder to one digest
/// and made every revisit a full re-decode over SMB.
enum LANFolderSessionCache {
    struct Entry: Sendable {
        let rootURL: URL
        let files: [URL]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var entriesByFolder: [UUID: Entry] = [:]

    static func entry(for id: UUID) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entriesByFolder[id]
    }

    static func store(rootURL: URL, files: [URL], for id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        entriesByFolder[id] = Entry(rootURL: rootURL, files: files)
    }

    static func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entriesByFolder.removeAll()
    }
}
