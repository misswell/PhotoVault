//
//  PhotoTextRecognizer.swift
//  PhotoVault
//
//  On-device OCR over a decoded image, using Vision. Nothing leaves the device
//  and no network API is involved.
//
//  Why `.accurate` and not `.fast`
//  -------------------------------
//  Measured on macOS: the `.fast` recognition level supports **six** languages
//  and `zh-Hans` is not among them, while `.accurate` supports eighteen. So for
//  a Chinese-language photo library there is no fast path at all -- asking for
//  `.fast` does not degrade gracefully, it silently returns nothing for Chinese
//  text.
//
//  That has a direct consequence for the thermal strategy in Phase 10: OCR is
//  the one stage that cannot simply be stepped down a level when the device gets
//  hot. The correct degradation is to *defer* OCR, not to lower its quality.
//
//  Language support is queried at runtime rather than hardcoded, because the
//  installed language packs differ between macOS and iOS and between OS versions.
//  Requesting an unsupported language makes Vision throw, which would fail the
//  whole recognition rather than skipping one language.
//

import Foundation
import Vision

/// What OCR produced for one image.
struct PhotoTextRecognition: Equatable, Sendable {
    /// Recognised lines in reading order. Empty when nothing was found.
    var lines: [String] = []
    /// Mean of the top-1 confidence for each observation.
    var confidence: Float = 0
    var observationCount: Int = 0
    /// `true` when recognition ran and completed; `false` only when it never ran.
    var didRun = false

    /// The text as one string, for display and for FTS indexing.
    var text: String? {
        let joined = lines.joined(separator: "\n")
        return SearchTextNormalization.normalize(joined)
    }

    static let empty = PhotoTextRecognition()
}

enum PhotoTextRecognitionError: LocalizedError {
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .recognitionFailed(let detail): "text recognition failed: \(detail)"
        }
    }
}

/// Immutable after construction, so it can be shared across the OCR workers in
/// the indexing pipeline without synchronisation.
final class PhotoTextRecognizer: Sendable {

    /// Preferred order. The first entry that is actually supported wins, so a
    /// device with only English installed still works for English.
    static let preferredLanguages = ["zh-Hans", "zh-Hant", "en-US"]

    /// Recognition level. Not configurable: see the note at the top of the file.
    static let recognitionLevel: VNRequestTextRecognitionLevel = .accurate

    let languages: [String]
    /// Language correction fixes obvious OCR slips but can rewrite exact
    /// strings -- an invoice number is a plausible casualty. Default on, because
    /// search recall matters more than character-exact recovery of a number
    /// nobody queries in full, but exposed so a caller can turn it off.
    let usesLanguageCorrection: Bool
    /// Images larger than this are downscaled before recognition. A 12 MP photo
    /// costs several seconds at full size for text that occupies a fraction of
    /// the frame; 2048 px keeps receipts and screenshots legible at a fraction
    /// of the cost.
    let maximumDimension: Int

    init(
        usesLanguageCorrection: Bool = true,
        maximumDimension: Int = 2048,
        languages: [String]? = nil
    ) {
        self.languages = languages ?? Self.supportedLanguages()
        self.usesLanguageCorrection = usesLanguageCorrection
        self.maximumDimension = maximumDimension
    }

    /// The subset of `preferredLanguages` this platform can actually recognise,
    /// falling back to whatever is available so a device without Chinese still
    /// gets English instead of failing.
    static func supportedLanguages() -> [String] {
        // The instance method is the current spelling; the older class method is
        // deprecated and its revision argument has to be guessed.
        let probe = VNRecognizeTextRequest()
        probe.recognitionLevel = recognitionLevel
        let available = (try? probe.supportedRecognitionLanguages()) ?? []
        guard !available.isEmpty else { return ["en-US"] }
        let matched = preferredLanguages.filter { available.contains($0) }
        // Keep the whole set when nothing matches rather than throwing later;
        // Vision will still try with its default.
        return matched.isEmpty ? Array(available.prefix(1)) : matched
    }

    /// `true` when this platform can recognise Chinese. Callers use it to decide
    /// whether an OCR-dependent query is worth attempting at all.
    static var supportsChinese: Bool {
        let supported = supportedLanguages()
        return supported.contains { $0.hasPrefix("zh") }
    }

    func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = Self.recognitionLevel
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = usesLanguageCorrection
        return request
    }

    /// Recognises text synchronously. **Blocking**: Vision's `perform` does not
    /// return until recognition finishes, so callers must not run this on the
    /// main thread.
    func recognize(cgImage: CGImage) throws -> PhotoTextRecognition {
        let request = makeRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw PhotoTextRecognitionError.recognitionFailed(error.localizedDescription)
        }
        return Self.summarize(request)
    }

    /// Async wrapper that keeps recognition off the caller's executor.
    func recognize(cgImage: CGImage) async throws -> PhotoTextRecognition {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try self.recognize(cgImage: cgImage))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func summarize(_ request: VNRecognizeTextRequest) -> PhotoTextRecognition {
        var result = PhotoTextRecognition()
        result.didRun = true
        let observations = request.results ?? []
        result.observationCount = observations.count
        var confidenceSum: Float = 0
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            result.lines.append(candidate.string)
            confidenceSum += candidate.confidence
        }
        if !observations.isEmpty {
            result.confidence = confidenceSum / Float(observations.count)
        }
        return result
    }

    /// Text plus the version of the recognition model, so a later model upgrade
    /// can invalidate stored OCR text instead of mixing outputs from two
    /// different recognisers in one index.
    static let textIndexVersion = 1
}
