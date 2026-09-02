#!/usr/bin/env swift

import AppKit
import Foundation

guard let destination = CommandLine.arguments.dropFirst().first else {
    fputs("Usage: make_icon.swift output.png\n", stderr)
    exit(1)
}

let canvasSize = NSSize(width: 1024, height: 1024)
let image = NSImage(size: canvasSize)
image.lockFocus()

NSColor.clear.setFill()
NSRect(origin: .zero, size: canvasSize).fill()

let tile = NSBezierPath(
    roundedRect: NSRect(x: 76, y: 76, width: 872, height: 872),
    xRadius: 210,
    yRadius: 210
)
NSColor(calibratedRed: 0.075, green: 0.075, blue: 0.070, alpha: 1).setFill()
tile.fill()

let heights: [CGFloat] = [250, 410, 610, 430, 270]
let barWidth: CGFloat = 54
let gap: CGFloat = 42
let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
let startX = (canvasSize.width - totalWidth) / 2

for (index, height) in heights.enumerated() {
    let rect = NSRect(
        x: startX + CGFloat(index) * (barWidth + gap),
        y: (canvasSize.height - height) / 2,
        width: barWidth,
        height: height
    )
    let bar = NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2)
    if index == 2 {
        NSColor(calibratedRed: 0.62, green: 0.78, blue: 0.61, alpha: 1).setFill()
    } else {
        NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
    }
    bar.fill()
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
else {
    fputs("Could not render the WERAI icon.\n", stderr)
    exit(1)
}

try png.write(to: URL(fileURLWithPath: destination))
