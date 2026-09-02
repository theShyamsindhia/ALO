import Foundation
import Security
import Testing
@testable import WERAI

struct AppUpdaterTests {
    @Test("GitHub release metadata decodes its signed asset digest")
    func releaseMetadataDecodes() throws {
        let json = #"{"tag_name":"v1.2.3","html_url":"https://example.com/release","assets":[{"name":"ALO-macos-arm64.zip","browser_download_url":"https://example.com/app.zip","digest":"sha256:abc","size":123}]}"#
        let release = try JSONDecoder().decode(AppUpdater.Release.self, from: Data(json.utf8))
        #expect(release.tagName == "v1.2.3")
        #expect(release.assets.first?.name == "ALO-macos-arm64.zip")
        #expect(release.assets.first?.digest == "sha256:abc")
    }

    @Test("Update archives stay inside the expected app root")
    func archiveEntryValidation() {
        #expect(AppUpdater.archiveEntriesAreSafe([
            "ALO.app/",
            "ALO.app/Contents/MacOS/alo",
            "__MACOSX/ALO.app/Contents/._Info.plist",
        ]))
        #expect(!AppUpdater.archiveEntriesAreSafe(["../../Applications/ALO.app"]))
        #expect(!AppUpdater.archiveEntriesAreSafe(["/Applications/ALO.app"]))
        #expect(!AppUpdater.archiveEntriesAreSafe(["ALO.app/Contents/../escape"]))
        #expect(!AppUpdater.archiveEntriesAreSafe(["another-root/payload"]))
        #expect(!AppUpdater.archiveEntriesAreSafe([]))
    }

    @Test("Update archive metadata rejects links, special files, and oversized payloads")
    func archiveMetadataValidation() {
        let safe = """
        Archive: app.zip
        drwxr-xr-x  2.1 unx        0 bx        0 stor 26-Sep-03 02:17 ALO.app/
        -rwxr-xr-x  2.1 unx  3845584 bX   903151 defN 26-Sep-03 02:17 ALO.app/Contents/MacOS/alo
        2 files, 3845584 bytes uncompressed
        """
        #expect(AppUpdater.archiveMetadataIsSafe(safe, expectedEntryCount: 2))
        #expect(!AppUpdater.archiveMetadataIsSafe(
            safe.replacingOccurrences(of: "-rwxr-xr-x", with: "lrwxr-xr-x"),
            expectedEntryCount: 2
        ))
        #expect(!AppUpdater.archiveMetadataIsSafe(
            safe.replacingOccurrences(of: "3845584 bX", with: "600000000 bX"),
            expectedEntryCount: 2
        ))
        #expect(!AppUpdater.archiveMetadataIsSafe(safe, expectedEntryCount: 3))
    }

    @Test("Extracted update trees reject symlinks")
    func extractedTreeValidation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alo-updater-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("ALO.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("safe".utf8).write(to: app.appendingPathComponent("payload"))
        #expect(try AppUpdater.extractedTreeIsSafe(root))
        try FileManager.default.createSymbolicLink(
            at: app.appendingPathComponent("escape"),
            withDestinationURL: URL(fileURLWithPath: "/Applications")
        )
        #expect(try !AppUpdater.extractedTreeIsSafe(root))
    }

    @Test("Updater requires a Developer ID Application from the expected team")
    func developerIDRequirementParses() {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(
            AppUpdater.developerIDRequirement as CFString,
            [],
            &requirement
        )
        #expect(status == errSecSuccess)
        #expect(requirement != nil)
        #expect(AppUpdater.developerIDRequirement.contains("1.2.840.113635.100.6.1.13"))
        #expect(AppUpdater.developerIDRequirement.contains(AppUpdater.teamID))
    }
}
