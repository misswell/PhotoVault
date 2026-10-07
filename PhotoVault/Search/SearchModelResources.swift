//
//  SearchModelResources.swift
//  PhotoVault
//
//  Loads the optional, verified SigLIP2 installation from Application Support.
//  Models are never downloaded automatically or included in the shipping app.
//

import Foundation
import CoreML

enum SearchModelResourcesError: LocalizedError {
    case notInstalled(String)
    case manifestUnreadable(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let name):
            "智能搜索模型尚未下载或文件不完整（\(name)）。请在设置或智能搜索页下载模型。"
        case .manifestUnreadable(let detail):
            "无法读取模型信息：\(detail)"
        }
    }
}

/// The app-facing view of `SearchModelManifest.json`, written by
/// `install_models.py` from the conversion's own manifest.
struct SearchModelManifest: Decodable, Equatable, Sendable {
    var name: String
    var source: String
    var license: String
    var embeddingDimension: Int
    var imageSize: Int
    var textMaxLength: Int
    var vocabSize: Int
    var quantization: String
    var modelVersion: Int

    /// Which build `install_models.py` copied in. `quantization` describes how
    /// the model was converted; this describes what is actually on disk, which
    /// is the one a bug report needs.
    var installedPrecision: String?
}

struct SearchModelResources: Sendable {

    /// Downloaded mlpackages are compiled on the device before installation.
    static let visionModelName = "SigLIP2Vision"
    static let textModelName = "SigLIP2Text"
    static let tokenizerName = "tokenizer-v1"
    static let manifestName = "SearchModelManifest"

    let directory: URL

    init(directory: URL = SearchModelInstallation.directory) {
        self.directory = directory
    }

    /// `true` when every artifact is present.
    ///
    /// Checked before any encoder is constructed so an uninstalled model is one
    /// clear state rather than three separate failures.
    var isInstalled: Bool {
        SearchModelInstallation.isInstalled(at: directory)
    }

    private func url(named name: String, extension ext: String) throws -> URL {
        let url = directory.appendingPathComponent("\(name).\(ext)")
        guard isInstalled, FileManager.default.fileExists(atPath: url.path) else {
            throw SearchModelResourcesError.notInstalled("\(name).\(ext)")
        }
        return url
    }

    /// The compiled vision tower, used for indexing.
    func visionModelURL() throws -> URL {
        try url(named: Self.visionModelName, extension: "mlmodelc")
    }

    /// The compiled text tower, used for queries.
    func textModelURL() throws -> URL {
        try url(named: Self.textModelName, extension: "mlmodelc")
    }

    func tokenizerURL() throws -> URL {
        try url(named: Self.tokenizerName, extension: "bin")
    }

    /// Identifies the model that produced the stored embeddings.
    ///
    /// Lives here, next to the manifest it is derived from, so that everything
    /// that opens the index agrees on it. When this was duplicated the
    /// self-check opened the real index with a placeholder fingerprint, which
    /// drifted from what the app writes and reported a spurious model mismatch
    /// the moment the app had actually built an index.
    ///
    /// The store compares it as an opaque string; padding to the length it
    /// expects keeps the column readable without hashing 359 MB.
    func modelFingerprint() throws -> String {
        let name = try manifest().name
        return String(repeating: "0", count: max(0, 64 - name.count)) + name
    }

    func manifest() throws -> SearchModelManifest {
        let url = try url(named: Self.manifestName, extension: "json")
        do {
            return try JSONDecoder().decode(
                SearchModelManifest.self, from: try Data(contentsOf: url)
            )
        } catch {
            throw SearchModelResourcesError.manifestUnreadable(String(describing: error))
        }
    }

    // MARK: - Constructing the encoders

    /// Installation already compiled the models; loading never copies weights.
    func makeVisionEncoder(
        computeUnits: MLComputeUnits = .all
    ) throws -> SigLIP2VisionEncoder {
        try SigLIP2VisionEncoder(
            modelURL: try visionModelURL(), computeUnits: computeUnits, compileIfNeeded: false
        )
    }

    /// The pad token is read from the tokenizer artifact rather than assumed.
    ///
    /// The two must agree: padding is what the text tower pools over, so a pad
    /// token that disagrees with the artifact would mean the model attending to
    /// a token the tokenizer never emits. Taking it from the artifact makes that
    /// impossible to get wrong, and costs one `SigLIP2Tokenizer` decode.
    func makeTextEncoder(computeUnits: MLComputeUnits = .all) throws -> SigLIP2TextEncoder {
        let padTokenID = try makeTokenizer().configuration.padID
        return try SigLIP2TextEncoder(
            modelURL: try textModelURL(),
            computeUnits: computeUnits,
            padTokenID: padTokenID,
            compileIfNeeded: false
        )
    }

    /// Both encoders plus the tokenizer, which is what a search actually needs.
    ///
    /// Deliberately not `isInstalled`-guarded: each accessor throws the specific
    /// missing-artifact error, which is more useful than one generic message.
    func makePipeline(computeUnits: MLComputeUnits = .all) throws
        -> (tokenizer: SigLIP2Tokenizer, vision: SigLIP2VisionEncoder, text: SigLIP2TextEncoder)
    {
        let tokenizer = try makeTokenizer()
        return (
            tokenizer,
            try makeVisionEncoder(computeUnits: computeUnits),
            try SigLIP2TextEncoder(
                modelURL: try textModelURL(),
                computeUnits: computeUnits,
                padTokenID: tokenizer.configuration.padID,
                compileIfNeeded: false
            )
        )
    }

    func makeTokenizer() throws -> SigLIP2Tokenizer {
        try SigLIP2Tokenizer(artifactURL: try tokenizerURL())
    }
}
