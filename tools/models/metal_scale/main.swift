//
//  metal_scale — Metal vs Accelerate at 100k x 768.
//
//  The two existing harnesses leave the actual Phase 4 question unanswered:
//  `metal_test` proves the kernel is *correct* but only on 137 rows, and
//  `embeddingstore_bench` times the Accelerate path at scale but never runs the
//  GPU. So "Metal is the primary path, Accelerate the fallback" was a design
//  statement with no measurement behind it either way.
//
//  This compares them on the same 100k x 768 matrix, on the same query set, and
//  checks the rankings still agree -- because a faster path that ranks
//  differently is not a faster path, it is a different answer.
//

import Foundation
import Metal

let rowCount = 100_000
let dimension = 768
let iterations = 20

var libraryPath = "/tmp/pv-embedding.metallib"
var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    if argument == "--library", !arguments.isEmpty { libraryPath = arguments.removeFirst() }
}
let libraryURL = URL(fileURLWithPath: libraryPath)

let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let buildDirectory = here.appendingPathComponent("build")
try? FileManager.default.createDirectory(at: buildDirectory, withIntermediateDirectories: true)
let matrixURL = buildDirectory.appendingPathComponent("metal-scale.bin")

/// Deterministic generator, matching the other harnesses so the matrix is
/// reproducible.
struct LCG {
    var state: UInt64
    mutating func nextFloat() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
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

func quantile(_ sorted: [Double], _ q: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let index = Int((Double(sorted.count - 1) * q).rounded())
    return sorted[index]
}

if !FileManager.default.fileExists(atPath: matrixURL.path) {
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
    let size = (try FileManager.default.attributesOfItem(atPath: matrixURL.path)[.size] as? Int) ?? 0
    print(String(format: "built in %.1f s (%.1f MB)", Date().timeIntervalSince(buildStart), Double(size) / 1_048_576))
} else {
    print("reusing existing matrix")
}

let reader = try EmbeddingMatrixReader(url: matrixURL)
print("reader sees \(reader.count) rows, stride \(reader.rowStride) B")

let searcher: MetalSimilaritySearch
do {
    searcher = try MetalSimilaritySearch(
        matrixURL: matrixURL, dimension: dimension, rowCount: rowCount, libraryURL: libraryURL
    )
    print("metal device ok: maxThreads \(searcher.maxThreadsPerThreadgroup)")
} catch {
    print("SKIP: metal unavailable: \(error)")
    exit(2)
}

// A handful of distinct queries, so the timings are not one lucky vector.
var queryGenerator = LCG(state: 0xC0FFEE)
var queries: [[Float]] = []
for _ in 0..<8 { queries.append(unitVector(&queryGenerator)) }

// Warm both paths: first-touch page faults on the mmap and the first pipeline
// launch are not part of the steady-state cost being compared.
_ = try reader.scores(query: queries[0])
_ = try searcher.scores(query: queries[0])

var cpuTimes: [Double] = []
var gpuTimes: [Double] = []
var worstDelta: Float = 0
var rankingsAgree = true

for iteration in 0..<iterations {
    let query = queries[iteration % queries.count]

    let cpuStart = Date()
    let cpuScores = try reader.scores(query: query)
    cpuTimes.append(Date().timeIntervalSince(cpuStart))

    let gpuStart = Date()
    let gpuScores = try searcher.scores(query: query)
    gpuTimes.append(Date().timeIntervalSince(gpuStart))

    // Same top-k ordering, and scores that agree to float16 storage precision.
    let k = 100
    let cpuTop = MetalSimilaritySearch.selectTopK(cpuScores, k: k).map(\.slot)
    let gpuTop = MetalSimilaritySearch.selectTopK(gpuScores, k: k).map(\.slot)
    if cpuTop != gpuTop { rankingsAgree = false }
    for index in 0..<min(cpuScores.count, gpuScores.count) {
        worstDelta = max(worstDelta, abs(cpuScores[index] - gpuScores[index]))
    }
}

cpuTimes.sort()
gpuTimes.sort()
print(String(format: "accelerate: P50 %.2f ms, P95 %.2f ms, min %.2f ms",
             quantile(cpuTimes, 0.5) * 1000, quantile(cpuTimes, 0.95) * 1000, cpuTimes[0] * 1000))
print(String(format: "metal:      P50 %.2f ms, P95 %.2f ms, min %.2f ms",
             quantile(gpuTimes, 0.5) * 1000, quantile(gpuTimes, 0.95) * 1000, gpuTimes[0] * 1000))
print(String(format: "speedup:    %.2fx (metal vs accelerate, P50)",
             quantile(cpuTimes, 0.5) / quantile(gpuTimes, 0.5)))
print(String(format: "top-100 rankings agree: %@", rankingsAgree ? "YES" : "NO"))
print(String(format: "max score delta:        %.2e", worstDelta))
