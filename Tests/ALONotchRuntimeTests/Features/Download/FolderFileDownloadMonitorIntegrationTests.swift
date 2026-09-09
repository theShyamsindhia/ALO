import XCTest
@testable import ALONotchRuntime

final class FolderFileDownloadMonitorIntegrationTests: XCTestCase {
    func testObservationIgnoresRepeatedAndPostTeardownSnapshots() async throws {
        let expectation = expectation(description: "first populated snapshot")
        let observation = TransferObservation(expectation: expectation, name: "dataset.zip")
        let url = URL(fileURLWithPath: "/tmp/dataset.zip.crdownload")
        let now = Date()
        let exact = DownloadModel(url: url, displayName: "dataset.zip", directoryName: "tmp",
            byteCount: 25_000, estimatedTotalByteCount: 100_000, progress: 0.25,
            startedAt: now, lastUpdatedAt: now, isTemporaryFile: true, bytesPerSecond: 0)
        let fallback = DownloadModel(url: url, displayName: "dataset.zip", directoryName: "tmp",
            byteCount: 25_000, estimatedTotalByteCount: 312_500, progress: 0.08,
            startedAt: now, lastUpdatedAt: now, isTemporaryFile: true, bytesPerSecond: 0)
        observation.record([exact])
        observation.record([exact])
        await fulfillment(of: [expectation], timeout: 1)
        XCTAssertEqual(observation.close(), exact)
        observation.record([fallback])
        XCTAssertEqual(observation.close(), exact)

        let never = self.expectation(description: "no callback after early teardown")
        never.isInverted = true
        let closed = TransferObservation(expectation: never, name: "dataset.zip")
        closed.close()
        closed.record([exact])
        await fulfillment(of: [never], timeout: 0.05)
        XCTAssertNil(closed.close())
    }

    func testSafariStyleDownloadPackagePublishesActiveTransfer() async throws {
        let tempDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let monitor = FolderFileDownloadMonitor(monitoredDirectories: [tempDirectory], chromiumReader: ChromiumDownloadMetadataReader(explicitDatabaseURLs: []))
        let expectation = expectation(description: "publishes safari download package")
        let observation = TransferObservation(expectation: expectation, name: "archive.zip")
        monitor.onSnapshotChange = { observation.record($0) }
        defer { observation.close(); monitor.stopMonitoring() }

        monitor.startMonitoring()

        let packageURL = tempDirectory.appendingPathComponent("archive.zip.download")
        try? FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let partialFileURL = packageURL.appendingPathComponent("archive.zip")
        FileManager.default.createFile(
            atPath: partialFileURL.path,
            contents: Data(repeating: 0xA, count: 32_768)
        )

        await fulfillment(of: [expectation], timeout: 3.0)
        let transfer = try XCTUnwrap(observation.close())
        XCTAssertEqual(transfer.displayName, "archive.zip")
        XCTAssertEqual(transfer.directoryName, tempDirectory.lastPathComponent)
        XCTAssertTrue(transfer.isTemporaryFile)
        XCTAssertEqual(transfer.byteCount, 32_768)
    }

    func testEventDrivenTemporaryDownloadDetection() async throws {
        let tempDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let monitor = FolderFileDownloadMonitor(monitoredDirectories: [tempDirectory], chromiumReader: ChromiumDownloadMetadataReader(explicitDatabaseURLs: []))
        let expectation = expectation(description: "publishes chrome download package")
        let observation = TransferObservation(expectation: expectation, name: "video.mp4")
        monitor.onSnapshotChange = { observation.record($0) }
        defer { observation.close(); monitor.stopMonitoring() }

        monitor.startMonitoring()

        let downloadURL = tempDirectory.appendingPathComponent("video.mp4.crdownload")
        FileManager.default.createFile(
            atPath: downloadURL.path,
            contents: Data(repeating: 0xB, count: 16_384)
        )

        await fulfillment(of: [expectation], timeout: 3.0)
        let transfer = try XCTUnwrap(observation.close())
        XCTAssertEqual(transfer.displayName, "video.mp4")
        XCTAssertTrue(transfer.isTemporaryFile)
        XCTAssertEqual(transfer.byteCount, 16_384)
    }
}

/// Directory creation and content writes produce separate snapshots. Capture
/// the first populated transfer, not the legitimate empty package in between.
/// Queued callbacks may outlive stopMonitoring(), so assertions belong to the
/// test body and fulfillment must be both one-shot and closed at teardown.
final class TransferObservation: @unchecked Sendable {
    private let lock = NSLock()
    private let expectation: XCTestExpectation
    private let name: String
    private var active = true
    private var transfer: DownloadModel?

    init(expectation: XCTestExpectation, name: String) {
        self.expectation = expectation
        self.name = name
    }

    func record(_ transfers: [DownloadModel]) {
        lock.withLock {
            guard active, let found = transfers.first(where: {
                $0.displayName == name && $0.isTemporaryFile && $0.byteCount > 0
            }) else { return }
            transfer = found
            active = false
            expectation.fulfill()
        }
    }

    @discardableResult
    func close() -> DownloadModel? {
        lock.withLock {
            active = false
            return transfer
        }
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
