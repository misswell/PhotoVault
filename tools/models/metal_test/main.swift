// Metal exact-search tests.
//
// Two independent obligations:
//
//   1. The GPU path must agree with the Accelerate path element-by-element, on
//      every embedding dimension shape including the scalar-tail case.
//   2. On the 100k matrix it must reproduce the ranking that NumPy already
//      verified end to end. Metal agreeing with Accelerate is only meaningful
//      because Accelerate was itself checked against an independent NumPy
//      reader; without that, both could be wrong together.
//
// Run `python verify_siglip2.py metal` to build the metallib and this binary.

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
// Argument handling: the metallib is built by the verifier and handed in.

var libraryPath = "/tmp/pv-embedding.metallib"
var benchPath = "build/embedding-bench-results.json"
var matrixPath = "build/embedding-bench.bin"

var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let flag = arguments.removeFirst()
    switch flag {
    case "--library" where !arguments.isEmpty: libraryPath = arguments.removeFirst()
    case "--bench" where !arguments.isEmpty: benchPath = arguments.removeFirst()
    case "--matrix" where !arguments.isEmpty: matrixPath = arguments.removeFirst()
    default: break
    }
}
let libraryURL = URL(fileURLWithPath: libraryPath)

guard MetalSimilaritySearch.isAvailable() else {
    print("SKIP: no Metal device on this machine; the GPU path cannot be verified here.")
    print("      The Accelerate fallback is verified by verify_siglip2.py embedding.")
    exit(0)
}

let workDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pv-metal-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workDirectory) }

let modelHash = String(repeating: "ef", count: 32)

/// Deterministic generator, matching the one used to build the benchmark matrix
/// so a small matrix can be regenerated identically if needed.
struct LCG {
    var state: UInt64
    mutating func nextFloat() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let value = Float(Int32(truncatingIfNeeded: state >> 33))
        return value / Float(Int32.max)
    }
}

func unitVector(_ generator: inout LCG, dimension: Int) -> [Float] {
    var v = [Float](repeating: 0, count: dimension)
    var sum: Float = 0
    for i in 0..<dimension {
        let value = generator.nextFloat()
        v[i] = value
        sum += value * value
    }
    let norm = sum.squareRoot()
    for i in 0..<dimension { v[i] /= norm }
    return v
}

// ---------------------------------------------------------------------------
section("GPU and CPU agree on every dimension shape")

// 13 exercises the scalar tail; 1 is the extreme case where the vectorised loop
// runs zero times and every component goes through the tail. The embedding
// dimension comes from the model manifest and is never assumed, so these paths
// are reachable in principle and must be correct when they are.
for dimension in [768, 13, 4, 1, 6] {
    let rowCount = 137
    let matrixURL = workDirectory.appendingPathComponent("d\(dimension).bin")
    var generator = LCG(state: 0xBEEF_0000 &+ UInt64(dimension))
    let writer = try EmbeddingMatrixWriter(
        url: matrixURL, dimension: dimension, sourceModelSHA256: modelHash
    )
    var rows: [[Float]] = []
    for _ in 0..<rowCount {
        let vector = unitVector(&generator, dimension: dimension)
        rows.append(vector)
        _ = try writer.append(vector)
    }
    try writer.flush()

    let query = unitVector(&generator, dimension: dimension)
    let reader = try EmbeddingMatrixReader(url: matrixURL)
    let cpuScores = try reader.scores(query: query)

    do {
        let searcher = try MetalSimilaritySearch(
            matrixURL: matrixURL, dimension: dimension, rowCount: rowCount, libraryURL: libraryURL
        )
        let gpuScores = try searcher.scores(query: query)
        check(gpuScores.count == cpuScores.count,
              "d=\(dimension): GPU returns one score per row",
              "\(gpuScores.count) vs \(cpuScores.count)")
        let worst = zip(gpuScores, cpuScores).map { abs($0 - $1) }.max() ?? 0
        // Both sides accumulate in Float32 but in a different order, so exact
        // equality is not expected; this tolerance is far below any gap that
        // could reorder two distinct photos.
        check(worst < 1e-5, "d=\(dimension): GPU scores match the CPU path",
              "worst delta \(worst)")

        // An independently computed dot product, accumulated in Double so the
        // reference is the true value rather than one more Float32 estimate.
        //
        // A Float32 sequential sum was tried first and "failed" here at up to
        // 2.7e-4: that was the reference's own rounding error, not the kernel's.
        // Summing `dimension` terms in Float32 cannot beat ~1e-4, and blocked
        // accumulation (what the GPU and BLAS both do) is *more* accurate than
        // the sequential version, which is why d=1 agreed exactly and larger
        // dimensions did not.
        //
        // The reference is computed from the *Float16-quantized* rows, because
        // that is what the matrix stores. Using the original Float32 rows
        // instead put a 2.7e-4 discrepancy at dimension 4 in both the GPU and
        // the CPU path -- far too large for six terms of Float32 rounding
        // (epsilon is 1.2e-7), and the tell that the comparison was against a
        // value nothing could produce. The query stays Float32, since it is
        // passed through unquantized.
        let reference = rows.map { row in
            zip(row, query).reduce(Double(0)) {
                $0 + Double(Float16($1.0)) * Double($1.1)
            }
        }
        let worstReference = zip(gpuScores, reference).map { abs(Double($0) - $1) }.max() ?? 0
        // Bounded by Float32 accumulation error for `dimension` terms, not by
        // the kernel; the CPU path is held to the same bound in the same run.
        let worstCpuReference = zip(cpuScores, reference).map { abs(Double($0) - $1) }.max() ?? 0
        // 1e-4 leaves room for Float32 accumulation over `dimension` terms;
        // the dominant error in this pipeline is the Float16 *storage*, which
        // the reference now reproduces exactly rather than ignoring.
        check(worstReference < 1e-4,
              "d=\(dimension): GPU scores match a Double-precision dot product",
              "worst delta \(worstReference)")
        check(worstCpuReference < 1e-4, "d=\(dimension): CPU scores match the same reference",
              "worst delta \(worstCpuReference)")
        print(String(format: "        d=%d worst vs Double reference: gpu %.2e, cpu %.2e",
                     dimension, worstReference, worstCpuReference))
        check(worstReference <= max(worstCpuReference, 1e-6) * 2,
              "d=\(dimension): the GPU is no less accurate than the CPU",
              "gpu \(worstReference) vs cpu \(worstCpuReference)")
    } catch {
        check(false, "d=\(dimension): GPU search runs", "\(error)")
    }
}

// ---------------------------------------------------------------------------
section("GPU reproduces the NumPy-verified ranking on 100k rows")

let resultsURL = URL(fileURLWithPath: benchPath)
let matrixURL = URL(fileURLWithPath: matrixPath)

if !FileManager.default.fileExists(atPath: resultsURL.path) {
    print("  SKIP: \(resultsURL.path) missing; run verify_siglip2.py embedding first")
} else {
    let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: resultsURL)) as! [String: Any]
    let dimension = payload["dimension"] as! Int
    let rowCount = payload["rowCount"] as! Int
    let topK = payload["topK"] as! Int
    let queries = (payload["queries"] as! [[Double]]).map { $0.map { Float($0) } }
    let expectedResults = (payload["results"] as! [[[String: Any]]]).map { entries in
        entries.map { (slot: $0["slot"] as! Int, score: Float($0["score"] as! Double)) }
    }

    let reader = try EmbeddingMatrixReader(url: matrixURL)
    let searcher = try MetalSimilaritySearch(
        matrixURL: matrixURL, dimension: dimension, rowCount: rowCount, libraryURL: libraryURL
    )
    check(searcher.rowCount == rowCount && searcher.dimension == dimension,
          "the GPU searcher maps the whole matrix", "\(searcher.rowCount)x\(searcher.dimension)")

    _ = try searcher.scores(query: queries[0])  // warm up the pipeline

    var cpuTimes: [Double] = []
    var gpuTimes: [Double] = []
    var worstScoreDelta: Float = 0
    var setsMatched = 0

    for (index, query) in queries.enumerated() {
        let gpuStart = Date()
        let gpuScores = try searcher.scores(query: query)
        gpuTimes.append(Date().timeIntervalSince(gpuStart))

        let cpuStart = Date()
        let cpuScores = try reader.scores(query: query)
        cpuTimes.append(Date().timeIntervalSince(cpuStart))

        // Element-wise agreement over all 100k rows, not just the top k: a
        // kernel that is subtly wrong for low-scoring rows would still produce a
        // correct top-100 and is still a bug.
        worstScoreDelta = max(worstScoreDelta, zip(gpuScores, cpuScores).map { abs($0 - $1) }.max() ?? 0)

        let gpuTop = MetalSimilaritySearch.selectTopK(gpuScores, k: topK)
        let expectedSlots = Set(expectedResults[index].map(\.slot))
        if Set(gpuTop.map(\.slot)) == expectedSlots { setsMatched += 1 }
    }

    // 1e-4 is safe: the smallest gap anywhere in the top 100 of these fixtures is
    // orders of magnitude larger, so no pair of distinct scores can flip.
    check(worstScoreDelta < 1e-4,
          "GPU and CPU agree on all \(rowCount) scores", "worst delta \(worstScoreDelta)")
    check(setsMatched == queries.count,
          "GPU top-\(topK) matches the NumPy-verified ranking on every query",
          "\(setsMatched)/\(queries.count) matched")

    // Ordering parity. Exactly-equal scores break identically, because both
    // paths call the same `selectTopK`. But two scores that differ by less than
    // Float32 accumulation error can still order differently, because the
    // underlying floats genuinely differ between the two implementations.
    //
    // That is inherent to computing on different hardware and is not a defect,
    // so the claim tested is the precise one: any disagreement is confined to
    // scores that are indistinguishable at this precision.
    let cpuTop = MetalSimilaritySearch.selectTopK(try reader.scores(query: queries[0]), k: topK)
    let gpuTop = MetalSimilaritySearch.selectTopK(try searcher.scores(query: queries[0]), k: topK)
    check(Set(cpuTop.map(\.slot)) == Set(gpuTop.map(\.slot)),
          "the two paths select the same top-\(topK) set")
    var ambiguousPositions = 0
    var worstAmbiguity: Float = 0
    for i in 0..<min(cpuTop.count, gpuTop.count) where cpuTop[i].slot != gpuTop[i].slot {
        ambiguousPositions += 1
        worstAmbiguity = max(worstAmbiguity, abs(cpuTop[i].score - gpuTop[i].score))
    }
    check(worstAmbiguity < 1e-4,
          "any ranking difference is between scores that are indistinguishable",
          "worst \(worstAmbiguity) across \(ambiguousPositions) positions")

    func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded(.up)))]
    }
    let cpuP50 = percentile(cpuTimes, 0.5) * 1000
    let gpuP50 = percentile(gpuTimes, 0.5) * 1000
    print(String(format: "        100k x %d: Metal P50 %.2f ms, Accelerate P50 %.2f ms (%.1fx)",
                 dimension, gpuP50, cpuP50, cpuP50 / gpuP50))
    check(gpuP50 < 500, "the GPU scan is well inside the 500 ms budget",
          String(format: "%.2f ms", gpuP50))
}

// ---------------------------------------------------------------------------
print("\nchecks: \(checks), failures: \(failures)")
if failures == 0 {
    print("RESULT: all \(checks) Metal search checks passed")
    exit(0)
} else {
    print("RESULT: \(failures) of \(checks) checks FAILED")
    exit(1)
}
