// Run from the repository root: swift Scripts/import-app-icons.swift <generated-image-directory>
// Resizes approved renders without regenerating or changing their artwork.
import AppKit

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift Scripts/import-app-icons.swift <generated-image-directory>")
}
let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let destination = URL(fileURLWithPath: "Sources/ALO/Resources/AppIcons", isDirectory: true)
let icons = [
    ("original", "fc6da404-f8cf-44da-9504-54318b02cc5d"),
    ("midnight", "c97aa661-2003-49c9-997e-86d6b574b3e3"),
    ("coral", "3d7edff9-28b5-4eb4-9cb2-2b85ddf73480"),
    ("cobalt", "c81b377c-eb52-46ac-893a-244442d08fdf"),
    ("pearl-color", "cd89c8cc-aec7-40be-afd2-6c65d824820f"),
    ("graphite-keycap", "b820487d-ddb4-4c35-8396-2a49e517211a"),
    ("layered-white", "fe9b01ea-f2d8-4976-8885-c52b123f4f0f"),
    ("aurora-pearl", "c8187a56-3293-4cf7-9cf3-ac5c3d231735"),
    ("spectrum-ink", "c871d526-86c9-40e2-867a-f23a9c85a4f2"),
    ("frosted-ice", "c2e1e246-0354-4ab6-ac7c-7cf3624ab0b6"),
    ("violet-chrome", "08ef702c-010c-406d-8b5d-d94473ff863c"),
    ("milk-glass", "947329aa-59ea-4c82-9446-a5c310d7f29a"),
    ("ink-and-lime", "a325ab8f-a543-45d2-b4ce-fe3dd759de5f"),
    ("sunset-gel", "e4817aba-0983-40d6-ba15-292aab7002da"),
    ("electric-mint", "0e56faf7-21a5-4b6f-b77e-7f3ef6e97e87"),
    ("frosted-orange", "1ede00a3-33ca-43b2-b5fa-c98b7b285f30")
]
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for (name, identifier) in icons {
    let input = source.appendingPathComponent("exec-\(identifier).png")
    guard let image = NSImage(contentsOf: input),
          let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Cannot load \(input.path)")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using: .png, properties: [:])!
    try data.write(to: destination.appendingPathComponent("\(name).png"))
    if name == "original" {
        try data.write(to: URL(fileURLWithPath: "Resources/ALOLogo-1024.png"))
    }
    print("Imported \(name)")
}
