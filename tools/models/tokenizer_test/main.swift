// Swift tokenizer parity harness.
//
// Compiled together with `PhotoVault/Search/SigLIP2Tokenizer.swift` and run on
// macOS, so the port is checked against Python-generated ground truth without
// needing an Xcode test target or a device. Exits non-zero on any mismatch.

import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: harness <artifact> <ground-truth.json>\n".utf8))
    exit(2)
}
let artifactURL = URL(fileURLWithPath: arguments[1])
let truthURL = URL(fileURLWithPath: arguments[2])

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
}

let tokenizer: SigLIP2Tokenizer
do {
    let started = Date()
    tokenizer = try SigLIP2Tokenizer(artifactURL: artifactURL)
    let elapsed = Date().timeIntervalSince(started) * 1000
    print(String(format: "loaded artifact in %.1f ms", elapsed))
    print("  \(tokenizer.description)")
    print("  source sha256: \(tokenizer.configuration.sourceSHA256.prefix(16))…")
} catch {
    fail("could not load tokenizer: \(error)")
}

// Configuration facts the app relies on. If any of these drift, the text tower
// is being fed a different token stream than it was trained on.
let expected = (vocab: 256_000, unk: Int32(3), bos: Int32(2), eos: Int32(1), pad: Int32(0))
let c = tokenizer.configuration
guard c.vocabSize == expected.vocab else { fail("vocabSize \(c.vocabSize) != \(expected.vocab)") }
guard c.unkID == expected.unk, c.bosID == expected.bos, c.eosID == expected.eos, c.padID == expected.pad
else { fail("special ids drifted: unk=\(c.unkID) bos=\(c.bosID) eos=\(c.eosID) pad=\(c.padID)") }
guard c.byteFallback else { fail("byteFallback must be enabled") }
guard c.userDefinedCount == 245 else { fail("userDefinedCount \(c.userDefinedCount) != 245") }
// This checkpoint's normalizer is the identity: asserting it here means a future
// checkpoint swap cannot silently introduce NFKC or case folding.
guard !c.addDummyPrefix, !c.removeExtraWhitespaces, c.escapeWhitespaces
else { fail("unexpected normalizer configuration: \(c)") }
print("configuration assertions passed")

guard let truthData = try? Data(contentsOf: truthURL),
      let truth = try? JSONSerialization.jsonObject(with: truthData) as? [String: Any],
      let texts = truth["texts"] as? [String],
      let expectedIDs = truth["ids"] as? [[Int]]
else { fail("could not parse ground truth at \(truthURL.path)") }

print("comparing \(texts.count) strings against Python ground truth")
var mismatches = 0
let started = Date()
for (index, text) in texts.enumerated() {
    let got = tokenizer.encode(text).map(Int.init)
    let want = expectedIDs[index]
    if got != want {
        mismatches += 1
        if mismatches <= 10 {
            print("MISMATCH text[\(index)] = \(text.debugDescription)")
            print("  swift : \(got.prefix(24))\(got.count > 24 ? " …(\(got.count))" : "")")
            print("  python: \(want.prefix(24))\(want.count > 24 ? " …(\(want.count))" : "")")
            // Point at the first differing position, which is the actionable part.
            if let firstDiff = (0..<min(got.count, want.count)).first(where: { got[$0] != want[$0] }) {
                print("  first divergence at index \(firstDiff): swift=\(got[firstDiff]) python=\(want[firstDiff])")
            }
        }
    }
}
let elapsed = Date().timeIntervalSince(started)

print(String(format: "encoded %d strings in %.0f ms (%.1f µs/string)",
             texts.count, elapsed * 1000, elapsed * 1_000_000 / Double(texts.count)))

// Realistic-query latency. The corpus average above is dominated by 300-character
// adversarial strings; what the search field actually tokenizes is much shorter,
// and this is the number that matters next to the ~10 ms text encoder.
let realistic = ["海边的狗", "去年夏天在海边拍的照片", "发票", "dog on the beach at sunset"]
let iterations = 2000
var benchIDs: [Int32] = []
let benchStart = Date()
for _ in 0..<iterations {
    for query in realistic { benchIDs = tokenizer.encode(query) }
}
let benchElapsed = Date().timeIntervalSince(benchStart)
let perQuery = benchElapsed * 1_000_000 / Double(iterations * realistic.count)
print(String(format: "realistic query latency: %.1f µs/query (%d queries)", perQuery, iterations * realistic.count))
_ = benchIDs

if mismatches == 0 {
    print("RESULT: Swift tokenizer matches Python on all \(texts.count) strings")
    exit(0)
} else {
    print("RESULT: \(mismatches) mismatches out of \(texts.count)")
    exit(1)
}
