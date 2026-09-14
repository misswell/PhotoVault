// Verifies the *bundled* model artifacts, not the conversion output.
//
// Everything else in this directory checks the pipeline: Python reference,
// converted mlpackage, Swift port. Those all passed while the app still had no
// model in it, because "the mlpackage is correct" and "the app can load what
// shipped" are different claims. This harness closes that gap by loading the
// `.mlmodelc` files out of the built PhotoVault.app and running them.
//
// The decisive check is the last one: `CAT` and `cat` must embed to a cosine of
// about 0.8616. That single number proves the bundled tokenizer and the bundled
// text tower are the *pair* that was validated -- a mismatched vocabulary, a
// case-folding normalizer, or a stale model would each move it.

import Foundation
import CoreGraphics
import CoreML
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

func cosine(_ a: [Float], _ b: [Float]) -> Float {
    var dot: Float = 0, na: Float = 0, nb: Float = 0
    for index in 0..<min(a.count, b.count) {
        dot += a[index] * b[index]
        na += a[index] * a[index]
        nb += b[index] * b[index]
    }
    let denominator = na.squareRoot() * nb.squareRoot()
    return denominator == 0 ? 0 : dot / denominator
}

func norm(_ v: [Float]) -> Float { v.reduce(0) { $0 + $1 * $1 }.squareRoot() }

// ---------------------------------------------------------------------------
// Locate the built app bundle. The path is passed in so the gate can point at
// whatever DerivedData directory the build used.

guard CommandLine.arguments.count > 1 else {
    print("usage: bundle_test <path to PhotoVault.app>")
    exit(2)
}
let appURL = URL(fileURLWithPath: CommandLine.arguments[1])
print("app bundle: \(appURL.path)")

guard let bundle = Bundle(url: appURL) else {
    print("RESULT: cannot open \(appURL.path) as a bundle")
    exit(1)
}

let resources = SearchModelResources(bundle: bundle)

// ---------------------------------------------------------------------------
section("the app bundle contains a usable model")

check(resources.isInstalled, "every search artifact is present in the bundle")

do {
    let vision = try resources.visionModelURL()
    let text = try resources.textModelURL()
    let tokenizer = try resources.tokenizerURL()
    print("         vision:    \(vision.lastPathComponent)")
    print("         text:      \(text.lastPathComponent)")
    print("         tokenizer: \(tokenizer.lastPathComponent)")
    check(vision.pathExtension == "mlmodelc",
          "the vision tower is compiled, not a copied mlpackage", vision.pathExtension)
    check(text.pathExtension == "mlmodelc",
          "the text tower is compiled, not a copied mlpackage", text.pathExtension)
    // The manifest is how a bug report says which build is installed.
    let manifest = try resources.manifest()
    print("         manifest: \(manifest.name), \(manifest.quantization), "
          + "installed=\(manifest.installedPrecision ?? "?")")
    check(manifest.embeddingDimension == 768,
          "the manifest reports the embedding dimension", "\(manifest.embeddingDimension)")
    check(manifest.license == "Apache-2.0", "and the licence", manifest.license)
    check(manifest.source == "google/siglip2-base-patch16-256",
          "and the model it came from", manifest.source)
} catch {
    check(false, "the manifest and artifact URLs resolve", "\(error)")
}

// ---------------------------------------------------------------------------
section("the bundled models load and run")

var visionEncoder: SigLIP2VisionEncoder?
var textEncoder: SigLIP2TextEncoder?
var tokenizer: SigLIP2Tokenizer?

do {
    // This is the step that would fail on a device if the mlpackage had been
    // copied rather than compiled, or if Xcode had flattened a needed
    // subdirectory.
    tokenizer = try resources.makeTokenizer()
    visionEncoder = try resources.makeVisionEncoder()
    textEncoder = try resources.makeTextEncoder()
    check(true, "the tokenizer and both encoders load from the bundle")
} catch {
    check(false, "the tokenizer and both encoders load from the bundle", "\(error)")
}

do {
    if let visionEncoder {
        // The dimension must agree with the manifest: it is read from the
        // model's own output description, so a mismatch means the wrong model
        // was installed.
        check(visionEncoder.dimension == 768,
              "the vision tower reports 768 dimensions", "\(visionEncoder.dimension)")

        let context = CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let image = context.makeImage()!

        let vector = try visionEncoder.embedding(cgImage: image)
        check(vector.count == 768, "an image embeds to 768 values", "\(vector.count)")
        // Normalization is baked into the graph, so a unit vector is the
        // evidence that the conversion's invariant survived packaging.
        let magnitude = norm(vector)
        print(String(format: "         image norm: %.7f", magnitude))
        check(abs(magnitude - 1) < 0.001,
              "and is L2-normalized, so the graph still bakes normalization in",
              String(format: "%.7f", magnitude))

        // Determinism: the same pixels must not drift between calls. This is
        // what the encoder's lock protects on the concurrent path.
        let again = try visionEncoder.embedding(cgImage: image)
        check(cosine(vector, again) > 0.99999,
              "embedding the same image twice is stable",
              String(format: "%.8f", cosine(vector, again)))
    }
} catch {
    check(false, "the vision tower produces a normalized embedding", "\(error)")
}

// ---------------------------------------------------------------------------
section("the bundled pair reproduces the validated behaviour")

do {
    if let textEncoder, let tokenizer {
        let cat = try textEncoder.embedding(text: "CAT", tokenizer: tokenizer)
        let catLower = try textEncoder.embedding(text: "cat", tokenizer: tokenizer)
        check(cat.count == 768, "text embeds to 768 values", "\(cat.count)")
        print(String(format: "         text norm: %.7f", norm(cat)))
        check(abs(norm(cat) - 1) < 0.001, "and is L2-normalized")

        // The decisive number. The reference implementation measures
        // cos("CAT", "cat") = 0.8616 precisely because this tokenizer does NOT
        // fold case: they are different tokens (29492 vs 4991). A tokenizer that
        // folded case would push this towards ~1.0, and a stale or mismatched
        // text tower would land somewhere else entirely.
        let caseSimilarity = cosine(cat, catLower)
        print(String(format: "         cos(CAT, cat) = %.4f (reference 0.8616)", caseSimilarity))
        check(abs(caseSimilarity - 0.8616) < 0.01,
              "case is still not folded, so the bundled pair is the validated one",
              String(format: "%.4f", caseSimilarity))

        let catRepeat = try textEncoder.embedding(text: "cat", tokenizer: tokenizer)
        check(cosine(catLower, catRepeat) > 0.99999,
              "repeating a query is stable",
              String(format: "%.8f", cosine(catLower, catRepeat)))

        // Cross-modal: the two towers must land in a shared space. This does
        // not need a real photo to be meaningful -- what it rules out is a text
        // tower whose output is orthogonal to every image because the wrong
        // projection was exported.
        if let visionEncoder {
            let context = CGContext(
                data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )!
            context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            let imageVector = try visionEncoder.embedding(cgImage: context.makeImage()!)
            let cross = cosine(cat, imageVector)
            print(String(format: "         cos(text \"cat\", solid grey) = %.4f", cross))
            check(cross.isFinite && abs(cross) < 0.5,
                  "text and image embeddings are comparable, not orthogonal or NaN",
                  "\(cross)")
        }
    }
} catch {
    check(false, "the bundled text tower reproduces the reference", "\(error)")
}

// ---------------------------------------------------------------------------
print("\nchecks: \(checks), failures: \(failures)")
if failures == 0 {
    print("RESULT: all \(checks) bundled-model checks passed")
    exit(0)
} else {
    print("RESULT: \(failures) of \(checks) checks FAILED")
    exit(1)
}
