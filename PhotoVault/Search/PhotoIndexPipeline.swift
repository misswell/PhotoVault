//
//  PhotoIndexPipeline.swift
//  PhotoVault
//
//  Fills the search index: takes the assets that still need work and turns them
//  into embeddings and OCR text.
//
//  Why the scheduling lives here and not in a PhotoKit loop
//  -------------------------------------------------------
//  Everything in this file is deliberately independent of PhotoKit. What needs
//  testing is not "does PhotoKit return assets" -- that is Apple's code -- but
//  the decisions this app makes: when to stop, what to retry, what to defer when
//  the device is hot, and how to guarantee that a run which has been superseded
//  cannot write. Those are the parts that produce silent corruption, and they are
//  testable exactly because no framework is involved.
//
//  The one decision worth stating up front:
//
//      **OCR is deferred, never downgraded.**
//
//  Vision's `.fast` recognition level supports six languages and `zh-Hans` is not
//  among them. So "step OCR down a level when the device is hot" is not a
//  lower-quality OCR, it is *no OCR for Chinese* -- it would quietly stop
//  indexing every Chinese receipt while still looking like it was working. The
//  only honest degradation is to leave the work for later.
//
//  Image embedding is different: it degrades gracefully and is the whole point of
//  the feature, so it continues under thermal pressure and only stops when the
//  system says `.critical`.
//

import Foundation
import CoreGraphics

// ---------------------------------------------------------------------------
// MARK: - What an asset is

/// One photo that needs indexing, with only the parts the search cares about.
///
/// Deliberately not a `PHAsset`: holding one for the duration of a batch would
/// keep PhotoKit objects alive across an await, and the batch works from a
/// snapshot of metadata anyway.
struct IndexableAsset: Equatable, Sendable {
    var metadata: AIPhotoSearchStore.AssetMetadata
    /// `false` for assets that cannot contain legible text (a video's poster
    /// frame, an asset already known to be a screenshot whose text was read on a
    /// previous run).
    var wantsTextRecognition: Bool = true

    var assetID: String { metadata.assetID }
}

// ---------------------------------------------------------------------------
// MARK: - Dependencies

protocol PendingAssetProviding: Sendable {
    /// Assets still needing work, newest first. Must respect retry times, which
    /// is what makes backoff work without any state in this file.
    func pendingAssets(limit: Int) throws -> [IndexableAsset]
    /// Library size, for a progress fraction. Best effort.
    func totalAssetCount() throws -> Int
}

protocol AssetImageLoading: Sendable {
    /// A decodable image, or `nil` when the asset is temporarily unavailable.
    ///
    /// `nil` is not an error. An iCloud original that has not been downloaded is
    /// the normal case on a fresh device, and treating it as a failure would
    /// count a healthy photo towards a failure budget and eventually park it.
    func image(for asset: IndexableAsset) throws -> CGImage?
}

protocol AssetEmbedding: Sendable {
    var dimension: Int { get }
    func embedding(cgImage: CGImage) throws -> [Float]
}

protocol AssetTextRecognizing: Sendable {
    func recognize(cgImage: CGImage) throws -> PhotoTextRecognition
}

// ---------------------------------------------------------------------------
// MARK: - Conditions and policy

enum ThermalPressure: Int, Equatable, Sendable, Comparable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    static func < (first: ThermalPressure, second: ThermalPressure) -> Bool {
        first.rawValue < second.rawValue
    }

    /// Maps the system state. Kept out of the pipeline's logic so tests can
    /// state a condition directly instead of trying to heat up a machine.
    static func from(_ state: ProcessInfo.ThermalState) -> ThermalPressure {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .fair
        }
    }
}

struct PhotoSearchIndexConditions: Equatable, Sendable {
    var thermal: ThermalPressure = .nominal
    var lowPowerMode = false

    /// What the app should sample before each batch.
    static func current() -> PhotoSearchIndexConditions {
        PhotoSearchIndexConditions(
            thermal: ThermalPressure.from(ProcessInfo.processInfo.thermalState),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }
}

/// How much work to attempt under the current conditions.
struct PhotoSearchIndexPolicy: Equatable, Sendable {
    var batchSize: Int
    var recognizesText: Bool
    var proceeds: Bool
    /// Why work was reduced or stopped, for the UI and the log.
    var reason: String?

    static let baseBatchSize = 32

    /// What a device with nothing wrong with it should use.
    static func unconstrained(batchSize: Int) -> PhotoSearchIndexPolicy {
        PhotoSearchIndexPolicy(batchSize: batchSize, recognizesText: true, proceeds: true, reason: nil)
    }

    /// Resolves the policy for a set of conditions.
    ///
    /// The asymmetry is intentional: `.serious` and Low Power Mode drop OCR but
    /// keep embedding, because embedding is what makes search work at all and
    /// degrades gracefully, whereas OCR has no graceful degradation available.
    static func resolve(
        _ conditions: PhotoSearchIndexConditions, batchSize: Int = baseBatchSize
    ) -> PhotoSearchIndexPolicy {
        if conditions.thermal == .critical {
            return PhotoSearchIndexPolicy(
                batchSize: 0, recognizesText: false, proceeds: false,
                reason: "device is critically hot; indexing paused"
            )
        }
        if conditions.thermal == .serious {
            return PhotoSearchIndexPolicy(
                batchSize: max(1, batchSize / 2), recognizesText: false, proceeds: true,
                reason: "device is hot; text recognition deferred"
            )
        }
        if conditions.lowPowerMode {
            return PhotoSearchIndexPolicy(
                batchSize: max(1, batchSize / 2), recognizesText: false, proceeds: true,
                reason: "low power mode; text recognition deferred"
            )
        }
        return unconstrained(batchSize: batchSize)
    }
}

// ---------------------------------------------------------------------------
// MARK: - Progress and state

struct PhotoSearchIndexProgress: Equatable, Sendable {
    enum Phase: String, Equatable, Sendable {
        case idle
        case embedding
        case textRecognition
        case finished
    }

    var completed = 0
    var failed = 0
    /// Assets that were not attempted because they are not on this device.
    var unavailable = 0
    /// Assets embedded but whose text is still owed because OCR was deferred.
    var deferredText = 0
    var total = 0
    var phase: Phase = .idle

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(completed + failed + unavailable) / Double(total))
    }

    var isComplete: Bool { phase == .finished }
}

enum PhotoSearchIndexState: Equatable, Sendable {
    case idle
    case running(PhotoSearchIndexProgress)
    case paused(PhotoSearchIndexProgress)
    /// Stopped by the device rather than by the user. Distinct from `paused` so
    /// the UI can say why and resume on its own.
    case deferred(PhotoSearchIndexProgress, reason: String)
    case finished(PhotoSearchIndexProgress)
    case failed(String)

    var progress: PhotoSearchIndexProgress {
        switch self {
        case .idle: PhotoSearchIndexProgress()
        case .running(let progress), .paused(let progress),
             .deferred(let progress, _), .finished(let progress):
            progress
        case .failed: PhotoSearchIndexProgress()
        }
    }
}

enum PhotoSearchIndexStep: Equatable, Sendable {
    case processed(PhotoSearchIndexProgress)
    /// Nothing left to do.
    case finished(PhotoSearchIndexProgress)
    case paused(PhotoSearchIndexProgress)
    case deferred(PhotoSearchIndexProgress, reason: String)
    /// A newer run started, so this one stopped without writing.
    case superseded
}

// ---------------------------------------------------------------------------
// MARK: - Coordinator

/// Runs the indexing loop one batch at a time.
///
/// `step` is synchronous and holds all the logic; `run` is a thin async loop
/// that adds progress throttling and condition sampling. Splitting them is what
/// makes the interesting behaviour -- pause boundaries, backoff, supersession --
/// testable without timing.
/// Drives the index one batch at a time.
///
/// ## Why this type is locked rather than `@MainActor`
///
/// The batch loop does image decoding and model inference -- seconds of work per
/// batch -- so it cannot run on the main actor. But `pause()` is called from the
/// main actor (the user tapping "pause"), and the UI reads `state`/`progress`.
/// That is two threads touching the same fields, which Swift 6 rejects and which
/// was a genuine race: pausing mid-batch could be lost, or read a half-updated
/// progress snapshot.
///
/// The fix is real synchronisation, not `@unchecked Sendable` alone. All four
/// mutable fields sit behind `lock`, and `onStateChange` is invoked *after* the
/// lock is released so a callback that re-enters cannot deadlock.
///
/// `step` additionally works on a **local copy** of progress and publishes it at
/// the end, so the lock is never held across decoding or inference. Holding it
/// for a whole batch would make `pause()` block the main thread for seconds --
/// the exact stall this design exists to avoid.
final class PhotoSearchIndexCoordinator: @unchecked Sendable {

    private let store: AIPhotoSearchStore
    private let source: PendingAssetProviding
    private let imageLoader: AssetImageLoading
    private let embedder: AssetEmbedding
    private let recognizer: AssetTextRecognizing?
    private let now: @Sendable () -> Date
    private let baseBatchSize: Int

    /// Guards every field below it.
    private let lock = NSLock()
    private var _state: PhotoSearchIndexState = .idle
    private var _progress = PhotoSearchIndexProgress()
    /// Bumped whenever a run starts. A step that finds a different value aborts
    /// without writing, which is the guarantee that a superseded run cannot
    /// corrupt the index.
    private var _generation: UInt64 = 0
    private var _pauseRequested = false
    private var _onStateChange: (@Sendable (PhotoSearchIndexState) -> Void)?

    var state: PhotoSearchIndexState { lock.withLock { _state } }
    var progress: PhotoSearchIndexProgress { lock.withLock { _progress } }
    var generation: UInt64 { lock.withLock { _generation } }

    /// Called on state changes. Throttling happens in `run`; `step` publishes
    /// only phase changes and completion, which are always worth sending.
    var onStateChange: (@Sendable (PhotoSearchIndexState) -> Void)? {
        get { lock.withLock { _onStateChange } }
        set { lock.withLock { _onStateChange = newValue } }
    }

    init(
        store: AIPhotoSearchStore,
        source: PendingAssetProviding,
        imageLoader: AssetImageLoading,
        embedder: AssetEmbedding,
        recognizer: AssetTextRecognizing? = nil,
        baseBatchSize: Int = PhotoSearchIndexPolicy.baseBatchSize,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.source = source
        self.imageLoader = imageLoader
        self.embedder = embedder
        self.recognizer = recognizer
        self.now = now
        self.baseBatchSize = baseBatchSize
    }

    /// Starts a new run, invalidating any in flight.
    @discardableResult
    func beginRun() -> UInt64 {
        lock.lock()
        _generation += 1
        _pauseRequested = false
        _progress = PhotoSearchIndexProgress(phase: .embedding)
        _state = .running(_progress)
        let generation = _generation
        lock.unlock()
        return generation
    }

    /// Requests a pause. Safe to call from the main actor: it takes the lock only
    /// to flip a flag and snapshot progress, never to wait for the batch.
    func pause() {
        lock.lock()
        _pauseRequested = true
        if case .running(let current) = _state {
            _progress = current
        }
        _state = .paused(_progress)
        let snapshot = _state
        let handler = _onStateChange
        lock.unlock()
        handler?(snapshot)
    }

    func resume() {
        lock.withLock { _pauseRequested = false }
    }

    private var isPauseRequested: Bool { lock.withLock { _pauseRequested } }

    private func isCurrent(_ run: UInt64) -> Bool { lock.withLock { run == _generation } }

    /// Writes a progress snapshot and, optionally, the accompanying state.
    private func commit(
        progress newProgress: PhotoSearchIndexProgress,
        state newState: PhotoSearchIndexState? = nil,
        publish: Bool = false
    ) {
        lock.lock()
        _progress = newProgress
        if let newState { _state = newState }
        let handler = _onStateChange
        let snapshot = _state
        lock.unlock()
        if publish { handler?(snapshot) }
    }

    /// Processes one batch.
    ///
    /// - Parameters:
    ///   - run: the generation this batch belongs to, as returned by
    ///     `beginRun()`. Passed in rather than read from `self` because a
    ///     synchronous step cannot otherwise notice that a newer run started --
    ///     the check at entry would always compare a value against itself.
    ///   - conditions: sampled by the caller so a batch does not change policy
    ///     halfway through.
    @discardableResult
    func step(generation run: UInt64, conditions: PhotoSearchIndexConditions) throws -> PhotoSearchIndexStep {
        guard isCurrent(run) else { return .superseded }

        if isPauseRequested {
            let snapshot = progress
            commit(progress: snapshot, state: .paused(snapshot), publish: true)
            return .paused(snapshot)
        }

        let policy = PhotoSearchIndexPolicy.resolve(conditions, batchSize: baseBatchSize)
        guard policy.proceeds else {
            let snapshot = progress
            let reason = policy.reason ?? "deferred"
            commit(progress: snapshot, state: .deferred(snapshot, reason: reason), publish: true)
            return .deferred(snapshot, reason: reason)
        }

        let assets = try source.pendingAssets(limit: policy.batchSize)
        guard !assets.isEmpty else {
            var finished = progress
            finished.phase = .finished
            commit(progress: finished, state: .finished(finished), publish: true)
            return .finished(finished)
        }

        // Everything below runs without the lock held.
        var working = progress
        if working.total == 0 {
            working.total = (try? source.totalAssetCount()) ?? assets.count
        }

        var touchedText = false
        for asset in assets {
            // Re-checked per asset, not per batch: pausing has to take effect
            // within a batch or a large batch would ignore it for seconds.
            guard isCurrent(run), !isPauseRequested else {
                let paused = isPauseRequested
                commit(progress: working, state: paused ? .paused(working) : nil, publish: true)
                return .paused(working)
            }
            try process(asset: asset, policy: policy, touchedText: &touchedText, progress: &working)
        }

        if touchedText { working.phase = .textRecognition }
        commit(progress: working, state: .running(working))
        return .processed(working)
    }

    /// Processes one asset, translating every outcome into index state rather
    /// than into control flow: one bad asset must never stop the run.
    private func process(
        asset: IndexableAsset,
        policy: PhotoSearchIndexPolicy,
        touchedText: inout Bool,
        progress: inout PhotoSearchIndexProgress
    ) throws {
        let image: CGImage?
        do {
            image = try imageLoader.image(for: asset)
        } catch {
            try store.markFailed(assetID: asset.assetID, error: String(describing: error))
            progress.failed += 1
            return
        }

        guard let image else {
            // Not on this device. Deferred, not failed -- see `deferAsset`.
            try store.deferAsset(assetID: asset.assetID, until: now().addingTimeInterval(6 * 3600))
            progress.unavailable += 1
            return
        }

        do {
            let vector = try embedder.embedding(cgImage: image)
            try store.storeEmbedding(assetID: asset.assetID, vector: vector)
        } catch {
            try store.markFailed(assetID: asset.assetID, error: String(describing: error))
            progress.failed += 1
            return
        }

        // Metadata is attached to the same row the embedding just landed in.
        try store.upsertMetadata([asset.metadata])

        if asset.wantsTextRecognition, policy.recognizesText, let recognizer {
            do {
                let recognition = try recognizer.recognize(cgImage: image)
                try store.storeText(assetID: asset.assetID, text: recognition.text)
                touchedText = true
            } catch {
                // A failed OCR pass must not fail the asset: the embedding is
                // already stored and searchable, and the text can be retried.
                progress.deferredText += 1
            }
        } else if asset.wantsTextRecognition {
            progress.deferredText += 1
        }

        progress.completed += 1
    }

    /// Samples the conditions before each batch and publishes progress at most
    /// four times a second.
    ///
    /// The throttle is not cosmetic. Publishing every asset rebuilds the whole
    /// SwiftUI tree several times a second on a 100k index, which is the
    /// difference between a usable app and a frozen one.
    func run(
        conditions: @escaping @Sendable () -> PhotoSearchIndexConditions = { .current() },
        progressInterval: TimeInterval = 0.25
    ) async {
        let run = beginRun()
        var lastPublished = Date.distantPast
        while isCurrent(run) {
            let step: PhotoSearchIndexStep
            do {
                step = try self.step(generation: run, conditions: conditions())
            } catch {
                commit(progress: progress, state: .failed(String(describing: error)), publish: true)
                return
            }

            switch step {
            case .superseded, .paused, .deferred, .finished:
                let snapshot = state
                onStateChange?(snapshot)
                return
            case .processed:
                let timestamp = now()
                if timestamp.timeIntervalSince(lastPublished) >= progressInterval {
                    lastPublished = timestamp
                    let snapshot = state
                    onStateChange?(snapshot)
                }
            }
        }
    }
}
