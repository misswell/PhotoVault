#if DEBUG
import CoreImage
import ImageIO
import Photos
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class PhotoEditProbe: ObservableObject {
    static let shared = PhotoEditProbe()
    @Published var result = "pending"
    private var ran = false
    func runIfRequested() async {
        guard !ran, ProcessInfo.processInfo.arguments.contains("--pv-edit-probe") else { return }
        ran = true
        var checks = 0, failures: [String] = []
        func check(_ condition: Bool, _ label: String) { checks += 1; if !condition { failures.append(label) } }
        do {
            let context = CIContext()
            let image = CIImage(color: CIColor(red: 0.8, green: 0.2, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 120, height: 80))
            let cg = context.createCGImage(image, from: image.extent)!
            let input = NSMutableData()
            let destination = CGImageDestinationCreateWithData(input, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, cg, [
                kCGImagePropertyOrientation: 1,
                kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2020:02:29 12:30:00"],
                kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 31.2, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 121.5, kCGImagePropertyGPSLongitudeRef: "E"]
            ] as CFDictionary)
            check(CGImageDestinationFinalize(destination), "fixture")
            let data = input as Data
            var options = PhotoExportOptions(); options.quality = 0.8
            let base = try await PhotoRenderWorker.shared.render(data: data, recipe: .init(), options: options)
            check(base.width == 120 && base.height == 80, "original geometry")
            var recipe = PhotoEditRecipe(); recipe.quarterTurns = 1
            let rotated = try await PhotoRenderWorker.shared.render(data: data, recipe: recipe, options: options)
            check(rotated.width == 80 && rotated.height == 120, "rotation geometry")
            recipe.quarterTurns = -1
            let left = try await PhotoRenderWorker.shared.render(data: data, recipe: recipe, options: options)
            check(left.width == 80 && left.height == 120, "negative rotation")
            recipe = .init(); recipe.crop = PhotoCrop(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
            let cropped = try await PhotoRenderWorker.shared.render(data: data, recipe: recipe, options: options)
            check(cropped.width == 60 && cropped.height == 40, "crop geometry")
            recipe = .init(); recipe.angle = 15
            let straightened = try await PhotoRenderWorker.shared.render(data: data, recipe: recipe, options: options)
            check(straightened.width > 50 && straightened.height > 30, "straighten geometry")
            if let source = CGImageSourceCreateWithData(straightened.data as CFData, nil), let result = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                var pixel = [UInt8](repeating: 0, count: 4)
                pixel.withUnsafeMutableBytes { bytes in
                    CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.draw(result, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                }
                check(pixel[0] > 100, "straighten retains pixels")
            }
            options.maxDimension = 60
            let resized = try await PhotoRenderWorker.shared.render(data: data, recipe: .init(), options: options)
            check(resized.width == 60 && resized.height == 40, "resize")
            options.maxDimension = 1000
            let neverUpscaled = try await PhotoRenderWorker.shared.render(data: data, recipe: .init(), options: options)
            check(neverUpscaled.width == 120, "no upscale")
            for look in PhotoLook.allCases {
                recipe = .init(); recipe.look = look
                let value = try await PhotoRenderWorker.shared.render(data: data, recipe: recipe, options: options)
                check(!value.data.isEmpty && value.width == 120, "look \(look.rawValue)")
            }
            for adjustment in PhotoAdjustment.allCases {
                recipe = .init(); recipe[adjustment] = 0.5
                let value = try await PhotoRenderWorker.shared.render(data: data, recipe: recipe, options: options)
                check(!value.data.isEmpty, "adjustment \(adjustment.rawValue)")
            }
            for format in PhotoExportFormat.allCases {
                options.format = format
                let value = try await PhotoRenderWorker.shared.render(data: data, recipe: .init(), options: options)
                let source = CGImageSourceCreateWithData(value.data as CFData, nil)!
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
                check((properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1, "orientation \(format.rawValue)")
                check((properties[kCGImagePropertyGPSDictionary] as? [CFString: Any])?[kCGImagePropertyGPSLatitude] != nil, "GPS \(format.rawValue)")
                check((properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] != nil, "date \(format.rawValue)")
            }
            let invalid = PhotoCrop(x: 2, y: -2, width: 2, height: -1).clamped
            check(invalid.x + invalid.width <= 1 && invalid.y >= 0 && invalid.height >= 0.05, "crop clamp")
            let encoded = try JSONEncoder().encode(recipe)
            check(try JSONDecoder().decode(PhotoEditRecipe.self, from: encoded) == recipe, "recipe round trip")
            do { _ = try await PhotoRenderWorker.shared.render(data: Data(), recipe: .init(), options: options); check(false, "invalid data") }
            catch { check(true, "invalid data") }
            let calendar = Calendar(identifier: .gregorian)
            let birthday = PhotoAnniversary(name: "Leap", date: calendar.date(from: DateComponents(year: 2000, month: 2, day: 29))!, isBirthday: true)
            check(birthday.daysUntilNext(from: calendar.date(from: DateComponents(year: 2026, month: 2, day: 27))!, calendar: calendar) == 1, "leap anniversary")
        } catch { failures.append(error.localizedDescription) }
        result = "checks=\(checks) failures=\(failures.count)"
        PagerDiagnostics.log("photo_edit_probe \(result) \(failures.joined(separator: ", "))")
    }
}
#endif
