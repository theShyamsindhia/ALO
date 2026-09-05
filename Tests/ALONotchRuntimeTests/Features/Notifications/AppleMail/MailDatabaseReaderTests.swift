import XCTest
@testable import ALONotchRuntime

final class MailDatabaseReaderTests: XCTestCase {

    func testLatestRowIDReturnsHighestNonDeletedMessageRowID() async throws {
        let database = try MailTestDatabase()

        try database.createMessagesOnlySchema()
        try database.insertSimpleMessage(rowID: 10, deleted: false)
        try database.insertSimpleMessage(rowID: 42, deleted: false)
        try database.insertSimpleMessage(rowID: 100, deleted: true)

        let reader = MailDatabaseReader(databaseURL: database.url, contactResolver: MessagesContactResolver(contactStore: DeniedMessagesContactStore()))

        let rowID = reader.latestRowID()

        XCTAssertEqual(rowID, 42)
    }

    func testLatestRowIDReturnsZeroWhenMessagesTableIsEmpty() async throws {
        let database = try MailTestDatabase()

        try database.createMessagesOnlySchema()

        let reader = MailDatabaseReader(databaseURL: database.url, contactResolver: MessagesContactResolver(contactStore: DeniedMessagesContactStore()))

        let rowID = reader.latestRowID()

        XCTAssertEqual(rowID, 0)
    }

    func testMessagesReturnsOnlyNewInboxMessages() async throws {
        let database = try makeMessagesDatabase()
        let reader = MailDatabaseReader(databaseURL: database.url, contactResolver: MessagesContactResolver(contactStore: DeniedMessagesContactStore()))

        let messages = reader.messages(after: 5)

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.map(\.rowID), [10, 20])
    }

    func testMessageByRowIDReturnsInboxMessage() async throws {
        let database = try makeMessagesDatabase()
        let reader = MailDatabaseReader(databaseURL: database.url, contactResolver: MessagesContactResolver(contactStore: DeniedMessagesContactStore()))

        let message = reader.message(withRowID: 10)

        XCTAssertNotNil(message)
        XCTAssertEqual(message?.rowID, 10)
        XCTAssertEqual(message?.sender, "sender@example.com")
        XCTAssertEqual(message?.subject, "Test subject")
        XCTAssertEqual(message?.summary, "Preview text")
        XCTAssertEqual(message?.messageIDHeader, "<message@example.com>")
    }

    func testMessageByRowIDDoesNotReturnDeletedMessage() async throws {
        let database = try makeMessagesDatabase()
        let reader = MailDatabaseReader(databaseURL: database.url, contactResolver: MessagesContactResolver(contactStore: DeniedMessagesContactStore()))

        let message = reader.message(withRowID: 40)

        XCTAssertNil(message)
    }

    private func makeMessagesDatabase() throws -> MailTestDatabase {
        let database = try MailTestDatabase()

        try database.createMailSchema()
        try database.insertReferenceData()

        try database.insertMessage(rowID: 10, receivedTimestamp: 1000)
        try database.insertMessage(rowID: 20, receivedTimestamp: 2000)
        try database.insertMessage(rowID: 30, mailboxID: 2, receivedTimestamp: 3000)
        try database.insertMessage(rowID: 40, receivedTimestamp: 4000, deleted: true)

        return database
    }
}
