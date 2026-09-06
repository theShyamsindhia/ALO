#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: remove-chroma-green.swift <input.png> <output.png>")
}

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      image.width == image.height, image.width >= 1_024 else {
    fatalError("Expected a readable square PNG of at least 1024×1024")
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

// Only chroma pixels connected to the canvas edge count as background. This
// protects green details that are enclosed by the icon body.
func isChroma(_ pixel: Int) -> Bool {
    let index = pixel * 4
    let red = Int(pixels[index])
    let green = Int(pixels[index + 1])
    let blue = Int(pixels[index + 2])
    return green >= 150 && green - red >= 65 && green - blue >= 45
}

let pixelCount = width * height
var background = [Bool](repeating: false, count: pixelCount)
var queue = [Int]()
queue.reserveCapacity(pixelCount / 2)

func enqueue(_ x: Int, _ y: Int) {
    let pixel = y * width + x
    guard !background[pixel], isChroma(pixel) else { return }
    background[pixel] = true
    queue.append(pixel)
}

for x in 0..<width {
    enqueue(x, 0)
    enqueue(x, height - 1)
}
for y in 0..<height {
    enqueue(0, y)
    enqueue(width - 1, y)
}

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

guard queue.count >= pixelCount / 8 else {
    fatalError("The edge-connected green background was too small")
}

for pixel in queue {
    let index = pixel * 4
    pixels[index] = 0
    pixels[index + 1] = 0
    pixels[index + 2] = 0
    pixels[index + 3] = 0
}

// Despill only the first two subject pixels next to the removed background.
// Treat the observed pixel as foreground composited over pure green, then
// store the recovered premultiplied foreground. The limited band keeps mint
// and lime artwork elsewhere in the icon completely untouched.
var frontier = queue
var seen = background
for _ in 0..<6 {
    var next = [Int]()
    next.reserveCapacity(frontier.count / 8)
    for pixel in frontier {
        let x = pixel % width
        let y = pixel / width
        let neighbors = [
            x > 0 ? pixel - 1 : pixel,
            x + 1 < width ? pixel + 1 : pixel,
            y > 0 ? pixel - width : pixel,
            y + 1 < height ? pixel + width : pixel,
        ]
        for neighbor in neighbors where !seen[neighbor] {
            seen[neighbor] = true
            next.append(neighbor)
        }
    }

    for pixel in next {
        let index = pixel * 4
        let red = Int(pixels[index])
        let green = Int(pixels[index + 1])
        let blue = Int(pixels[index + 2])
        let greenExcess = max(0, green - max(red, blue))
        guard greenExcess > 4 else { continue }

        let alpha = max(16, 255 - greenExcess)
        pixels[index] = UInt8(min(red, alpha))
        pixels[index + 1] = UInt8(max(0, min(alpha, green - (255 - alpha))))
        pixels[index + 2] = UInt8(min(blue, alpha))
        pixels[index + 3] = UInt8(alpha)
    }
    frontier = next
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
guard CGImageDestinationFinalize(destination) else {
    fatalError("Could not write PNG output")
}

fputs("Removed \(queue.count) edge-connected chroma pixels from \(input.lastPathComponent)\n", stderr)
