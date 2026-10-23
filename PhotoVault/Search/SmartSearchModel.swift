//
//  SmartSearchModel.swift
//  PhotoVault
//
//  The state behind the smart-search screen: owns the index, the encoders and
//  the pipeline, and turns a query into an ordered list of assets.
//
//  Design notes worth keeping
//  --------------------------
//  * Models are loaded **lazily and off the main thread**. First load is seconds
//    (6.4 s measured for the vision tower on macOS), so doing it in `init` would
//    stall the first frame of the screen. The screen shows "preparing" instead.
//
//  * The index is filled from here rather than from app launch. Indexing 100k
//    photos is hours of work, and starting it automatically on first launch
//    would mean a user who never opens search pays for it. Opening the screen is
//    the signal that the feature is wanted -- so `prepare()` starts (or
//    resumes) indexing by itself. An explicit pause is remembered across
//    launches; otherwise reopening the screen would undo the user's choice.
//
//  * Results are `[PHAsset]`, not a `PHFetchResult`. PhotoKit returns assets
//    from an identifier fetch in an arbitrary order, and the whole point of
//    ranked search is the order. The result set is bounded by
//    `PhotoSearchConfiguration.maximumResults`, so materialising it is safe.
//

import Foundation
import Photos
import CoreML
import SwiftUI

@MainActor
@Observable
final class SmartSearchModel {

    /// One model for the whole process.
    ///
    /// Indexing deliberately outlives the screen: leaving search and coming
    /// back used to build a second `SmartSearchModel`, and the old task kept
    /// running (it retains its model) -- two indexers appending to the same
    /// embedding matrix. Sharing the instance also means a run started here is
    /// still visible, with its progress, the next time the screen opens.
    static let shared = SmartSearchModel()

    enum Phase: Equatable {
        case idle
        case modelRequired
        case preparingModel
        /// Searching is possible but the index is still filling.
        case searching
        case results
        case failed(String)
    }

    // MARK: - Observable state

    private(set) var phase: Phase = .idle
    private(set) var query = ""
    private(set) var hits: [PhotoSearchHit] = []
    /// One entry per hit, same order. PhotoKit does not preserve our ranking, so
    /// the ordered array is the source of truth and this dictionary only fills
    /// in the pixels.
    private(set) var assets: [PHAsset] = []
    private(set) var diagnostics: PhotoSearchDiagnostics?
    private(set) var indexProgress: PhotoSearchIndexProgress?
    private(set) var indexState: PhotoSearchIndexState = .idle
    private(set) var indexStats: AISearchIndexStats?
    private(set) var statusMessage: String?

    /// The metadata sync and vision-model load happen before the coordinator's
    /// first batch. Reporting that window as "indexing" is what keeps the
    /// progress UI honest while a 100k-photo library is being brought up to
    /// date -- without it the screen looks idle for minutes.
    private(set) var isStartingIndex = false

    private static let indexingPausedKey = "PhotoVault.smartSearch.indexingPaused"

    /// `true` once the model is loaded and the index is usable, so the UI can
    /// distinguish "still preparing" from "no results".
    var isReady: Bool {
        if case .preparingModel = phase { return false }
        return engine != nil
    }

    var isIndexing: Bool {
        if isStartingIndex { return true }
        if case .running = indexState { return true }
        return false
    }

    /// Work the indexer can still do. Driven by stored statistics rather than
    /// the coordinator's in-memory progress, which is nil until a run starts --
    /// a screen opened after a relaunch must still offer "继续建立索引".
    var needsIndexing: Bool {
        guard isReady else { return false }
        guard let stats = indexStats else { return true }
        guard stats.totalAssets > 0 else { return true }
        // Assets waiting on a local preview cannot be indexed right now, so
        // offering "continue" for them would start a run that does nothing.
        return stats.pendingAssets > stats.waitingForLocalPreview
    }

    /// What the results do *not* cover, phrased for the empty state.
    ///
    /// A search that looks at 1,782 of 104,462 photos and finds nothing has not
    /// disproved the query; without saying so the feature looks broken.
    var coverageNote: String? {
        guard let stats = indexStats, stats.totalAssets > 0,
              stats.pendingAssets > 0 else { return nil }
        var note = "目前只为 \(stats.embeddedAssets)/\(stats.totalAssets) 张照片建立了索引，"
            + "搜索只能在已索引的照片里查找。"
        if stats.waitingForLocalPreview > 0 {
            note += "\n其中 \(stats.waitingForLocalPreview) 张在本机还没有可用的预览。"
                + "索引不会下载 iCloud 原图，系统缓存出预览后会自动补上。"
        }
        return note
    }

    // MARK: - Owned machinery

    private var store: AIPhotoSearchStore?
    private var engine: PhotoSearchEngine?
    private var coordinator: PhotoSearchIndexCoordinator?
    private var tokenizer: SigLIP2Tokenizer?
    private var textEncoder: SigLIP2TextEncoder?
    private var indexTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private let modelResources: SearchModelResources

    init(modelResources: SearchModelResources = SearchModelResources()) {
        self.modelResources = modelResources
    }

    // MARK: - Lifecycle

    /// Opens the index and loads the model, then starts filling the index.
    ///
    /// Idempotent: the screen calls it from `.task`, which re-runs on every
    /// appearance, and reloading a 270 MB text tower each time would be felt.
    func prepare() async {
        if isReady {
            // Already loaded from an earlier visit. Refresh the counts so the
            // coverage line is current, then pick the index back up if a
            // previous run stopped and the user did not pause it.
            await refreshIndexStatus()
            if needsIndexing, !Self.indexingIsPaused, indexTask == nil {
                startIndexing()
            }
            return
        }
        guard phase != .preparingModel else { return }
        guard modelResources.isInstalled else {
            statusMessage = "模型为可选下载"
            phase = .modelRequired
            return
        }
        phase = .preparingModel

        // Everything below the model load is cheap enough to do inline, but the
        // load itself is not: `MLModel` reads hundreds of megabytes.
        do {
            let paths = try Self.indexPaths()
            let store = AIPhotoSearchStore(
                databaseURL: paths.database, embeddingURL: paths.embeddings
            )
            let dimension = try modelResources.manifest().embeddingDimension
            let modelSHA = try Self.modelFingerprint(resources: modelResources)
            // Not `open`: a build that ships a new model changes the fingerprint,
            // and `open` would then refuse these files forever. The index is
            // derived data, so a mismatch means "rebuild", not "give up".
            try store.openRebuildingIfIncompatible(
                dimension: dimension, sourceModelSHA256: modelSHA
            )
            self.store = store

            let loaded = try await Task.detached(priority: .userInitiated) { [modelResources] in
                try modelResources.makePipeline()
            }.value
            tokenizer = loaded.tokenizer
            textEncoder = loaded.text

            let reader = try EmbeddingMatrixReader(url: paths.embeddings)
            let matrixURL = paths.embeddings
            engine = PhotoSearchEngine(
                store: store,
                embeddings: reader,
                encoder: SigLIP2QueryEncoder(encoder: loaded.text, tokenizer: loaded.tokenizer),
                // Auto-indexing can commit thousands of rows while this screen
                // is open; a query must see them without rebuilding the engine.
                reopenEmbeddings: { try EmbeddingMatrixReader(url: matrixURL) }
            )

            if let manifest = try? modelResources.manifest() {
                statusMessage = "\(manifest.quantization) 模型 · \(manifest.embeddingDimension) 维"
            }
            phase = .idle
            await refreshIndexStatus()

            // A query submitted while the model was loading was accepted into
            // `query` but could not run (no engine yet). Run it now instead of
            // leaving an empty grid with no explanation.
            if !query.isEmpty { search(query) }

            // Opening search is the signal that indexing is wanted. A previous
            // explicit pause is respected across launches; the button in the
            // status bar is how it is lifted.
            if needsIndexing, !Self.indexingIsPaused {
                startIndexing()
            }
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    func refreshIndexStatus() async {
        guard let store else { return }
        do {
            let stats = try store.stats()
            indexStats = stats
            statusMessage = Self.summary(stats: stats)
        } catch {
            statusMessage = Self.describe(error)
        }
    }

    private static var indexingIsPaused: Bool {
        UserDefaults.standard.bool(forKey: indexingPausedKey)
    }

    private static func setIndexingPaused(_ paused: Bool) {
        UserDefaults.standard.set(paused, forKey: indexingPausedKey)
    }

    /// Fills the index, one batch at a time, until it is complete or paused.
    ///
    /// The model is shared, so leaving the screen does not stop a run; this is
    /// what lets a 100k-photo index make progress while the user is elsewhere in
    /// the app. The task ends when the app is suspended or killed, and the next
    /// visit resumes from the rows already committed.
    ///
    /// The metadata sync comes first: the pipeline embeds whatever the store
    /// considers pending, and nothing is pending until PhotoKit's assets have
    /// been written down.
    func startIndexing() {
        guard isReady, indexTask == nil, let store else { return }
        Self.setIndexingPaused(false)
        isStartingIndex = true
        indexTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isStartingIndex = false
                self.indexTask = nil
                // The coordinator owns the vision tower. Keeping it after the
                // run would pin ~90 MB for a model nothing is using.
                self.coordinator = nil
            }
            do {
                // The sync walks the library and writes metadata; the model
                // load reads ~90 MB. Neither belongs on the main actor, and the
                // task inherits it unless explicitly detached.
                let result = try await Task.detached(priority: .utility) {
                    try PhotoKitMetadataSync(store: store).sync()
                }.value
                guard !Task.isCancelled else { return }
                // A limited library is a first-class state, not a failure: the
                // index covers the selection the user granted.
                if result.isLimited {
                    self.statusMessage = "仅有部分照片权限，索引范围限于已选择项目"
                }
                await self.refreshIndexStatus()

                let embedder = try await Task.detached(priority: .userInitiated) { [modelResources] in
                    try modelResources.makeVisionEncoder()
                }.value
                guard !Task.isCancelled else { return }

                let coordinator = PhotoSearchIndexCoordinator(
                    store: store,
                    source: PhotoKitPendingSource(store: store),
                    imageLoader: PhotoKitImageLoader(),
                    embedder: embedder,
                    recognizer: PhotoTextRecognizer()
                )
                self.coordinator = coordinator
                coordinator.onStateChange = { [weak self] state in
                    Task { @MainActor in self?.apply(indexState: state) }
                }

                if result.didFullScan {
                    self.statusMessage = "已重新扫描照片库"
                }
                // The sync phase is over; from here the coordinator's progress
                // is what the status bar should describe.
                self.isStartingIndex = false
                await coordinator.run()
            } catch {
                self.statusMessage = Self.describe(error)
            }
            await self.refreshIndexStatus()
        }
    }

    /// Stops at the next pause boundary and remembers the choice.
    ///
    /// `indexTask` is deliberately not cleared here: the task's own cleanup
    /// clears it once the current batch (or the metadata sync) has actually
    /// stopped. Clearing it now would let a second run start while the first
    /// one is still winding down.
    func cancelIndexing() {
        Self.setIndexingPaused(true)
        indexTask?.cancel()
        coordinator?.pause()
        indexState = .paused(coordinator?.progress ?? PhotoSearchIndexProgress())
        isStartingIndex = false
    }

    // MARK: - Searching

    func search(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        query = trimmed
        searchTask?.cancel()
        guard !trimmed.isEmpty else {
            hits = []
            assets = []
            diagnostics = nil
            if isReady { phase = .idle }
            return
        }
        guard let engine else {
            return
        }

        phase = .searching
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Run the vector scan off the main thread: 100k rows is ~10 ms
                // of Accelerate, or ~8 ms on the GPU, and the text tower is
                // another ~9 ms. Small, but not on the main actor.
                let response = try await Task.detached(priority: .userInitiated) {
                    try engine.search(trimmed)
                }.value
                // A newer query may have started while this one ran; the older
                // answer must not overwrite the newer one.
                guard !Task.isCancelled, self.query == trimmed else { return }
                // The empty state names how much of the library was searched,
                // and indexing may have advanced since the screen opened.
                await self.refreshIndexStatus()
                self.apply(response: response)
            } catch {
                guard !Task.isCancelled else { return }
                self.phase = .failed(Self.describe(error))
            }
        }
    }

    /// Finds photos that look like the given one.
    func search(similarTo asset: PHAsset) {
        query = "相似于这张照片"
        searchTask?.cancel()
        guard let engine else { return }
        phase = .searching
        let identifier = asset.localIdentifier
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await Task.detached(priority: .userInitiated) {
                    try engine.search(similarTo: identifier)
                }.value
                guard !Task.isCancelled else { return }
                await self.refreshIndexStatus()
                self.apply(response: response)
            } catch {
                guard !Task.isCancelled else { return }
                self.phase = .failed(Self.describe(error))
            }
        }
    }

    func clear() {
        searchTask?.cancel()
        query = ""
        hits = []
        assets = []
        diagnostics = nil
        phase = .idle
    }

    // MARK: - Applying results

    private func apply(response: PhotoSearchResponse) {
        hits = response.hits
        diagnostics = response.diagnostics
        let orderedIDs = response.hits.map(\.assetID)
        guard !orderedIDs.isEmpty else {
            assets = []
            phase = .results
            return
        }
        // PhotoKit returns an identifier fetch in its own order, so the ranked
        // array is rebuilt from a lookup rather than used directly. Using the
        // fetch result's order would silently discard the ranking, which is the
        // entire output of the search.
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: orderedIDs, options: nil)
        var byID: [String: PHAsset] = [:]
        byID.reserveCapacity(fetched.count)
        fetched.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
        assets = orderedIDs.compactMap { byID[$0] }
        phase = .results
    }

    private func apply(indexState: PhotoSearchIndexState) {
        self.indexState = indexState
        switch indexState {
        case .running(let progress), .paused(let progress):
            indexProgress = progress
        case .deferred(let progress, let reason):
            indexProgress = progress
            statusMessage = reason
        case .finished(let progress):
            indexProgress = progress
            Task { await self.refreshIndexStatus() }
        case .failed(let message):
            statusMessage = message
        case .idle:
            break
        }
    }

    // MARK: - Paths and helpers

    /// A **separate** database from `PhotoIndex.sqlite`, which is verified and
    /// load bearing. Keeping them apart means the AI index can be dropped or
    /// schema-bumped with zero migration risk to the existing one.
    private static func indexPaths() throws -> (database: URL, embeddings: URL) {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let directory = support.appendingPathComponent("PhotoVault", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (
            directory.appendingPathComponent("AIPhotoSearch.sqlite"),
            directory.appendingPathComponent("embeddings-v1.bin")
        )
    }

    /// The store records which model produced each embedding and refuses to
    /// serve rows from a different one. The manifest carries the conversion's
    /// own name, which is stable across installs of the same build.
    private static func modelFingerprint(resources: SearchModelResources) throws -> String {
        try resources.modelFingerprint()
    }

    private static func summary(stats: AISearchIndexStats) -> String {
        if stats.totalAssets == 0 { return "尚未建立索引" }
        if stats.pendingAssets == 0 && stats.failedAssets == 0 {
            return "已索引 \(stats.embeddedAssets) 张"
        }
        var parts = ["已索引 \(stats.embeddedAssets)/\(stats.totalAssets)"]
        let actionable = stats.pendingAssets - stats.waitingForLocalPreview
        if actionable > 0 { parts.append("待处理 \(actionable)") }
        if stats.failedAssets > 0 { parts.append("失败 \(stats.failedAssets)") }
        if stats.waitingForLocalPreview > 0 {
            parts.append("等待本机预览 \(stats.waitingForLocalPreview)")
        }
        return parts.joined(separator: " · ")
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
