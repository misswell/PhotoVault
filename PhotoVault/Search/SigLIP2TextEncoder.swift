//
//  SigLIP2TextEncoder.swift
//  PhotoVault
//
//  Runs the converted SigLIP2 text tower and returns a 768-dimensional query
//  embedding.
//
//  This is the Swift half of the pipeline that was previously only ever executed
//  from Python. The tokenizer port and the Core ML conversion were each verified
//  against the PyTorch reference separately, but the two Swift pieces had never
//  actually met; `verify_siglip2.py textencoder` closes that gap by running this
//  class end to end against reference embeddings for the same strings.
//
//  What the caller must not get wrong
//  ----------------------------------
//  * The input is **not** lowercased. The manifest's `doLowerCase` is false, and
//    the reference model scores cos("CAT", "cat") = 0.86 -- folding case here
//    would silently stop matching the model it was converted from.
//  * The sequence must be padded to exactly `maxLength` (64). The model has no
//    attention mask and pools the **last position**, which for a short query is
//    a pad token. Truncating-and-padding is therefore not cosmetic: a shorter
//    input would change which position is pooled and produce a different
//    embedding than the reference.
//

import Foundation
import CoreML

enum SigLIP2TextEncoderError: LocalizedError {
    case modelMissing(URL)
    case inputMissing(String)
    case outputMissing(String)
    case unexpectedShape(String)
    case predictionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelMissing(let url): "no Core ML model at \(url.path)"
        case .inputMissing(let name): "the model has no input named \(name)"
        case .outputMissing(let name): "the model has no output named \(name)"
        case .unexpectedShape(let detail): "unexpected model shape: \(detail)"
        case .predictionFailed(let detail): "text encoding failed: \(detail)"
        }
    }
}

/// The shipping query encoder.
///
/// `@unchecked Sendable` rests on `lock`, for the same reason as the vision
/// encoder: `inputArray`/`inputPointer` is a single reused buffer, so concurrent
/// encodes would mix two queries' tokens and return one query's embedding for
/// another. That is worse than a wrong answer -- it would silently attribute a
/// search to the wrong text.
final class SigLIP2TextEncoder: @unchecked Sendable {

    /// Matches the manifest; asserted against the loaded model rather than
    /// assumed, so a mismatched model fails loudly instead of producing a
    /// plausible-looking wrong embedding.
    static let expectedDimension = 768
    static let expectedMaxLength = 64
    static let inputName = "input_ids"
    static let outputName = "embedding"

    let dimension: Int
    let maxLength: Int
    let padTokenID: Int32

    private let model: MLModel
    private let inputArray: MLMultiArray
    /// Mutable view of `inputArray`, so filling tokens is a memory write rather
    /// than a per-element `NSNumber` boxing on the query path.
    private let inputPointer: UnsafeMutablePointer<Int32>
    /// Guards the whole fill-then-predict cycle on the shared input buffer.
    private let lock = NSLock()

    /// - Parameter compileIfNeeded: an `.mlpackage` must be compiled before
    ///   `MLModel` will load it. An app bundle ships the already-compiled
    ///   `.mlmodelc`, so this is only true for tooling and the test harness.
    init(
        modelURL: URL,
        computeUnits: MLComputeUnits = .all,
        padTokenID: Int32 = 0,
        compileIfNeeded: Bool = false
    ) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw SigLIP2TextEncoderError.modelMissing(modelURL)
        }
        let loadURL: URL
        if compileIfNeeded, modelURL.pathExtension == "mlpackage" {
            loadURL = try MLModel.compileModel(at: modelURL)
        } else {
            loadURL = modelURL
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        self.model = try MLModel(contentsOf: loadURL, configuration: configuration)

        let description = model.modelDescription
        guard let input = description.inputDescriptionsByName[Self.inputName],
              let inputConstraint = input.multiArrayConstraint
        else {
            throw SigLIP2TextEncoderError.inputMissing(Self.inputName)
        }
        guard let output = description.outputDescriptionsByName[Self.outputName],
              let outputConstraint = output.multiArrayConstraint
        else {
            throw SigLIP2TextEncoderError.outputMissing(Self.outputName)
        }

        let inputShape = inputConstraint.shape.map(\.intValue)
        let outputShape = outputConstraint.shape.map(\.intValue)
        guard inputShape.count == 2, inputShape[0] == 1, inputShape[1] > 0 else {
            throw SigLIP2TextEncoderError.unexpectedShape("input \(inputShape)")
        }
        guard outputShape.count == 2, outputShape[1] == Self.expectedDimension else {
            throw SigLIP2TextEncoderError.unexpectedShape("output \(outputShape)")
        }

        self.dimension = outputShape[1]
        self.maxLength = inputShape[1]
        self.padTokenID = padTokenID

        let array = try MLMultiArray(shape: inputShape as [NSNumber], dataType: .int32)
        self.inputArray = array
        self.inputPointer = array.dataPointer.bindMemory(
            to: Int32.self, capacity: inputShape[1]
        )
        // The padding is fixed for the lifetime of the encoder, so write it once
        // instead of on every query.
        for index in 0..<inputShape[1] { inputPointer[index] = padTokenID }
    }

    /// Embeds already-tokenized ids.
    ///
    /// Ids are truncated to `maxLength` and right-padded with the pad token --
    /// see the note at the top of this file about why the padding is required.
    func embedding(tokenIDs: [Int32]) throws -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let count = min(tokenIDs.count, maxLength)
        for index in 0..<count { inputPointer[index] = tokenIDs[index] }
        for index in count..<maxLength { inputPointer[index] = padTokenID }

        let provider = try MLDictionaryFeatureProvider(
            dictionary: [Self.inputName: MLFeatureValue(multiArray: inputArray)]
        )
        let result: MLFeatureProvider
        do {
            result = try model.prediction(from: provider)
        } catch {
            throw SigLIP2TextEncoderError.predictionFailed(error.localizedDescription)
        }
        guard let embedding = result.featureValue(for: Self.outputName)?.multiArrayValue else {
            throw SigLIP2TextEncoderError.outputMissing(Self.outputName)
        }
        if embedding.dataType == .float32 {
            let pointer = embedding.dataPointer.bindMemory(to: Float.self, capacity: embedding.count)
            return Array(UnsafeBufferPointer(start: pointer, count: embedding.count))
        }
        // float16 output: convert explicitly rather than letting `floatValue`
        // box every element.
        var values = [Float](repeating: 0, count: embedding.count)
        for index in 0..<embedding.count { values[index] = embedding[index].floatValue }
        return values
    }

    /// Embeds one query through the tokenizer and this model.
    ///
    /// Kept here so callers cannot accidentally pass unpadded ids.
    func embedding(text: String, tokenizer: SigLIP2Tokenizer) throws -> [Float] {
        try embedding(tokenIDs: tokenizer.encode(text))
    }
}
