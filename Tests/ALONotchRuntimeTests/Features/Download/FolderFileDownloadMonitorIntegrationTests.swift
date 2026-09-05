import XCTest
@testable import ALONotchRuntime

final class FolderFileDownloadMonitorIntegrationTests: XCTestCase {
    func testSafariStyleDownloadPackagePublishesActiveTransfer() async {
        let tempDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let monitor = FolderFileDownloadMonitor(monitoredDirectories: [tempDirectory], chromiumReader: ChromiumDownloadMetadataReader(explicitDatabaseURLs: []))
        let expectation = expectation(description: "publishes safari download package")

        monitor.onSnapshotChange = { transfers in
            guard let transfer = transfers.first else { return }
            XCTAssertEqual(transfer.displayName, "archive.zip")
            XCTAssertEqual(transfer.directoryName, tempDirectory.lastPathComponent)
            XCTAssertTrue(transfer.isTemporaryFile)
            XCTAssertGreaterThan(transfer.byteCount, 0)
            expectation.fulfill()
        }

        monitor.startMonitoring()

        let packageURL = tempDirectory.appendingPathComponent("archive.zip.download")
        try? FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let partialFileURL = packageURL.appendingPathComponent("archive.zip")
        FileManager.default.createFile(
            atPath: partialFileURL.path,
            contents: Data(repeating: 0xA, count: 32_768)
        )

        await fulfillment(of: [expectation], timeout: 3.0)
        monitor.stopMonitoring()
    }

    func testEventDrivenTemporaryDownloadDetection() async {
        let tempDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let monitor = FolderFileDownloadMonitor(monitoredDirectories: [tempDirectory], chromiumReader: ChromiumDownloadMetadataReader(explicitDatabaseURLs: []))
        let expectation = expectation(description: "publishes chrome download package")

        monitor.onSnapshotChange = { transfers in
            guard let transfer = transfers.first else { return }
            XCTAssertEqual(transfer.displayName, "video.mp4")
            XCTAssertTrue(transfer.isTemporaryFile)
            expectation.fulfill()
        }

        monitor.startMonitoring()

        let downloadURL = tempDirectory.appendingPathComponent("video.mp4.crdownload")
        FileManager.default.createFile(
            atPath: downloadURL.path,
            contents: Data(repeating: 0xB, count: 16_384)
        )

        await fulfillment(of: [expectation], timeout: 3.0)
        monitor.stopMonitoring()
    }
}

private extension FolderFileDownloadMonitorIntegrationTests {
    func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
