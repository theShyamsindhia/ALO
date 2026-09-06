import AppKit
import Testing
@testable import ALO

@MainActor
struct AppIconTests {
    @Test func sourceIconsExcludeGeneratedExteriorShadows() throws {
        let expectedBounds: [String: [Int]] = [
            "aurora-pearl": [130, 889, 114, 869],
            "cobalt": [130, 893, 122, 881],
            "coral": [138, 885, 126, 865],
            "electric-mint": [114, 909, 102, 921],
            "frosted-ice": [86, 933, 82, 941],
            "frosted-orange": [142, 881, 134, 857],
            "graphite-keycap": [138, 885, 138, 881],
            "ink-and-lime": [142, 881, 134, 865],
            "layered-white": [142, 881, 130, 877],
            "midnight": [138, 885, 126, 861],
            "milk-glass": [142, 881, 130, 873],
            "original": [142, 881, 134, 857],
            "pearl-color": [134, 885, 126, 869],
            "spectrum-ink": [138, 881, 122, 877],
            "sunset-gel": [138, 885, 118, 873],
            "violet-chrome": [66, 957, 58, 953]
        ]

        for option in AppIconOption.all {
            let image = try #require(NSImage(contentsOf: sourceURL(for: option.id)))
            let alpha = try alphaChannel(of: image)
            #expect(alphaBounds(alpha, threshold: 8) == expectedBounds[option.id],
                    "\(option.name) must stop at its front face instead of retaining the generated shadow skirt")
        }
    }

    @Test func catalogAndDownloadAssets() throws {
        #expect(AppIconOption.all.count == 16)
        #expect(Set(AppIconOption.all.map(\.id)).count == 16)
        #expect(AppIconOption.all.first?.id == "original")

        for option in AppIconOption.all.dropFirst() {
            let url = try #require(option.downloadURL)
            #expect(url.scheme == "https")
            #expect(url.host == "raw.githubusercontent.com")
            #expect(!url.path.contains("/main/"), "Downloads must use an immutable source revision")
            let data = try Data(contentsOf: sourceURL(for: option.id))
            let image = try option.validate(data)
            #expect(image.isValid)
            #expect(image.size == NSSize(width: 1_024, height: 1_024))
            let alpha = try alphaChannel(of: image)
            #expect(alpha[0] == 0)
            #expect(alpha[1_023] == 0)
            #expect(alpha[1_023 * 1_024] == 0)
            #expect(alpha[1_024 * 1_024 - 1] == 0)
            #expect(alpha.lazy.filter { $0 > 0 && $0 < 255 }.prefix(1_001).count > 1_000,
                    "\(option.name) must keep a feathered edge rather than a jagged binary cutout")
        }
    }

    @Test func unknownChoiceFallsBackToOriginal() {
        #expect(AppIconOption.resolvedID(nil) == "original")
        #expect(AppIconOption.resolvedID("removed-icon") == "original")
        #expect(AppIconOption.resolvedID("frosted-orange") == "frosted-orange")
    }

    @Test func downloadedSelectionPersistsAndCanBeRemoved() throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let option = try #require(AppIconOption.all.first { $0.id == "midnight" })
        let preferences = AppIconPreferences(defaults: context.defaults, directory: context.directory)
        #expect(preferences.selectedID == "original")
        try preferences.install(Data(contentsOf: sourceURL(for: option.id)), for: option)
        #expect(preferences.isDownloaded(option.id))
        preferences.select(option.id)
        #expect(preferences.error == nil)
        #expect(AppIconPreferences(defaults: context.defaults, directory: context.directory).selectedID == option.id)
        preferences.removeDownloads()
        #expect(preferences.selectedID == "original")
        #expect(preferences.installedIDs.isEmpty)
        #expect(context.defaults.string(forKey: AppIconPreferences.defaultsKey) == nil)
    }

    @Test func selectingMissingIconDownloadsVerifiesAndAppliesIt() async throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let option = try #require(AppIconOption.all.first { $0.id == "coral" })
        let expected = try Data(contentsOf: sourceURL(for: option.id))
        let preferences = AppIconPreferences(defaults: context.defaults, directory: context.directory) { url, limit in
            #expect(url == option.downloadURL)
            #expect(limit == option.bytes)
            return expected
        }

        preferences.select(option.id)
        try await waitUntilIdle(preferences)
        #expect(preferences.error == nil)
        #expect(preferences.selectedID == option.id)
        #expect(preferences.isDownloaded(option.id))
        #expect(FileManager.default.fileExists(atPath: context.directory.appendingPathComponent(option.id + ".png").path))
    }

    @Test func damagedDownloadIsRejectedWithoutChangingSelection() async throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let option = try #require(AppIconOption.all.first { $0.id == "cobalt" })
        var damaged = try Data(contentsOf: sourceURL(for: option.id))
        damaged[damaged.startIndex] ^= 0xff
        let damagedDownload = damaged
        let preferences = AppIconPreferences(defaults: context.defaults, directory: context.directory) { _, _ in damagedDownload }

        preferences.select(option.id)
        try await waitUntilIdle(preferences)
        #expect(preferences.selectedID == "original")
        #expect(preferences.error != nil)
        #expect(!preferences.isDownloaded(option.id))
        #expect(!FileManager.default.fileExists(atPath: context.directory.appendingPathComponent(option.id + ".png").path))
    }

    private func waitUntilIdle(_ preferences: AppIconPreferences) async throws {
        for _ in 0..<200 where preferences.downloadingID != nil {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(preferences.downloadingID == nil)
    }

    private func sourceURL(for id: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ALO/Resources/AppIcons/\(id).png")
    }

    private func makeContext() throws -> TestContext {
        let suite = "ALO.AppIconTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ALO-AppIconTests-\(UUID().uuidString)", isDirectory: true)
        return TestContext(suite: suite, defaults: defaults, directory: directory)
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

    private func alphaBounds(_ alpha: [UInt8], threshold: UInt8) -> [Int] {
        var minimumX = 1_024
        var maximumX = 0
        var minimumY = 1_024
        var maximumY = 0
        for y in 0..<1_024 {
            for x in 0..<1_024 where alpha[y * 1_024 + x] > threshold {
                minimumX = min(minimumX, x)
                maximumX = max(maximumX, x)
                minimumY = min(minimumY, y)
                maximumY = max(maximumY, y)
            }
        }
        return [minimumX, maximumX, minimumY, maximumY]
    }

    private struct TestContext {
        let suite: String
        let defaults: UserDefaults
        let directory: URL

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
