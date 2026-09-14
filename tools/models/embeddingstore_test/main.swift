// Embedding matrix file tests.
//
// Compiled together with `PhotoVault/Search/EmbeddingStoreFile.swift` and run on
// macOS, so the format, the mmap read path and the swap-remove bookkeeping are
// exercised without a device. Exits non-zero on the first failure.

import Foundation

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

func section(_ title: String) {
    print("\n\(title)")
}

let workDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pv-embedding-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workDirectory) }

let dimension = 768
let matrixURL = workDirectory.appendingPathComponent("embeddings-v1.bin")
let modelSHA = String(repeating: "a1b2c3d4", count: 8)  // 64 hex chars

/// Deterministic pseudo-random vectors. Fixed seed so a failure is reproducible.
struct Generator {
    var state: UInt64
    mutating func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int32(truncatingIfNeeded: state >> 33)) / Float(Int32.max)
    }
    mutating func vector(_ n: Int) -> [Float] { (0..<n).map { _ in next() } }
    /// Unit-length vector, which is what the Core ML graph actually emits.
    mutating func unitVector(_ n: Int) -> [Float] {
        var v = vector(n)
        var sum: Float = 0
        for value in v { sum += value * value }
        let norm = sum.squareRoot()
        for i in 0..<n { v[i] /= norm }
        return v
    }
}

func cosine(_ a: [Float], _ b: [Float]) -> Float {
    var dot: Float = 0, na: Float = 0, nb: Float = 0
    for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
    return dot / (na.squareRoot() * nb.squareRoot())
}

// ---------------------------------------------------------------------------
section("creation and append")

var generator = Generator(state: 0x5EED)
let writer = try EmbeddingMatrixWriter(url: matrixURL, dimension: dimension, sourceModelSHA256: modelSHA)
check(writer.count == 0 && writer.capacity == 0, "a new matrix starts empty")

var stored: [[Float]] = []
let initialRows = 300
for _ in 0..<initialRows {
    let vector = generator.unitVector(dimension)
    stored.append(vector)
    let slot = try writer.append(vector)
    if slot != stored.count - 1 {
        check(false, "append returns sequential slots", "got \(slot) at index \(stored.count - 1)")
    }
}
check(writer.count == initialRows, "count tracks appends", "count=\(writer.count)")
// 300 rows exceed one 4096-row chunk? No: the first grow allocates 4096, so the
// file must have grown exactly once and stayed there.
check(writer.capacity == 4096, "capacity grew by exactly one chunk", "capacity=\(writer.capacity)")
try writer.flush()

// ---------------------------------------------------------------------------
section("persistence and mmap read path")

var reader = try EmbeddingMatrixReader(url: matrixURL)
check(reader.count == initialRows, "reopened reader sees every row", "count=\(reader.count)")
check(reader.dimension == dimension, "dimension survives the round trip")
check(reader.sourceModelSHA256 == modelSHA, "model hash survives the round trip")

var rowErrors = 0
var worstRowDelta: Float = 0
for (slot, original) in stored.enumerated() {
    let readBack = try reader.row(at: slot)
    for i in 0..<dimension {
        let delta = abs(readBack[i] - original[i])
        worstRowDelta = max(worstRowDelta, delta)
        // Float16 has ~3 decimal digits; this bound catches a layout bug while
        // allowing normal half-precision rounding.
        if delta > 0.001 { rowErrors += 1; break }
    }
}
check(rowErrors == 0, "every row round-trips through Float16", "\(rowErrors) rows differ")
print("         worst per-component delta: \(worstRowDelta)")

// ---------------------------------------------------------------------------
section("exact similarity")

let query = generator.vector(dimension)
let scores = try reader.scores(query: query)
check(scores.count == initialRows, "one score per row")

// The query is normalized inside `scores`, so a brute-force cosine in Float
// must agree for every row; and because stored vectors are not unit length in
// this test, the correct comparison is against normalized dot, not raw dot.
var queryUnit = query
var queryMagnitude: Float = 0
for value in queryUnit { queryMagnitude += value * value }
let queryNorm = queryMagnitude.squareRoot()
queryUnit = queryUnit.map { $0 / queryNorm }

// Rows are stored unit-length, so the expectation is a plain dot product against
// the normalized query -- exactly what a cosine reduces to.
var worstScoreDelta: Float = 0
for slot in 0..<initialRows {
    var expected: Float = 0
    for i in 0..<dimension {
        expected += Float(Float16(stored[slot][i])) * Float(Float16(queryUnit[i]))
    }
    worstScoreDelta = max(worstScoreDelta, abs(expected - scores[slot]))
}
check(worstScoreDelta < 1e-4, "scores match a brute-force cosine on Float16 rows",
      "worst delta \(worstScoreDelta)")

// The invariant the fast path silently depends on.
let validation = reader.validateNormalization()
check(validation.worstDeviation < 0.001,
      "stored rows are unit length as the fast path assumes",
      "worst deviation \(validation.worstDeviation)")

let top = try reader.topK(query: query, k: 10)
check(top.count == 10, "topK returns exactly k")
let topIsSorted = zip(top, top.dropFirst()).allSatisfy { $0.score >= $1.score }
check(topIsSorted, "topK is sorted by descending score")

// Independent top-10 by full sort of the raw scores.
let referenceTop = scores.enumerated()
    .sorted { $0.element == $1.element ? $0.offset < $1.offset : $0.element > $1.element }
    .prefix(10)
    .map { $0.offset }
check(top.map(\.slot) == Array(referenceTop), "topK agrees with a full sort",
      "got \(top.map(\.slot)) want \(Array(referenceTop))")

// k larger than the matrix, and k == 0.
check(try reader.topK(query: query, k: 10_000).count == initialRows, "topK clamps to the row count")
check(try reader.topK(query: query, k: 0).isEmpty, "topK of zero is empty")

// ---------------------------------------------------------------------------
section("swap-remove keeps the matrix dense")

// Delete a middle slot. The last row must move into it, and the count must drop.
let victim = 42
let lastRowBefore = try reader.row(at: initialRows - 1)
let moved = try writer.swapRemove(slot: victim)
check(moved, "removing a non-final slot reports that a row moved")
check(writer.count == initialRows - 1, "count decrements", "count=\(writer.count)")
try writer.flush()

reader = try EmbeddingMatrixReader(url: matrixURL)
let relocated = try reader.row(at: victim)
var relocationDelta: Float = 0
for i in 0..<dimension { relocationDelta = max(relocationDelta, abs(relocated[i] - lastRowBefore[i])) }
check(relocationDelta < 0.001, "the last row took over the vacated slot", "delta \(relocationDelta)")

// Removing the final slot must not move anything.
let countBefore = writer.count
let movedAgain = try writer.swapRemove(slot: countBefore - 1)
check(!movedAgain, "removing the final slot moves nothing")
check(writer.count == countBefore - 1, "count decrements again")
try writer.flush()

// Reopen and confirm the reader agrees after deletions.
reader = try EmbeddingMatrixReader(url: matrixURL)
check(reader.count == initialRows - 2, "reader sees the post-deletion count", "count=\(reader.count)")

var outOfRangeRejected = false
do { _ = try writer.swapRemove(slot: writer.count) } catch { outOfRangeRejected = true }
check(outOfRangeRejected, "removing past the end is rejected")

// ---------------------------------------------------------------------------
section("growth beyond the first chunk")

let extraRows = 4200  // pushes past the initial 4096
for _ in 0..<extraRows {
    _ = try writer.append(generator.unitVector(dimension))
}
try writer.flush()
check(writer.count == initialRows - 2 + extraRows, "count spans a growth boundary", "count=\(writer.count)")
check(writer.capacity >= writer.count, "capacity always covers count")
reader = try EmbeddingMatrixReader(url: matrixURL)
check(reader.count == writer.count, "reader sees the grown count")
check(reader.capacity == writer.capacity, "reader sees the grown capacity")
// Spot-check a row that landed after the growth.
let probeSlot = writer.count - 1
let probeRow = try reader.row(at: probeSlot)
check(probeRow.contains { $0 != 0 }, "a row written after growth is readable")

// ---------------------------------------------------------------------------
section("rejecting incompatible or damaged files")

// Wrong dimension.
var dimensionRejected = false
do {
    _ = try EmbeddingMatrixWriter(url: matrixURL, dimension: 512, sourceModelSHA256: modelSHA)
} catch EmbeddingStoreError.dimensionMismatch { dimensionRejected = true } catch {}
check(dimensionRejected, "opening with the wrong dimension is rejected")

// Wrong model.
var modelRejected = false
do {
    _ = try EmbeddingMatrixWriter(url: matrixURL, dimension: dimension, sourceModelSHA256: "deadbeef")
} catch EmbeddingStoreError.modelMismatch { modelRejected = true } catch {}
check(modelRejected, "opening with a different model hash is rejected")

// Corrupt a header byte: the checksum must catch it.
let corruptURL = workDirectory.appendingPathComponent("corrupt.bin")
var corruptBytes = [UInt8](try Data(contentsOf: matrixURL))
corruptBytes[12] ^= 0xFF  // dimension field
try Data(corruptBytes).write(to: corruptURL)
var checksumCaught = false
do { _ = try EmbeddingMatrixReader(url: corruptURL) } catch { checksumCaught = true }
check(checksumCaught, "a flipped header byte is detected by the checksum")

// Wrong magic.
let magicURL = workDirectory.appendingPathComponent("magic.bin")
var magicBytes = [UInt8](try Data(contentsOf: matrixURL))
magicBytes[0] = UInt8(ascii: "X")
try Data(magicBytes).write(to: magicURL)
var magicCaught = false
do { _ = try EmbeddingMatrixReader(url: magicURL) } catch { magicCaught = true }
check(magicCaught, "a bad magic is rejected")

// Truncated to less than a page.
let shortURL = workDirectory.appendingPathComponent("short.bin")
try Data(bytes: corruptBytes, count: 100).write(to: shortURL)
var shortCaught = false
do { _ = try EmbeddingMatrixReader(url: shortURL) } catch { shortCaught = true }
check(shortCaught, "a file shorter than one page is rejected")

// A same-dimension-different-model matrix must not be mistaken for this one.
let otherURL = workDirectory.appendingPathComponent("other-model.bin")
let otherWriter = try EmbeddingMatrixWriter(url: otherURL, dimension: dimension, sourceModelSHA256: "ffff")
_ = try otherWriter.append(generator.unitVector(dimension))
try otherWriter.flush()
let otherReader = try EmbeddingMatrixReader(url: otherURL)
check(otherReader.sourceModelSHA256 == "ffff", "a different model's matrix reports its own hash")

// ---------------------------------------------------------------------------
section("backup exclusion")

let values = try matrixURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
check(values.isExcludedFromBackup == true, "the matrix is excluded from backup")

// ---------------------------------------------------------------------------
section("a freshly created matrix is laid out correctly on disk")

// The header must start at byte 0 and the file must be exactly one page.
//
// This asserts the layout rather than "reopening works", because on macOS
// reopening works even when the layout is wrong. `FileHandle.truncate(atOffset:)`
// moves the write offset to the new end of file on iOS but not on macOS, so
// writing immediately after truncating put the header at byte 4096 with a page
// of zeros in front of it -- on device only. The file grew to 8192 bytes, the
// first `open` succeeded because the header was still in memory, and every
// later launch threw `notAnEmbeddingFile`. Every test in this file passed while
// the app was broken on real hardware, so the bytes are checked directly.
do {
    let url = workDirectory.appendingPathComponent("layout-check.bin")
    _ = try EmbeddingMatrixWriter(url: url, dimension: 64, sourceModelSHA256: modelSHA)

    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    check(size == 4096, "the file is exactly one header page", "\(size ?? 0) bytes")

    let head = try Data(contentsOf: url, options: .mappedIfSafe)
    let magic = String(decoding: head.prefix(8), as: UTF8.self)
    check(magic == "PVEMB001", "the header starts at byte 0, not after a zero page", magic)

    // A zero page in front would parse as garbage; make that explicit rather
    // than relying on the magic check alone.
    let leadingZeros = head.prefix(4096).allSatisfy { $0 == 0 }
    check(!leadingZeros, "the first page is the header, not padding")

    // And the whole point: it must still open after the header is gone from
    // memory. This is what failed on device.
    let reader = try EmbeddingMatrixReader(url: url)
    check(reader.count == 0, "an empty matrix reloads from disk", "\(reader.count)")
}

// ---------------------------------------------------------------------------
print("\nchecks: \(checks), failures: \(failures)")
if failures == 0 {
    print("RESULT: all \(checks) embedding-store checks passed")
    exit(0)
} else {
    print("RESULT: \(failures) of \(checks) checks FAILED")
    exit(1)
}
