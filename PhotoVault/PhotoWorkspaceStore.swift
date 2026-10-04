import Foundation
import Photos
import SwiftUI

/// PhotoKit delivers an immutable input on its callback queue; the wrapper
/// transfers ownership once to the awaiting task without exposing shared edits.
struct WorkspaceEditingInput: @unchecked Sendable {
    let value: PHContentEditingInput
}

struct WorkspacePhotoAsset: @unchecked Sendable { let value: PHAsset }

/// Handles cancellation before, during, or after PhotoKit registers a request.
/// Late callbacks cannot resume an already cancelled continuation.
final class WorkspaceContinuation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var cancelRequest: (@Sendable () -> Void)?
    private var finished = false
    private var cancelled = false
    func attach(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if finished { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation; lock.unlock()
    }
    func installCancellation(_ action: @escaping @Sendable () -> Void) {
        lock.lock(); let shouldCancel = cancelled
        if !finished { cancelRequest = action }; lock.unlock()
        if shouldCancel { action() }
    }
    func resume(_ result: Result<Value, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = continuation
        self.continuation = nil; cancelRequest = nil; lock.unlock()
        continuation?.resume(with: result)
    }
    func cancel() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true; cancelled = true
        let continuation = continuation, action = cancelRequest
        self.continuation = nil; cancelRequest = nil; lock.unlock()
        action?(); continuation?.resume(throwing: CancellationError())
    }
}

struct CompressionRecord: Codable, Identifiable, Sendable {
    var id = UUID()
    let date: Date
    let originalID: String
    let resultID: String
    let originalBytes: Int64
    let resultBytes: Int64
    let replaced: Bool
}

struct PhotoJournalEntry: Codable, Identifiable, Sendable {
    var id = UUID()
    var date: Date
    var text: String
    var assetID: String?
}

struct PhotoAnniversary: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var date: Date
    var isBirthday: Bool

    func daysUntilNext(from today: Date = .now, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: today)
        let parts = calendar.dateComponents([.month, .day], from: date)
        // Feb 29 anniversaries fall on Feb 28 in non-leap years.
        let year = calendar.component(.year, from: start)
        func occurrence(_ year: Int) -> Date {
            let month = parts.month ?? 1
            let first = calendar.date(from: DateComponents(year: year, month: month, day: 1))!
            let day = min(parts.day ?? 1, calendar.range(of: .day, in: .month, for: first)!.count)
            return calendar.date(from: DateComponents(year: year, month: month, day: day))!
        }
        var next = occurrence(year)
        if next < start { next = occurrence(year + 1) }
        return calendar.dateComponents([.day], from: start, to: next).day ?? 0
    }
}

/// Small, user-authored metadata only. Library assets stay in PhotoKit/SQLite.
@MainActor
final class PhotoWorkspaceStore: ObservableObject {
    static let shared = PhotoWorkspaceStore()
    @Published private(set) var notes: [String: String]
    @Published private(set) var journal: [PhotoJournalEntry]
    @Published private(set) var anniversaries: [PhotoAnniversary]
    @Published private(set) var compressionHistory: [CompressionRecord]
    @Published private(set) var recentAlbumIDs: [String]
    @Published private(set) var savedLooks: [String: PhotoEditRecipe]

    private init() {
        notes = Self.load("notes", fallback: [:])
        journal = Self.load("journal", fallback: [])
        anniversaries = Self.load("anniversaries", fallback: [])
        compressionHistory = Self.load("compression", fallback: [])
        recentAlbumIDs = Self.load("recentAlbums", fallback: [])
        savedLooks = Self.load("looks", fallback: [:])
    }

    private static func load<T: Decodable>(_ key: String, fallback: T) -> T {
        guard let data = UserDefaults.standard.data(forKey: "PhotoVault.workspace.\(key)"),
              let value = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
        return value
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: "PhotoVault.workspace.\(key)")
    }

    func setNote(_ text: String, for id: String) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            notes.removeValue(forKey: id)
        } else { notes[id] = text }
        persist(notes, key: "notes")
    }

    func saveEntry(_ entry: PhotoJournalEntry) {
        journal.removeAll { $0.id == entry.id }
        journal.append(entry)
        journal.sort { $0.date > $1.date }
        persist(journal, key: "journal")
    }

    func deleteEntry(_ id: UUID) {
        journal.removeAll { $0.id == id }
        persist(journal, key: "journal")
    }

    func saveAnniversary(_ item: PhotoAnniversary) {
        anniversaries.removeAll { $0.id == item.id }
        anniversaries.append(item)
        persist(anniversaries, key: "anniversaries")
    }

    func deleteAnniversary(_ id: UUID) {
        anniversaries.removeAll { $0.id == id }
        persist(anniversaries, key: "anniversaries")
    }

    func recordCompression(_ record: CompressionRecord) {
        // A reversible edit has one current result in Photos. Keep its latest
        // record rather than showing old byte counts beside the newest image.
        if record.replaced { compressionHistory.removeAll { $0.replaced && $0.resultID == record.resultID } }
        compressionHistory.insert(record, at: 0)
        persist(compressionHistory, key: "compression")
        if let note = notes[record.originalID], !record.replaced {
            setNote(note, for: record.resultID)
        }
    }

    func visitAlbum(_ id: String) {
        recentAlbumIDs.removeAll { $0 == id }
        recentAlbumIDs.insert(id, at: 0)
        recentAlbumIDs = Array(recentAlbumIDs.prefix(40))
        persist(recentAlbumIDs, key: "recentAlbums")
    }

    func removeReplacedCompression(for assetID: String) {
        compressionHistory.removeAll { $0.replaced && $0.resultID == assetID }
        persist(compressionHistory, key: "compression")
    }

    func saveLook(_ recipe: PhotoEditRecipe, named name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var look = recipe
        look.quarterTurns = 0; look.mirrored = false; look.angle = 0
        look.crop = .full
        savedLooks[name] = look
        persist(savedLooks, key: "looks")
    }

    func deleteLook(_ name: String) {
        savedLooks.removeValue(forKey: name)
        persist(savedLooks, key: "looks")
    }

    func journalExport() -> String {
        var text = "# PhotoVault 日记与备注\n\n"
        for entry in journal {
            text += "## \(entry.date.formatted(date: .complete, time: .omitted))\n\n\(entry.text)\n\n"
        }
        for (id, note) in notes.sorted(by: { $0.key < $1.key }) {
            text += "## 照片 \(id)\n\n\(note)\n\n"
        }
        return text
    }
}

struct WorkspaceAsset: Identifiable {
    let asset: PHAsset
    var id: String { asset.localIdentifier }
}

enum MediaWorkspaceError: LocalizedError {
    case unavailable, encoding, unsupported, cancelled
    var errorDescription: String? {
        switch self {
        case .unavailable: "无法读取媒体，请检查照片权限或 iCloud 网络连接。"
        case .encoding: "无法生成编辑结果，请调整设置后重试。"
        case .unsupported: "此媒体格式不支持这项操作。"
        case .cancelled: "操作已取消。"
        }
    }
}

@MainActor
enum WorkspacePhotoAccess {
    static func asset(_ id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    static func imageData(_ asset: PHAsset, original: Bool = false) async throws -> Data {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = original ? .original : .current
        let box = WorkspaceContinuation<Data>()
        return try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { continuation in
            box.attach(continuation)
            let id = PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { @Sendable data, _, _, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    box.resume(.failure(error))
                } else if let data {
                    box.resume(.success(data))
                } else { box.resume(.failure(MediaWorkspaceError.unavailable)) }
            }
            box.installCancellation { PHImageManager.default().cancelImageRequest(id) }
          }
        } onCancel: { box.cancel() }
    }

    static func editingInput(_ asset: PHAsset, network: Bool = true) async throws -> PHContentEditingInput {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = network
        options.canHandleAdjustmentData = { @Sendable _ in false }
        let box = WorkspaceContinuation<WorkspaceEditingInput>()
        let source = WorkspacePhotoAsset(value: asset)
        let result = try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { continuation in
            box.attach(continuation)
            let id = asset.requestContentEditingInput(with: options) { @Sendable input, info in
                if let input { box.resume(.success(WorkspaceEditingInput(value: input))) }
                else { box.resume(.failure((info[PHContentEditingInputErrorKey] as? Error) ?? MediaWorkspaceError.unavailable)) }
            }
            box.installCancellation { source.value.cancelContentEditingInputRequest(id) }
          }
        } onCancel: { box.cancel() }
        return result.value
    }
}
