import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Photos
import UniformTypeIdentifiers

struct PhotoCrop: Codable, Equatable, Sendable {
    var x: Double = 0
    var y: Double = 0
    var width: Double = 1
    var height: Double = 1
    static let full = PhotoCrop()

    var clamped: PhotoCrop {
        let w = min(1, max(0.05, width)), h = min(1, max(0.05, height))
        return PhotoCrop(x: min(1 - w, max(0, x)), y: min(1 - h, max(0, y)), width: w, height: h)
    }
}

enum PhotoAdjustment: String, CaseIterable, Codable, Identifiable, Sendable {
    case exposure, brightness, contrast, saturation, vibrance, temperature
    case shadows, highlights, sharpness, noise, hue, gamma, sepia, bloom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .exposure: "曝光"
        case .brightness: "整体亮度"
        case .contrast: "对比度"
        case .saturation: "整体饱和"
        case .vibrance: "自然饱和"
        case .temperature: "色温"
        case .shadows: "暗部提亮"
        case .highlights: "降低高光"
        case .sharpness: "锐化"
        case .noise: "降噪"
        case .hue: "色调"
        case .gamma: "伽马亮度"
        case .sepia: "复古胶片"
        case .bloom: "柔光"
        }
    }
    var symbol: String {
        switch self {
        case .exposure: "plusminus.circle"
        case .brightness, .gamma: "sun.max"
        case .contrast: "circle.lefthalf.filled"
        case .temperature: "thermometer.medium"
        case .saturation, .vibrance: "drop.halffull"
        case .shadows: "sun.horizon"
        case .highlights: "sun.max.trianglebadge.exclamationmark"
        case .sharpness: "triangle"
        case .noise: "waveform.path"
        case .hue: "paintpalette"
        case .sepia: "film"
        case .bloom: "sparkles"
        }
    }
}

enum PhotoLook: String, CaseIterable, Codable, Identifiable, Sendable {
    case original, chrome, fade, instant, mono, noir, process, tonal, transfer, sepia, vivid, cool, warm
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: "原图"
        case .chrome: "鲜明"
        case .fade: "褪色"
        case .instant: "即影即有"
        case .mono: "黑白"
        case .noir: "黑金"
        case .process: "冲印"
        case .tonal: "灰调"
        case .transfer: "怀旧"
        case .sepia: "复古"
        case .vivid: "艳丽"
        case .cool: "冷色"
        case .warm: "暖色"
        }
    }
    var filterName: String? {
        switch self {
        case .chrome: "CIPhotoEffectChrome"
        case .fade: "CIPhotoEffectFade"
        case .instant: "CIPhotoEffectInstant"
        case .mono: "CIPhotoEffectMono"
        case .noir: "CIPhotoEffectNoir"
        case .process: "CIPhotoEffectProcess"
        case .tonal: "CIPhotoEffectTonal"
        case .transfer: "CIPhotoEffectTransfer"
        case .sepia: "CISepiaTone"
        default: nil
        }
    }
}

struct PhotoEditRecipe: Codable, Equatable, Sendable {
    var quarterTurns = 0
    var mirrored = false
    var angle: Double = 0
    var crop = PhotoCrop.full
    var look = PhotoLook.original
    var adjustments: [String: Double] = [:]
    var automatic = false

    subscript(_ adjustment: PhotoAdjustment) -> Double {
        get { adjustments[adjustment.rawValue] ?? 0 }
        set { adjustments[adjustment.rawValue] = newValue }
    }
}

enum PhotoExportFormat: String, CaseIterable, Identifiable, Sendable {
    case jpeg, heic, png
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var type: UTType {
        switch self { case .jpeg: .jpeg; case .heic: .heic; case .png: .png }
    }
}

struct PhotoExportOptions: Equatable, Sendable {
    var quality: Double = 0.7
    var maxDimension = 0
    var format = PhotoExportFormat.jpeg
    static let resolutions = [0, 854, 1280, 1920, 2560, 3840]
    static func resolutionTitle(_ value: Int) -> String {
        switch value {
        case 854: "480p"
        case 1280: "720p"
        case 1920: "1080p"
        case 2560: "2K"
        case 3840: "4K"
        default: "不变"
        }
    }
}

struct RenderedPhoto: Sendable {
    let data: Data
    let width: Int
    let height: Int
}

struct PhotoCompressionRequest: Equatable, Sendable {
    let recipe: PhotoEditRecipe
    let options: PhotoExportOptions
}

/// Prepared completely before the Photos transaction; the callback only reads it.
private struct PreparedPhotoOutput: @unchecked Sendable { let value: PHContentEditingOutput }

actor PhotoRenderWorker {
    static let shared = PhotoRenderWorker()
    private let context = CIContext(options: [.cacheIntermediates: false])

    /// All geometry is baked in; ImageIO writes orientation=up plus the source
    /// EXIF/GPS dictionaries. The preview and final export share this recipe.
    func render(data: Data, recipe: PhotoEditRecipe, options: PhotoExportOptions, preview: Bool = false) throws -> RenderedPhoto {
        try Task.checkCancellation()
        guard var image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            throw MediaWorkspaceError.unavailable
        }
        if preview {
            image = Self.resized(image, maximumDimension: 1400)
        }
        image = Self.apply(recipe, to: image)
        if options.maxDimension > 0 {
            image = Self.resized(image, maximumDimension: CGFloat(options.maxDimension))
        }
        try Task.checkCancellation()
        // Expand no fractional crop beyond its valid pixels: integral rounds
        // outwards and introduces a transparent (black in JPEG) border.
        let rect = image.extent
        guard let cg = context.createCGImage(image, from: rect) else { throw MediaWorkspaceError.encoding }
        let output = NSMutableData()
        let type = preview ? UTType.jpeg : options.format.type
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            throw MediaWorkspaceError.encoding
        }
        var properties: [CFString: Any] = [:]
        if !preview, let source = CGImageSourceCreateWithData(data as CFData, nil),
           let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            properties = original
        }
        properties[kCGImagePropertyOrientation] = 1
        properties[kCGImagePropertyPixelWidth] = cg.width
        properties[kCGImagePropertyPixelHeight] = cg.height
        properties[kCGImageDestinationLossyCompressionQuality] = preview ? 0.85 : options.quality
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = cg.width
            exif[kCGImagePropertyExifPixelYDimension] = cg.height
            properties[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        CGImageDestinationAddImage(destination, cg, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw MediaWorkspaceError.encoding }
        try Task.checkCancellation()
        return RenderedPhoto(data: output as Data, width: cg.width, height: cg.height)
    }

    nonisolated private static func resized(_ image: CIImage, maximumDimension: CGFloat) -> CIImage {
        let extent = image.extent
        let scale = min(1, maximumDimension / max(extent.width, extent.height))
        let width = max(1, floor(extent.width * scale + 0.000001))
        let height = max(1, floor(extent.height * scale + 0.000001))
        let normalized = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        return normalized.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: width / extent.width, y: height / extent.height))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    nonisolated private static func pixelCrop(_ image: CIImage, to rect: CGRect) -> CIImage {
        // CIImage.cropped(to:) rounds outwards internally, even before render.
        let x = ceil(rect.minX - 0.000001), y = ceil(rect.minY - 0.000001)
        let width = floor(rect.maxX + 0.000001) - x
        let height = floor(rect.maxY + 0.000001) - y
        let aligned = width >= 1 && height >= 1 ? CGRect(x: x, y: y, width: width, height: height) : rect.integral.intersection(image.extent)
        return image.cropped(to: aligned)
    }

    nonisolated static func apply(_ recipe: PhotoEditRecipe, to source: CIImage) -> CIImage {
        var image = source
        if recipe.automatic {
            for filter in image.autoAdjustmentFilters() {
                filter.setValue(image, forKey: kCIInputImageKey)
                image = filter.outputImage ?? image
            }
        }
        let turns = ((recipe.quarterTurns % 4) + 4) % 4
        if turns != 0 { image = image.oriented([.up, .right, .down, .left][turns]) }
        if recipe.mirrored { image = image.oriented(.upMirrored) }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if recipe.angle != 0 {
            let extent = image.extent
            let angle = recipe.angle * .pi / 180
            let rotation = CGAffineTransform(translationX: extent.midX, y: extent.midY)
                .rotated(by: angle).translatedBy(x: -extent.midX, y: -extent.midY)
            image = image.transformed(by: rotation)
            // A conservative inscribed rectangle removes transparent corners.
            let factor = 1 / (abs(cos(angle)) + abs(sin(angle)) * max(extent.width / extent.height, extent.height / extent.width))
            image = pixelCrop(image, to: CGRect(x: extent.midX - extent.width * factor / 2,
                                            y: extent.midY - extent.height * factor / 2,
                                            width: extent.width * factor, height: extent.height * factor))
        }
        let crop = recipe.crop.clamped, extent = image.extent
        image = pixelCrop(image, to: CGRect(x: extent.minX + crop.x * extent.width,
                                        y: extent.minY + (1 - crop.y - crop.height) * extent.height,
                                        width: crop.width * extent.width, height: crop.height * extent.height))
        if let filter = recipe.look.filterName { image = image.applyingFilter(filter) }
        if recipe.look == .vivid { image = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.35, kCIInputContrastKey: 1.1]) }
        let warm: Double = recipe.look == .warm ? 1200 : (recipe.look == .cool ? -1200 : 0)
        image = image.applyingFilter("CIColorControls", parameters: [
            kCIInputBrightnessKey: recipe[.brightness] * 0.35,
            kCIInputContrastKey: 1 + recipe[.contrast] * 0.7,
            kCIInputSaturationKey: 1 + recipe[.saturation]
        ])
        if recipe[.exposure] != 0 { image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: recipe[.exposure] * 3]) }
        if recipe[.vibrance] != 0 { image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": recipe[.vibrance]]) }
        if warm != 0 || recipe[.temperature] != 0 {
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 + warm + recipe[.temperature] * 2500, y: 0)
            ])
        }
        if recipe[.shadows] != 0 || recipe[.highlights] != 0 {
            image = image.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputShadowAmount": recipe[.shadows], "inputHighlightAmount": 1 - max(0, recipe[.highlights])
            ])
        }
        if recipe[.sharpness] > 0 { image = image.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: recipe[.sharpness] * 2]) }
        if recipe[.noise] > 0 { image = image.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": recipe[.noise] * 0.1]) }
        if recipe[.hue] != 0 { image = image.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: recipe[.hue] * .pi]) }
        if recipe[.gamma] != 0 { image = image.applyingFilter("CIGammaAdjust", parameters: ["inputPower": pow(2, -recipe[.gamma])]) }
        if recipe[.sepia] > 0 { image = image.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: recipe[.sepia]]) }
        if recipe[.bloom] > 0 { image = image.clampedToExtent().applyingFilter("CIBloom", parameters: [kCIInputRadiusKey: 6, kCIInputIntensityKey: recipe[.bloom]]).cropped(to: image.extent) }
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }
}

@MainActor
enum PhotoEditSaver {
    static func save(_ rendered: RenderedPhoto, sourceData: Data, asset: PHAsset,
                     recipe: PhotoEditRecipe, options: PhotoExportOptions,
                     replace: Bool, albums: [PhotoAlbum]) async throws -> CompressionRecord {
        try Task.checkCancellation()
        let originalBytes = replace ? Int64((try await WorkspacePhotoAccess.imageData(asset, original: true)).count) : Int64(sourceData.count)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(options.format.rawValue)
        try rendered.data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        let resultID: String
        if replace && !asset.mediaSubtypes.contains(.photoLive) {
            let input = try await WorkspacePhotoAccess.editingInput(asset)
            let output = PHContentEditingOutput(contentEditingInput: input)
            let type: UTType = options.format == .heic ? .heic : .jpeg
            let destination = try output.renderedContentURL(for: type)
            let bytes: Data
            if options.format == .png {
                var compatible = options; compatible.format = .jpeg; compatible.quality = 1
                bytes = try await PhotoRenderWorker.shared.render(data: sourceData, recipe: recipe, options: compatible).data
            } else { bytes = rendered.data }
            try bytes.write(to: destination)
            output.adjustmentData = PHAdjustmentData(formatIdentifier: "com.misswell.PhotoVault.edit", formatVersion: "1", data: try JSONEncoder().encode(recipe))
            let prepared = PreparedPhotoOutput(value: output)
            try await PHPhotoLibrary.shared().performChanges { @Sendable in
                PHAssetChangeRequest(for: asset).contentEditingOutput = prepared.value
            }
            resultID = asset.localIdentifier
        } else {
            // A Live Photo is saved through PHLivePhotoEditingContext so its
            // image/video pairing and frame geometry remain valid.
            if asset.mediaSubtypes.contains(.photoLive) {
                let input = try await WorkspacePhotoAccess.editingInput(asset)
                guard let context = PHLivePhotoEditingContext(livePhotoEditingInput: input) else { throw MediaWorkspaceError.unsupported }
                let output = PHContentEditingOutput(contentEditingInput: input)
                context.frameProcessor = { @Sendable frame, _ in PhotoRenderWorker.apply(recipe, to: frame.image) }
                output.adjustmentData = PHAdjustmentData(formatIdentifier: "com.misswell.PhotoVault.edit", formatVersion: "1", data: try JSONEncoder().encode(recipe))
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    context.saveLivePhoto(to: output, options: nil) { @Sendable success, error in
                        if success { continuation.resume() }
                        else { continuation.resume(throwing: error ?? MediaWorkspaceError.encoding) }
                    }
                }
                // Live Photo edits are reversible in place and retain motion.
                let prepared = PreparedPhotoOutput(value: output)
                try await PHPhotoLibrary.shared().performChanges { @Sendable in
                    PHAssetChangeRequest(for: asset).contentEditingOutput = prepared.value
                }
                resultID = asset.localIdentifier
            } else {
                let box = CreatedAssetID()
                try await PHPhotoLibrary.shared().performChanges { @Sendable in
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, fileURL: url, options: nil)
                    request.creationDate = asset.creationDate
                    request.location = asset.location
                    request.isFavorite = asset.isFavorite
                    if let placeholder = request.placeholderForCreatedAsset {
                        box.set(placeholder.localIdentifier)
                        for album in albums where album.kind == .user {
                            PHAssetCollectionChangeRequest(for: album.collection)?.addAssets([placeholder] as NSArray)
                        }
                    }
                }
                guard let id = box.get() else { throw MediaWorkspaceError.encoding }
                resultID = id
            }
        }
        let record = CompressionRecord(date: .now, originalID: asset.localIdentifier, resultID: resultID,
                                       originalBytes: originalBytes, resultBytes: Int64(rendered.data.count),
                                       replaced: replace || resultID == asset.localIdentifier)
        PhotoWorkspaceStore.shared.recordCompression(record)
        return record
    }
}

/// PhotoKit invokes its mutation block off the main actor.
final class CreatedAssetID: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ id: String) { lock.lock(); defer { lock.unlock() }; value = id }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
}
