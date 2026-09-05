import XCTest
@testable import ALONotchRuntime

final class MailDatabaseWatcherTests: XCTestCase {
    func testStoppingCancelsPendingSummaryRefresh() async throws {
        let database = try makeWatcherDatabase()
        defer { withExtendedLifetime(database) {} }
        try database.setSummary(dataID: 2, value: "")
        let reader = MailDatabaseReader(databaseURL: database.url, contactResolver: MessagesContactResolver(contactStore: DeniedMessagesContactStore()))
        let watcher = MailDatabaseWatcher(reader: reader)
        watcher.startMonitoring()
        await assertEventually { await MainActor.run { watcher.isWatching } }
        try database.insertMessage(rowID: 2, dataID: 2, receivedTimestamp: 2000)
        XCTAssertEqual(reader.message(withRowID: 2)?.summary, "")
        // Allow the 250 ms WAL debounce to schedule the delayed body refresh.
        try await Task.sleep(for: .milliseconds(350))
        watcher.stopMonitoring()
        XCTAssertFalse(watcher.isWatching)
        let notification = expectation(forNotification: .mailDatabaseDidReceiveMessage, object: nil)
        notification.isInverted = true
        try database.setSummary(dataID: 2, value: "Body arrived after disable")
        await fulfillment(of: [notification], timeout: 1)
    }

    func testStoppingCancelsMissingWALRetry() async throws {
        let database = try MailTestDatabase()
        defer { withExtendedLifetime(database) {} }
        try database.createMessagesOnlySchema()
        try database.insertSimpleMessage(rowID: 1, deleted: false)
        let watcher = MailDatabaseWatcher(reader: MailDatabaseReader(databaseURL: database.url, contactResolver: MessagesContactResolver(contactStore: DeniedMessagesContactStore())))
        watcher.startMonitoring()
        XCTAssertFalse(watcher.isWatching)
        watcher.stopMonitoring()
        XCTAssertFalse(watcher.isWatching)
        try database.enableWAL()
        try database.insertSimpleMessage(rowID: 2, deleted: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.url.path + "-wal"))
        // Cross the original one-second retry deadline; it must stay stopped.
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertFalse(watcher.isWatching)
    }


    func testStartMonitoringPostsNotificationForNewMessage() async throws {
        let database = try makeWatcherDatabase()
        defer { withExtendedLifetime(database) {} }
        let reader = MailDatabaseReader(databaseURL: database.url, contactResolver: MessagesContactResolver(contactStore: DeniedMessagesContactStore()))
        let watcher = MailDatabaseWatcher(reader: reader)

        let notificationExpectation = expectation(forNotification: .mailDatabaseDidReceiveMessage, object: nil) { notification in
            guard let message = notification.object as? MailMessage else { return false }

            return message.rowID == 2
        }

        watcher.startMonitoring()
        await assertEventually { await MainActor.run { watcher.isWatching } }
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.url.path + "-wal"))

        try database.insertMessage(rowID: 2, dataID: 2, receivedTimestamp: 2000)
        XCTAssertEqual(reader.message(withRowID: 2)?.summary, "Second preview")

        await fulfillment(
            of: [notificationExpectation],
            timeout: 3
        )

        watcher.stopMonitoring()
        try await Task.sleep(for: .milliseconds(200))
    }

    func testStopMonitoringPreventsNotificationForNewMessage() async throws {
        let database = try makeWatcherDatabase()
        defer { withExtendedLifetime(database) {} }
        let reader = MailDatabaseReader(databaseURL: database.url, contactResolver: MessagesContactResolver(contactStore: DeniedMessagesContactStore()))
        let watcher = MailDatabaseWatcher(reader: reader)

        let notificationExpectation = expectation(forNotification: .mailDatabaseDidReceiveMessage, object: nil)

        notificationExpectation.isInverted = true

        watcher.startMonitoring()

        try await Task.sleep(for: .seconds(1))

        watcher.stopMonitoring()

        try await Task.sleep(for: .milliseconds(200))

        try database.insertMessage(rowID: 2, dataID: 2, receivedTimestamp: 2000)

        await fulfillment(
            of: [notificationExpectation],
            timeout: 1
        )
    }

    private func makeWatcherDatabase() throws -> MailTestDatabase {
        let database = try MailTestDatabase(usesWAL: true)

        try database.createMailSchema()
        try database.insertReferenceData()

        try database.insertMessage(rowID: 1, receivedTimestamp: 1000)

        return database
    }
}
