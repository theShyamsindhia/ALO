import AppKit
import Testing
@testable import ALO

@MainActor
struct AppIconTests {
    @Test func catalogAndAssets() throws {
        #expect(AppIconOption.all.count == 16)
        #expect(Set(AppIconOption.all.map(\.id)).count == 16)
        for icon in AppIconOption.all {
            let image = try #require(icon.image)
            #expect(image.isValid)
            #expect(image.size == NSSize(width: 1024, height: 1024))
            let alpha = try alphaChannel(of: image)
            #expect(alpha[0] == 0)
            #expect(alpha[1_023] == 0)
            #expect(alpha[1_023 * 1_024] == 0)
            #expect(alpha[1_024 * 1_024 - 1] == 0)
            #expect(alpha.lazy.filter { $0 > 0 && $0 < 255 }.prefix(1_001).count > 1_000,
                    "\(icon.name) must keep a feathered edge rather than a jagged binary cutout")
        }
    }

    @Test func unknownChoiceFallsBackToOriginal() {
        #expect(AppIconOption.resolvedID(nil) == "original")
        #expect(AppIconOption.resolvedID("removed-icon") == "original")
        #expect(AppIconOption.resolvedID("frosted-orange") == "frosted-orange")
    }

    @Test func selectionPersistsAndRestoresDefault() throws {
        let suite = "ALO.AppIconTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppIconPreferences(defaults: defaults)
        #expect(preferences.selectedID == "original")
        preferences.select("midnight")
        #expect(preferences.error == nil)
        #expect(AppIconPreferences(defaults: defaults).selectedID == "midnight")
        preferences.select("original")
        #expect(AppIconPreferences(defaults: defaults).selectedID == "original")
        #expect(defaults.string(forKey: AppIconPreferences.defaultsKey) == nil)
    }

    private func alphaChannel(of image: NSImage) throws -> [UInt8] {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        let source = try #require(image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil))
        let width = source.width
        let height = source.height
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
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        #expect(rendered)
        return stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
    }
}
