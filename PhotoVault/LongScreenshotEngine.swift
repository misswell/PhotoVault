import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

struct LongScreenshotInput: Identifiable, Sendable {
    let id: UUID
    let url: URL
    let width: Int
    let height: Int
}

struct LongScreenshotRecipe: Equatable, Sendable {
    var header = 0.0
    var footer = 0.0
    // Fraction of the remaining image removed at each seam.
    var overlaps: [Double] = []
}

struct LongScreenshotOutput: Sendable {
    let url: URL
    let width: Int
    let height: Int
    let reduced: Bool
}

enum LongScreenshotError: LocalizedError {
    case unreadable, insufficient, encoding, tooLarge
    var errorDescription: String? {
        switch self {
        case .unreadable: "无法读取图片，请重新选择。"
        case .insufficient: "请选择至少两张图片。"
        case .encoding: "长截图生成失败，请重试。"
        case .tooLarge: "图片尺寸过大，请先缩小图片后再拼接。"
        }
    }
}

/// Disk-backed inputs; only one source frame and a bounded output bitmap are
/// decoded at a time. All ImageIO work stays off the main actor.
actor LongScreenshotEngine {
    static let shared = LongScreenshotEngine()
    static let pixelBudget = 12_000_000

    func importImage(_ data: Data, directory: URL) throws -> LongScreenshotInput {
        try Task.checkCancellation()
        let id = UUID(), url = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return try inspectInput(id: id, url: url)
    }

    func importFile(_ source: URL, directory: URL) throws -> LongScreenshotInput {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID(), url = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: source, to: url)
        return try inspectInput(id: id, url: url)
    }

    private func inspectInput(id: UUID, url: URL) throws -> LongScreenshotInput {
        do {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = properties[kCGImagePropertyPixelWidth] as? Int,
                  let h = properties[kCGImagePropertyPixelHeight] as? Int,
                  w > 0, h > 0, w <= 100_000, h <= 100_000 else { throw LongScreenshotError.unreadable }
            guard w * h <= 60_000_000 else { throw LongScreenshotError.tooLarge }
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            try Task.checkCancellation()
            return .init(id: id, url: url, width: orientation >= 5 ? h : w, height: orientation >= 5 ? w : h)
        } catch { try? FileManager.default.removeItem(at: url); throw error }
    }

    func removeFiles(_ urls: [URL]) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    func thumbnail(_ input: LongScreenshotInput, maxPixel: Int = 320) throws -> UIImage {
        try Task.checkCancellation()
        return UIImage(cgImage: try Self.decode(input.url, maxPixel: maxPixel))
    }

    func detectOverlaps(_ inputs: [LongScreenshotInput], recipe: LongScreenshotRecipe) throws -> [Double] {
        guard inputs.count >= 2 else { throw LongScreenshotError.insufficient }
        var result = [0.0]
        var previous = try Self.sample(inputs[0], recipe: recipe)
        for input in inputs.dropFirst() {
            try Task.checkCancellation()
            let next = try Self.sample(input, recipe: recipe)
            result.append(try Self.overlap(previous, next))
            previous = next
        }
        return result
    }

    func render(_ inputs: [LongScreenshotInput], recipe: LongScreenshotRecipe, directory: URL) throws -> LongScreenshotOutput {
        try Task.checkCancellation()
        guard inputs.count >= 2 else { throw LongScreenshotError.insufficient }
        let baseWidth = min(1600, inputs.map { min($0.width, max(1, 4096 * $0.width / $0.height)) }.min() ?? 1600)
        let portions = inputs.enumerated().map { index, _ in Self.portion(index, recipe: recipe) }
        let heights = zip(inputs, portions).map { input, portion in
            Double(input.height) / Double(input.width) * Double(baseWidth) * (portion.upperBound - portion.lowerBound)
        }
        let total = heights.reduce(0, +)
        guard total.isFinite, total > 0 else { throw LongScreenshotError.encoding }
        let scale = min(1, sqrt(Double(Self.pixelBudget) / (Double(baseWidth) * total)), 32760 / total)
        let width = max(1, Int(Double(baseWidth) * scale))
        let rows = heights.map { max(1, Int($0 * Double(width) / Double(baseWidth))) }
        let height = rows.reduce(0, +)
        guard width * height <= Self.pixelBudget, height <= 32768,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw LongScreenshotError.encoding }
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        var offset = 0
        for (index, input) in inputs.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                // ImageIO transforms EXIF orientation before cropping.
                let maxPixel = max(width, Int(ceil(Double(input.height) / Double(input.width) * Double(width))))
                let image = try Self.decode(input.url, maxPixel: maxPixel)
                let portion = portions[index]
                let top = min(image.height - 1, Int(Double(image.height) * portion.lowerBound))
                let bottom = min(image.height, max(top + 1, Int(Double(image.height) * portion.upperBound)))
                guard let strip = image.cropping(to: CGRect(x: 0, y: top, width: image.width, height: bottom - top)) else { throw LongScreenshotError.encoding }
                context.draw(strip, in: CGRect(x: 0, y: height - offset - rows[index], width: width, height: rows[index]))
            }
            offset += rows[index]
        }
        try Task.checkCancellation()
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        do {
            guard let image = context.makeImage(),
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw LongScreenshotError.encoding }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw LongScreenshotError.encoding }
            try Task.checkCancellation()
            return .init(url: url, width: width, height: height, reduced: width < (inputs.map(\.width).min() ?? width))
        } catch { try? FileManager.default.removeItem(at: url); throw error }
    }

    func fullPreview(_ output: LongScreenshotOutput) throws -> UIImage {
        try Task.checkCancellation()
        return UIImage(cgImage: try Self.decode(output.url, maxPixel: max(output.width, output.height)))
    }

    func preview(_ output: LongScreenshotOutput) throws -> UIImage {
        try Task.checkCancellation()
        return UIImage(cgImage: try Self.decode(output.url, maxPixel: 1600))
    }

    private static func portion(_ index: Int, recipe: LongScreenshotRecipe) -> ClosedRange<Double> {
        let top = min(0.25, max(0, recipe.header)), bottom = 1 - min(0.25, max(0, recipe.footer))
        let overlap = index > 0 && recipe.overlaps.indices.contains(index) ? min(0.95, max(0, recipe.overlaps[index])) : 0
        return (top + (bottom - top) * overlap)...bottom
    }

    private static func decode(_ url: URL, maxPixel: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, min(32768, maxPixel)),
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw LongScreenshotError.unreadable }
        return image
    }

    private struct Sample { let pixels: [UInt8]; let height: Int }
    private static func sample(_ input: LongScreenshotInput, recipe: LongScreenshotRecipe) throws -> Sample {
        // Fixed width keeps matching cheap; cap height for unusual panoramas.
        let image = try decode(input.url, maxPixel: min(1600, max(80, 80 * input.height / input.width)))
        let portion = portion(0, recipe: recipe)
        let top = Int(Double(image.height) * portion.lowerBound)
        let bottom = max(top + 1, Int(Double(image.height) * portion.upperBound))
        guard let cropped = image.cropping(to: CGRect(x: 0, y: top, width: image.width, height: bottom - top)) else { throw LongScreenshotError.unreadable }
        let height = min(1600, max(1, Int(Double(cropped.height) / Double(cropped.width) * 80)))
        var pixels = [UInt8](repeating: 0, count: height * 80)
        let success = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 80, height: height, bitsPerComponent: 8,
                                          bytesPerRow: 80, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 80, height: height))
            return true
        }
        guard success else { throw LongScreenshotError.encoding }
        return .init(pixels: pixels, height: height)
    }

    private static func overlap(_ a: Sample, _ b: Sample) throws -> Double {
        let limit = min(a.height, b.height) * 3 / 4
        guard limit >= 12 else { return 0 }
        var candidates: [(rows: Int, error: Double)] = []
        for count in 12...limit {
            if count % 32 == 0 { try Task.checkCancellation() }
            var difference = 0.0, texture = 0.0, samples = 0
            let step = max(1, count / 30)
            for row in stride(from: 0, to: count, by: step) {
                for column in stride(from: 8, to: 72, by: 2) {
                    let lhs = Int(a.pixels[(a.height - count + row) * 80 + column])
                    let rhs = Int(b.pixels[row * 80 + column])
                    difference += Double(abs(lhs - rhs))
                    texture += Double(abs(rhs - Int(b.pixels[row * 80 + column - 2])))
                    samples += 1
                }
            }
            let error = difference / Double(samples)
            // Plain backgrounds/repeating chrome must never erase content.
            if texture / Double(samples) > 8 { candidates.append((count, error)) }
        }
        guard let best = candidates.min(by: { $0.error < $1.error }), best.error < 18 else { return 0 }
        let alternative = candidates.filter { abs($0.rows - best.rows) > 3 }.map(\.error).min() ?? 255
        // Resampling/colour management can vary even for identical pixels.
        // A match must be distinctly better than other possible seams.
        guard best.error + 2 < alternative, best.error < alternative * 0.55 else { return 0 }
        return Double(best.rows) / Double(b.height)
    }
}

#if DEBUG
extension LongScreenshotEngine {
    static func fixtureData() throws -> [Data] {
        let width = 160, height = 560
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let value = UInt8(20 + ((row / 4 * 733 + column / 4 * 397) ^ (row / 4 * 197 + column / 4 * 977)) % 215)
                let offset = (row * width + column) * 4
                pixels[offset] = value; pixels[offset + 1] = value; pixels[offset + 2] = value
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw LongScreenshotError.encoding }
        return try [0, 200].map { top in
            guard let part = image.cropping(to: CGRect(x: 0, y: top, width: width, height: 320)) else { throw LongScreenshotError.encoding }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw LongScreenshotError.encoding }
            CGImageDestinationAddImage(destination, part, nil)
            guard CGImageDestinationFinalize(destination) else { throw LongScreenshotError.encoding }
            return data as Data
        }
    }

    func runProbe() async throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var checks = 0, failures: [String] = []
        func check(_ condition: Bool, _ name: String) { checks += 1; if !condition { failures.append(name) } }
        let data = try Self.fixtureData()
        let inputs = try data.map { try importImage($0, directory: directory) }
        let overlaps = try detectOverlaps(inputs, recipe: .init())
        let a = try Self.sample(inputs[0], recipe: .init()), b = try Self.sample(inputs[1], recipe: .init())
        let count = 60
        var score = 0, reverse = 0, texture = 0
        for row in 0..<count {
            for col in 8..<72 {
                score += abs(Int(a.pixels[(a.height - count + row) * 80 + col]) - Int(b.pixels[row * 80 + col]))
                reverse += abs(Int(a.pixels[row * 80 + col]) - Int(b.pixels[(b.height - count + row) * 80 + col]))
                texture += abs(Int(b.pixels[row * 80 + col]) - Int(b.pixels[row * 80 + col - 2]))
            }
        }
        PagerDiagnostics.log("longshot_probe overlap=\(overlaps) sample=\(a.height),\(b.height) error=\(score / (count * 64)) reverse=\(reverse / (count * 64)) texture=\(texture / (count * 64))")
        check(abs(overlaps[1] - 0.375) < 0.01, "scroll overlap: \(overlaps)")
        let stitched = try render(inputs, recipe: .init(overlaps: overlaps), directory: directory)
        check(stitched.width == 160 && abs(stitched.height - 520) <= 2, "stitched dimensions")
        let direct = try render(inputs, recipe: .init(), directory: directory)
        check(direct.height == 640, "no overlap retains content")
        let manual = try render(inputs, recipe: .init(header: 0.1, footer: 0.1, overlaps: [0, 0.5]), directory: directory)
        check(manual.height == 384, "manual seams and chrome crop")
        let large = LongScreenshotInput(id: UUID(), url: inputs[0].url, width: 4000, height: 8000)
        let repeated = Array(repeating: large, count: 12)
        let bounded = try render(repeated, recipe: .init(), directory: directory)
        check(bounded.width * bounded.height <= Self.pixelBudget && bounded.height <= 32768, "pixel budget")
        let source = CGImageSourceCreateWithURL(stitched.url as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        check(props?[kCGImagePropertyPixelHeight] as? Int == stitched.height, "PNG on disk")
        // Different portions of a patterned fixture cannot be auto-cropped.
        let unrelated = Sample(pixels: [UInt8](repeating: 255, count: 80 * 160), height: 160)
        check(try Self.overlap(unrelated, unrelated) == 0, "blank regions retained")
        let repeatedPattern = Sample(pixels: (0..<(80 * 160)).map { $0 % 4 < 2 ? 0 : 255 }, height: 160)
        check(try Self.overlap(repeatedPattern, repeatedPattern) == 0, "ambiguous repeating content retained")
        let transfer = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data[0].write(to: transfer)
        let imported = try importFile(transfer, directory: directory)
        check(!FileManager.default.fileExists(atPath: transfer.path) && imported.width == 160, "file transfer ownership")
        removeFiles([imported.url])
        check(!FileManager.default.fileExists(atPath: imported.url.path), "file cleanup")
        let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let sourceBytes = sourceImage.dataProvider!.data! as Data
        check(sourceBytes.first == 20, "top orientation")
        let cancelled = Task { () throws -> Void in
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try self.render(inputs, recipe: .init(), directory: directory)
        }
        do { try await cancelled.value; check(false, "cancellation") }
        catch { check(error is CancellationError, "cancellation") }
        return "checks=\(checks) failures=\(failures.count) \(failures.joined(separator: ","))"
    }
}
#endif
