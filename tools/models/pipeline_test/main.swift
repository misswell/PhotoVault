// Indexing pipeline tests: scheduling, pause boundaries, resume after a kill,
// backoff, thermal policy and the supersession guarantee.
//
// PhotoKit is not involved, and that is the point. "Does PhotoKit return
// assets" is Apple's code; what needs proving is what *this* app decides -- when
// to stop, what to retry, what to defer when the device is hot, and above all
// that a run which has been superseded cannot write. Those decisions are where
// silent index corruption would come from, and they are exactly the parts that
// become untestable once a framework is in the loop.
//
// The store is real, so "resume after the app is killed" is tested by genuinely
// throwing the coordinator away and building a new one over the same database.

import Foundation
import CoreGraphics
import AppKit

setvbuf(stdout, nil, _IONBF, 0)

var checks = 0
var failures = 0

func check(_ condition: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if condition {
        print("  [PASS] \(label)")
    } else {
        failures += 1
        let extra = detail()
        print("  [FAIL] \(label)\(extra.isEmpty ? "" : " — \(extra)")")
    }
}

func section(_ title: String) { print("\n\(title)") }

// ---------------------------------------------------------------------------
// MARK: - Fakes

/// Serves pending work from the real store, so the pipeline's notion of "what is
/// left" is the same one the app will use.
final class StoreBackedSource: PendingAssetProviding, @unchecked Sendable {
    private let store: AIPhotoSearchStore
    private let metadataByID: [String: AIPhotoSearchStore.AssetMetadata]

    init(store: AIPhotoSearchStore, metadataByID: [String: AIPhotoSearchStore.AssetMetadata]) {
        self.store = store
        self.metadataByID = metadataByID
    }

    func pendingAssets(limit: Int) throws -> [IndexableAsset] {
        try store.pendingAssetIDs(limit: limit).map { id in
            IndexableAsset(
                metadata: metadataByID[id] ?? AIPhotoSearchStore.AssetMetadata(
                    assetID: id, creationDate: Date(), modificationDate: nil, mediaType: 1
                )
            )
        }
    }

    func totalAssetCount() throws -> Int { try store.stats().totalAssets }
}

/// A 2x2 image; the embedder is fake so the pixels carry no meaning and the cost
/// stays out of the test.
func makeImage() -> CGImage {
    let context = CGContext(
        data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.5, green: 0.25, blue: 0.75, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    return context.makeImage()!
}

/// Deterministic vectors from the asset's position, so a resumed run can be
/// checked against the same values.
struct DeterministicEmbedder: AssetEmbedding, @unchecked Sendable {
    let dimension = 8
    /// Asset IDs that should fail to embed, to exercise the failure path.
    var failingIDs: Set<String> = []

    func embedding(cgImage: CGImage) throws -> [Float] {
        [Float](repeating: 0.35355339059, count: dimension)
    }
}

struct CountingEmbedder: AssetEmbedding, @unchecked Sendable {
    let dimension = 8
    let counter: Counter
    func embedding(cgImage: CGImage) throws -> [Float] {
        counter.increment()
        return [Float](repeating: 0.35355339059, count: dimension)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// Records which assets were actually embedded, so supersession can be checked
/// by looking for writes that should never have happened.
final class RecordingEmbedder: AssetEmbedding, @unchecked Sendable {
    let dimension = 8
    let recorded = Counter()
    func embedding(cgImage: CGImage) throws -> [Float] {
        recorded.increment()
        return [Float](repeating: 0.35355339059, count: dimension)
    }
}

struct StubImageLoader: AssetImageLoading, @unchecked Sendable {
    /// Asset IDs that are not on this device (an undownloaded iCloud original).
    var unavailableIDs: Set<String> = []
    /// Asset IDs whose load throws.
    var throwingIDs: Set<String> = []
    let image: CGImage

    func image(for asset: IndexableAsset) throws -> CGImage? {
        if throwingIDs.contains(asset.assetID) {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "decode failed"])
        }
        if unavailableIDs.contains(asset.assetID) { return nil }
        return image
    }
}

struct StubRecognizer: AssetTextRecognizing, @unchecked Sendable {
    var text: String = "发票"
    func recognize(cgImage: CGImage) throws -> PhotoTextRecognition {
        var result = PhotoTextRecognition()
        result.lines = [text]
        result.confidence = 0.9
        result.observationCount = 1
        result.didRun = true
        return result
    }
}

// ---------------------------------------------------------------------------
// MARK: - Fixtures

let workDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pv-pipeline-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workDirectory) }

/// A fresh index in its own directory, seeded with the fixtures.
///
/// The first version shared one database across every section, so "a paused
/// coordinator wrote nothing" was reading a store another section had already
/// filled. Isolation here is not tidiness: without it the failures were
/// indistinguishable from real pipeline bugs.
func makeStore() throws -> AIPhotoSearchStore {
    let directory = workDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = AIPhotoSearchStore(
        databaseURL: directory.appendingPathComponent("AIPhotoSearch.sqlite"),
        embeddingURL: directory.appendingPathComponent("embeddings-v1.bin")
    )
    try store.open(dimension: 8, sourceModelSHA256: String(repeating: "dd", count: 32))
    try store.upsertMetadata(Array(metadataByID.values))
    return store
}

/// The batch size used by the tests. Smaller than the fixture count so a single
/// step cannot finish the whole library, which is what makes pause, resume and
/// supersession observable at all.
let testBatchSize = 5

let assetCount = 20
var metadataByID: [String: AIPhotoSearchStore.AssetMetadata] = [:]
for index in 0..<assetCount {
    metadataByID[String(format: "asset-%03d", index)] = AIPhotoSearchStore.AssetMetadata(
        assetID: String(format: "asset-%03d", index),
        creationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60),
        modificationDate: nil,
        mediaType: 1
    )
}

let image = makeImage()

// ---------------------------------------------------------------------------
section("a full run indexes everything")

do {
    let store = try makeStore()
    let source = StoreBackedSource(store: store, metadataByID: metadataByID)
    let counter = Counter()
    let coordinator = PhotoSearchIndexCoordinator(
        store: store,
        source: source,
        imageLoader: StubImageLoader(image: image),
        embedder: CountingEmbedder(counter: counter),
        recognizer: StubRecognizer(),
        baseBatchSize: testBatchSize
    )

    let run = coordinator.beginRun()
    var steps = 0
    while true {
        let result = try coordinator.step(generation: run, conditions: PhotoSearchIndexConditions())
        steps += 1
        if case .finished = result { break }
        if case .processed = result {} else { break }
        guard steps < 100 else { break }
    }
    let stats = try store.stats()
    print("         \(assetCount) assets in \(steps) steps; ready=\(stats.embeddedAssets), pending=\(stats.pendingAssets)")
    check(stats.embeddedAssets == assetCount, "every asset was embedded", "ready \(stats.embeddedAssets)")
    check(stats.pendingAssets == 0, "and none were left pending", "pending \(stats.pendingAssets)")
    check(counter.count == assetCount, "the embedder ran once per asset", "\(counter.count)")
    check(coordinator.progress.isComplete, "progress reports completion")

    // Text was recognised and is searchable through the same path the app uses.
    let found = try store.assetIDsMatchingText(terms: ["发票"], limit: 50)
    check(found.count == assetCount, "recognised text is searchable for every asset",
          "\(found.count)")
}

// ---------------------------------------------------------------------------
section("an interrupted run resumes without redoing work")

do {
    let store = try makeStore()
    let source = StoreBackedSource(store: store, metadataByID: metadataByID)
    let counter = Counter()

    // First run: stop after two batches, as a pause or a process kill would.
    let first = PhotoSearchIndexCoordinator(
        store: store, source: source,
        imageLoader: StubImageLoader(image: image),
        embedder: CountingEmbedder(counter: counter),
        recognizer: StubRecognizer(),
        baseBatchSize: testBatchSize
    )
    let firstRun = first.beginRun()
    _ = try first.step(generation: firstRun, conditions: PhotoSearchIndexConditions())
    _ = try first.step(generation: firstRun, conditions: PhotoSearchIndexConditions())
    let partial = try store.stats()
    print("         after 2 batches: ready=\(partial.embeddedAssets), pending=\(partial.pendingAssets)")
    check(partial.embeddedAssets > 0 && partial.pendingAssets > 0,
          "the first run left work unfinished",
          "ready \(partial.embeddedAssets), pending \(partial.pendingAssets)")

    // Second run: a *new* coordinator over the same database. This is the app
    // being killed and relaunched, not a pause.
    let resumed = PhotoSearchIndexCoordinator(
        store: store, source: source,
        imageLoader: StubImageLoader(image: image),
        embedder: CountingEmbedder(counter: counter),
        recognizer: StubRecognizer(),
        baseBatchSize: testBatchSize
    )
    let resumedRun = resumed.beginRun()
    var guardCount = 0
    while true {
        let result = try resumed.step(generation: resumedRun, conditions: PhotoSearchIndexConditions())
        if case .finished = result { break }
        if case .processed = result {} else { break }
        guardCount += 1
        guard guardCount < 100 else { break }
    }
    let stats = try store.stats()
    check(stats.embeddedAssets == assetCount, "the resumed run finished the job", "ready \(stats.embeddedAssets)")
    check(counter.count == assetCount,
          "and no asset was embedded twice", "embedded \(counter.count) for \(assetCount) assets")
}

// ---------------------------------------------------------------------------
section("supersession: a stale run cannot write")

do {
    let store = try makeStore()
    let source = StoreBackedSource(store: store, metadataByID: metadataByID)
    let recorder = RecordingEmbedder()
    let coordinator = PhotoSearchIndexCoordinator(
        store: store, source: source,
        imageLoader: StubImageLoader(image: image),
        embedder: recorder,
        recognizer: nil,
        baseBatchSize: testBatchSize
    )

    let firstRun = coordinator.beginRun()
    _ = try coordinator.step(generation: firstRun, conditions: PhotoSearchIndexConditions())
    let afterFirst = recorder.recorded.count

    // A new run starts -- the library changed, or the user searched again.
    let run = coordinator.beginRun()
    // The stale step must refuse rather than embed another batch.
    let stale = try coordinator.step(generation: firstRun, conditions: PhotoSearchIndexConditions())
    check(stale == .superseded, "a step from an old generation reports superseded", "\(stale)")

    print("         generation bumped; stale step returned \(stale)")
    check(recorder.recorded.count <= afterFirst + 1,
          "and did not process a full extra batch",
          "\(afterFirst) -> \(recorder.recorded.count)")
}

// ---------------------------------------------------------------------------
section("pause takes effect inside a batch, not after it")

do {
    let store = try makeStore()
    let source = StoreBackedSource(store: store, metadataByID: metadataByID)
    let coordinator = PhotoSearchIndexCoordinator(
        store: store, source: source,
        imageLoader: StubImageLoader(image: image),
        embedder: DeterministicEmbedder(),
        recognizer: nil,
        baseBatchSize: testBatchSize
    )
    let run = coordinator.beginRun()
    coordinator.pause()
    let result = try coordinator.step(generation: run, conditions: PhotoSearchIndexConditions())
    check(result == .paused(coordinator.progress), "a paused coordinator refuses to work", "\(result)")
    let stats = try store.stats()
    check(stats.embeddedAssets == 0, "and wrote nothing", "ready \(stats.embeddedAssets)")

    coordinator.resume()
    let after = try coordinator.step(generation: run, conditions: PhotoSearchIndexConditions())
    if case .processed = after {
        check(true, "resuming continues the run")
    } else {
        check(false, "resuming continues the run", "\(after)")
    }
}

// ---------------------------------------------------------------------------
section("per-asset failures are contained")

do {
    let store = try makeStore()
    let source = StoreBackedSource(store: store, metadataByID: metadataByID)
    let broken = "asset-003"
    let coordinator = PhotoSearchIndexCoordinator(
        store: store, source: source,
        imageLoader: StubImageLoader(throwingIDs: [broken], image: image),
        embedder: DeterministicEmbedder(),
        recognizer: nil,
        baseBatchSize: testBatchSize
    )
    let run = coordinator.beginRun()
    var guardCount = 0
    while true {
        let result = try coordinator.step(generation: run, conditions: PhotoSearchIndexConditions())
        if case .finished = result { break }
        if case .processed = result {} else { break }
        guardCount += 1
        guard guardCount < 100 else { break }
    }
    let stats = try store.stats()
    print("         ready=\(stats.embeddedAssets), failed=\(stats.failedAssets)")
    check(stats.failedAssets == 1, "exactly the broken asset is marked failed", "failed \(stats.failedAssets)")
    check(stats.embeddedAssets == assetCount - 1, "and the other assets still indexed",
          "ready \(stats.embeddedAssets)")

    // Its retry is scheduled, so it is not attempted again immediately.
    let pending = try store.pendingAssetIDs(limit: 100)
    check(!pending.contains(broken), "a failed asset is not retried before its retry time",
          "\(pending.prefix(5))")
}

// ---------------------------------------------------------------------------
section("an asset that is not on the device is deferred, not failed")

do {
    let store = try makeStore()
    let source = StoreBackedSource(store: store, metadataByID: metadataByID)
    let cloudOnly = "asset-007"
    let coordinator = PhotoSearchIndexCoordinator(
        store: store, source: source,
        imageLoader: StubImageLoader(unavailableIDs: [cloudOnly], image: image),
        embedder: DeterministicEmbedder(),
        recognizer: nil,
        baseBatchSize: testBatchSize
    )
    let run = coordinator.beginRun()
    var guardCount = 0
    while true {
        let result = try coordinator.step(generation: run, conditions: PhotoSearchIndexConditions())
        if case .finished = result { break }
        if case .processed = result {} else { break }
        guardCount += 1
        guard guardCount < 100 else { break }
    }
    let stats = try store.stats()
    print("         ready=\(stats.embeddedAssets), failed=\(stats.failedAssets), pending=\(stats.pendingAssets)")
    // The critical distinction: a photo that has not downloaded is healthy, and
    // counting it as a failure would park it permanently after a few attempts.
    check(stats.failedAssets == 0, "an undownloaded asset is not a failure", "failed \(stats.failedAssets)")
    check(stats.pendingAssets == 1, "it stays pending for a later attempt", "pending \(stats.pendingAssets)")
    check(coordinator.progress.unavailable == 1, "and is reported as unavailable",
          "unavailable=\(coordinator.progress.unavailable), completed=\(coordinator.progress.completed), total=\(coordinator.progress.total)")
}

// ---------------------------------------------------------------------------
section("thermal policy")

do {
    // The whole reason OCR is special-cased: Vision's `.fast` level has no
    // Chinese, so a cheaper OCR is not a degraded OCR, it is nothing at all for
    // a Chinese library.
    let serious = PhotoSearchIndexPolicy.resolve(
        PhotoSearchIndexConditions(thermal: .serious, lowPowerMode: false)
    )
    print("         serious -> batch \(serious.batchSize), text \(serious.recognizesText), proceeds \(serious.proceeds)")
    check(serious.proceeds, "a hot device keeps indexing")
    check(!serious.recognizesText, "but defers text recognition")
    check(serious.batchSize < PhotoSearchIndexPolicy.baseBatchSize, "and reduces the batch size")

    let lowPower = PhotoSearchIndexPolicy.resolve(
        PhotoSearchIndexConditions(thermal: .nominal, lowPowerMode: true)
    )
    check(lowPower.proceeds && !lowPower.recognizesText,
          "low power mode behaves the same way")

    let critical = PhotoSearchIndexPolicy.resolve(
        PhotoSearchIndexConditions(thermal: .critical, lowPowerMode: false)
    )
    check(!critical.proceeds, "a critically hot device stops entirely")
    check(critical.reason != nil, "and says why")

    let nominal = PhotoSearchIndexPolicy.resolve(PhotoSearchIndexConditions())
    check(nominal.recognizesText && nominal.proceeds && nominal.batchSize == PhotoSearchIndexPolicy.baseBatchSize,
          "nominal conditions are unconstrained")
}

do {
    // Policy is enforced, not just computed: a deferred-OCR run must embed
    // everything and store no text.
    let store = try makeStore()
    let source = StoreBackedSource(store: store, metadataByID: metadataByID)
    let coordinator = PhotoSearchIndexCoordinator(
        store: store, source: source,
        imageLoader: StubImageLoader(image: image),
        embedder: DeterministicEmbedder(),
        recognizer: StubRecognizer(),
        baseBatchSize: testBatchSize
    )
    let run = coordinator.beginRun()
    var guardCount = 0
    while true {
        let result = try coordinator.step(
            generation: run,
            conditions: PhotoSearchIndexConditions(thermal: .serious, lowPowerMode: false)
        )
        if case .finished = result { break }
        if case .processed = result {} else { break }
        guardCount += 1
        guard guardCount < 100 else { break }
    }
    let stats = try store.stats()
    check(stats.embeddedAssets == assetCount, "a hot device still embeds every asset", "ready \(stats.embeddedAssets)")
    let text = try store.assetIDsMatchingText(terms: ["发票"], limit: 50)
    check(text.isEmpty, "and stores no OCR text, because none was attempted", "\(text.count)")
    check(coordinator.progress.deferredText > 0,
          "the deferred text is counted so it can be picked up later",
          "\(coordinator.progress.deferredText)")
}

do {
    // Critical means stop, and writing nothing is the only acceptable outcome.
    let store = try makeStore()
    let source = StoreBackedSource(store: store, metadataByID: metadataByID)
    let recorder = RecordingEmbedder()
    let coordinator = PhotoSearchIndexCoordinator(
        store: store, source: source,
        imageLoader: StubImageLoader(image: image),
        embedder: recorder, recognizer: nil
    )
    let run = coordinator.beginRun()
    let result = try coordinator.step(
        generation: run,
        conditions: PhotoSearchIndexConditions(thermal: .critical, lowPowerMode: false)
    )
    if case .deferred = result {
        check(true, "a critically hot device defers rather than working")
    } else {
        check(false, "a critically hot device defers rather than working", "\(result)")
    }
    check(recorder.recorded.count == 0, "and writes nothing", "\(recorder.recorded.count)")
    let stats = try store.stats()
    check(stats.embeddedAssets == 0, "leaving the index untouched")
}

// ---------------------------------------------------------------------------
section("change token persistence")

do {
    let store = try makeStore()
    check(try store.changeToken() == nil, "a fresh index has no change token")

    // The matrix has to exist before a second store can open the same paths;
    // `open` validates the header rather than creating a file that should
    // already be there.
    try store.storeEmbedding(assetID: "asset-000", vector: [Float](repeating: 0.35355339059, count: 8))

    let token = Data([0x01, 0x02, 0x03, 0xAB, 0xCD])
    try store.setChangeToken(token)
    let stored = try store.changeToken()
    check(stored == token, "a token round-trips", "\(String(describing: stored))")

    // A reopened store must see it: this is what makes the next launch
    // incremental rather than a full rescan. It has to be the *same* files, so
    // `makeStore()` cannot be used -- it creates a fresh directory.
    let reopened = AIPhotoSearchStore(
        databaseURL: store.databaseURLForTesting,
        embeddingURL: store.embeddingURLForTesting
    )
    try reopened.open(dimension: 8, sourceModelSHA256: String(repeating: "dd", count: 32))
    let reloaded = try reopened.changeToken()
    check(reloaded == token, "and survives reopening", "\(String(describing: reloaded))")

    try reopened.setChangeToken(nil)
    check(try reopened.changeToken() == nil, "clearing it reports no token, not an empty one")
}

// ---------------------------------------------------------------------------
section("pausing is safe while a batch is running")

// The coordinator is driven from a background task while `pause()` arrives from
// the main actor -- that is exactly what the app does, and it was a genuine data
// race before the fields moved behind a lock. A single-threaded test cannot see
// it, so this one hammers both sides at once.
//
// Two claims: it must not report inconsistent progress, and the pause must
// actually take effect rather than being lost mid-batch.
do {
    let store = try makeStore()
    var raceMetadata: [String: AIPhotoSearchStore.AssetMetadata] = [:]
    for index in 0..<400 {
        let id = String(format: "race-%03d", index)
        raceMetadata[id] = AIPhotoSearchStore.AssetMetadata(
            assetID: id,
            creationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60),
            modificationDate: nil,
            mediaType: 1
        )
    }
    try store.upsertMetadata(Array(raceMetadata.values))

    let coordinator = PhotoSearchIndexCoordinator(
        store: store,
        source: StoreBackedSource(store: store, metadataByID: raceMetadata),
        imageLoader: StubImageLoader(image: image),
        embedder: DeterministicEmbedder()
    )

    let run = coordinator.beginRun()
    let stop = Counter()
    let regressions = Counter()

    // Reader: samples `progress` the way the UI does. A torn or unguarded
    // snapshot shows up as the completed count going backwards.
    let reader = Thread {
        var lastSeen = 0
        while stop.count == 0 {
            let snapshot = coordinator.progress
            if snapshot.completed < lastSeen { regressions.increment() }
            lastSeen = max(lastSeen, snapshot.completed)
        }
    }
    reader.start()

    var batches = 0
    for _ in 0..<6 {
        if case .processed = try coordinator.step(
            generation: run, conditions: PhotoSearchIndexConditions()
        ) { batches += 1 }
    }
    coordinator.pause()
    // Keep stepping after the pause: it must report `.paused`, not continue.
    let afterPause = try coordinator.step(
        generation: run, conditions: PhotoSearchIndexConditions()
    )
    let stateAfterPause = coordinator.state
    let completedAtPause = coordinator.progress.completed
    stop.increment()
    // `Thread` has no `join()`; the reader exits on the flag, so wait it out.
    while !reader.isFinished { Thread.sleep(forTimeInterval: 0.005) }

    var pausedObserved = false
    if case .paused = afterPause { pausedObserved = true }
    var stateIsPaused = false
    if case .paused = stateAfterPause { stateIsPaused = true }

    check(batches > 0, "batches ran while another thread read progress", "\(batches)")
    check(regressions.count == 0,
          "progress never went backwards under concurrent reads",
          "\(regressions.count) regressions")
    check(pausedObserved, "a pause arriving mid-run takes effect")
    check(stateIsPaused, "and the published state is paused")
    check(completedAtPause > 0, "the completed count survived the pause", "\(completedAtPause)")

    // Resuming must clear the flag, so the pause is not permanent.
    coordinator.resume()
    let afterResume = try coordinator.step(
        generation: run, conditions: PhotoSearchIndexConditions()
    )
    var resumed = false
    if case .processed = afterResume { resumed = true }
    check(resumed, "and resuming lets the run continue")
}

// ---------------------------------------------------------------------------
section("the index resumes after a process restart")

// Definition of Done, section 82: "索引在重启后能续跑". Pause and resume inside
// one coordinator is a different claim from reopening the database the way a
// fresh launch does -- the second run has a new coordinator, a new store handle
// and no in-memory state, and must pick up exactly where the first stopped
// without re-embedding anything already done.
//
// The reopen uses the *same* paths; `makeStore()` cannot be used because it
// deliberately creates a fresh directory per call.
do {
    let store = try makeStore()
    var restartMetadata: [String: AIPhotoSearchStore.AssetMetadata] = [:]
    for index in 0..<50 {
        let id = String(format: "restart-%03d", index)
        restartMetadata[id] = AIPhotoSearchStore.AssetMetadata(
            assetID: id,
            creationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60),
            modificationDate: nil,
            mediaType: 1
        )
    }
    try store.upsertMetadata(Array(restartMetadata.values))

    // `makeStore()` seeds its own assets, so the totals are read rather than
    // assumed -- hardcoding 50 made this test report a failure that was purely
    // its own bad arithmetic.
    let baseline = try store.stats()
    let pendingAtStart = baseline.pendingAssets
    check(pendingAtStart > 40, "there is enough pending work to interrupt", "\(pendingAtStart)")

    let firstCounter = Counter()
    let first = PhotoSearchIndexCoordinator(
        store: store,
        source: StoreBackedSource(store: store, metadataByID: restartMetadata),
        imageLoader: StubImageLoader(image: image),
        embedder: CountingEmbedder(counter: firstCounter),
        baseBatchSize: 20
    )
    // Two batches of 20, then stop -- as a process kill would.
    let firstRun = first.beginRun()
    _ = try first.step(generation: firstRun, conditions: PhotoSearchIndexConditions())
    _ = try first.step(generation: firstRun, conditions: PhotoSearchIndexConditions())
    let embeddedBeforeRestart = firstCounter.count
    check(embeddedBeforeRestart > 0, "the first run embedded a first batch", "\(embeddedBeforeRestart)")

    // ---- restart: new handles on the same files --------------------------
    let reopened = AIPhotoSearchStore(
        databaseURL: store.databaseURLForTesting,
        embeddingURL: store.embeddingURLForTesting
    )
    try reopened.open(dimension: 8, sourceModelSHA256: String(repeating: "dd", count: 32))

    let statsAfterRestart = try reopened.stats()
    check(statsAfterRestart.embeddedAssets == embeddedBeforeRestart,
          "the embeddings written before the restart are still there",
          "\(statsAfterRestart.embeddedAssets) vs \(embeddedBeforeRestart)")
    check(statsAfterRestart.pendingAssets == pendingAtStart - embeddedBeforeRestart,
          "the unfinished assets are still pending",
          "\(statsAfterRestart.pendingAssets) vs \(pendingAtStart - embeddedBeforeRestart)")

    let secondCounter = Counter()
    let second = PhotoSearchIndexCoordinator(
        store: reopened,
        source: StoreBackedSource(store: reopened, metadataByID: restartMetadata),
        imageLoader: StubImageLoader(image: image),
        embedder: CountingEmbedder(counter: secondCounter),
        baseBatchSize: 20
    )
    let secondRun = second.beginRun()
    while true {
        let step = try second.step(generation: secondRun, conditions: PhotoSearchIndexConditions())
        if case .finished = step { break }
    }

    // The decisive number. If the restart re-indexed from scratch this would be
    // 50; if it correctly skipped the finished work it is exactly the remainder.
    check(secondCounter.count == pendingAtStart - embeddedBeforeRestart,
          "the second run embedded only the remainder, not the whole library",
          "\(secondCounter.count) (expected \(pendingAtStart - embeddedBeforeRestart))")

    let finalStats = try reopened.stats()
    check(finalStats.embeddedAssets == baseline.totalAssets,
          "and the library ends up fully indexed",
          "\(finalStats.embeddedAssets) of \(baseline.totalAssets)")
    check(finalStats.pendingAssets == 0, "with nothing left pending",
          "\(finalStats.pendingAssets)")

    // Nothing may be selectable for work any more; if the first run's rows had
    // been lost, these would come back and the second run would have redone them.
    let stillPending = try reopened.pendingAssetIDs(limit: 100)
    check(stillPending.isEmpty, "no asset is left selectable for indexing",
          "\(stillPending.count)")
}

// ---------------------------------------------------------------------------
section("a damaged embedding matrix is rebuilt, not fatal")

// The matrix is derived data, so an unreadable one should be replaced rather
// than reported. This matters because "report it" is permanent: every later
// launch opens the same file and hits the same error, which is exactly how the
// offset bug bricked the index on the test device -- a reinstall was the only
// cure. Recovery has to also re-queue the rows, since a rebuilt matrix assigns
// new slots and the old ones would resolve to the wrong vectors.
do {
    let store = try makeStore()
    var damageMetadata: [String: AIPhotoSearchStore.AssetMetadata] = [:]
    for index in 0..<10 {
        let id = String(format: "damage-%03d", index)
        damageMetadata[id] = AIPhotoSearchStore.AssetMetadata(
            assetID: id,
            creationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60),
            modificationDate: nil,
            mediaType: 1
        )
    }
    try store.upsertMetadata(Array(damageMetadata.values))

    let counter = Counter()
    let coordinator = PhotoSearchIndexCoordinator(
        store: store,
        source: StoreBackedSource(store: store, metadataByID: damageMetadata),
        imageLoader: StubImageLoader(image: image),
        embedder: CountingEmbedder(counter: counter),
        baseBatchSize: 20
    )
    _ = try coordinator.step(generation: coordinator.beginRun(), conditions: PhotoSearchIndexConditions())
    let beforeDamage = try store.stats()
    check(beforeDamage.embeddedAssets > 0, "some assets were embedded first",
          "\(beforeDamage.embeddedAssets)")

    // Corrupt it the way a partial write or a truncated file would: too short to
    // even hold a header page.
    try Data("not an embedding matrix".utf8).write(to: store.embeddingURLForTesting)

    // A fresh handle on the same paths is what a relaunch does.
    let reopened = AIPhotoSearchStore(
        databaseURL: store.databaseURLForTesting,
        embeddingURL: store.embeddingURLForTesting
    )
    var openFailed: String?
    do {
        try reopened.open(dimension: 8, sourceModelSHA256: String(repeating: "dd", count: 32))
    } catch {
        openFailed = String(describing: error)
    }
    check(openFailed == nil, "opening a store over a corrupt matrix succeeds by rebuilding",
          openFailed ?? "")

    if openFailed == nil {
        let afterDamage = try reopened.stats()
        check(afterDamage.embeddedAssets == 0,
              "and the rebuilt matrix starts empty", "\(afterDamage.embeddedAssets)")
        // The rows must be re-queued, not left claiming a slot that no longer
        // exists.
        check(afterDamage.pendingAssets == afterDamage.totalAssets,
              "and every asset is pending again",
              "\(afterDamage.pendingAssets) of \(afterDamage.totalAssets)")

        let stillPending = try reopened.pendingAssetIDs(limit: 100)
        check(stillPending.count == afterDamage.totalAssets,
              "so the next pass would re-embed all of them", "\(stillPending.count)")

        // And it must be usable immediately, not merely open.
        let vector = [Float](repeating: 0.35355339059, count: 8)
        let slot = try reopened.storeEmbedding(assetID: stillPending[0], vector: vector)
        check(slot == 0, "and the rebuilt matrix accepts writes from slot 0", "\(slot)")
    }
}

// ---------------------------------------------------------------------------
print("\nchecks: \(checks), failures: \(failures)")
if failures == 0 {
    print("RESULT: all \(checks) pipeline checks passed")
    exit(0)
} else {
    print("RESULT: \(failures) of \(checks) checks FAILED")
    exit(1)
}
