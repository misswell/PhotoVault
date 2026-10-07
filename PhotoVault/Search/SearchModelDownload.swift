import CoreML
import CryptoKit
import Foundation

struct SearchModelCatalog: Sendable {
    struct File: Sendable {
        let path: String
        let asset: String
        let bytes: Int64
        let sha256: String
    }

    let modelName: String
    let baseURL: URL
    let files: [File]
    var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
}

enum SearchModelInstallation {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoVault/SearchModels/siglip2-w8-v1", isDirectory: true)
    }

    static func isInstalled(at directory: URL) -> Bool {
        ["SigLIP2Vision.mlmodelc", "SigLIP2Text.mlmodelc", "tokenizer-v1.bin",
         "SearchModelManifest.json", "installed.json"].allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }
}

enum SearchModelDownloadError: LocalizedError {
    case invalidCatalog
    case http(Int)
    case integrity(String)
    case insufficientSpace
    case incompatibleModel

    var errorDescription: String? {
        switch self {
        case .invalidCatalog: "模型下载配置无效。"
        case .http(let status): "模型下载失败（HTTP \(status)），请稍后重试。"
        case .integrity: "模型文件校验失败，请重新下载。"
        case .insufficientSpace: "存储空间不足，请至少留出 1.2 GB 后重试。"
        case .incompatibleModel: "下载的模型无法在此设备上使用，请重试。"
        }
    }
}

/// All large reads, hashing and Core ML compilation stay off the main actor.
/// The final directory is published only after the complete installation passes.
enum SearchModelDownloader {
    enum Progress: Sendable {
        case downloading(received: Int64, total: Int64)
        case installing
    }

    static func install(
        catalog: SearchModelCatalog,
        destination: URL,
        session: URLSession = .shared,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws {
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        // A terminated app cannot run defer. Reclaim only our own partial folders
        // on the next explicit download attempt; completed models stay intact.
        for item in try manager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            where item.lastPathComponent.hasPrefix(".download-") {
            try? manager.removeItem(at: item)
        }
        let capacity = try? parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        if let capacity, capacity < catalog.totalBytes * 3 {
            throw SearchModelDownloadError.insufficientSpace
        }
        guard !catalog.files.isEmpty, catalog.baseURL.scheme == "https" else {
            throw SearchModelDownloadError.invalidCatalog
        }
        let staging = parent.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }

        var received: Int64 = 0
        for file in catalog.files {
            try Task.checkCancellation()
            let components = file.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !file.asset.contains("/"), file.bytes > 0, file.sha256.count == 64 else {
                throw SearchModelDownloadError.invalidCatalog
            }
            let offset = received
            let delegate = SearchModelDownloadProgress { count in
                progress(.downloading(received: offset + min(count, file.bytes), total: catalog.totalBytes))
            }
            let request = URLRequest(url: catalog.baseURL.appendingPathComponent(file.asset), timeoutInterval: 120)
            let (temporary, response) = try await session.download(for: request, delegate: delegate)
            defer { try? manager.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw SearchModelDownloadError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            try Task.checkCancellation()
            try validate(temporary, file: file)
            let target = staging.appendingPathComponent(file.path)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.moveItem(at: temporary, to: target)
            received += file.bytes
            progress(.downloading(received: received, total: catalog.totalBytes))
        }

        progress(.installing)
        try compileAndPublish(staging: staging, destination: destination, catalog: catalog)
    }

    static func validate(_ url: URL, file: SearchModelCatalog.File) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard Int64(size ?? -1) == file.bytes else { throw SearchModelDownloadError.integrity(file.path) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == file.sha256 else { throw SearchModelDownloadError.integrity(file.path) }
    }

    static func compileAndPublish(staging: URL, destination: URL, catalog: SearchModelCatalog) throws {
        let manager = FileManager.default
        let manifestURL = staging.appendingPathComponent("SearchModelManifest.json")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        guard manifest?["name"] as? String == catalog.modelName,
              manifest?["embeddingDimension"] as? Int == 768 else {
            throw SearchModelDownloadError.incompatibleModel
        }
        for name in ["SigLIP2Vision", "SigLIP2Text"] {
            try Task.checkCancellation()
            let package = staging.appendingPathComponent("\(name).mlpackage")
            let compiled = try MLModel.compileModel(at: package)
            defer { try? manager.removeItem(at: compiled) }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuOnly
            let model = try MLModel(contentsOf: compiled, configuration: configuration)
            guard model.modelDescription.outputDescriptionsByName["embedding"]?
                .multiArrayConstraint?.shape.last?.intValue == 768 else {
                throw SearchModelDownloadError.incompatibleModel
            }
            try manager.moveItem(at: compiled, to: staging.appendingPathComponent("\(name).mlmodelc"))
            try manager.removeItem(at: package)
        }
        try Task.checkCancellation()
        try JSONEncoder().encode(["modelName": catalog.modelName])
            .write(to: staging.appendingPathComponent("installed.json"), options: .atomic)
        // Downloaded models are reproducible and must not inflate iCloud backups.
        var directory = staging
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: destination)
        }
    }
}

private final class SearchModelDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let update: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var lastUpdate = Date.distantPast

    init(update: @escaping @Sendable (Int64) -> Void) { self.update = update }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let shouldUpdate = lock.withLock {
            let now = Date()
            guard now.timeIntervalSince(lastUpdate) >= 0.25 || totalBytesWritten == totalBytesExpectedToWrite else {
                return false
            }
            lastUpdate = now
            return true
        }
        if shouldUpdate { update(totalBytesWritten) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
