import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import WERAI

struct DeviceProfileImageTests {
    @Test("Profile images are center-cropped and bounded to 128 pixels")
    func centerCropAndResize() throws {
        let source = try encodedPNG(width: 384, height: 192, hasAlpha: true) { context in
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 192))
            context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
            context.fill(CGRect(x: 96, y: 0, width: 192, height: 192))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 288, y: 0, width: 96, height: 192))
        }

        let normalized = try DeviceProfileImage.normalizedData(from: source)
        let image = try decodedImage(normalized)
        let color = try averageRGBA(image)

        #expect(image.width == DeviceProfileImage.maximumPixelDimension)
        #expect(image.height == DeviceProfileImage.maximumPixelDimension)
        #expect(color.green > 220)
        #expect(color.red < 35)
        #expect(color.blue < 35)
    }

    @Test("Transparent profile images remain PNG and fit the mesh budget")
    func transparentPNG() throws {
        let source = try encodedPNG(width: 256, height: 192, hasAlpha: true) { context in
            context.clear(CGRect(x: 0, y: 0, width: 256, height: 192))
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 1, alpha: 0.5))
            context.fillEllipse(in: CGRect(x: 48, y: 16, width: 160, height: 160))
        }

        let normalized = try DeviceProfileImage.normalizedData(from: source)
        let imageSource = try #require(CGImageSourceCreateWithData(normalized as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))

        #expect(CGImageSourceGetType(imageSource) as String? == UTType.png.identifier)
        #expect(image.width <= DeviceProfileImage.maximumPixelDimension)
        #expect(image.height <= DeviceProfileImage.maximumPixelDimension)
        #expect(normalized.count <= DeviceProfileImage.maximumEncodedBytes)
    }

    @Test("High-entropy profile images are compressed below the mesh budget")
    func encodedByteLimit() throws {
        let source = try noisyPNG(width: 384, height: 256)

        let normalized = try DeviceProfileImage.normalizedData(from: source)
        let imageSource = try #require(CGImageSourceCreateWithData(normalized as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))

        #expect(CGImageSourceGetType(imageSource) as String? == UTType.jpeg.identifier)
        #expect(image.width <= DeviceProfileImage.maximumPixelDimension)
        #expect(image.height <= DeviceProfileImage.maximumPixelDimension)
        #expect(normalized.count <= DeviceProfileImage.maximumEncodedBytes)
    }

    @Test("Invalid image data is rejected")
    func invalidData() {
        #expect(throws: DeviceProfileImageError.self) {
            try DeviceProfileImage.normalizedData(from: Data("not an image".utf8))
        }
    }
}

private func encodedPNG(
    width: Int,
    height: Int,
    hasAlpha: Bool,
    draw: (CGContext) -> Void
) throws -> Data {
    let alphaInfo: CGImageAlphaInfo = hasAlpha ? .premultipliedLast : .noneSkipLast
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: alphaInfo.rawValue
    ))
    draw(context)
    let image = try #require(context.makeImage())
    return try encodePNG(image)
}

private func noisyPNG(width: Int, height: Int) throws -> Data {
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
    var state: UInt64 = 0x1234_5678_9ABC_DEF0
    for offset in stride(from: 0, to: width * height * 4, by: 4) {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        bytes[offset] = UInt8(truncatingIfNeeded: state >> 24)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: state >> 32)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: state >> 40)
        bytes[offset + 3] = 255
    }
    return try encodePNG(#require(context.makeImage()))
}

private func encodePNG(_ image: CGImage) throws -> Data {
    let output = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        output,
        UTType.png.identifier as CFString,
        1,
        nil
    ))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
}

private func decodedImage(_ data: Data) throws -> CGImage {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
}

private func averageRGBA(_ image: CGImage) throws -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
    let context = try #require(CGContext(
        data: nil,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
    return (bytes[0], bytes[1], bytes[2], bytes[3])
}
