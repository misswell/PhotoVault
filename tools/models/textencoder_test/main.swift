// End-to-end text pipeline tests: Swift tokenizer + Core ML text tower against
// the PyTorch reference, on the same strings.
//
// The tokenizer test proves the Swift BPE port matches sentencepiece, and the
// conversion test proves the Core ML graph matches PyTorch. Both are verified
// separately, with the Swift and Python halves never meeting. This harness is
// where they meet: if the manifest says something the artifact does not do (case
// folding, padding, pooling position), the failure shows up here and nowhere
// else.

import Foundation
import CoreML

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

var fixturePath = "build/text-parity.json"
var modelPath: String?
var tokenizerPath = "build/tokenizer-v1.bin"
// Calibrated, not guessed. Measured against the PyTorch reference on the same
// 32 queries:
//
//     fp32  min 1.000000   (bit-exact)
//     fp16  min 0.999998
//     w8    min 0.998961   mean 0.999569   <- the shipping model
//
// The W8 worst case is a whitespace-only query, which carries almost no
// information; the gate sits just below it so a real regression is still caught
// while quantisation noise is not mistaken for one. The product-level gate is
// nDCG@20 loss, measured separately -- embedding cosine is a proxy, not the
// acceptance criterion.
var threshold: Float = 0.998

var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let flag = arguments.removeFirst()
    switch flag {
    case "--fixture" where !arguments.isEmpty: fixturePath = arguments.removeFirst()
    case "--model" where !arguments.isEmpty: modelPath = arguments.removeFirst()
    case "--tokenizer" where !arguments.isEmpty: tokenizerPath = arguments.removeFirst()
    case "--threshold" where !arguments.isEmpty: threshold = Float(arguments.removeFirst()) ?? threshold
    default: break
    }
}

guard let modelPath else {
    print("usage: --model <SigLIP2TextEncoder-w8.mlpackage> [--fixture ...] [--tokenizer ...]")
    exit(2)
}
guard FileManager.default.fileExists(atPath: fixturePath) else {
    print("SKIP: no fixture at \(fixturePath); run build_text_parity.py first")
    exit(0)
}

// ---------------------------------------------------------------------------
section("loading")

let tokenizer = try SigLIP2Tokenizer(artifactURL: URL(fileURLWithPath: tokenizerPath))
print("         tokenizer artifact loaded")

let encoder = try SigLIP2TextEncoder(
    modelURL: URL(fileURLWithPath: modelPath), compileIfNeeded: true
)
check(encoder.dimension == SigLIP2TextEncoder.expectedDimension,
      "model outputs \(SigLIP2TextEncoder.expectedDimension) dimensions", "got \(encoder.dimension)")
check(encoder.maxLength == SigLIP2TextEncoder.expectedMaxLength,
      "model takes a \(SigLIP2TextEncoder.expectedMaxLength)-token window", "got \(encoder.maxLength)")

// ---------------------------------------------------------------------------
section("tokenization through the Swift port")

struct Record {
    var text: String
    var tokenIDs: [Int32]
    var embedding: [Float]
}

let payload = try JSONSerialization.jsonObject(
    with: Data(contentsOf: URL(fileURLWithPath: fixturePath))
) as! [String: Any]
let records: [Record] = (payload["records"] as! [[String: Any]]).map { entry in
    Record(
        text: entry["text"] as! String,
        tokenIDs: (entry["tokenIds"] as! [Int]).map { Int32($0) },
        embedding: (entry["embedding"] as! [Double]).map { Float($0) }
    )
}
print("         \(records.count) reference queries")

var tokenMismatches: [String] = []
for record in records {
    let mine = tokenizer.encode(record.text)
    if mine != record.tokenIDs {
        let position = (0..<min(mine.count, record.tokenIDs.count))
            .first { mine[$0] != record.tokenIDs[$0] }
        tokenMismatches.append(
            "\(record.text.prefix(24))… at \(position.map(String.init) ?? "length"): "
            + "\(position.map { mine[$0] } ?? -1) vs \(position.map { record.tokenIDs[$0] } ?? -1)"
        )
    }
}
check(tokenMismatches.isEmpty,
      "the Swift tokenizer reproduces sentencepiece on all \(records.count) queries",
      tokenMismatches.prefix(3).joined(separator: "; "))

// ---------------------------------------------------------------------------
section("the full Swift pipeline against the PyTorch reference")

// Case folding is the trap this exists to catch: the HuggingFace config claims
// do_lower_case and the artifact does not do it. If anything in the Swift path
// lowercased its input, these would collapse together and the cosine would jump
// to ~1.0.
let caseVariants = records.filter { ["CAT", "cat", "Cat"].contains($0.text) }
if caseVariants.count == 3 {
    let embeddings = try caseVariants.map { try encoder.embedding(text: $0.text, tokenizer: tokenizer) }
    let upperLower = zip(embeddings[0], embeddings[1]).reduce(Float(0)) { $0 + $1.0 * $1.1 }
    check(upperLower < 0.95,
          "the pipeline does not fold case (CAT and cat stay distinct)",
          String(format: "cos = %.4f, expected ~0.86", upperLower))
} else {
    check(false, "the fixture contains the case-variant probes")
}

var worstCosine: Float = 1
var worstQuery = ""
var worstNormDeviation: Float = 0
var cosines: [Float] = []

for record in records {
    do {
        let mine = try encoder.embedding(text: record.text, tokenizer: tokenizer)
        let reference = record.embedding

        var dot: Float = 0
        var norm: Float = 0
        for i in 0..<min(mine.count, reference.count) {
            dot += mine[i] * reference[i]
            norm += mine[i] * mine[i]
        }
        let cosine = dot / max(norm.squareRoot(), 1e-9)
        cosines.append(cosine)
        if cosine < worstCosine {
            worstCosine = cosine
            worstQuery = record.text
        }
        worstNormDeviation = max(worstNormDeviation, abs(norm.squareRoot() - 1))
    } catch {
        check(false, "embedding \(record.text.prefix(20))", "\(error)")
    }
}

let mean = cosines.reduce(0, +) / Float(max(cosines.count, 1))
print(String(format: "        cosine vs PyTorch: min %.6f, mean %.6f across %d queries",
             worstCosine, mean, cosines.count))
check(cosines.count == records.count, "every query produced an embedding")
check(worstCosine >= threshold,
      "every Swift embedding matches the PyTorch reference",
      String(format: "worst %.6f \"%@\" < %.4f", worstCosine, worstQuery, threshold))

// The graph bakes normalization in, so a norm far from 1 means the output is
// being read or reshaped wrongly.
check(worstNormDeviation < 0.01,
      "embeddings come out L2-normalized as the manifest claims",
      String(format: "worst deviation %.5f", worstNormDeviation))

// ---------------------------------------------------------------------------
section("padding and truncation")

// A long query must truncate to the window rather than fail, and a short one must
// pad. Both are covered by the fixture, but assert the shape explicitly.
if let long = records.first(where: { $0.text.count > 200 }) {
    let ids = tokenizer.encode(long.text)
    check(ids.count == encoder.maxLength,
          "a query longer than the window truncates to \(encoder.maxLength) tokens",
          "got \(ids.count)")
    _ = try encoder.embedding(tokenIDs: ids)
    check(true, "a truncated query still encodes")
}

// ---------------------------------------------------------------------------
section("latency")

_ = try encoder.embedding(text: "warm up", tokenizer: tokenizer)
var times: [Double] = []
for record in records.prefix(12) {
    let start = Date()
    _ = try encoder.embedding(text: record.text, tokenizer: tokenizer)
    times.append(Date().timeIntervalSince(start) * 1000)
}
times.sort()
let p50 = times[times.count / 2]
print(String(format: "        query encode P50 %.1f ms, min %.1f ms (macOS CPU/GPU)",
             p50, times[0]))
check(p50 < 500, "query encoding is inside the 500 ms search budget",
      String(format: "%.1f ms", p50))

// ---------------------------------------------------------------------------
print("\nchecks: \(checks), failures: \(failures)")
if failures == 0 {
    print("RESULT: all \(checks) text-pipeline checks passed")
    exit(0)
} else {
    print("RESULT: \(failures) of \(checks) checks FAILED")
    exit(1)
}
