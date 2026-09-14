// Vision-encoder parity: does the Swift image pipeline reproduce the tensor and
// the embedding the Python reference produced?
//
// Two independently reported numbers, because they fail for different reasons:
//
//   1. Preprocessing parity -- the Swift tensor against `image_input.bin`, which
//      is the exact array the reference fed to PyTorch. A mismatch here is a
//      resize, colour or layout bug in this code.
//   2. Embedding parity -- the Core ML output against the reference embeddings.
//      This bundles preprocessing with the model, so it is the number that
//      actually predicts whether an indexed photo will be findable.
//
// Reporting only the second would hide a preprocessing bug behind a cosine that
// still looked acceptable.

import Foundation
import CoreGraphics
import ImageIO

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
section("fixtures")

let modelsDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // visionencoder_test
    .deletingLastPathComponent()   // models
let parityDirectory = modelsDirectory.appendingPathComponent("build/parity")
let manifestURL = parityDirectory.appendingPathComponent("manifest.json")

guard let manifestData = try? Data(contentsOf: manifestURL),
      let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
      let imagePaths = manifest["image_paths"] as? [String],
      let referenceEmbeddings = manifest["image_embeddings"] as? [[Double]],
      let tensorShape = manifest["image_input_shape"] as? [Int],
      tensorShape.count == 4
else {
    print("could not read \(manifestURL.path)")
    print("run: python verify_siglip2.py walk   (regenerates build/parity)")
    exit(1)
}

let referenceTensorPath = parityDirectory.appendingPathComponent("image_input.bin")
guard let referenceTensorData = try? Data(contentsOf: referenceTensorPath) else {
    print("could not read \(referenceTensorPath.path)")
    exit(1)
}

let referenceTensor = referenceTensorData.withUnsafeBytes { raw -> [Float] in
    let bound = raw.bindMemory(to: Float.self)
    return Array(bound)
}

let channels = tensorShape[1]
let side = tensorShape[2]
let plane = side * side
let valuesPerImage = channels * plane
print("         reference tensor: \(tensorShape), \(referenceTensor.count) floats")

// Only the images actually present are usable; the manifest also lists app
// screenshots that are not in the working tree.
func fixtureURL(_ relative: String) -> URL {
    // Some manifest entries are absolute paths (the app screenshots). Appending
    // an absolute path to a directory URL percent-encodes its leading slash and
    // produces a path that silently does not exist -- which is how the first
    // version of this harness reported 50 of 57 available.
    relative.hasPrefix("/")
        ? URL(fileURLWithPath: relative)
        : parityDirectory.appendingPathComponent(relative)
}

var available: [(index: Int, url: URL)] = []
for (index, relative) in imagePaths.enumerated() {
    let url = fixtureURL(relative)
    if FileManager.default.fileExists(atPath: url.path) { available.append((index, url)) }
}
print("         \(available.count) of \(imagePaths.count) fixture images present")
check(!available.isEmpty, "at least one fixture image is available")

// ---------------------------------------------------------------------------
section("preprocessing parity (Swift tensor vs the reference tensor)")

func cosine(_ a: [Float], _ b: [Double]) -> Double {
    var dot = 0.0, normA = 0.0, normB = 0.0
    for index in 0..<min(a.count, b.count) {
        dot += Double(a[index]) * b[index]
        normA += Double(a[index]) * Double(a[index])
        normB += b[index] * b[index]
    }
    guard normA > 0, normB > 0 else { return 0 }
    return dot / (normA.squareRoot() * normB.squareRoot())
}

func cosine(_ a: [Float], _ b: [Float]) -> Double {
    var dot = 0.0, normA = 0.0, normB = 0.0
    for index in 0..<min(a.count, b.count) {
        dot += Double(a[index]) * Double(b[index])
        normA += Double(a[index]) * Double(a[index])
        normB += Double(b[index]) * Double(b[index])
    }
    guard normA > 0, normB > 0 else { return 0 }
    return dot / (normA.squareRoot() * normB.squareRoot())
}

/// Loads an image at its native size, not a thumbnail: the reference resized
/// from the full-resolution pixels, so downsampling here would compare against
/// a different input than the one the model was verified with.
func loadImage(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    return image
}

struct PreprocessingResult {
    var name: String
    var maxAbsoluteDifference: Float
    var meanAbsoluteDifference: Float
    var tensorCosine: Double
    var flippedCosine: Double
}

var preprocessingResults: [PreprocessingResult] = []

for entry in available {
    let name = URL(fileURLWithPath: imagePaths[entry.index]).lastPathComponent
    guard let image = loadImage(entry.url) else {
        print("         \(name): could not decode")
        continue
    }
    guard let tensor = try? SigLIP2ImagePreprocessing.tensor(for: image, imageSize: side) else {
        print("         \(name): preprocessing failed")
        continue
    }
    let start = entry.index * valuesPerImage
    let expected = Array(referenceTensor[start..<(start + valuesPerImage)])

    var maxDifference: Float = 0
    var totalDifference: Double = 0
    for index in 0..<valuesPerImage {
        let difference = abs(tensor[index] - expected[index])
        if difference > maxDifference { maxDifference = difference }
        totalDifference += Double(difference)
    }
    // A vertical flip is the classic layout bug, and it produces a tensor that
    // still looks plausible in isolation. Comparing against the flipped
    // reference identifies it instead of leaving it as a mystery.
    var flipped = [Float](repeating: 0, count: valuesPerImage)
    for channel in 0..<channels {
        for row in 0..<side {
            for column in 0..<side {
                let source = channel * plane + (side - 1 - row) * side + column
                let destination = channel * plane + row * side + column
                flipped[destination] = expected[source]
            }
        }
    }

    preprocessingResults.append(PreprocessingResult(
        name: name,
        maxAbsoluteDifference: maxDifference,
        meanAbsoluteDifference: Float(totalDifference / Double(valuesPerImage)),
        tensorCosine: cosine(tensor, expected.map { Double($0) }),
        flippedCosine: cosine(tensor, flipped)
    ))
}

preprocessingResults.sort { $0.maxAbsoluteDifference > $1.maxAbsoluteDifference }
for result in preprocessingResults.prefix(4) {
    print(String(format: "         %@: max %.5f, mean %.6f, cos %.6f (flipped %.6f)",
                 result.name, result.maxAbsoluteDifference, result.meanAbsoluteDifference,
                 result.tensorCosine, result.flippedCosine))
}

// PNG is lossless, so both decoders must produce identical pixels and any
// difference is this code's fault. JPEG is not: Apple's ImageIO and libjpeg
// implement the IDCT and chroma upsampling differently, so a difference is
// expected and cannot be removed -- the app has to decode with the platform
// decoder. Separating them is what makes the failure interpretable.
let lossless = preprocessingResults.filter { $0.name.hasSuffix(".png") }
let lossy = preprocessingResults.filter { !$0.name.hasSuffix(".png") }

if let worst = lossless.first {
    check(worst.maxAbsoluteDifference <= 0.004,
          "a lossless source reproduces the reference tensor",
          String(format: "max %.5f on %@", worst.maxAbsoluteDifference, worst.name))
}
if let worst = lossy.first {
    print(String(format: "         lossy (decoder-limited): worst max %.5f, cos %.6f on %@",
                 worst.maxAbsoluteDifference, worst.tensorCosine, worst.name))
    // The decoder moves pixels; this asserts the move stayed a decoder-sized
    // perturbation rather than growing into a resampling error.
    check(lossy.allSatisfy { $0.tensorCosine > 0.99 },
          "a lossy source stays close to the reference despite a different decoder",
          "\(lossy.map { String(format: "%.4f", $0.tensorCosine) })")
}
if let worst = preprocessingResults.first {
    // If the flipped score were higher, the decoder were emitting rows bottom-up.
    check(worst.tensorCosine >= worst.flippedCosine,
          "the image is not vertically flipped",
          String(format: "upright %.6f vs flipped %.6f", worst.tensorCosine, worst.flippedCosine))
}

// ---------------------------------------------------------------------------
section("resampler parity on identical pixels (the decisive resampling test)")

// Feeding the resampler the exact bytes PIL produced removes decoding from the
// comparison, so a difference here is unambiguously a resampling bug.
do {
    let directory = parityDirectory.appendingPathComponent("resample")
    let isolatedManifestURL = directory.appendingPathComponent("manifest.json")
    if let data = try? Data(contentsOf: isolatedManifestURL),
       let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let records = root["images"] as? [[String: Any]],
       let rawData = try? Data(contentsOf: directory.appendingPathComponent("raw_rgb.bin")),
       let expectedData = try? Data(contentsOf: directory.appendingPathComponent("expected.bin")) {
        let expected = expectedData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let side = (root["imageSize"] as? Int) ?? 256
        let perImage = 3 * side * side

        var worst = (name: "", difference: Float(0))
        var worstCosine = 1.0
        var checked = 0
        rawData.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for (position, record) in records.enumerated() {
                guard let name = record["name"] as? String,
                      let width = record["width"] as? Int,
                      let height = record["height"] as? Int,
                      let offset = record["rawOffset"] as? Int,
                      let length = record["rawLength"] as? Int,
                      offset + length <= bytes.count
                else { continue }
                let pixels = Array(UnsafeBufferPointer(
                    start: bytes.baseAddress!.advanced(by: offset), count: length
                ))
                let tensor = SigLIP2ImagePreprocessing.tensor(
                    rgb: pixels, width: width, height: height, imageSize: side
                )
                let start = position * perImage
                guard start + perImage <= expected.count else { continue }
                var maximum: Float = 0
                for index in 0..<perImage {
                    maximum = max(maximum, abs(tensor[index] - expected[start + index]))
                }
                let score = cosine(tensor, Array(expected[start..<(start + perImage)]))
                worstCosine = min(worstCosine, score)
                if maximum > worst.difference { worst = (name, maximum) }
                checked += 1
            }
        }
        print(String(format: "         %d images, worst max %.6f on %@, worst cos %.7f",
                     checked, worst.difference, worst.name, worstCosine))
        check(checked == records.count, "every isolated fixture was checked",
              "\(checked) of \(records.count)")
        // The reference tensor itself is quantized to float32 and this repeats
        // the same arithmetic, so anything above float rounding is a real
        // algorithmic difference.
        check(worst.difference <= 0.004,
              "the resampler reproduces the reference tensor from identical pixels",
              String(format: "max %.5f on %@", worst.difference, worst.name))
        check(worstCosine > 0.99999, "and does so for every image",
              String(format: "worst cos %.7f", worstCosine))
    } else {
        print("         no isolated fixtures; run: python dump_resample_fixtures.py")
        check(false, "isolated resample fixtures are available")
    }
}

// ---------------------------------------------------------------------------
section("embedding parity (Core ML vision tower vs PyTorch)")

let modelURL = modelsDirectory.appendingPathComponent("out/SigLIP2ImageEncoder-w8.mlpackage")
var visionEncoder: SigLIP2VisionEncoder?
if FileManager.default.fileExists(atPath: modelURL.path) {
    do {
        visionEncoder = try SigLIP2VisionEncoder(
            modelURL: modelURL, computeUnits: .cpuAndGPU, compileIfNeeded: true
        )
    } catch {
        print("         failed to load the model: \(error)")
    }
} else {
    print("         \(modelURL.lastPathComponent) not present; skipping embedding parity")
    print("         run: python convert_siglip2.py")
}

if let encoder = visionEncoder {
    print("         model: dimension \(encoder.dimension), input \(encoder.imageSize)x\(encoder.imageSize)")
    check(encoder.dimension == 768, "the model produces 768-dimensional embeddings")
    check(encoder.imageSize == side, "and consumes the same image size as the reference")

    var embeddingScores: [(name: String, cosine: Double)] = []
    // The first prediction includes Core ML's own load and shape specialization,
    // so it is timed separately rather than mixed into the warm figure.
    var firstPredictionSeconds: Double = 0

    for (position, entry) in available.enumerated() {
        let name = URL(fileURLWithPath: imagePaths[entry.index]).lastPathComponent
        guard let image = loadImage(entry.url) else { continue }
        let started = Date()
        guard let embedding = try? encoder.embedding(cgImage: image) else {
            print("         \(name): encoding failed")
            continue
        }
        if position == 0 { firstPredictionSeconds = Date().timeIntervalSince(started) }
        let score = cosine(embedding, referenceEmbeddings[entry.index])
        embeddingScores.append((name, score))
    }

    embeddingScores.sort { $0.cosine < $1.cosine }
    for result in embeddingScores.prefix(4) {
        print(String(format: "         %@: cos %.6f", result.name, result.cosine))
    }

    if let worst = embeddingScores.first {
        print(String(format: "         worst %.6f, best %.6f over %d images",
                     worst.cosine, embeddingScores.last?.cosine ?? 0, embeddingScores.count))
        // The conversion's own W8 image parity is 0.99977 with Python
        // preprocessing. What is left is the decoder: the app cannot decode a
        // JPEG the way libjpeg does, and an extreme aspect ratio squashed to a
        // square amplifies that difference. The floor is set from the measured
        // worst case with margin, and the two numbers are reported separately so
        // a regression is visible before it reaches the floor.
        check(worst.cosine > 0.99,
              "every Swift-encoded embedding matches the PyTorch reference",
              String(format: "%.6f on %@", worst.cosine, worst.name))
    }
    check(embeddingScores.count == available.count,
          "every available image was encoded", "\(embeddingScores.count) of \(available.count)")

    // The stored rows must be unit length or the search's single multiply-add
    // shortcut is invalid; the conversion bakes normalization in, and this is
    // where that claim is checked from the Swift side.
    if let first = available.first, let image = loadImage(first.url),
       let embedding = try? encoder.embedding(cgImage: image) {
        let norm = embedding.reduce(0) { $0 + Double($1) * Double($1) }.squareRoot()
        print(String(format: "         output norm: %.7f", norm))
        check(abs(norm - 1) < 0.01, "the model output is L2-normalized", String(format: "%.7f", norm))
    }

    print(String(format: "         first prediction (includes load): %.2f s", firstPredictionSeconds))

    if let first = available.first, let image = loadImage(first.url) {
        _ = try? encoder.embedding(cgImage: image)
        var times: [Double] = []
        for _ in 0..<5 {
            let started = Date()
            _ = try? encoder.embedding(cgImage: image)
            times.append(Date().timeIntervalSince(started) * 1000)
        }
        times.sort()
        print(String(format: "         warm encode P50: %.1f ms (CPU+GPU, macOS)", times[times.count / 2]))
        check(times[times.count / 2] < 2_000, "warm encoding is not pathologically slow")
    }
}

// ---------------------------------------------------------------------------
section("resampler correctness in isolation")

do {
    // A constant image must stay constant through the filter: the coefficients
    // are normalized, so any non-constant output means they are not.
    let constant = [UInt8](repeating: 200, count: 37 * 53 * 3)
    let resized = PILResampler.resize(
        source: constant, sourceWidth: 37, sourceHeight: 53, channels: 3,
        destinationWidth: 256, destinationHeight: 256
    )
    check(resized.allSatisfy { $0 == 200 },
          "a constant image survives resizing unchanged",
          "\(Set(resized).sorted().prefix(4))")
}

do {
    // Upscaling and downscaling must both produce the requested size, and a
    // 1:1 resize must be the identity.
    let source = (0..<(16 * 16 * 3)).map { UInt8($0 % 251) }
    let identity = PILResampler.resize(
        source: source, sourceWidth: 16, sourceHeight: 16, channels: 3,
        destinationWidth: 16, destinationHeight: 16
    )
    check(identity == source, "a 1:1 resize is the identity")

    let down = PILResampler.resize(
        source: source, sourceWidth: 16, sourceHeight: 16, channels: 3,
        destinationWidth: 4, destinationHeight: 4
    )
    check(down.count == 4 * 4 * 3, "downscaling produces the requested size", "\(down.count)")
}

do {
    // Coefficient normalization is the property the whole filter rests on.
    let coefficients = PILResampler.coefficients(sourceSize: 811, destinationSize: 256)
    var worstDeviation = 0.0
    for row in coefficients.weights {
        let total = row.reduce(Int64(0), +)
        let deviation = abs(Double(total) / Double(PILResampler.precisionScale) - 1.0)
        worstDeviation = max(worstDeviation, deviation)
    }
    // Fixed-point rounding on ~8 coefficients, so a few parts in 2^22.
    check(worstDeviation < 1e-5, "every coefficient row sums to one",
          String(format: "worst %.2e", worstDeviation))
}

// ---------------------------------------------------------------------------
print("\nchecks: \(checks), failures: \(failures)")
if failures == 0 {
    print("RESULT: all \(checks) vision-encoder checks passed")
    exit(0)
} else {
    print("RESULT: \(failures) of \(checks) checks FAILED")
    exit(1)
}
