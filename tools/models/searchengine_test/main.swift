// End-to-end search tests: a query string in, ranked asset IDs out, through the
// real analyzer, gazetteer, SQLite store, mmap matrix and scoring code.
//
// Only the text tower is stubbed. That is deliberate: the *mechanics* being
// tested -- how clauses combine, how negation rejects, whether a metadata filter
// actually restricts the work -- need vectors whose relationships are known
// exactly. With real embeddings these properties are merely plausible, and a
// failure could be blamed on the model instead of the logic.
//
// The dimensions are named concepts rather than arbitrary numbers, so a failure
// says which concept went wrong:
//
//     0 = cat   1 = beach   2 = invoice   3 = dog   4 = something else

import Foundation

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
// A text tower that returns concept vectors.
//
// Matching is by substring so the test does not encode how the analyzer happens
// to split a clause -- that is a separate concern with its own tests, and
// coupling to it here would make an analyzer change look like an engine bug.

struct ConceptEncoder: QueryTextEncoding {
    var dimension: Int { 5 }
    /// Flip to exercise the dimension guard.
    var reportedDimension: Int?

    func encodeQuery(_ text: String) throws -> [Float] {
        let lowered = text.lowercased()
        var vector = [Float](repeating: 0, count: 5)
        if lowered.contains("cat") || lowered.contains("猫") { vector[0] = 1 }
        if lowered.contains("beach") || lowered.contains("沙滩") { vector[1] = 1 }
        if lowered.contains("invoice") || lowered.contains("发票") { vector[2] = 1 }
        if lowered.contains("dog") || lowered.contains("狗") { vector[3] = 1 }
        // Anything unrecognised lands on the "something else" axis, so an
        // unresolved place still produces a real vector rather than a zero one
        // that would silently pass the score floor.
        if vector.allSatisfy({ $0 == 0 }) { vector[4] = 1 }
        return vector
    }
}

struct MismatchedEncoder: QueryTextEncoding {
    var dimension: Int { 8 }
    func encodeQuery(_ text: String) throws -> [Float] {
        [Float](repeating: 0.1, count: 8)
    }
}

// ---------------------------------------------------------------------------
section("fixtures")

let workDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pv-engine-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workDirectory) }

let dimension = 5
let matrixURL = workDirectory.appendingPathComponent("embeddings-v1.bin")
let store = AIPhotoSearchStore(
    databaseURL: workDirectory.appendingPathComponent("AIPhotoSearch.sqlite"),
    embeddingURL: matrixURL
)
try store.open(dimension: dimension, sourceModelSHA256: String(repeating: "cc", count: 32))

func unit(_ values: [Float]) -> [Float] {
    let norm = values.reduce(0) { $0 + $1 * $1 }.squareRoot()
    return norm == 0 ? values : values.map { $0 / norm }
}

struct Asset {
    var id: String
    var vector: [Float]
    var year: Int
    var latitude: Double?
    var longitude: Double?
    var ocrText: String?
}

// Sanya, for the place tests; Beijing for the rest.
let sanya = (latitude: 18.2528, longitude: 109.5119)
let beijing = (latitude: 39.9042, longitude: 116.4074)

let assets: [Asset] = [
    Asset(id: "cat-indoors", vector: unit([1, 0, 0, 0, 0]), year: 2022,
          latitude: beijing.latitude, longitude: beijing.longitude, ocrText: nil),
    Asset(id: "cat-on-beach", vector: unit([1, 1, 0, 0, 0]), year: 2023,
          latitude: sanya.latitude, longitude: sanya.longitude, ocrText: nil),
    Asset(id: "cat-and-dog", vector: unit([1, 0, 0, 1, 0]), year: 2023,
          latitude: beijing.latitude, longitude: beijing.longitude, ocrText: nil),
    Asset(id: "dog-on-beach", vector: unit([0, 1, 0, 1, 0]), year: 2023,
          latitude: sanya.latitude, longitude: sanya.longitude, ocrText: nil),
    Asset(id: "beach-only", vector: unit([0, 1, 0, 0, 0]), year: 2021,
          latitude: sanya.latitude, longitude: sanya.longitude, ocrText: nil),
    Asset(id: "invoice", vector: unit([0, 0, 1, 0, 0]), year: 2023,
          latitude: beijing.latitude, longitude: beijing.longitude,
          ocrText: "发票 报销凭证 12345"),
]

let calendar = Calendar(identifier: .gregorian)
func date(year: Int, month: Int = 6, day: Int = 15) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
}

for asset in assets {
    try store.upsertMetadata([AIPhotoSearchStore.AssetMetadata(
        assetID: asset.id,
        creationDate: date(year: asset.year),
        modificationDate: nil,
        mediaType: 1,
        latitude: asset.latitude,
        longitude: asset.longitude
    )])
    try store.storeEmbedding(assetID: asset.id, vector: asset.vector)
    if let text = asset.ocrText { try store.storeText(assetID: asset.id, text: text) }
}

// The reader mmaps the file, so it must be created after every write: the
// mapping has a fixed length and would not see later appends.
let reader = try EmbeddingMatrixReader(url: matrixURL)
let engine = PhotoSearchEngine(store: store, embeddings: reader, encoder: ConceptEncoder())

print("         \(assets.count) assets, dimension \(dimension), \(reader.count) rows")

// ---------------------------------------------------------------------------
section("ranking")

do {
    let response = try engine.search("猫")
    let ids = response.hits.map(\.assetID)
    print("         猫 -> \(ids.map { "\($0)(\(String(format: "%.2f", 0)))" })")
    print("         scores: \(response.hits.map { String(format: "%@=%.3f", $0.assetID, $0.score) }.joined(separator: " "))")
    check(ids.first == "cat-indoors",
          "a pure cat query ranks the unambiguous cat photo first", "\(ids)")
    check(ids.contains("cat-on-beach"), "and includes the cat on the beach")
    check(!ids.contains("beach-only"), "but not a photo with no cat in it", "\(ids)")
    check(!ids.contains("invoice"), "and not the invoice", "\(ids)")
    check(!ids.contains("dog-on-beach"), "and not the dog", "\(ids)")
}

do {
    // The strongest cat photo must outrank the weaker ones.
    let ids = try engine.search("猫").hits.map(\.assetID)
    if let first = ids.firstIndex(of: "cat-indoors"), let second = ids.firstIndex(of: "cat-on-beach") {
        check(first < second, "a stronger match outranks a weaker one", "\(ids)")
    } else {
        check(false, "both cat photos are present", "\(ids)")
    }
}

// ---------------------------------------------------------------------------
section("AND is a conjunction, not an average")

do {
    let response = try engine.search("猫和沙滩")
    let ids = response.hits.map(\.assetID)
    print("         猫和沙滩 -> \(ids)")
    check(response.plan.combine == .all, "two clauses combine with AND",
          "\(response.plan.combine.rawValue)")
    check(response.plan.positiveVisualClauses.count == 2,
          "and are two separate clauses",
          "\(response.plan.positiveVisualClauses)")
    check(ids.first == "cat-on-beach", "the photo with both wins", "\(ids)")
    check(!ids.contains("cat-indoors"),
          "a photo with only the cat is excluded — AND is not an average", "\(ids)")
    check(!ids.contains("beach-only"),
          "a photo with only the beach is excluded", "\(ids)")
}

do {
    let response = try engine.search("猫或者沙滩")
    let ids = response.hits.map(\.assetID)
    print("         猫或者沙滩 -> \(ids)")
    check(response.plan.combine == .any, "or combines with OR",
          "\(response.plan.combine.rawValue)")
    check(ids.contains("cat-indoors") && ids.contains("beach-only"),
          "and admits a photo matching either side", "\(ids)")
}

// ---------------------------------------------------------------------------
section("negation excludes rather than penalises")

do {
    let plain = try engine.search("猫").hits.map(\.assetID)
    check(plain.contains("cat-and-dog"),
          "a photo containing a cat and a dog matches a plain cat query", "\(plain)")

    let response = try engine.search("猫 不要狗")
    let ids = response.hits.map(\.assetID)
    print("         猫 不要狗 -> \(ids)")
    check(response.plan.negativeVisualClauses == ["狗"],
          "the negation is recognised", "\(response.plan.negativeVisualClauses)")
    check(!ids.contains("cat-and-dog"),
          "and the photo containing a dog is excluded even though it matches the cat",
          "\(ids)")
    check(ids.contains("cat-indoors"),
          "while a pure cat photo survives — negation must not take the whole set",
          "\(ids)")
}

// ---------------------------------------------------------------------------
section("metadata filters restrict the work, not a global ranking")

do {
    let response = try engine.search("2023年拍的猫")
    let ids = response.hits.map(\.assetID)
    print("         2023年拍的猫 -> \(ids), candidates=\(response.diagnostics.candidateCount)")
    check(response.plan.dateFilter != nil, "the year is extracted as a date filter")
    check(!ids.contains("cat-indoors"), "a 2022 cat is excluded by the year", "\(ids)")
    check(ids.contains("cat-on-beach"), "a 2023 cat is included", "\(ids)")
    // Six assets in the library; only four are from 2023.
    check(response.diagnostics.candidateCount == 4,
          "only in-range rows were candidates",
          "\(response.diagnostics.candidateCount) of \(assets.count)")
    check(response.diagnostics.scoredCount == response.diagnostics.candidateCount,
          "and exactly those rows were scored",
          "\(response.diagnostics.scoredCount)")
    check(response.diagnostics.usedVectorSearch, "the vector path was used")
}

do {
    // "2023年拍的照片" is a date question. Sending "拍" to the text tower would be
    // asking a vision-language model about a shutter action.
    let response = try engine.search("2023年拍的照片")
    print("         2023年拍的照片 -> \(response.hits.count) hits, vector=\(response.diagnostics.usedVectorSearch)")
    check(!response.diagnostics.usedVectorSearch,
          "a date-only query never touches the text tower")
    check(response.diagnostics.encodedClauses.isEmpty, "so no clause was encoded")
    check(response.hits.count == 4, "and every 2023 photo is returned",
          "\(response.hits.count)")
    check(response.hits.allSatisfy(\.isMetadataOnly),
          "hits are marked as metadata-only")
    check(response.hits.allSatisfy { $0.score == PhotoSearchEngine.metadataOnlyScore },
          "and carry no invented relevance score")
}

// ---------------------------------------------------------------------------
section("places")

do {
    let ids = try engine.search("在三亚拍的猫").hits.map(\.assetID)
    print("         在三亚拍的猫 -> \(ids)")
    check(ids.contains("cat-on-beach"), "an explicit marker scopes to the place", "\(ids)")
    check(!ids.contains("cat-indoors"), "and excludes the other city", "\(ids)")
}

do {
    // No locative marker: how people actually type.
    let response = try engine.search("三亚 猫")
    let ids = response.hits.map(\.assetID)
    print("         三亚 猫 -> \(ids), clauses=\(response.diagnostics.encodedClauses)")
    check(ids.contains("cat-on-beach"),
          "a place with no marker is still treated as a location", "\(ids)")
    check(!ids.contains("cat-indoors"), "and scopes the search", "\(ids)")
    check(!response.diagnostics.encodedClauses.contains(where: { $0.contains("三亚") }),
          "the place is removed from the clause sent to the model",
          "\(response.diagnostics.encodedClauses)")
}

do {
    let response = try engine.search("海边")
    check(!response.hits.isEmpty || response.diagnostics.candidateCount >= 0,
          "a non-place word does not become a location filter")
    // 海边 is not in the gazetteer, so it must remain a visual clause.
    check(response.diagnostics.unresolvedLocation == nil,
          "a word that is not a place does not raise an unresolved-location warning",
          "\(String(describing: response.diagnostics.unresolvedLocation))")
}

do {
    let response = try engine.search("在瓦坎达拍的猫")
    print("         在瓦坎达拍的猫 -> warnings=\(response.diagnostics.warnings)")
    check(response.diagnostics.unresolvedLocation == "瓦坎达",
          "an unknown place is reported",
          "\(String(describing: response.diagnostics.unresolvedLocation))")
    check(response.diagnostics.warnings.contains { $0.contains("瓦坎达") },
          "and produces a warning")
    check(response.diagnostics.encodedClauses.contains(where: { $0.contains("瓦坎达") }),
          "and is handed to the model rather than silently dropped",
          "\(response.diagnostics.encodedClauses)")
}

// ---------------------------------------------------------------------------
section("OCR terms")

do {
    let response = try engine.search("\"发票\"")
    let ids = response.hits.map(\.assetID)
    print("         \"发票\" -> \(ids), ocrTerms=\(response.plan.ocrTerms)")
    check(response.plan.ocrTerms == ["发票"], "quoted text becomes an OCR term",
          "\(response.plan.ocrTerms)")
    check(ids == ["invoice"], "and only the asset whose OCR text contains it matches",
          "\(ids)")
}

// ---------------------------------------------------------------------------
section("edge cases")

do {
    let response = try engine.search("")
    check(response.hits.isEmpty, "an empty query returns nothing")
    check(!response.diagnostics.warnings.isEmpty, "and says why")
}

do {
    let response = try engine.search("猫", limit: 1)
    check(response.hits.count == 1, "the limit is honoured", "\(response.hits.count)")
}

do {
    let response = try engine.search("不存在的概念xyzzy")
    // Nothing matches the unknown axis, so nothing clears the floor.
    check(response.hits.isEmpty,
          "a query with no match returns nothing rather than everything",
          "\(response.hits.map(\.assetID))")
}

do {
    let first = try engine.search("猫和沙滩").hits.map(\.assetID)
    let second = try engine.search("猫和沙滩").hits.map(\.assetID)
    check(first == second, "repeating a search gives the same order", "\(first) vs \(second)")
}

do {
    // A dimension mismatch must be an error, not a ranking. Comparing vectors
    // from different models produces confidently wrong results.
    let mismatched = PhotoSearchEngine(
        store: store, embeddings: reader, encoder: MismatchedEncoder()
    )
    do {
        _ = try mismatched.search("猫")
        check(false, "a dimension mismatch is rejected")
    } catch {
        check(true, "a dimension mismatch is rejected rather than ranked")
    }
}

// ---------------------------------------------------------------------------
section("similar-image search")

do {
    // `cat-on-beach` is [1,1,0,0,0]/√2, so its exact cosines are known:
    //   beach-only, cat-indoors   0.7071  (tie -> broken by asset id)
    //   cat-and-dog, dog-on-beach 0.5     (tie -> broken by asset id)
    //   invoice                   0       -> below the floor, must be absent
    let response = try engine.search(similarTo: "cat-on-beach")
    let ids = response.hits.map(\.assetID)
    print("         cat-on-beach -> \(ids)")

    check(!ids.contains("cat-on-beach"),
          "the reference photo is not its own top result", "\(ids)")
    check(ids == ["beach-only", "cat-indoors", "cat-and-dog", "dog-on-beach"],
          "neighbours are ordered by similarity, ties broken by id", "\(ids)")
    check(!ids.contains("invoice"),
          "an unrelated photo falls below the floor rather than padding the list")
    check(response.diagnostics.usedVectorSearch,
          "the vector path was used")
    check(response.diagnostics.scoredCount == assets.count - 1,
          "every other asset was scored", "\(response.diagnostics.scoredCount)")
    check(response.diagnostics.encodedClauses.isEmpty,
          "no text was encoded: the query vector came from the matrix")
}

do {
    // The scores must be the *stored* vectors' cosines, not a re-encoding of the
    // image. Comparing against the matrix read back independently is the only way
    // to catch a reference that drifted into its own space.
    let slot = try store.embeddingSlots(for: ["cat-on-beach"])["cat-on-beach"]!
    let query = try reader.row(at: slot)
    let expected = try reader.scores(query: query, slots: [
        try store.embeddingSlots(for: ["beach-only"])["beach-only"]!,
        try store.embeddingSlots(for: ["cat-indoors"])["cat-indoors"]!,
    ])
    let response = try engine.search(similarTo: "cat-on-beach")
    let top = response.hits.prefix(2).map(\.score)
    let matches = zip(top, expected).allSatisfy { abs($0 - $1) < 1e-6 }
    check(matches, "scores equal the stored vectors' cosines",
          "\(top) vs \(expected)")
}

do {
    let limited = try engine.search(similarTo: "cat-on-beach", limit: 2)
    check(limited.hits.count == 2, "the limit is respected", "\(limited.hits.count)")

    // A photo with no embedding is a normal state while the index fills, not an
    // error: it must report why rather than throw or return everything.
    let unindexed = try engine.search(similarTo: "never-indexed")
    check(unindexed.hits.isEmpty, "an unindexed reference yields no hits")
    check(!unindexed.diagnostics.warnings.isEmpty,
          "and says why rather than looking like an empty library")

    // A photo with no neighbours above the floor returns empty, not padding.
    let lonely = try engine.search(similarTo: "invoice")
    check(lonely.hits.isEmpty,
          "a photo with no similar neighbours returns nothing",
          "\(lonely.hits.map(\.assetID))")
}

do {
    let mismatched = PhotoSearchEngine(
        store: store, embeddings: reader, encoder: MismatchedEncoder()
    )
    do {
        _ = try mismatched.search(similarTo: "cat-on-beach")
        check(false, "a dimension mismatch is rejected for similar-image search too")
    } catch {
        check(true, "a dimension mismatch is rejected for similar-image search too")
    }
}

// ---------------------------------------------------------------------------
print("\nchecks: \(checks), failures: \(failures)")
if failures == 0 {
    print("RESULT: all \(checks) engine checks passed")
    exit(0)
} else {
    print("RESULT: \(failures) of \(checks) checks FAILED")
    exit(1)
}
