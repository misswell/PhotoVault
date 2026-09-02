import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// A folder the user picked through the Files app (an SMB/NAS share, a
/// network drive, iCloud, anything Files can reach) and wants treated as one
/// album. Access survives relaunches through a security-scoped bookmark; if
/// the underlying share is gone the bookmark fails to resolve and the folder
/// must be re-added.
struct LANFolderAlbum: Codable, Identifiable, Equatable {
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

    /// Creates a persisted security-scoped bookmark for the picked folder.
    static func add(from pickedURL: URL) -> LANFolderAlbum? {
        guard let bookmark = try? pickedURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return nil }
        return LANFolderAlbum(
            id: UUID(),
            name: pickedURL.lastPathComponent,
            bookmark: bookmark,
            addedAt: .now
        )
    }

    /// Resolves the bookmark back to a usable folder URL, or nil when the
    /// share is unreachable and the entry needs re-adding.
    static func resolve(_ album: LANFolderAlbum) -> URL? {
        var stale = false
        return try? URL(
            resolvingBookmarkData: album.bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
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

    /// Idempotent: activating an already-active folder is a no-op.
    func activate(id: UUID, url: URL) {
        lock.lock()
        defer { lock.unlock() }
        if let existing = active[id] {
            guard existing.url != url || !existing.started else { return }
            if existing.started {
                existing.url.stopAccessingSecurityScopedResource()
            }
        }
        let started = url.startAccessingSecurityScopedResource()
        active[id] = ActiveScope(url: url, started: started)
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
            guard values?.isRegularFile == true else { continue }
            files.append((fileURL, values?.contentModificationDate))
        }

        return files
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            .map(\.url)
    }

    /// Downscaled decode through ImageIO. A full-resolution decode of a 50MP
    /// file inside a grid cell is exactly the main-thread hitch we never
    /// allow; callers run this off the main actor. Folder scope must already
    /// be held via `LANFolderScopeManager`.
    static func image(at url: URL, maxPixelSize: CGFloat) -> UIImage? {
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
/// safe, so cells can decode off the main actor.
final class LANFolderImageCache: @unchecked Sendable {
    static let shared = LANFolderImageCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 800
    }

    func image(forKey key: NSString) -> UIImage? {
        cache.object(forKey: key)
    }

    func store(_ image: UIImage, forKey key: NSString) {
        cache.setObject(image, forKey: key)
    }
}

/// Bounded loader for LAN folder images. SMB reads are network round trips:
/// unbounded concurrent decodes once starved Swift's cooperative thread pool
/// and froze the entire app, and repeated screen visits queued duplicate
/// work for the same files. Loads are therefore coalesced per file, capped
/// at three concurrent decodes, and the gate wait times out so a poisoned
/// slot can never back the queue up forever. All bookkeeping happens on a
/// dedicated GCD queue, never on Swift concurrency threads.
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

    static func load(at url: URL, maxPixelSize: CGFloat) async -> UIImage? {
        let key: NSString = "\(url.path)#\(Int(maxPixelSize))" as NSString
        if let cached = LANFolderImageCache.shared.image(forKey: key) {
            return cached
        }
        return await withCheckedContinuation { continuation in
            lock.lock()
            waiters[key, default: []].append { image in
                continuation.resume(returning: image)
            }
            let shouldStart = inFlight.insert(key).inserted
            lock.unlock()

            guard shouldStart else { return }
            queue.async {
                process(key: key, url: url, maxPixelSize: maxPixelSize)
            }
        }
    }

    private static func process(key: NSString, url: URL, maxPixelSize: CGFloat) {
        var image: UIImage?
        if loadGate.wait(timeout: .now() + gateTimeout) == .success {
            image = LANFolderImageLoader.image(at: url, maxPixelSize: maxPixelSize)
            loadGate.signal()
        } else {
            photoVaultTrace("lan image gate timeout path=\(url.lastPathComponent)")
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

/// Runs blocking work on a GCD thread (its own growable pool) so a hung
/// share can never occupy a Swift cooperative thread, and races it against
/// a timeout. On timeout the work keeps running in the background; the
/// caller just stops waiting.
enum LANFolderTimeout {
    static func run<T: Sendable>(
        seconds: Double,
        _ work: @escaping @Sendable () -> T
    ) async -> T? {
        let workTask = Task.detached(priority: .userInitiated) {
            await LANFolderGCDBridge.run(work)
        }
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil as T?
        }
        let winner = await groupFirst(workTask, timeoutTask)
        timeoutTask.cancel()
        return winner
    }

    private static func groupFirst<T: Sendable>(
        _ workTask: Task<T, Never>,
        _ timeoutTask: Task<T?, Never>
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await workTask.value }
            group.addTask { await timeoutTask.value }
            let first = await group.next() ?? nil
            group.cancelAll()
            _ = await group.next()
            return first
        }
    }
}

private enum LANFolderGCDBridge {
    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }
}
