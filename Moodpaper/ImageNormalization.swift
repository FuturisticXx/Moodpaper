import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Decode an image from `sourceURL` and write a normalized sRGB JPEG to `destinationURL`.
/// Used by both MoodStore (Mood slot imports) and UserWallpaperManager
/// (global pool imports). Centralized here to avoid duplication.
///
/// Compression quality is 0.92: visually lossless for photographs, keeps file
/// sizes reasonable under the 750 MB user-imported cap.
nonisolated func writeNormalizedImage(from sourceURL: URL, to destinationURL: URL) throws {
    guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
        throw NSError(domain: "HorizonImageNormalization", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "Image could not be decoded"
        ])
    }

    guard let destination = CGImageDestinationCreateWithURL(
        destinationURL as CFURL,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ) else {
        throw NSError(domain: "HorizonImageNormalization", code: -2, userInfo: [
            NSLocalizedDescriptionKey: "Image destination could not be created"
        ])
    }

    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
    guard let context = CGContext(
        data: nil,
        width: cgImage.width,
        height: cgImage.height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        throw NSError(domain: "HorizonImageNormalization", code: -3, userInfo: [
            NSLocalizedDescriptionKey: "Image normalization context could not be created"
        ])
    }

    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
    guard let normalizedImage = context.makeImage() else {
        throw NSError(domain: "HorizonImageNormalization", code: -4, userInfo: [
            NSLocalizedDescriptionKey: "Image normalization failed"
        ])
    }

    CGImageDestinationAddImage(destination, normalizedImage, [
        kCGImageDestinationLossyCompressionQuality: 0.92
    ] as CFDictionary)

    if !CGImageDestinationFinalize(destination) {
        throw NSError(domain: "HorizonImageNormalization", code: -5, userInfo: [
            NSLocalizedDescriptionKey: "Image write failed"
        ])
    }
}
