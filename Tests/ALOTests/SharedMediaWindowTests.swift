import AppKit
import Testing
@testable import ALO

@Suite("Shared media presentation", .serialized)
struct SharedMediaWindowTests {
    @Test @MainActor func rejectsTextDisguisedAsImageAndMovie() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["unsafe.png", "unsafe.mp4", "unsafe.mp3"] {
            let url = directory.appendingPathComponent(name)
            try Data("not media".utf8).write(to: url)
            #expect(await SharedMediaKind.validate(url) == nil)
        }
        #expect(SharedMediaKind.candidate("document.pdf") == nil)
        #expect(SharedMediaKind.candidate("script.svg") == nil)
    }
    @Test @MainActor func imageOpensInResizableFloatingBorderlessWindow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Shared landscape.png")
        let image = NSImage(size: CGSize(width: 720, height: 480), flipped: false) { rect in
            NSGradient(starting: .systemIndigo, ending: .systemTeal)!.draw(in: rect, angle: 35)
            let text = "A moment worth sharing" as NSString
            text.draw(at: CGPoint(x: 80, y: 230), withAttributes: [.font: NSFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: NSColor.white])
            return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
        #expect(await SharedMediaKind.validate(url) == .image)
        var closed = false
        var returned: URL?
        _ = NSApplication.shared
        let viewer = SharedMediaWindow(url: url, sender: "Shyam", kind: .image, sendBack: { returned = $0 }, closed: { closed = true })
        defer { viewer.close() }
        let panel = try #require(NSApp.windows.first { $0.title == "Shared landscape.png from Shyam" })
        #expect(panel.styleMask.contains(.resizable))
        #expect(!panel.styleMask.contains(.titled))
        #expect(panel.level == .floating)
        viewer.togglePin()
        #expect(panel.level == .normal)
        viewer.annotate()
        #expect(viewer.editingImage != nil)
        viewer.strokes = [[CGPoint(x: 0.15, y: 0.6), CGPoint(x: 0.45, y: 0.7), CGPoint(x: 0.8, y: 0.55)]]
        viewer.returnImage()
        let returnedURL = try #require(returned)
        #expect(await SharedMediaKind.validate(returnedURL) == .image)
        if let output = ProcessInfo.processInfo.environment["ALO_SHARED_MEDIA_PREVIEW"], let content = panel.contentView {
            try Data(contentsOf: returnedURL).write(to: URL(fileURLWithPath: output + "-returned.png"))
            content.layoutSubtreeIfNeeded()
            if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
            }
        }
        viewer.close()
        #expect(closed)
        #expect(panel.contentView == nil)
    }
}
