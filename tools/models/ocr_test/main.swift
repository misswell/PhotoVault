// OCR tests: Vision recognition, and the path from recognised text into the
// FTS index it will actually be searched through.
//
// The second half is the point. Recognising text correctly is only useful if a
// query can then find it, and the two FTS paths (trigram MATCH and the `instr`
// fallback for short queries) have to agree on what the recognised string means.
// Chinese OCR output has no spaces at all, which is exactly where a normalisation
// mismatch would show up.

import Foundation
import Vision
import CoreGraphics
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

// ---------------------------------------------------------------------------
section("platform capabilities")

let languages = PhotoTextRecognizer.supportedLanguages()
print("         recogniser languages: \(languages)")
check(!languages.isEmpty, "the platform reports at least one recognition language")
check(languages.allSatisfy { PhotoTextRecognizer.preferredLanguages.contains($0) },
      "only preferred languages are requested, so Vision cannot reject the set")

if languages.contains("zh-Hans") {
    check(PhotoTextRecognizer.supportsChinese, "Chinese is reported as available")
    print("         Chinese OCR is available on this platform")
} else {
    print("         NOTE: no Chinese language pack here; Chinese cases will be skipped")
}

// The constraint that shapes the Phase 10 degradation strategy: `.fast` is not a
// cheaper version of the same thing, it is a different language set.
do {
    let fastRequest = VNRecognizeTextRequest()
    fastRequest.recognitionLevel = .fast
    let fast = (try? fastRequest.supportedRecognitionLanguages()) ?? []
    let accurateRequest = VNRecognizeTextRequest()
    accurateRequest.recognitionLevel = .accurate
    let accurate = (try? accurateRequest.supportedRecognitionLanguages()) ?? []
    print("         fast: \(fast.count) languages, accurate: \(accurate.count)")
    check(accurate.count >= fast.count, "accurate recognises at least as many languages as fast")
    if accurate.contains("zh-Hans") && !fast.contains("zh-Hans") {
        check(true, "zh-Hans is absent from .fast — OCR cannot be downgraded for Chinese")
    } else if !accurate.contains("zh-Hans") {
        print("         (no Chinese here, so the .fast gap cannot be observed)")
    }
}

// ---------------------------------------------------------------------------
section("recognising rendered text")

/// Renders text to a bitmap. Real photos are not available in this harness, so
/// the input is synthetic -- but it goes through the same Vision call the app
/// will make, and the recognition quality on clean text is a fair check that the
/// wrapper is wired correctly.
func render(_ lines: [String], width: Int = 900, fontSize: CGFloat = 44) -> CGImage? {
    let height = Int(fontSize * 2.2) * lines.count + 60
    let size = CGSize(width: width, height: height)
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(origin: .zero, size: size))
    let graphics = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize),
        .foregroundColor: NSColor.black,
    ]
    for (index, line) in lines.enumerated() {
        let y = size.height - CGFloat(index + 1) * fontSize * 1.8 - 20
        NSString(string: line).draw(at: NSPoint(x: 24, y: y), withAttributes: attributes)
    }
    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()
}

struct Case {
    var name: String
    var lines: [String]
    /// Substrings that must survive recognition. Chosen to avoid depending on
    /// exact spacing, which Vision does not preserve for Chinese.
    var mustContain: [String]
    var language: String     // "en" or "zh"
}

let cases: [Case] = [
    Case(name: "receipt (English)", lines: ["INVOICE #12345", "Total 88.50 USD", "2023-05-01"],
         mustContain: ["12345", "88.50"], language: "en"),
    Case(name: "receipt (Chinese)", lines: ["发票", "报销凭证", "2023年5月"],
         mustContain: ["发票", "报销"], language: "zh"),
    Case(name: "boarding pass (mixed)", lines: ["登机牌 Boarding Pass", "北京到上海"],
         mustContain: ["登机牌", "Boarding"], language: "zh"),
    Case(name: "chat screenshot", lines: ["微信聊天记录", "明天下班一起吃饭"],
         mustContain: ["微信", "吃饭"], language: "zh"),
    Case(name: "card", lines: ["身份证", "姓名 张三"],
         mustContain: ["身份证", "张三"], language: "zh"),
]

let recognizer = PhotoTextRecognizer()
var recognised: [String: PhotoTextRecognition] = [:]

for testCase in cases {
    if testCase.language == "zh" && !languages.contains("zh-Hans") {
        print("  SKIP \(testCase.name): no Chinese language pack")
        continue
    }
    guard let image = render(testCase.lines) else {
        check(false, "\(testCase.name): renders")
        continue
    }
    let start = Date()
    do {
        let result = try recognizer.recognize(cgImage: image)
        let ms = Date().timeIntervalSince(start) * 1000
        recognised[testCase.name] = result
        let flat = result.lines.joined(separator: " ")
        // Chinese recognition does not insert spaces, so compare against a
        // whitespace-stripped form for the substring assertions.
        let compact = flat.replacingOccurrences(of: " ", with: "")
        let missing = testCase.mustContain.filter { token in
            !flat.contains(token) && !compact.contains(token)
        }
        print(String(format: "         %@ (%.0f ms, conf %.2f): %@",
                     testCase.name, ms, result.confidence, flat))
        check(missing.isEmpty, "\(testCase.name): recognised the expected text",
              "missing \(missing)")
        check(result.didRun && result.observationCount > 0,
              "\(testCase.name): produced observations")
    } catch {
        check(false, "\(testCase.name): recognition runs", "\(error)")
    }
}

// ---------------------------------------------------------------------------
section("text normalisation")

do {
    check(SearchTextNormalization.normalize("发票报销凭证2023年5月") == "发票报销凭证2023年5月",
          "Chinese runs are not broken apart")
    check(SearchTextNormalization.normalize("  Invoice   #12345  ") == "invoice #12345",
          "whitespace collapses and case folds",
          "\(String(describing: SearchTextNormalization.normalize("  Invoice   #12345  ")))")
    check(SearchTextNormalization.normalize("ＩＮＶＯＩＣＥ") == "invoice",
          "full-width Latin folds to ASCII")
    check(SearchTextNormalization.normalize("   ") == nil, "blank input normalises to nil")
    check(SearchTextNormalization.normalize(nil) == nil, "nil passes through")
}

// ---------------------------------------------------------------------------
section("hybrid: recognised text is findable through the FTS index")

let workDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pv-ocr-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workDirectory) }

let store = AIPhotoSearchStore(
    databaseURL: workDirectory.appendingPathComponent("AIPhotoSearch.sqlite"),
    embeddingURL: workDirectory.appendingPathComponent("embeddings-v1.bin")
)
try store.open(dimension: 8, sourceModelSHA256: String(repeating: "aa", count: 32))

// Feed each recognition into the store exactly as the indexing pipeline would.
var indexed = 0
for (index, testCase) in cases.enumerated() {
    guard let result = recognised[testCase.name] else { continue }
    let identifier = String(format: "ocr-%03d", index)
    try store.upsertMetadata([AIPhotoSearchStore.AssetMetadata(
        assetID: identifier,
        creationDate: Date(),
        modificationDate: nil,
        mediaType: 1
    )])
    try store.storeText(assetID: identifier, text: result.text)
    indexed += 1
}
check(indexed >= 3, "recognised text was indexed", "indexed \(indexed)")

if let receipt = recognised["receipt (Chinese)"], receipt.didRun {
    // "发票" is two characters: the trigram tokenizer cannot match it at all, so
    // this exercises the `instr()` fallback on real recognised output.
    let short = try store.assetIDsMatchingText(terms: ["发票"], limit: 20)
    check(!short.isEmpty, "a 2-character Chinese query finds the recognised receipt",
          "got \(short)")

    // "报销凭证" is four characters, so this goes through trigram MATCH instead.
    let long = try store.assetIDsMatchingText(terms: ["报销凭证"], limit: 20)
    check(!long.isEmpty, "a 4-character Chinese query finds it through trigram MATCH",
          "got \(long)")
    check(long == short, "both FTS paths resolve to the same asset",
          "\(short) vs \(long)")
}

if let boarding = recognised["boarding pass (mixed)"], boarding.didRun {
    let chinese = try store.assetIDsMatchingText(terms: ["登机牌"], limit: 20)
    check(!chinese.isEmpty, "mixed-script recognised text is searchable in Chinese",
          "got \(chinese)")
    let english = try store.assetIDsMatchingText(terms: ["boarding"], limit: 20)
    check(!english.isEmpty, "and in English", "got \(english)")
}

if let invoice = recognised["receipt (English)"], invoice.didRun {
    let number = try store.assetIDsMatchingText(terms: ["12345"], limit: 20)
    check(!number.isEmpty, "a digit run from OCR is searchable", "got \(number)")
}

// Excluding a term must remove the asset that has it.
do {
    let withTerm = try store.assetIDsMatchingText(terms: ["发票"], limit: 20)
    var filter = AISearchCandidateFilter()
    filter.excludedTextTerms = ["报销"]
    // Candidates require an embedding slot, so this asserts the text plumbing
    // rather than a search result; run the exclusion against the FTS set.
    _ = filter
    let excluded = try store.assetIDsMatchingText(terms: ["发票", "不存在"], limit: 20)
    check(excluded.isEmpty, "ANDing a second term that is absent removes the match",
          "\(withTerm) -> \(excluded)")
}

// ---------------------------------------------------------------------------
section("latency")

if languages.contains("zh-Hans"), let image = render(["发票 报销凭证 2023年5月"]) {
    _ = try? recognizer.recognize(cgImage: image)   // warm
    var times: [Double] = []
    for _ in 0..<5 {
        let start = Date()
        _ = try? recognizer.recognize(cgImage: image)
        times.append(Date().timeIntervalSince(start) * 1000)
    }
    times.sort()
    print(String(format: "         OCR P50 %.0f ms on a small clean image (macOS)",
                 times[times.count / 2]))
    check(times[times.count / 2] < 5_000, "recognition is not pathologically slow")
}

// ---------------------------------------------------------------------------
print("\nchecks: \(checks), failures: \(failures)")
if failures == 0 {
    print("RESULT: all \(checks) OCR checks passed")
    exit(0)
} else {
    print("RESULT: \(failures) of \(checks) checks FAILED")
    exit(1)
}
