import Foundation
import XCTest
@testable import ALONotchRuntime

final class MessagesDatabaseWatcherTests: XCTestCase {

    func testStartMonitoringPostsNotificationForNewMessage() async throws {
        let database = try makeWatcherDatabase()
        defer { withExtendedLifetime(database) {} }
        let reader = MessagesDatabaseReader(databaseURL: database.url, contactResolver: MessagesContactResolver(contactStore: DeniedMessagesContactStore()))
        let watcher = MessagesDatabaseWatcher(reader: reader)
        let messageExpectation = expectationForMessage(rowID: 2)

        await startAndSettle(watcher)

        try insertCurrentMessage(rowID: 2, text: "New message", into: database)

        await fulfillment(of: [messageExpectation], timeout: 3)

        await stopAndSettle(watcher)
    }

    func testStartMonitoringDoesNotReplayExistingMessage() async throws {
        let database = try makeWatcherDatabase()
        defer { withExtendedLifetime(database) {} }
        let reader = MessagesDatabaseReader(databaseURL: database.url, contactResolver: MessagesContactResolver(contactStore: DeniedMessagesContactStore()))
        let watcher = MessagesDatabaseWatcher(reader: reader)
        let messageExpectation = expectationForMessage(rowID: 1)

        messageExpectation.isInverted = true

        await startAndSettle(watcher)

        await fulfillment(of: [messageExpectation], timeout: 1)

        await stopAndSettle(watcher)
    }

    func testStopMonitoringPreventsNewMessageNotification() async throws {
        let database = try makeWatcherDatabase()
        defer { withExtendedLifetime(database) {} }
        let reader = MessagesDatabaseReader(databaseURL: database.url, contactResolver: MessagesContactResolver(contactStore: DeniedMessagesContactStore()))
        let watcher = MessagesDatabaseWatcher(reader: reader)
        let messageExpectation = expectationForMessage(rowID: 2)

        messageExpectation.isInverted = true

        await startAndSettle(watcher)
        await stopAndSettle(watcher)

        try insertCurrentMessage(rowID: 2, text: "Message after stop", into: database)

        await fulfillment(of: [messageExpectation], timeout: 1)
    }

    func testMonitoringPostsEveryMessageFromSingleDatabaseRead() async throws {
        let database = try makeWatcherDatabase()
        defer { withExtendedLifetime(database) {} }
        let reader = MessagesDatabaseReader(databaseURL: database.url, contactResolver: MessagesContactResolver(contactStore: DeniedMessagesContactStore()))
        let watcher = MessagesDatabaseWatcher(reader: reader)
        let firstMessageExpectation = expectationForMessage(rowID: 2)
        let secondMessageExpectation = expectationForMessage(rowID: 3)

        await startAndSettle(watcher)

        try insertCurrentMessage(rowID: 2, text: "First message", into: database)
        try insertCurrentMessage(rowID: 3, text: "Second message", into: database)

        await fulfillment(of: [firstMessageExpectation, secondMessageExpectation], timeout: 3)

        await stopAndSettle(watcher)
    }

    func testMonitoringIgnoresMessageReceivedBeforeMonitoringStarted() async throws {
        let database = try makeWatcherDatabase()
        defer { withExtendedLifetime(database) {} }
        let reader = MessagesDatabaseReader(databaseURL: database.url, contactResolver: MessagesContactResolver(contactStore: DeniedMessagesContactStore()))
        let watcher = MessagesDatabaseWatcher(reader: reader)
        let messageExpectation = expectationForMessage(rowID: 2)

        messageExpectation.isInverted = true

        await startAndSettle(watcher)

        try database.insertMessage(
            rowID: 2,
            guid: "old-message",
            text: "Old message",
            date: Date().addingTimeInterval(-60).timeIntervalSinceReferenceDate
        )

        await fulfillment(of: [messageExpectation], timeout: 1)

        await stopAndSettle(watcher)
    }

    func testMonitoringWaitsForAttachmentFileBeforePostingMessage() async throws {
        let database = try makeWatcherDatabase()
        defer { withExtendedLifetime(database) {} }
        let reader = MessagesDatabaseReader(databaseURL: database.url, contactResolver: MessagesContactResolver(contactStore: DeniedMessagesContactStore()))
        let watcher = MessagesDatabaseWatcher(reader: reader)
        let attachmentURL = database.url.deletingLastPathComponent().appendingPathComponent("attachment.bin")
        let prematureExpectation = expectationForMessage(rowID: 2)

        prematureExpectation.isInverted = true

        await startAndSettle(watcher)

        try database.insertAttachment(
            rowID: 100,
            filename: attachmentURL.path,
            transferName: "Attachment.bin",
            mimeType: "application/octet-stream",
            uti: "public.data"
        )

        try database.linkAttachment(rowID: 1, messageID: 2, attachmentID: 100)

        try database.insertMessage(
            rowID: 2,
            guid: "file-message",
            text: nil,
            date: Date().timeIntervalSinceReferenceDate
        )

        await fulfillment(of: [prematureExpectation], timeout: 0.4)

        let readyExpectation = expectation(forNotification: .messagesDatabaseDidReceiveMessage, object: nil) { notification in
            guard let message = notification.object as? MessagesMessage else { return false }
            guard message.rowID == 2 else { return false }
            guard case .attachment(.file(let attachment)) = message.parts.first else { return false }

            return attachment.fileURL == attachmentURL.standardizedFileURL
        }

        _ = try database.createFile(named: "attachment.bin", data: Data([0]))

        await fulfillment(of: [readyExpectation], timeout: 3)

        await stopAndSettle(watcher)
    }

    func testStopMonitoringCancelsPendingAttachmentRefresh() async throws {
        let database = try makeWatcherDatabase()
        defer { withExtendedLifetime(database) {} }
        let reader = MessagesDatabaseReader(databaseURL: database.url, contactResolver: MessagesContactResolver(contactStore: DeniedMessagesContactStore()))
        let watcher = MessagesDatabaseWatcher(reader: reader)
        let attachmentURL = database.url.deletingLastPathComponent().appendingPathComponent("attachment.bin")
        let prematureExpectation = expectationForMessage(rowID: 2)

        prematureExpectation.isInverted = true

        await startAndSettle(watcher)

        try database.insertAttachment(
            rowID: 100,
            filename: attachmentURL.path,
            transferName: "Attachment.bin",
            mimeType: "application/octet-stream",
            uti: "public.data"
        )

        try database.linkAttachment(rowID: 1, messageID: 2, attachmentID: 100)

        try database.insertMessage(
            rowID: 2,
            guid: "file-message",
            text: nil,
            date: Date().timeIntervalSinceReferenceDate
        )

        await fulfillment(of: [prematureExpectation], timeout: 0.4)

        let notificationAfterStopExpectation = expectationForMessage(rowID: 2)

        notificationAfterStopExpectation.isInverted = true

        await stopAndSettle(watcher)

        _ = try database.createFile(named: "attachment.bin", data: Data([0]))

        await fulfillment(of: [notificationAfterStopExpectation], timeout: 1)
    }

    func testMonitoringCanStartAgainAfterStopping() async throws {
        let database = try makeWatcherDatabase()
        defer { withExtendedLifetime(database) {} }
        let reader = MessagesDatabaseReader(databaseURL: database.url, contactResolver: MessagesContactResolver(contactStore: DeniedMessagesContactStore()))
        let watcher = MessagesDatabaseWatcher(reader: reader)

        await startAndSettle(watcher)
        await stopAndSettle(watcher)

        let messageExpectation = expectationForMessage(rowID: 2)

        await startAndSettle(watcher)

        try insertCurrentMessage(rowID: 2, text: "Message after restart", into: database)

        await fulfillment(of: [messageExpectation], timeout: 3)

        await stopAndSettle(watcher)
    }

    private func makeWatcherDatabase() throws -> MessagesTestDatabase {
        let database = try MessagesTestDatabase(usesWAL: true)
        defer { withExtendedLifetime(database) {} }

        try database.createSchema()

        try database.insertMessage(
            rowID: 1,
            guid: "existing-message",
            text: "Existing message",
            date: Date().addingTimeInterval(-60).timeIntervalSinceReferenceDate
        )

        return database
    }

    private func insertCurrentMessage(rowID: Int64, text: String, into database: MessagesTestDatabase) throws {
        try database.insertMessage(
            rowID: rowID,
            guid: "message-\(rowID)",
            text: text,
            date: Date().timeIntervalSinceReferenceDate
        )
    }

    private func expectationForMessage(rowID: Int64) -> XCTestExpectation {
        expectation(forNotification: .messagesDatabaseDidReceiveMessage, object: nil) { notification in
            guard let message = notification.object as? MessagesMessage else { return false }

            return message.rowID == rowID
        }
    }

    private func startAndSettle(_ watcher: MessagesDatabaseWatcher) async {
        watcher.startMonitoring()
        try? await Task.sleep(for: .milliseconds(500))
    }

    private func stopAndSettle(_ watcher: MessagesDatabaseWatcher) async {
        watcher.stopMonitoring()
        try? await Task.sleep(for: .milliseconds(300))
    }
}
