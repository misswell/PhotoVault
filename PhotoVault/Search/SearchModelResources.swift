//
//  SearchModelResources.swift
//  PhotoVault
//
//  Locates the bundled SigLIP2 artifacts and builds the encoders from them.
//
//  Why this file exists at all
//  ---------------------------
//  The model files are **not in git** -- the W8 build is 364 MB, reproducible
//  from `tools/models/install_models.py`. So there is a state this app can
//  legitimately be in where the code is present and correct but the model is
//  simply not there: a fresh clone, or a build that skipped the install step.
//
//  That state must be *legible*. The failure it replaces is the bad one: a
//  `Bundle.main.url(forResource:)` returning nil and being force-unwrapped, or a
//  search that silently returns nothing because the encoder was never created.
//  Here it produces a specific error naming the missing file and the command
//  that installs it.
//
//  The manifest is read rather than trusted from a constant for the same reason
//  the encoders read their dimension from the model's own output description:
//  the numbers that matter belong to the artifact, not to this source file. If
//  the installed model is a different build, the manifest says so.
//

import Foundation
import CoreML

enum SearchModelResourcesError: LocalizedError {
    case notInstalled(String)
    case manifestUnreadable(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let name):
            """
            the search model "\(name)" is not in this build's resources. \
            Run `python tools/models/install_models.py` and rebuild -- the model \
            files are deliberately kept out of git because they total 364 MB.
            """
        case .manifestUnreadable(let detail):
            "the search model manifest could not be read: \(detail)"
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

    /// Names without extensions: Xcode compiles `SigLIP2Vision.mlpackage` into
    /// `SigLIP2Vision.mlmodelc`, so the bundle never contains the extension the
    /// conversion produced.
    static let visionModelName = "SigLIP2Vision"
    static let textModelName = "SigLIP2Text"
    static let tokenizerName = "tokenizer-v1"
    static let manifestName = "SearchModelManifest"

    let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    /// `true` when every artifact is present.
    ///
    /// Checked before any encoder is constructed so an uninstalled model is one
    /// clear state rather than three separate failures.
    var isInstalled: Bool {
        (try? visionModelURL()) != nil
            && (try? textModelURL()) != nil
            && (try? tokenizerURL()) != nil
    }

    private func url(named name: String, extension ext: String) throws -> URL {
        // `subdirectory: nil` because the resources are flattened into the
        // bundle root: the Models group is a *group*, not a folder reference, so
        // it does not survive as a directory.
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
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

    /// `compileIfNeeded` is false throughout: the bundle contains `.mlmodelc`,
    /// which `MLModel` loads directly. Compiling an already-compiled model would
    /// copy 359 MB for nothing.
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
