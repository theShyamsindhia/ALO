import AppKit
import XCTest
@testable import ALONotchRuntime

@MainActor
final class RoomTrayIntegrationTests: XCTestCase {
    func testRoomSnapshotUsesStableIDsAndRestoresStandaloneItems() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: fixture.defaultsName))
        defer { defaults.removePersistentDomain(forName: fixture.defaultsName) }
        let viewModel = FileTrayViewModel(defaults: defaults)
        viewModel.add([fixture.localFile])
        let standaloneID = try XCTUnwrap(viewModel.items.first?.id)

        viewModel.applyRoomSnapshot(.init(items: [
            .init(id: "shared-1", fileName: "Shared Notes.txt", byteCount: 12,
                  transferState: .unavailable),
            .init(id: "shared-2", fileName: "Available.txt", byteCount: 3,
                  localFileURL: fixture.localFile, transferState: .available)
        ]))

        XCTAssertTrue(viewModel.isRoomBacked)
        XCTAssertEqual(viewModel.items.map(\.id), ["shared-1", "shared-2"])
        XCTAssertFalse(viewModel.items[0].isAvailable)
        XCTAssertTrue(viewModel.items[1].isAvailable)

        viewModel.applyRoomSnapshot(nil)
        XCTAssertFalse(viewModel.isRoomBacked)
        XCTAssertEqual(viewModel.items.map(\.id), [standaloneID])
        XCTAssertEqual(viewModel.items.first?.localURL, fixture.localFile.standardizedFileURL)
    }

    func testRoomOperationsUseCallbacksWithoutEchoingOrMovingOriginals() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let viewModel = FileTrayViewModel(defaults: try XCTUnwrap(
            UserDefaults(suiteName: fixture.defaultsName)
        ))
        var added = [[URL]]()
        var removed = [[String]]()
        var downloaded = [String]()
        var exported = [(String, URL)]()
        viewModel.onRoomAddRequested = { added.append($0) }
        viewModel.onRoomRemoveRequested = { removed.append($0) }
        viewModel.onRoomDownloadRequested = { downloaded.append($0) }
        viewModel.onRoomExportRequested = { exported.append(($0, $1)) }

        viewModel.applyRoomSnapshot(.init(items: [
            .init(id: "pending", fileName: "Pending.txt", byteCount: 8,
                  transferState: .unavailable),
            .init(id: "ready", fileName: "Ready.txt", byteCount: 3,
                  localFileURL: fixture.localFile, transferState: .available)
        ]))
        XCTAssertTrue(added.isEmpty)
        XCTAssertTrue(removed.isEmpty)
        XCTAssertTrue(downloaded.isEmpty)

        try viewModel.add([fixture.localFile], mode: .moveOriginals)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.localFile.path))
        XCTAssertEqual(added, [[fixture.localFile.standardizedFileURL]])

        viewModel.requestDownload(viewModel.items[0])
        XCTAssertEqual(downloaded, ["pending"])
        viewModel.remove(viewModel.items[1])
        XCTAssertEqual(removed, [["ready"]])
        XCTAssertEqual(viewModel.count, 2, "The room snapshot remains authoritative until ALO publishes its update")

        let destination = fixture.directory.appendingPathComponent("Exported.txt")
        viewModel.export(viewModel.items[1], to: destination)
        XCTAssertEqual(exported.first?.0, "ready")
        XCTAssertEqual(exported.first?.1, destination.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testDownloadingAndInvalidSnapshotsArePresentedSafely() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let viewModel = FileTrayViewModel(defaults: try XCTUnwrap(
            UserDefaults(suiteName: fixture.defaultsName)
        ))
        var requested = [String]()
        viewModel.onRoomDownloadRequested = { requested.append($0) }

        viewModel.applyRoomSnapshot(.init(items: [
            .init(id: "downloading", fileName: "Archive.zip", byteCount: 42,
                  transferState: .downloading),
            .init(id: "missing-local", fileName: "Gone.txt", byteCount: 2,
                  localFileURL: fixture.directory.appendingPathComponent("missing"),
                  transferState: .available),
            .init(id: "downloading", fileName: "Duplicate.zip", byteCount: 42,
                  transferState: .unavailable),
            .init(id: "bad", fileName: "../escape", byteCount: 1,
                  transferState: .unavailable)
        ]))

        XCTAssertEqual(viewModel.items.map(\.id), ["downloading", "missing-local"])
        XCTAssertEqual(viewModel.items[0].transferState, .downloading)
        XCTAssertEqual(viewModel.items[1].transferState, .unavailable)
        viewModel.requestDownload(viewModel.items[0])
        viewModel.requestDownload(viewModel.items[1])
        XCTAssertEqual(requested, ["missing-local"])
    }

    func testPasteboardWriterAdvertisesNativeFileURLAndLocalDragMarker() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()

        XCTAssertTrue(pasteboard.writeObjects([FileTrayPasteboardWriter(url: fixture.localFile)]))
        XCTAssertTrue(pasteboard.isFileTrayLocalDrag)
        XCTAssertEqual(pasteboard.fileURLsForAirDrop(), [fixture.localFile.standardizedFileURL])
    }

    private func makeFixture() throws -> Fixture {
        let name = "ALORoomTrayTests.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let localFile = directory.appendingPathComponent("Local.txt")
        try Data("ALO".utf8).write(to: localFile)
        return Fixture(defaultsName: name, directory: directory, localFile: localFile)
    }
}

private struct Fixture {
    let defaultsName: String
    let directory: URL
    let localFile: URL

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
