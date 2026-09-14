// 100k-row embedding matrix benchmark.
//
// Builds a realistic-sized matrix, measures the exact-search path, and dumps the
// top-k results so an independent NumPy implementation can read the same file
// and confirm the rankings. This is the golden reference the Phase 4 Metal kernel
// has to match, so it is deliberately cross-checked rather than self-asserted.

import Foundation

let dimension = 768
let rowCount = 100_000
let topK = 100
let queryCount = 5

let buildDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("build")
try FileManager.default.createDirectory(at: buildDirectory, withIntermediateDirectories: true)
let matrixURL = buildDirectory.appendingPathComponent("embedding-bench.bin")
let resultURL = buildDirectory.appendingPathComponent("embedding-bench-results.json")

try? FileManager.default.removeItem(at: matrixURL)

/// Deterministic generator. Must be reproducible in Python, so it is a plain
/// 64-bit LCG with the same constants on both sides.
struct LCG {
    var state: UInt64
    mutating func nextFloat() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        // Map the top 31 bits to [-1, 1).
        let value = Float(Int32(truncatingIfNeeded: state >> 33))
        return value / Float(Int32.max)
    }
}

func unitVector(_ generator: inout LCG) -> [Float] {
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

print("building \(rowCount) x \(dimension) Float16 matrix")
var generator = LCG(state: 0x2026_0913)
let buildStart = Date()
let writer = try EmbeddingMatrixWriter(
    url: matrixURL, dimension: dimension, sourceModelSHA256: String(repeating: "ab", count: 32)
)
for _ in 0..<rowCount {
    _ = try writer.append(unitVector(&generator))
}
try writer.flush()
let buildElapsed = Date().timeIntervalSince(buildStart)
let fileSize = (try FileManager.default.attributesOfItem(atPath: matrixURL.path)[.size] as? Int) ?? 0
print(String(format: "built in %.1f s (%.1f MB on disk, %.0f rows/s)",
             buildElapsed, Double(fileSize) / 1_048_576, Double(rowCount) / buildElapsed))

let queries = (0..<queryCount).map { _ in unitVector(&generator) }

let reader = try EmbeddingMatrixReader(url: matrixURL)
print("reader sees \(reader.count) rows, capacity \(reader.capacity), stride \(reader.rowStride) B")

// Measure the first scan separately, then warm the mapping. The first pass over
// a freshly built 192 MB file faults in its pages and is roughly twice the
// steady-state cost; reporting only one number would either overstate the
// production cost (cold) or hide a real first-search latency (warm).
let coldStart = Date()
_ = try reader.scores(query: queries[0])
let coldElapsed = Date().timeIntervalSince(coldStart)
for _ in 0..<3 { _ = try reader.scores(query: queries[0]) }

var scoreTimes: [Double] = []
var topKTimes: [Double] = []
var results: [[(slot: Int, score: Float)]] = []
for query in queries {
    // One query is timed twice: `scores` in isolation, then `topK`, which
    // internally repeats the scoring. Reporting both makes the selection cost
    // separable from the scan cost.
    let scoreStart = Date()
    let all = try reader.scores(query: query)
    scoreTimes.append(Date().timeIntervalSince(scoreStart))
    precondition(all.count == rowCount)

    let topStart = Date()
    let top = try reader.topK(query: query, k: topK)
    topKTimes.append(Date().timeIntervalSince(topStart))
    results.append(top)
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted()
    let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded(.up)))
    return sorted[index]
}

print(String(format: "first (cold, page-faulting) scan: %.1f ms", coldElapsed * 1000))
print(String(format: "exact scan over %d rows: P50 %.1f ms, min %.1f ms",
             rowCount, percentile(scoreTimes, 0.5) * 1000, (scoreTimes.min() ?? 0) * 1000))
print(String(format: "scan + top-%d:            P50 %.1f ms, min %.1f ms",
             topK, percentile(topKTimes, 0.5) * 1000, (topKTimes.min() ?? 0) * 1000))

// Sanity: the top hit must not be worse than the 100th.
let monotone = results.allSatisfy { top in zip(top, top.dropFirst()).allSatisfy { $0.score >= $1.score } }
print("top-k monotone: \(monotone)")

let payload: [String: Any] = [
    "dimension": dimension,
    "rowCount": rowCount,
    "topK": topK,
    "matrixPath": matrixURL.path,
    "seed": "0x20260913",
    "coldScanMs": coldElapsed * 1000,
    "scoreP50ms": percentile(scoreTimes, 0.5) * 1000,
    "topKP50ms": percentile(topKTimes, 0.5) * 1000,
    "queries": queries.map { $0.map { Double($0) } },
    "results": results.map { top in
        top.map { ["slot": $0.slot, "score": Double($0.score)] }
    },
]
let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
try data.write(to: resultURL)
print("wrote \(resultURL.path)")

if monotone {
    exit(0)
} else {
    print("RESULT: top-k is not monotonically ordered")
    exit(1)
}
