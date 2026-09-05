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
// remains byte-for-byte unchanged.
func isCanvas(_ index: Int) -> Bool {
    let red = pixels[index]
    let green = pixels[index + 1]
    let blue = pixels[index + 2]
    let low = min(red, min(green, blue))
    let high = max(red, max(green, blue))
    return low >= 244 && high - low <= 12
}

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
