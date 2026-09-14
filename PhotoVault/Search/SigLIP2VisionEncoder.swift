//
//  SigLIP2VisionEncoder.swift
//  PhotoVault
//
//  Turns a decoded image into the 768-dimensional embedding stored in the index.
//
//  This is the half of the on-device pipeline that had no Swift implementation
//  at all until now: the tokenizer, the text tower, the matrix, the search and
//  the query analyser were each verified, but nothing could *populate* the index
//  without this.
//
//  Preprocessing is reproduced, not approximated
//  ---------------------------------------------
//  The manifest's order is convertToRGB -> resize -> rescale -> normalize, and
//  the resize is squashing bilinear to a square: a 811x2168 screenshot is
//  distorted to 256x256 without preserving aspect ratio. That is what the
//  reference did, so it is what this must do; "improving" it with aspect
//  preservation or a centre crop would silently embed every photo differently
//  from the model that was verified.
//
//  Matching PIL exactly matters because the preprocessing is *part of the
//  model* for parity purposes. `PILResampler` below reproduces PIL's algorithm
//  including the two details an independent implementation usually gets wrong:
//
//   1. For a large downscale the triangle filter is widened by the scale factor
//      (`filterSupport * max(1, src/dst)`), which makes it an area-averaging
//      filter. A fixed-support bilinear that only samples the nearest four
//      pixels aliases badly on a 2168 -> 256 reduction and would embed a
//      moire pattern the reference never saw.
//   2. PIL clamps to 8 bits **after each pass**, and quantizes coefficients to
//      22-bit fixed point. Doing the arithmetic in floating point throughout is
//      more accurate and produces slightly *different* pixels.
//
//  The parity harness compares against the reference tensor element by element,
//  so any of these being wrong shows up as a number rather than as a vague
//  feeling that search quality is off.
//

import Foundation
import CoreML
import CoreGraphics

enum SigLIP2ImageEncoderError: LocalizedError {
    case modelMissing(URL)
    case inputMissing(String)
    case outputMissing(String)
    case unexpectedShape(String)
    case predictionFailed(String)
    case imageDecodeFailed
    case unsupportedImageSize(width: Int, height: Int)

    var errorDescription: String? {
        switch self {
        case .modelMissing(let url): "no Core ML model at \(url.path)"
        case .inputMissing(let name): "the model has no input named \(name)"
        case .outputMissing(let name): "the model has no output named \(name)"
        case .unexpectedShape(let detail): "unexpected model shape: \(detail)"
        case .predictionFailed(let detail): "image encoding failed: \(detail)"
        case .imageDecodeFailed: "the image could not be decoded to RGB"
        case .unsupportedImageSize(let width, let height):
            "the image is \(width)x\(height); at least one pixel is required"
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - PIL-compatible resampling

/// Reproduces PIL's `Image.resize(..., Image.BILINEAR)`.
///
/// Not a general-purpose image scaler and not intended as one: it exists so the
/// Swift pipeline produces the same tensor the Python reference produced. Where
/// PIL's choices are questionable (fixed-point quantization), matching them is
/// the point.
enum PILResampler {

    /// PIL's `PRECISION_BITS = 32 - 8 - 2`. Coefficients are stored as integers
    /// scaled by `1 << 22`, so the resample is integer arithmetic whose rounding
    /// is visible in the output.
    static let precisionBits = 22
    static let precisionScale = Int64(1) << Int64(precisionBits)

    /// One output position's contribution: `weights[i]` applies to source index
    /// `start + i`.
    struct Coefficients {
        var starts: [Int]
        var weights: [[Int64]]
    }

    /// PIL's `filter_bilinear`: a triangle filter with unit support.
    static func triangle(_ x: Double) -> Double {
        let magnitude = abs(x)
        return magnitude < 1.0 ? 1.0 - magnitude : 0.0
    }

    /// Builds PIL's coefficient table for one axis.
    ///
    /// The source span for output `x` is `center ± support`, where the support is
    /// scaled by `max(1, src/dst)` so a downscale averages over the region it is
    /// collapsing. Weights are normalized to sum to one, then quantized exactly
    /// as PIL quantizes them.
    static func coefficients(sourceSize: Int, destinationSize: Int) -> Coefficients {
        let scale = Double(sourceSize) / Double(destinationSize)
        let filterScale = max(1.0, scale)
        let support = 1.0 * filterScale

        var starts = [Int](repeating: 0, count: destinationSize)
        var weights = [[Int64]](repeating: [], count: destinationSize)

        for destination in 0..<destinationSize {
            let center = (Double(destination) + 0.5) * scale
            var start = Int((center - support + 0.5).rounded(.down))
            if start < 0 { start = 0 }
            var end = Int((center + support + 0.5).rounded(.down))
            if end > sourceSize { end = sourceSize }
            let count = max(0, end - start)

            var raw = [Double](repeating: 0, count: count)
            var total = 0.0
            for index in 0..<count {
                // PIL evaluates the filter at the *pixel centre* relative to the
                // output position, scaled into filter space.
                let position = (Double(index + start) - center + 0.5) / filterScale
                let weight = triangle(position)
                raw[index] = weight
                total += weight
            }
            if total != 0 {
                for index in 0..<count { raw[index] /= total }
            }
            starts[destination] = start
            weights[destination] = raw.map { Int64(($0 * Double(precisionScale) + 0.5).rounded(.down)) }
        }
        return Coefficients(starts: starts, weights: weights)
    }

    /// Clamps and rounds one accumulated value back to 8 bits, as PIL does after
    /// every pass.
    @inline(__always)
    static func clampToByte(_ accumulator: Int64) -> UInt8 {
        let rounded = (accumulator + (Int64(1) << Int64(precisionBits - 1))) >> Int64(precisionBits)
        if rounded <= 0 { return 0 }
        if rounded >= 255 { return 255 }
        return UInt8(rounded)
    }

    /// Resizes interleaved 8-bit RGB(A) pixels.
    ///
    /// Two separable passes with an 8-bit clamp between them, matching PIL
    /// rather than doing the whole thing in floating point.
    static func resize(
        source: [UInt8],
        sourceWidth: Int,
        sourceHeight: Int,
        channels: Int,
        destinationWidth: Int,
        destinationHeight: Int
    ) -> [UInt8] {
        // Horizontal pass: sourceHeight x sourceWidth -> sourceHeight x destinationWidth
        let horizontal = coefficients(sourceSize: sourceWidth, destinationSize: destinationWidth)
        var intermediate = [UInt8](repeating: 0, count: sourceHeight * destinationWidth * channels)
        source.withUnsafeBufferPointer { input in
            intermediate.withUnsafeMutableBufferPointer { output in
                for row in 0..<sourceHeight {
                    let sourceRow = row * sourceWidth * channels
                    let destinationRow = row * destinationWidth * channels
                    for column in 0..<destinationWidth {
                        let start = horizontal.starts[column]
                        let weight = horizontal.weights[column]
                        for channel in 0..<channels {
                            var accumulator: Int64 = 0
                            for (offset, coefficient) in weight.enumerated() {
                                accumulator += coefficient
                                    * Int64(input[sourceRow + (start + offset) * channels + channel])
                            }
                            output[destinationRow + column * channels + channel] = clampToByte(accumulator)
                        }
                    }
                }
            }
        }

        // Vertical pass: sourceHeight x destinationWidth -> destinationHeight x destinationWidth
        let vertical = coefficients(sourceSize: sourceHeight, destinationSize: destinationHeight)
        var result = [UInt8](repeating: 0, count: destinationHeight * destinationWidth * channels)
        intermediate.withUnsafeBufferPointer { input in
            result.withUnsafeMutableBufferPointer { output in
                for row in 0..<destinationHeight {
                    let start = vertical.starts[row]
                    let weight = vertical.weights[row]
                    let destinationRow = row * destinationWidth * channels
                    for column in 0..<destinationWidth {
                        for channel in 0..<channels {
                            var accumulator: Int64 = 0
                            for (offset, coefficient) in weight.enumerated() {
                                let sourceIndex = ((start + offset) * destinationWidth + column) * channels + channel
                                accumulator += coefficient * Int64(input[sourceIndex])
                            }
                            output[destinationRow + column * channels + channel] = clampToByte(accumulator)
                        }
                    }
                }
            }
        }
        return result
    }
}

// ---------------------------------------------------------------------------
// MARK: - Image preprocessing

enum SigLIP2ImagePreprocessing {

    static let defaultImageSize = 256
    /// `rescale_factor` from the manifest. Written as a literal rather than
    /// computed as 1/255 so it matches the reference to the last bit.
    static let rescaleFactor: Float = 0.00392156862745098
    static let mean: Float = 0.5
    static let std: Float = 0.5

    /// Decodes a `CGImage` to interleaved RGB8 in sRGB.
    ///
    /// Drawing into an 8-bit sRGB context is what makes the values comparable to
    /// PIL's `convert("RGB")`. A `CGImage` from a JPEG or PNG may carry its own
    /// colour space, and reading its raw provider data would skip the conversion
    /// the reference performed.
    static func rgbBytes(of image: CGImage) throws -> (bytes: [UInt8], width: Int, height: Int) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            throw SigLIP2ImageEncoderError.unsupportedImageSize(width: width, height: height)
        }
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw SigLIP2ImageEncoderError.imageDecodeFailed
        }
        let created: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                // Skip the alpha byte rather than premultiplying: a premultiplied
                // buffer would darken any pixel with alpha < 255, and RGB values
                // are what the reference sees.
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard created else { throw SigLIP2ImageEncoderError.imageDecodeFailed }

        // Drop the padding byte: the resampler works on tightly packed channels.
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for index in 0..<(width * height) {
            rgb[index * 3] = buffer[index * 4]
            rgb[index * 3 + 1] = buffer[index * 4 + 1]
            rgb[index * 3 + 2] = buffer[index * 4 + 2]
        }
        return (rgb, width, height)
    }

    /// Produces the `[1, 3, size, size]` float32 NCHW tensor the model expects.
    ///
    /// `range` in the manifest is [-1, 1], which is what `(x/255 - mean) / std`
    /// with mean = std = 0.5 gives.
    static func tensor(
        for image: CGImage, imageSize: Int = defaultImageSize
    ) throws -> [Float] {
        let decoded = try rgbBytes(of: image)
        return tensor(
            rgb: decoded.bytes, width: decoded.width, height: decoded.height, imageSize: imageSize
        )
    }

    /// The tensor for pixels that are already RGB8.
    ///
    /// Split out from the `CGImage` path so the resampler can be tested against
    /// identical input pixels. Comparing whole images conflates two independent
    /// things -- how the platform decodes a JPEG, and how this code resizes --
    /// and they have different fixes: one is a bug, the other is a difference
    /// between libjpeg and ImageIO that cannot be removed.
    static func tensor(
        rgb: [UInt8], width: Int, height: Int, imageSize: Int = defaultImageSize
    ) -> [Float] {
        let resized = PILResampler.resize(
            source: rgb,
            sourceWidth: width,
            sourceHeight: height,
            channels: 3,
            destinationWidth: imageSize,
            destinationHeight: imageSize
        )
        let plane = imageSize * imageSize
        var tensor = [Float](repeating: 0, count: 3 * plane)
        for index in 0..<plane {
            for channel in 0..<3 {
                let byte = resized[index * 3 + channel]
                let scaled = Float(byte) * rescaleFactor
                tensor[channel * plane + index] = (scaled - mean) / std
            }
        }
        return tensor
    }
}

// ---------------------------------------------------------------------------
// MARK: - Core ML vision tower

/// The shipping image encoder.
///
/// `@unchecked Sendable` is honest here only because of `lock`: the encoder
/// reuses **one** input buffer (`inputArray`/`inputPointer`), so two concurrent
/// encodes would interleave the copy and the prediction and one photo would be
/// embedded from another photo's pixels. That failure is silent -- both tensors
/// are valid, the output is just for the wrong image -- and it would corrupt the
/// index in a way no later check could detect.
///
/// Serialising is also the truthful model of the hardware: there is one ANE, so
/// concurrent encodes would queue on it regardless.
final class SigLIP2VisionEncoder: @unchecked Sendable {

    static let expectedDimension = 768
    static let expectedImageSize = 256
    static let inputName = "image"
    static let outputName = "embedding"

    let dimension: Int
    let imageSize: Int

    private let model: MLModel
    private let inputArray: MLMultiArray
    private let inputPointer: UnsafeMutablePointer<Float>
    /// Guards the whole fill-then-predict cycle on the shared input buffer.
    private let lock = NSLock()

    /// - Parameter compileIfNeeded: an `.mlpackage` has to be compiled before
    ///   `MLModel` will load it. A shipped bundle contains the compiled
    ///   `.mlmodelc`, so this is only true for tooling and the harness.
    init(
        modelURL: URL,
        computeUnits: MLComputeUnits = .all,
        compileIfNeeded: Bool = false
    ) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw SigLIP2ImageEncoderError.modelMissing(modelURL)
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
            throw SigLIP2ImageEncoderError.inputMissing(Self.inputName)
        }
        guard let output = description.outputDescriptionsByName[Self.outputName],
              let outputConstraint = output.multiArrayConstraint
        else {
            throw SigLIP2ImageEncoderError.outputMissing(Self.outputName)
        }

        let inputShape = inputConstraint.shape.map(\.intValue)
        let outputShape = outputConstraint.shape.map(\.intValue)
        guard inputShape.count == 4, inputShape[0] == 1, inputShape[1] == 3,
              inputShape[2] == inputShape[3], inputShape[2] > 0
        else {
            throw SigLIP2ImageEncoderError.unexpectedShape("input \(inputShape)")
        }
        guard outputShape.count == 2, outputShape[1] == Self.expectedDimension else {
            throw SigLIP2ImageEncoderError.unexpectedShape("output \(outputShape)")
        }

        self.dimension = outputShape[1]
        self.imageSize = inputShape[2]

        let array = try MLMultiArray(shape: inputShape as [NSNumber], dataType: .float32)
        self.inputArray = array
        self.inputPointer = array.dataPointer.bindMemory(
            to: Float.self, capacity: inputShape.reduce(1, *)
        )
    }

    /// Embeds a preprocessed tensor.
    func embedding(tensor: [Float]) throws -> [Float] {
        let expected = 3 * imageSize * imageSize
        guard tensor.count == expected else {
            throw SigLIP2ImageEncoderError.unexpectedShape(
                "tensor has \(tensor.count) values, expected \(expected)"
            )
        }
        // One lock around filling *and* predicting. Locking only the fill would
        // leave the buffer open to being overwritten while Core ML is still
        // reading it, which is the same corruption with a narrower window.
        lock.lock()
        defer { lock.unlock() }
        tensor.withUnsafeBufferPointer { source in
            inputPointer.update(from: source.baseAddress!, count: expected)
        }
        return try predictWhileLocked()
    }

    /// Embeds an image, running the manifest's preprocessing.
    func embedding(cgImage: CGImage) throws -> [Float] {
        try embedding(tensor: SigLIP2ImagePreprocessing.tensor(for: cgImage, imageSize: imageSize))
    }

    /// Must be called with `lock` held; the shared input buffer is read here.
    private func predictWhileLocked() throws -> [Float] {
        let provider = try MLDictionaryFeatureProvider(
            dictionary: [Self.inputName: MLFeatureValue(multiArray: inputArray)]
        )
        let result: MLFeatureProvider
        do {
            result = try model.prediction(from: provider)
        } catch {
            throw SigLIP2ImageEncoderError.predictionFailed(error.localizedDescription)
        }
        guard let embedding = result.featureValue(for: Self.outputName)?.multiArrayValue else {
            throw SigLIP2ImageEncoderError.outputMissing(Self.outputName)
        }
        if embedding.dataType == .float32 {
            let pointer = embedding.dataPointer.bindMemory(to: Float.self, capacity: embedding.count)
            return Array(UnsafeBufferPointer(start: pointer, count: embedding.count))
        }
        var values = [Float](repeating: 0, count: embedding.count)
        for index in 0..<embedding.count { values[index] = embedding[index].floatValue }
        return values
    }
}
