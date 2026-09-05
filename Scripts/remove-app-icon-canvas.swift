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
