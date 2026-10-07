import CoreML
import CryptoKit
import Foundation

@main
struct DownloadTests {
    static func main() async throws {
        guard CommandLine.arguments.count >= 3 else {
            print("usage: download_test <PhotoVault/Models> <validation directory> [--online]")
            exit(2)
        }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        if CommandLine.arguments.contains("--online") {
            let installed = root.appendingPathComponent("installed")
            print("Downloading production assets over HTTPS...")
            try await SearchModelDownloader.install(catalog: .production, destination: installed) { _ in }
            guard SearchModelInstallation.isInstalled(at: installed) else { exit(1) }
            print("PASS HTTPS download, hash verification, compilation and publication")
            return
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL") \(label)")
            if !condition { failures += 1 }
        }
        let catalog = SearchModelCatalog.production
        let installed = root.appendingPathComponent("installed")
        check(!SearchModelInstallation.isInstalled(at: root.appendingPathComponent("absent")),
              "a fresh installation has no search model")
        for file in catalog.files {
            try SearchModelDownloader.validate(source.appendingPathComponent(file.path), file: file)
        }
        check(true, "all eight pinned files pass size and SHA-256 checks")

        let corrupted = root.appendingPathComponent("corrupted.bin")
        let tokenizer = catalog.files.first { $0.path == "tokenizer-v1.bin" }!
        var bytes = try Data(contentsOf: source.appendingPathComponent(tokenizer.path))
        bytes[0] ^= 0xff
        try bytes.write(to: corrupted)
        do {
            try SearchModelDownloader.validate(corrupted, file: tokenizer)
            check(false, "same-size corruption is rejected")
        } catch SearchModelDownloadError.integrity {
            check(true, "same-size corruption is rejected")
        }
        try Data([0]).write(to: corrupted)
        do {
            try SearchModelDownloader.validate(corrupted, file: tokenizer)
            check(false, "truncated download is rejected")
        } catch SearchModelDownloadError.integrity {
            check(true, "truncated download is rejected")
        }

        let invalid = SearchModelCatalog(modelName: catalog.modelName, baseURL: catalog.baseURL,
            files: [.init(path: "../escape", asset: "file.bin", bytes: 1, sha256: String(repeating: "0", count: 64))])
        do {
            try await SearchModelDownloader.install(catalog: invalid, destination: installed) { _ in }
            check(false, "unsafe package paths are rejected")
        } catch SearchModelDownloadError.invalidCatalog {
            check(true, "unsafe package paths are rejected")
        }
        check(!(try manager.contentsOfDirectory(atPath: root.path)).contains { $0.hasPrefix(".download-") },
              "a failed download removes its staging directory")

        let cancelled = Task {
            try await SearchModelDownloader.install(catalog: catalog, destination: installed) { _ in }
        }
        cancelled.cancel()
        do {
            try await cancelled.value
            check(false, "cancellation prevents installation")
        } catch is CancellationError {
            check(true, "cancellation prevents installation")
        }
        check(!SearchModelInstallation.isInstalled(at: installed), "cancellation cannot publish partial files")
        check(!(try manager.contentsOfDirectory(atPath: root.path)).contains { $0.hasPrefix(".download-") },
              "cancellation cleans staging files")

        let staging = root.appendingPathComponent("valid-stage")
        try manager.copyItem(at: source, to: staging)
        try SearchModelDownloader.compileAndPublish(staging: staging, destination: installed, catalog: catalog)
        check(SearchModelInstallation.isInstalled(at: installed), "verified packages compile and publish a complete installation")
        check(!manager.fileExists(atPath: staging.path), "publication moves the staging directory")
        check(!manager.fileExists(atPath: installed.appendingPathComponent("SigLIP2Text.mlpackage").path),
              "installation retains only compiled models")
        let excluded = try installed.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        check(excluded == true, "models are excluded from iCloud backups")

        let broken = root.appendingPathComponent("broken-stage")
        try manager.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{\"name\":\"wrong\",\"embeddingDimension\":768}".utf8)
            .write(to: broken.appendingPathComponent("SearchModelManifest.json"))
        do {
            try SearchModelDownloader.compileAndPublish(staging: broken, destination: installed, catalog: catalog)
            check(false, "incompatible manifests cannot replace an installation")
        } catch SearchModelDownloadError.incompatibleModel {
            check(true, "incompatible manifests cannot replace an installation")
        }
        check(SearchModelInstallation.isInstalled(at: installed), "failed replacement preserves the usable model")
        print("RESULT: failures=\(failures)")
        if failures > 0 { exit(1) }
    }
}
