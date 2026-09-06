#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: remove-app-icon-canvas.swift <input.png> <output.png>")
}

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      image.width == 1_024, image.height == 1_024 else {
    fatalError("Expected a readable 1024×1024 PNG")
}

let width = image.width
let height = image.height
let bytesPerRow = width * 4
var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
let rendered = pixels.withUnsafeMutableBytes { storage -> Bool in
    guard let context = CGContext(
        data: storage.baseAddress,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return false }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return true
}
guard rendered else { fatalError("Could not render input") }

// Generated icon masters contain an opaque near-white canvas. Remove only the
// canvas connected to an image edge, so pale artwork enclosed by the icon edge
// remains unchanged. Older outputs from this script used a binary alpha edge;
// retain that cutout when it is supplied as input and repair its matte below.
func isCanvas(_ index: Int) -> Bool {
    let red = pixels[index]
    let green = pixels[index + 1]
    let blue = pixels[index + 2]
    let low = min(red, min(green, blue))
    let high = max(red, max(green, blue))
    return low >= 238 && high - low <= 18
}

let alreadyHasCutout = stride(from: 3, to: pixels.count, by: 4).contains {
    pixels[$0] == 0
}
let alreadyHasFeatheredCutout = stride(from: 3, to: pixels.count, by: 4).contains {
    pixels[$0] > 0 && pixels[$0] < 255
}
if !alreadyHasCutout {
    var visited = [Bool](repeating: false, count: width * height)
    var queue = [Int]()
    queue.reserveCapacity(width * height / 2)
    func enqueue(_ x: Int, _ y: Int) {
        let pixel = y * width + x
        guard !visited[pixel], isCanvas(pixel * 4) else { return }
        visited[pixel] = true
        queue.append(pixel)
    }
    for x in 0..<width { enqueue(x, 0); enqueue(x, height - 1) }
    for y in 0..<height { enqueue(0, y); enqueue(width - 1, y) }

    var cursor = 0
    while cursor < queue.count {
        let pixel = queue[cursor]
        cursor += 1
        let x = pixel % width
        let y = pixel / width
        if x > 0 { enqueue(x - 1, y) }
        if x + 1 < width { enqueue(x + 1, y) }
        if y > 0 { enqueue(x, y - 1) }
        if y + 1 < height { enqueue(x, y + 1) }
    }

    for pixel in queue {
        let index = pixel * 4
        pixels[index] = 0
        pixels[index + 1] = 0
        pixels[index + 2] = 0
        pixels[index + 3] = 0
    }
}

// A hard 0/255 cutout preserves a light canvas fringe and makes the rounded
// edge look chipped when AppKit scales it down. Build a narrow, deterministic
// inward antialiasing band and remove the old white matte from that band. The
// icon interior remains byte-identical and transparent pixels never expand,
// so neighboring artwork cannot bleed into the result.
if !alreadyHasFeatheredCutout {
    let pixelCount = width * height
    let infinity = Int.max / 8
    var distance = [Int](repeating: infinity, count: pixelCount)
    for pixel in 0..<pixelCount where pixels[pixel * 4 + 3] == 0 {
        distance[pixel] = 0
    }

    for y in 0..<height {
        for x in 0..<width {
            let pixel = y * width + x
            guard distance[pixel] != 0 else { continue }
            var nearest = distance[pixel]
            if x > 0 { nearest = min(nearest, distance[pixel - 1] + 3) }
            if y > 0 { nearest = min(nearest, distance[pixel - width] + 3) }
            if x > 0, y > 0 { nearest = min(nearest, distance[pixel - width - 1] + 4) }
            if x + 1 < width, y > 0 { nearest = min(nearest, distance[pixel - width + 1] + 4) }
            distance[pixel] = nearest
        }
    }
    for y in stride(from: height - 1, through: 0, by: -1) {
        for x in stride(from: width - 1, through: 0, by: -1) {
            let pixel = y * width + x
            guard distance[pixel] != 0 else { continue }
            var nearest = distance[pixel]
            if x + 1 < width { nearest = min(nearest, distance[pixel + 1] + 3) }
            if y + 1 < height { nearest = min(nearest, distance[pixel + width] + 3) }
            if x + 1 < width, y + 1 < height { nearest = min(nearest, distance[pixel + width + 1] + 4) }
            if x > 0, y + 1 < height { nearest = min(nearest, distance[pixel + width - 1] + 4) }
            distance[pixel] = nearest
        }
    }

    func smoothstep(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }

    for pixel in 0..<pixelCount {
        let index = pixel * 4
        guard pixels[index + 3] != 0 else { continue }
        let inset = Double(distance[pixel]) / 3
        guard inset < 15 else { continue }

        let red = Int(pixels[index])
        let green = Int(pixels[index + 1])
        let blue = Int(pixels[index + 2])
        let whiteDistance = Double(max(255 - red, max(255 - green, 255 - blue)))
        let geometricCoverage = smoothstep((inset - 0.2) / 8)
        let matteCoverage = min(1, max(0, (whiteDistance - 1) / 64))
        let interiorWeight = smoothstep((inset - 2) / 12)
        let matteLimit = matteCoverage + (1 - matteCoverage) * interiorWeight
        let alpha = UInt8((255 * min(geometricCoverage, matteLimit)).rounded())

        // CGContext stores premultiplied RGBA. Subtract the former white canvas
        // contribution directly to prevent a pale outline on dark backgrounds.
        let removedCanvas = 255 - Int(alpha)
        pixels[index] = UInt8(max(0, red - removedCanvas))
        pixels[index + 1] = UInt8(max(0, green - removedCanvas))
        pixels[index + 2] = UInt8(max(0, blue - removedCanvas))
        pixels[index + 3] = alpha
    }
}

// Generated masters also include a large neutral drop shadow outside the icon's
// rounded front face. macOS already supplies the presentation shadow, and the
// baked one turns into a gray/white "skirt" in Finder, notifications, and the
// icon picker. Each variant was rendered at a slightly different scale, so
// infer its face edges instead of applying one crop to every image.
struct EdgeSample {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    var high: Double { max(red, max(green, blue)) }
    var low: Double { min(red, min(green, blue)) }
    var chroma: Double { high - low }
}

func sample(x: Int, y: Int, verticalBand: Bool) -> EdgeSample {
    var red = 0
    var green = 0
    var blue = 0
    var alpha = 0
    var count = 0
    for offset in -3...3 {
        let sampledX = min(width - 1, max(0, x + (verticalBand ? offset : 0)))
        let sampledY = min(height - 1, max(0, y + (verticalBand ? 0 : offset)))
        let index = (sampledY * width + sampledX) * 4
        red += Int(pixels[index])
        green += Int(pixels[index + 1])
        blue += Int(pixels[index + 2])
        alpha += Int(pixels[index + 3])
        count += 1
    }
    return EdgeSample(
        red: Double(red) / Double(count),
        green: Double(green) / Double(count),
        blue: Double(blue) / Double(count),
        alpha: Double(alpha) / Double(count)
    )
}

func isExteriorShadow(_ value: EdgeSample) -> Bool {
    value.alpha > 72 && value.high >= 92 && value.high <= 245 && value.chroma <= 32
}

func isFace(_ value: EdgeSample) -> Bool {
    value.alpha >= 210 && !isExteriorShadow(value)
}

func inferredFaceEdge(
    positions: [Int],
    sampleAt: (Int) -> EdgeSample
) -> Int? {
    var sawContent = false
    var sawShadow = false
    for (offset, position) in positions.enumerated() {
        let value = sampleAt(position)
        if value.alpha > 24 { sawContent = true }
        if sawContent, isExteriorShadow(value) { sawShadow = true }
        guard sawContent, isFace(value) else { continue }

        let remaining = positions.dropFirst(offset).prefix(7)
        let faceSamples = remaining.lazy.map(sampleAt).filter(isFace).count
        if faceSamples >= min(5, remaining.count) || (!sawShadow && faceSamples >= 4) {
            return position
        }
    }
    return nil
}

func strongestOpaqueTransition(
    positions: [Int],
    sampleAt: (Int) -> EdgeSample
) -> Int? {
    var bestPosition: Int?
    var bestDifference = 0.0
    for offset in 1..<positions.count {
        let outside = sampleAt(positions[offset - 1])
        let inside = sampleAt(positions[offset])
        guard outside.alpha >= 248, inside.alpha >= 248 else { continue }
        let difference = abs(inside.high - outside.high) + abs(inside.chroma - outside.chroma) * 0.35
        if difference > bestDifference {
            bestDifference = difference
            bestPosition = positions[offset]
        }
    }
    return bestDifference >= 8 ? bestPosition : nil
}

let centerX = width / 2
let centerY = height / 2
let inferredLeft = inferredFaceEdge(
    positions: Array(0...centerX),
    sampleAt: { sample(x: $0, y: centerY, verticalBand: false) }
) ?? 128
let inferredRight = inferredFaceEdge(
    positions: Array(stride(from: width - 1, through: centerX, by: -1)),
    sampleAt: { sample(x: $0, y: centerY, verticalBand: false) }
) ?? (width - 129)
let inferredTop = inferredFaceEdge(
    positions: Array(0...centerY),
    sampleAt: { sample(x: centerX, y: $0, verticalBand: true) }
) ?? 128
var inferredBottom = inferredFaceEdge(
    positions: Array(stride(from: height - 1, through: centerY, by: -1)),
    sampleAt: { sample(x: centerX, y: $0, verticalBand: true) }
) ?? (height - 153)

if inferredBottom - inferredTop + 1 < 560 {
    let lowerQuarter = Array(stride(from: height - 1, through: height * 3 / 4, by: -1))
    inferredBottom = strongestOpaqueTransition(
        positions: lowerQuarter,
        sampleAt: { sample(x: centerX, y: $0, verticalBand: true) }
    ) ?? (height - 153)
}

// Stabilize the inferred mask against its own three-pixel antialiasing band.
// Snapping outward makes applying the repair again byte-for-byte idempotent.
let maskGrid = 4
let left = max(0, inferredLeft / maskGrid * maskGrid)
let right = min(width - 1, (inferredRight + maskGrid - 1) / maskGrid * maskGrid)
let top = max(0, inferredTop / maskGrid * maskGrid)
let bottom = min(height - 1, (inferredBottom + maskGrid - 1) / maskGrid * maskGrid)

let faceWidth = right - left + 1
let faceHeight = bottom - top + 1
guard faceWidth >= 560, faceHeight >= 560 else {
    fatalError("Could not infer a safe icon face (x: \(left)...\(right), y: \(top)...\(bottom))")
}

let halfWidth = Double(faceWidth) / 2
let halfHeight = Double(faceHeight) / 2
let faceCenterX = Double(left + right) / 2
let faceCenterY = Double(top + bottom) / 2
let cornerRadius = Double(min(faceWidth, faceHeight)) * 0.22

func faceSmoothstep(_ value: Double) -> Double {
    let t = min(1, max(0, value))
    return t * t * (3 - 2 * t)
}

for y in 0..<height {
    for x in 0..<width {
        let index = (y * width + x) * 4
        let oldAlpha = Int(pixels[index + 3])
        guard oldAlpha > 0 else { continue }

        let qx = abs(Double(x) + 0.5 - faceCenterX) - (halfWidth - cornerRadius)
        let qy = abs(Double(y) + 0.5 - faceCenterY) - (halfHeight - cornerRadius)
        let outsideDistance = hypot(max(qx, 0), max(qy, 0))
        let insideDistance = min(max(qx, qy), 0)
        let signedDistance = outsideDistance + insideDistance - cornerRadius
        let maskAlpha = Int((255 * faceSmoothstep((1.5 - signedDistance) / 3)).rounded())
        let newAlpha = min(oldAlpha, maskAlpha)
        guard newAlpha < oldAlpha else { continue }

        let scale = Double(newAlpha) / Double(oldAlpha)
        pixels[index] = UInt8((Double(pixels[index]) * scale).rounded())
        pixels[index + 1] = UInt8((Double(pixels[index + 1]) * scale).rounded())
        pixels[index + 2] = UInt8((Double(pixels[index + 2]) * scale).rounded())
        pixels[index + 3] = UInt8(newAlpha)
    }
}

fputs(
    "Clipped \(input.lastPathComponent) to face x \(left)...\(right), y \(top)...\(bottom)\n",
    stderr
)

let result = pixels.withUnsafeMutableBytes { storage -> CGImage? in
    guard let context = CGContext(
        data: storage.baseAddress,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    return context.makeImage()
}
guard let result,
      let destination = CGImageDestinationCreateWithURL(
        output as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
      ) else { fatalError("Could not create PNG output") }
CGImageDestinationAddImage(destination, result, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not write PNG output") }
