import Foundation
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import ALOCore

struct PreparedRoomCanvasImage: Sendable {
    let descriptor: RoomCanvasImage
    let bytes: Data
}

enum RoomCanvasImageError: LocalizedError, Equatable {
    case invalidImage, sourceTooLarge, cannotPrepare, invalidReceivedImage
    var errorDescription: String? {
        switch self {
        case .invalidImage: return "Choose a single still image for the canvas."
        case .sourceTooLarge: return "Choose an image under 64 MB, 40 megapixels, and 16,000 pixels per side."
        case .cannotPrepare: return "This image could not be prepared for the canvas."
        case .invalidReceivedImage: return "The shared image could not be verified. Reconnect to request a fresh copy."
        }
    }
}

/// File reads, image decoding and encoding stay off the UI and audio executors.
/// Shared copies are oriented, sRGB, 8-bit PNGs without copied source metadata;
/// the selected original is never edited or removed.
actor RoomCanvasImageIO {
    static let maximumSourceBytes = 64 * 1_024 * 1_024

    func prepare(fileURL: URL) throws -> PreparedRoomCanvasImage {
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw RoomCanvasImageError.invalidImage }
        guard let size = values.fileSize, size <= Self.maximumSourceBytes else { throw RoomCanvasImageError.sourceTooLarge }
        let file = try FileHandle(forReadingFrom: fileURL)
        defer { try? file.close() }
        // Bound the read itself, not just a file-size check that can go stale.
        let bytes = try file.read(upToCount: Self.maximumSourceBytes + 1) ?? Data()
        return try prepare(bytes: bytes, name: fileURL.lastPathComponent)
    }

    func prepare(bytes: Data, name: String) throws -> PreparedRoomCanvasImage {
        guard bytes.count <= Self.maximumSourceBytes else { throw RoomCanvasImageError.sourceTooLarge }
        guard !bytes.isEmpty,
              let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1 else { throw RoomCanvasImageError.invalidImage }
        guard Self.boundedDimensions(source) != nil else { throw RoomCanvasImageError.sourceTooLarge }
        // Most images fit at 2048. The second bound guarantees a compact copy
        // even for an incompressible image, without introducing lossy artifacts.
        for limit in [2_048, 1_024] {
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: limit,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary), let image = Self.sRGBImage(thumbnail), let png = Self.png(image) else {
                throw RoomCanvasImageError.cannotPrepare
            }
            guard png.count <= RoomCanvasImage.maximumBytes else { continue }
            let descriptor = RoomCanvasImage(name: Self.sharedName(name), byteCount: png.count,
                sha256: Data(SHA256.hash(data: png)), pixelWidth: image.width, pixelHeight: image.height)
            guard descriptor.isValid else { throw RoomCanvasImageError.cannotPrepare }
            return PreparedRoomCanvasImage(descriptor: descriptor, bytes: png)
        }
        throw RoomCanvasImageError.cannotPrepare
    }

    /// Metadata is checked before decoding pixels. A matching checksum alone
    /// does not establish image type, dimensions, frame count or valid pixels.
    func decode(_ prepared: PreparedRoomCanvasImage) throws -> CGImage {
        let descriptor = prepared.descriptor, bytes = prepared.bytes
        guard descriptor.isValid, bytes.count == descriptor.byteCount,
              Data(SHA256.hash(data: bytes)) == descriptor.sha256,
              let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) == UTType.png.identifier as CFString,
              CGImageSourceGetCount(source) == 1,
              let (width, height) = Self.boundedDimensions(source),
              width == descriptor.pixelWidth, height == descriptor.pixelHeight,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == width, image.height == height,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw RoomCanvasImageError.invalidReceivedImage
        }
        return image
    }

    private static func boundedDimensions(_ source: CGImageSource) -> (Int, Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...16_000).contains(width), (1...16_000).contains(height),
              Int64(width) * Int64(height) <= 40_000_000 else { return nil }
        return (width, height)
    }

    private static func sRGBImage(_ image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    private static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func sharedName(_ original: String) -> String {
        var stem = (original as NSString).deletingPathExtension
        while stem.utf8.count > 236 { stem.removeLast() }
        let proposed = stem + ".png"
        return RoomCanvasAdvertisement(canvasID: UUID(), imageName: proposed).isValid ? proposed : "Shared image.png"
    }
}
