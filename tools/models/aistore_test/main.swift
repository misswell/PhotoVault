// AI search index store tests.
//
// Compiled together with `AIPhotoSearchStore.swift` and `EmbeddingStoreFile.swift`
// and run on macOS. The centrepiece is the swap-remove contract between the
// SQLite slot bookkeeping and the embedding matrix: if those two ever disagree,
// search returns one photo's vector for another photo, which is invisible in
// every other kind of test.
//
// PhotoKit is not available here, so the tests drive the store with synthetic
// asset identifiers. Everything the store itself owns -- schema, slot
// arithmetic, full-text search, filtering, WAL behaviour -- is real.

import Foundation

// Unbuffered so a thrown error does not swallow the progress already printed.
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

let workDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pv-ai-store-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workDirectory) }

let databaseURL = workDirectory.appendingPathComponent("AIPhotoSearch.sqlite")
let embeddingURL = workDirectory.appendingPathComponent("embeddings-v1.bin")

// Small dimension keeps the test fast; the store never assumes 768, which is the
// point of passing it in from the manifest.
let dimension = 16
let modelHash = String(repeating: "cd", count: 32)

/// Distinct, easily-identifiable vectors: component 0 encodes the asset index so
/// a mis-attributed vector is immediately obvious rather than a subtle score
/// change.
func vector(for index: Int) -> [Float] {
    var v = [Float](repeating: 0, count: dimension)
    v[0] = Float(index + 1)
    v[1] = Float((index * 7) % 13) / 13
    v[2] = 0.5
    var sum: Float = 0
    for value in v { sum += value * value }
    let norm = sum.squareRoot()
    for i in 0..<dimension { v[i] /= norm }
    return v
}

let expectedVector: [Int: [Float]] = (0..<40).reduce(into: [:]) { $0[$1] = vector(for: $1) }
func assetID(_ index: Int) -> String { String(format: "asset-%03d", index) }

let store = AIPhotoSearchStore(databaseURL: databaseURL, embeddingURL: embeddingURL)

// ---------------------------------------------------------------------------
section("schema and open")

try store.open(dimension: dimension, sourceModelSHA256: modelHash)
check(true, "store opens and creates its schema")
let emptyStats = try store.stats()
check(emptyStats.totalAssets == 0 && emptyStats.embeddedAssets == 0, "a fresh index is empty")

let trigram = store.supportsTrigramFullTextSearch()
print("         FTS5 compiled in: \(trigram)")

// ---------------------------------------------------------------------------
section("metadata upsert")

let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
func metadata(_ index: Int, dayOffset: Double = 0, favorite: Bool = false,
              coordinate: (Double, Double)? = nil) -> AIPhotoSearchStore.AssetMetadata {
    AIPhotoSearchStore.AssetMetadata(
        assetID: assetID(index),
        creationDate: referenceDate.addingTimeInterval(dayOffset * 86_400),
        modificationDate: nil,
        mediaType: index % 5 == 0 ? 2 : 1,
        isFavorite: favorite,
        width: 4032,
        height: 3024,
        latitude: coordinate?.0,
        longitude: coordinate?.1
    )
}

var batch: [AIPhotoSearchStore.AssetMetadata] = []
for index in 0..<40 {
    batch.append(metadata(
        index,
        dayOffset: Double(index),
        favorite: index % 4 == 0,
        coordinate: index % 3 == 0 ? (37.7749 + Double(index) * 0.001, -122.4194) : nil
    ))
}
try store.upsertMetadata(batch)
var stats = try store.stats()
check(stats.totalAssets == 40, "40 assets inserted", "total=\(stats.totalAssets)")
check(stats.assetsWithLocation == 14, "location count is right", "got \(stats.assetsWithLocation)")
check(stats.pendingAssets == 40, "every asset starts pending")

// ---------------------------------------------------------------------------
section("embedding storage")

for index in 0..<40 {
    let slot = try store.storeEmbedding(assetID: assetID(index), vector: expectedVector[index]!)
    if slot != index {
        check(false, "slots are assigned in insertion order", "asset \(index) got slot \(slot)")
        break
    }
}
stats = try store.stats()
check(stats.embeddedAssets == 40, "40 assets embedded", "got \(stats.embeddedAssets)")
check(stats.pendingAssets == 0, "nothing is pending after embedding")
try store.validateSlotConsistency()
check(true, "slot bookkeeping is consistent after a full pass")

// Re-upserting metadata must not disturb embedding state. PhotoKit re-reports
// assets constantly, and resetting status here would re-embed the library on
// every favourite toggle.
try store.upsertMetadata([metadata(5, favorite: true)])
stats = try store.stats()
check(stats.embeddedAssets == 40, "re-upserting metadata keeps existing embeddings",
      "embedded=\(stats.embeddedAssets)")
check(stats.pendingAssets == 0, "re-upserting metadata does not re-queue assets")

// ---------------------------------------------------------------------------
section("the swap-remove contract")

/// Reads the matrix and asserts every asset's slot holds its own vector.
/// This is the assertion that catches a mis-attributed embedding.
func assertSlotsHoldOwnVectors(_ label: String) {
    do {
        let reader = try EmbeddingMatrixReader(url: embeddingURL)
        let ids = (0..<40).map(assetID).filter { id in
            (try? store.embeddingSlots(for: [id])[id]) != nil
        }
        let slots = try store.embeddingSlots(for: ids)
        var mismatches: [String] = []
        for (index, id) in ids.enumerated() {
            guard let slot = slots[id] else { continue }
            let originalIndex = Int(id.suffix(3))!
            let stored = try reader.row(at: slot)
            let expected = expectedVector[originalIndex]!
            let delta = zip(stored, expected).map { abs($0 - $1) }.max() ?? 0
            if delta > 0.001 { mismatches.append("\(id)@slot\(slot) delta=\(delta)") }
            _ = index
        }
        check(mismatches.isEmpty, label,
              mismatches.isEmpty ? "" : "\(mismatches.count) mis-attributed: \(mismatches.prefix(3))")
    } catch {
        check(false, label, "\(error)")
    }
}

assertSlotsHoldOwnVectors("every asset's slot holds its own vector before deletion")

// Delete a middle asset. The last asset must move into its slot, in both the
// matrix and SQLite.
try store.removeEmbeddings(assetIDs: [assetID(10)])
stats = try store.stats()
check(stats.totalAssets == 39, "the deleted asset is gone", "total=\(stats.totalAssets)")
check(stats.embeddedAssets == 39, "its embedding row is gone", "embedded=\(stats.embeddedAssets)")
try store.validateSlotConsistency()
check(true, "slot bookkeeping is consistent after deleting a middle asset")

// asset-039 was in the last slot and must now occupy slot 10.
let movedSlots = try store.embeddingSlots(for: [assetID(39), assetID(10)])
check(movedSlots[assetID(10)] == nil, "the deleted asset no longer reports a slot")
check(movedSlots[assetID(39)] == 10, "the last asset moved into the vacated slot",
      "got \(String(describing: movedSlots[assetID(39)]))")
assertSlotsHoldOwnVectors("every remaining asset still holds its own vector after deletion")

// Delete several at once, including ones that will themselves be relocated by an
// earlier deletion in the same batch. Descending-slot ordering is what makes
// this safe.
try store.removeEmbeddings(assetIDs: [assetID(0), assetID(20), assetID(30), assetID(38)])
try store.validateSlotConsistency()
check(true, "slot bookkeeping is consistent after a multi-delete")
assertSlotsHoldOwnVectors("every remaining asset holds its own vector after a multi-delete")

stats = try store.stats()
check(stats.totalAssets == 35, "multi-delete removed exactly four assets", "total=\(stats.totalAssets)")
let readerAfter = try EmbeddingMatrixReader(url: embeddingURL)
check(readerAfter.count == 35, "the matrix has exactly the remaining rows", "count=\(readerAfter.count)")

// Deleting an asset with no embedding must be a no-op, not a crash.
try store.removeEmbeddings(assetIDs: ["never-existed"])
check(true, "deleting an unknown asset is a no-op")

// ---------------------------------------------------------------------------
section("failure tracking")

try store.upsertMetadata([metadata(7)])
try store.markFailed(assetID: assetID(7), error: "iCloud asset unavailable")
stats = try store.stats()
check(stats.failedAssets == 1, "a failed asset is counted", "failed=\(stats.failedAssets)")
// The backoff must keep it out of the immediate pending set.
let pendingNow = try store.pendingAssetIDs(limit: 100)
check(!pendingNow.contains(assetID(7)), "a just-failed asset is not immediately retried")

// ---------------------------------------------------------------------------
section("OCR text and full-text search")

try store.storeText(assetID: assetID(1), text: "发票 报销凭证 2023年5月 餐饮")
try store.storeText(assetID: assetID(2), text: "Receipt for lunch at the cafe")
try store.storeText(assetID: assetID(3), text: "登机牌 Boarding Pass 北京到上海")
try store.storeText(assetID: assetID(4), text: nil)

stats = try store.stats()
check(stats.assetsWithText == 3, "three assets carry text", "got \(stats.assetsWithText)")

// Two-character Chinese terms are the reason the instr() fallback exists:
// a trigram tokenizer cannot match them at all.
let invoice = try store.assetIDsMatchingText(terms: ["发票"], limit: 50)
check(invoice == [assetID(1)], "a 2-character Chinese term matches via the fallback", "got \(invoice)")

let receipt = try store.assetIDsMatchingText(terms: ["receipt"], limit: 50)
check(receipt.contains(assetID(2)), "an English term matches case-insensitively", "got \(receipt)")

let boarding = try store.assetIDsMatchingText(terms: ["登机牌"], limit: 50)
check(boarding.contains(assetID(3)), "a 3-character Chinese term matches", "got \(boarding)")

let anded = try store.assetIDsMatchingText(terms: ["发票", "报销"], limit: 50)
check(anded == [assetID(1)], "multiple terms are ANDed", "got \(anded)")

let noMatch = try store.assetIDsMatchingText(terms: ["发票", "登机牌"], limit: 50)
check(noMatch.isEmpty, "contradictory terms match nothing", "got \(noMatch)")

// The reason for choosing the trigram tokenizer over the default word
// tokenizer: it matches *inside* a token. A word tokenizer would index
// "boardingpass2023" as one token and find nothing for "dingp"; if this ever
// falls back to instr() silently, the fallback is doing the work and the FTS
// index is dead weight nobody would notice.
try store.storeText(assetID: assetID(5), text: "boardingpass2023 confirmation")
let midToken = try store.assetIDsMatchingText(terms: ["dingp"], limit: 50)
check(midToken == [assetID(5)], "trigram matches a substring inside a token", "got \(midToken)")

let caseFolded = try store.assetIDsMatchingText(terms: ["BOARDINGPASS"], limit: 50)
check(caseFolded == [assetID(5)], "full-text matching folds case", "got \(caseFolded)")

// ---------------------------------------------------------------------------
section("candidate filtering")

var filter = AISearchCandidateFilter()
filter.limit = 100
var candidates = try store.candidateAssetIDs(filter: filter)
// asset-007 was marked failed above but it kept its vector, so it is still a
// candidate: a failed re-index must not remove a searchable photo.
check(candidates.count == 35, "an empty filter returns every asset that has a vector",
      "got \(candidates.count)")
check(candidates.contains(assetID(7)),
      "an asset that failed a re-index but still has a vector stays searchable")

filter.creationDateAfter = referenceDate.addingTimeInterval(10 * 86_400)
candidates = try store.candidateAssetIDs(filter: filter)
check(candidates.allSatisfy { Int($0.suffix(3))! >= 10 }, "a date lower bound is respected",
      "got \(candidates.prefix(3))")

filter = AISearchCandidateFilter()
filter.mediaType = 2
candidates = try store.candidateAssetIDs(filter: filter)
check(candidates.allSatisfy { Int($0.suffix(3))! % 5 == 0 }, "media type filtering works")

filter = AISearchCandidateFilter()
filter.favoritesOnly = true
candidates = try store.candidateAssetIDs(filter: filter)
// Every multiple of four was created as a favourite; asset-005 was flipped to
// favourite by the metadata re-upsert above.
let expectedFavourites = Set((0..<40).filter { $0 % 4 == 0 || $0 == 5 }
    .filter { !Set([0, 10, 20, 30, 38]).contains($0) }
    .map(assetID))
check(Set(candidates) == expectedFavourites, "favourites-only returns exactly the favourites",
      "got \(candidates.sorted()), want \(expectedFavourites.sorted())")

filter = AISearchCandidateFilter()
filter.requiresLocation = true
candidates = try store.candidateAssetIDs(filter: filter)
check(candidates.allSatisfy { Int($0.suffix(3))! % 3 == 0 }, "location presence filtering works")

filter = AISearchCandidateFilter()
filter.latitudeRange = 37.7749...37.7749 + 0.02
filter.longitudeRange = -122.4294 ... -122.4094
candidates = try store.candidateAssetIDs(filter: filter)
check(!candidates.isEmpty && candidates.count < 35, "a GPS box narrows the candidate set",
      "got \(candidates.count)")

// Excluded terms must remove assets, which a vector score cannot express.
filter = AISearchCandidateFilter()
filter.requiredTextTerms = ["报销"]
candidates = try store.candidateAssetIDs(filter: filter)
check(candidates == [assetID(1)], "required text terms restrict candidates", "got \(candidates)")

filter = AISearchCandidateFilter()
filter.excludedTextTerms = ["报销"]
candidates = try store.candidateAssetIDs(filter: filter)
check(!candidates.contains(assetID(1)), "excluded text terms remove candidates")
check(!candidates.isEmpty, "exclusion does not empty the whole set")

// A candidate must still be present in the matrix, or ranking will silently
// shrink the result set.
let readySlots = try store.embeddingSlots(for: candidates)
check(readySlots.count == candidates.count, "every candidate has a resolvable slot",
      "\(readySlots.count) of \(candidates.count)")

// ---------------------------------------------------------------------------
section("WAL behaviour and a second connection")

// A second store instance over the same files simulates the app reopening the
// index. It must see committed writes even though the writer never checkpointed.
let reopened = AIPhotoSearchStore(databaseURL: databaseURL, embeddingURL: embeddingURL)
try reopened.open(dimension: dimension, sourceModelSHA256: modelHash)
let reopenedStats = try reopened.stats()
check(reopenedStats.totalAssets == stats.totalAssets,
      "a freshly opened store sees committed data through the WAL",
      "got \(reopenedStats.totalAssets), want \(stats.totalAssets)")
let reopenedSlots = try reopened.embeddingSlots(for: [assetID(1)])
check(reopenedSlots[assetID(1)] != nil, "a freshly opened store resolves slots")

// ---------------------------------------------------------------------------
section("rejecting an incompatible index")

// Must point at the *existing* matrix: a fresh path would simply create a new
// file and succeed, which tests nothing.
var modelRejected = false
do {
    _ = try AIPhotoSearchStore(databaseURL: databaseURL, embeddingURL: embeddingURL)
        .open(dimension: dimension, sourceModelSHA256: "ffff")
} catch { modelRejected = true }
check(modelRejected, "reopening the index with a different model is rejected")

var dimensionRejected = false
do {
    _ = try AIPhotoSearchStore(databaseURL: databaseURL, embeddingURL: embeddingURL)
        .open(dimension: 8, sourceModelSHA256: modelHash)
} catch { dimensionRejected = true }
check(dimensionRejected, "opening the index with a different dimension is rejected")

// ---------------------------------------------------------------------------
section("generation guard")

let generationBefore = store.currentGeneration
store.invalidateInFlightWork()
check(store.currentGeneration == generationBefore + 1, "invalidating advances the generation")
check(!store.isGenerationCurrent(generationBefore), "stale work is detected")
check(store.isGenerationCurrent(store.currentGeneration), "current work is accepted")

// ---------------------------------------------------------------------------
section("batch metadata reads")

do {
    // Derived from the live index, not hardcoded: earlier sections deliberately
    // remove assets, so a fixed list would test the fixture's history rather
    // than the reader.
    let live = try store.candidateAssetIDs(filter: AISearchCandidateFilter())
    check(live.count >= 3, "there are assets to read", "\(live.count)")
    let wanted = Array(live.prefix(3))
    let records = try store.metadata(for: wanted)
    check(records.count == wanted.count, "every requested id comes back",
          "\(records.count) of \(wanted.count)")

    let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.assetID, $0) })
    // Compared against the fixture that produced them, not against a fixed
    // date: the fixture spreads creation times across days, so an arbitrary live
    // asset is not the first one.
    func fixture(_ identifier: String) -> AIPhotoSearchStore.AssetMetadata {
        let index = Int(identifier.split(separator: "-").last ?? "0") ?? 0
        // The same arguments the batch was built with, including the day offset
        // and favourite flag; the default would compare against a different day.
        return metadata(
            index,
            dayOffset: Double(index),
            favorite: index % 4 == 0,
            coordinate: index % 3 == 0 ? (37.7749 + Double(index) * 0.001, -122.4194) : nil
        )
    }
    var dateMismatches = 0
    for identifier in wanted {
        guard let actual = byID[identifier] else { continue }
        if actual.creationDate != fixture(identifier).creationDate { dateMismatches += 1 }
    }
    check(dateMismatches == 0,
          "creation dates round-trip exactly, not through a timezone",
          "\(dateMismatches) of \(wanted.count) differ")

    let sample = byID[wanted[0]]
    check(sample?.width == 4032 && sample?.height == 3024,
          "dimensions round-trip", "\(String(describing: sample?.width))")
    check(sample?.mediaType == fixture(wanted[0]).mediaType,
          "media type round-trips")
    check(sample?.isFavorite == fixture(wanted[0]).isFavorite,
          "the favourite flag round-trips")

    let requested = Set(wanted)
    check(Set(records.map(\.assetID)) == requested,
          "no unrelated rows are returned")
    check(try store.metadata(for: []).isEmpty, "an empty request is not an error")
    check(try store.metadata(for: ["does-not-exist"]).isEmpty,
          "an unknown id yields nothing rather than a placeholder row")
}

// ---------------------------------------------------------------------------
section("deleting an asset leaves no trace")

do {
    // `removeEmbeddings` only releases the vector. A photo deleted from the
    // library has to disappear from every table, or search returns an id PhotoKit
    // can no longer resolve and the UI shows a gap.
    let doomed = assetID(1)   // carries text as well as an embedding
    let statsBefore = try store.stats()
    check(try store.assetIDsMatchingText(terms: ["发票"], limit: 100).contains(doomed),
          "the asset is searchable by text before deletion")
    check(try store.embeddingSlots(for: [doomed])[doomed] != nil,
          "and occupies a matrix slot")

    try store.removeAssets(assetIDs: [doomed])

    check(try store.metadata(for: [doomed]).isEmpty, "its metadata row is gone")
    check(!(try store.assetIDsMatchingText(terms: ["发票"], limit: 100).contains(doomed)),
          "its OCR text is gone from the full-text index")
    check(!(try store.candidateAssetIDs(filter: AISearchCandidateFilter()).contains(doomed)),
          "and it is no longer a search candidate")

    let statsAfter = try store.stats()
    check(statsAfter.totalAssets == statsBefore.totalAssets - 1,
          "the library count drops by exactly one",
          "\(statsBefore.totalAssets) -> \(statsAfter.totalAssets)")
    check(statsAfter.embeddedAssets == statsBefore.embeddedAssets - 1,
          "and the embedded count drops with it",
          "\(statsBefore.embeddedAssets) -> \(statsAfter.embeddedAssets)")

    // Every survivor must still resolve to a slot holding its own vector: a
    // deletion that frees a slot by swapping the last row in must not scramble
    // the bookkeeping.
    let survivors = (0..<40).map(assetID).filter { $0 != doomed }
    let slots = try store.embeddingSlots(for: survivors)
    check(slots.count == statsAfter.embeddedAssets,
          "every survivor still resolves to a slot",
          "\(slots.count) for \(statsAfter.embeddedAssets) embedded")
    assertSlotsHoldOwnVectors("after a deletion")

    // PhotoKit can report a deletion for an asset the index never saw.
    try store.removeAssets(assetIDs: ["never-indexed"])
    try store.removeAssets(assetIDs: [])
    check(true, "deleting unknown or empty id sets is harmless")
}

// ---------------------------------------------------------------------------
section("a model change rebuilds the index instead of bricking it")

// `open` rejects a mismatch on purpose and that stays true (asserted above).
// But the app calls `openRebuildingIfIncompatible`, because the manifest name is
// the model fingerprint: shipping any new conversion changes it, and "reject"
// alone would leave every existing user unable to ever search again.
do {
    let paths = (database: workDirectory.appendingPathComponent("model-change.sqlite"),
                 embeddings: workDirectory.appendingPathComponent("model-change.bin"))
    let old = "aaaa" + String(repeating: "0", count: 60)
    let new = "bbbb" + String(repeating: "0", count: 60)

    var store: AIPhotoSearchStore? = AIPhotoSearchStore(
        databaseURL: paths.database, embeddingURL: paths.embeddings
    )
    try store?.open(dimension: 8, sourceModelSHA256: old)
    try store?.upsertMetadata([
        AIPhotoSearchStore.AssetMetadata(
            assetID: "model-change-1", creationDate: Date(timeIntervalSince1970: 1),
            modificationDate: nil, mediaType: 1
        )
    ])
    _ = try store?.storeEmbedding(assetID: "model-change-1", vector: [Float](repeating: 0.35355339059, count: 8))
    check(try store?.stats().embeddedAssets == 1, "the old model indexed an asset")

    // The strict entry point must still refuse.
    let strict = AIPhotoSearchStore(databaseURL: paths.database, embeddingURL: paths.embeddings)
    var strictRefused = false
    do { try strict.open(dimension: 8, sourceModelSHA256: new) }
    catch is EmbeddingStoreError { strictRefused = true }
    check(strictRefused, "plain `open` still rejects a different model")

    // Release the writer so the rebuild can delete the files underneath it.
    store = nil

    let upgraded = AIPhotoSearchStore(databaseURL: paths.database, embeddingURL: paths.embeddings)
    var upgradeError: String?
    do { try upgraded.openRebuildingIfIncompatible(dimension: 8, sourceModelSHA256: new) }
    catch { upgradeError = String(describing: error) }
    check(upgradeError == nil, "the rebuilding entry point accepts the new model",
          upgradeError ?? "")

    if upgradeError == nil {
        let stats = try upgraded.stats()
        // The old embeddings are gone: they came from a different model and
        // cannot be compared against the new one's query vectors.
        check(stats.embeddedAssets == 0, "and the stale embeddings are gone",
              "\(stats.embeddedAssets)")
        check(stats.pendingAssets == stats.totalAssets && stats.totalAssets == 1,
              "while the asset itself is kept and re-queued",
              "\(stats.pendingAssets)/\(stats.totalAssets)")

        let slot = try upgraded.storeEmbedding(
            assetID: "model-change-1", vector: [Float](repeating: 0.35355339059, count: 8)
        )
        check(slot == 0, "and it is writable by the new model from slot 0", "\(slot)")

        let reopened = AIPhotoSearchStore(databaseURL: paths.database, embeddingURL: paths.embeddings)
        var reopenError: String?
        do { try reopened.open(dimension: 8, sourceModelSHA256: new) }
        catch { reopenError = String(describing: error) }
        check(reopenError == nil, "and it survives a relaunch on the new model", reopenError ?? "")
    }

    // A dimension change is the same situation and must recover the same way.
    let resized = AIPhotoSearchStore(databaseURL: paths.database, embeddingURL: paths.embeddings)
    var resizeError: String?
    do { try resized.openRebuildingIfIncompatible(dimension: 32, sourceModelSHA256: new) }
    catch { resizeError = String(describing: error) }
    check(resizeError == nil, "a dimension change also rebuilds rather than failing",
          resizeError ?? "")
}

// ---------------------------------------------------------------------------
print("\nchecks: \(checks), failures: \(failures)")
if failures == 0 {
    print("RESULT: all \(checks) search-index checks passed")
    exit(0)
} else {
    print("RESULT: \(failures) of \(checks) checks FAILED")
    exit(1)
}
