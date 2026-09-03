import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum DeviceProfileImageError: LocalizedError {
    case invalidImage
    case cannotRender
    case cannotEncodeWithinLimit

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "The selected file is not a supported image."
        case .cannotRender:
            return "The selected image could not be prepared."
        case .cannotEncodeWithinLimit:
            return "The selected image could not be made small enough to share."
        }
    }
}

enum DeviceProfileImage {
    static let maximumPixelDimension = 128
    static let maximumEncodedBytes = 16 * 1_024

    /// Decodes, applies image orientation, center-crops to a square, and returns
    /// compact profile-image data suitable for inclusion in mesh identity data.
    static func normalizedData(from sourceData: Data) throws -> Data {
        guard !sourceData.isEmpty,
              let source = CGImageSourceCreateWithData(sourceData as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 2_048
                  ] as CFDictionary
              )
        else { throw DeviceProfileImageError.invalidImage }

        let cropSide = min(image.width, image.height)
        guard cropSide > 0,
              let cropped = image.cropping(
                  to: CGRect(
                      x: (image.width - cropSide) / 2,
                      y: (image.height - cropSide) / 2,
                      width: cropSide,
                      height: cropSide
                  )
              )
        else { throw DeviceProfileImageError.cannotRender }

        let largestOutput = min(cropSide, maximumPixelDimension)
        let dimensions = outputDimensions(startingAt: largestOutput)
        if image.hasAlpha {
            for dimension in dimensions {
                guard let rendered = render(cropped, dimension: dimension) else { continue }
                if let data = encode(rendered, as: .png), data.count <= maximumEncodedBytes {
                    return data
                }
            }
        } else {
            let qualities: [CGFloat] = [0.82, 0.70, 0.58, 0.46, 0.34]
            for dimension in dimensions {
                guard let rendered = render(cropped, dimension: dimension) else { continue }
                for quality in qualities {
                    if let data = encode(rendered, as: .jpeg, quality: quality),
                       data.count <= maximumEncodedBytes {
                        return data
                    }
                }
            }
        }
        throw DeviceProfileImageError.cannotEncodeWithinLimit
    }

    private static func outputDimensions(startingAt largest: Int) -> [Int] {
        var dimensions = [largest]
        for candidate in [112, 96, 80, 64, 48, 32] where candidate < largest {
            dimensions.append(candidate)
        }
        return dimensions
    }

    private static func render(_ image: CGImage, dimension: Int) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: dimension,
                  height: dimension,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: dimension, height: dimension))
        return context.makeImage()
    }

    private static func encode(
        _ image: CGImage,
        as type: UTType,
        quality: CGFloat? = nil
    ) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            type.identifier as CFString,
            1,
            nil
        ) else { return nil }
        let properties = quality.map {
            [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary
        }
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

private extension CGImage {
    var hasAlpha: Bool {
        switch alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
            return true
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        @unknown default:
            return true
        }
    }
}
