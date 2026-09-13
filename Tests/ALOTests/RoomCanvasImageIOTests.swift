import Foundation
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import Testing
import ALOCore
@testable import ALO

struct RoomCanvasImageIOTests {
    @Test func preparationAppliesOrientationAndDoesNotCopyPrivateMetadata() async throws {
        let image = try makeImage(width: 32, height: 16)
        let source = try encode(image, type: .jpeg, properties: [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.34, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFImageDescription: "private source metadata"]
        ] as CFDictionary)
        let io = RoomCanvasImageIO()
        let prepared = try await io.prepare(bytes: source, name: "Photo.jpeg")
        #expect(prepared.descriptor.name == "Photo.png")
        #expect(prepared.descriptor.pixelWidth == 16 && prepared.descriptor.pixelHeight == 32)
        #expect(prepared.descriptor.isValid)
        let decoded = try await io.decode(prepared)
        #expect(decoded.width == 16 && decoded.height == 32 && decoded.bitsPerComponent == 8)
        let png = try #require(CGImageSourceCreateWithData(prepared.bytes as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(png, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(properties[kCGImagePropertyTIFFDictionary] == nil)
        #expect((properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
    }

    @Test func filePreparationBoundsResolutionAndLeavesTheOriginalUntouched() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("alo-canvas-image-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Wide.png")
        let original = try encode(makeImage(width: 4_000, height: 1_000), type: .png)
        try original.write(to: file)
        let io = RoomCanvasImageIO()
        let prepared = try await io.prepare(fileURL: file)
        #expect(prepared.descriptor.pixelWidth == 2_048)
        #expect(prepared.descriptor.pixelHeight == 512)
        #expect(prepared.bytes.count <= RoomCanvasImage.maximumBytes)
        #expect(try Data(contentsOf: file) == original)
        _ = try await io.decode(prepared)
        await #expect(throws: RoomCanvasImageError.invalidImage) { try await io.prepare(fileURL: directory) }
    }

    @Test func receiverRequiresPNGExactDimensionsAndCompletePixelsNotJustTheHash() async throws {
        let io = RoomCanvasImageIO()
        let prepared = try await io.prepare(bytes: encode(makeImage(width: 32, height: 16), type: .png), name: "Sketch.png")
        let d = prepared.descriptor
        let wrongSize = PreparedRoomCanvasImage(descriptor: .init(name: d.name, byteCount: d.byteCount,
            sha256: d.sha256, pixelWidth: d.pixelWidth + 1, pixelHeight: d.pixelHeight), bytes: prepared.bytes)
        await #expect(throws: RoomCanvasImageError.invalidReceivedImage) { try await io.decode(wrongSize) }
        let jpeg = try encode(makeImage(width: 32, height: 16), type: .jpeg)
        let wrongFormat = PreparedRoomCanvasImage(descriptor: descriptor(jpeg), bytes: jpeg)
        await #expect(throws: RoomCanvasImageError.invalidReceivedImage) { try await io.decode(wrongFormat) }
        let truncated = Data(prepared.bytes.prefix(40))
        let incomplete = PreparedRoomCanvasImage(descriptor: descriptor(truncated), bytes: truncated)
        await #expect(throws: RoomCanvasImageError.invalidReceivedImage) { try await io.decode(incomplete) }
        let changed = PreparedRoomCanvasImage(descriptor: d, bytes: Data(repeating: 0, count: prepared.bytes.count))
        await #expect(throws: RoomCanvasImageError.invalidReceivedImage) { try await io.decode(changed) }
    }

    @Test func inputBoundsAndAnimationAreExplicitAndSharedNamesRemainValid() async throws {
        let io = RoomCanvasImageIO()
        await #expect(throws: RoomCanvasImageError.invalidImage) { try await io.prepare(bytes: Data(), name: "Empty") }
        await #expect(throws: RoomCanvasImageError.sourceTooLarge) {
            try await io.prepare(bytes: Data(repeating: 0, count: RoomCanvasImageIO.maximumSourceBytes + 1), name: "Too big")
        }
        let tooWide = try encode(makeImage(width: 16_001, height: 1), type: .png)
        await #expect(throws: RoomCanvasImageError.sourceTooLarge) { try await io.prepare(bytes: tooWide, name: "Wide") }
        let image = try makeImage(width: 32, height: 16)
        let animated = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(animated, UTType.gif.identifier as CFString, 2, nil))
        CGImageDestinationAddImage(destination, image, nil); CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        await #expect(throws: RoomCanvasImageError.invalidImage) { try await io.prepare(bytes: animated as Data, name: "Animated.gif") }
        let png = try encode(image, type: .png)
        for name in [String(repeating: "💬", count: 80) + ".png", "invalid/name.png", "a\nb.png"] {
            let prepared = try await io.prepare(bytes: png, name: name)
            #expect(prepared.descriptor.isValid)
            #expect(prepared.descriptor.pixelWidth == 32, "Small images must not be enlarged")
        }
    }

    private func descriptor(_ bytes: Data) -> RoomCanvasImage {
        .init(name: "Test.png", byteCount: bytes.count, sha256: Data(SHA256.hash(data: bytes)), pixelWidth: 32, pixelHeight: 16)
    }
    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
    private func encode(_ image: CGImage, type: UTType, properties: CFDictionary? = nil) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
