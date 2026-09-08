import Foundation
import Testing
@testable import ALONetworking

struct NetworkDeviceLiveReceiptTests {
    /// Baseline runtime failed twice under the old one-response contract.
    @Test func initialReceivedMustNotPreventFinalQueuedReceipt() throws {
        var ledger = NetworkDeviceResponseLedger()
        let key = NetworkDeviceResponseLedger.Key(grant: UUID(), message: UUID())
        _ = try ledger.reserve(key, digest: Data(repeating: 7, count: 32))
        _ = try ledger.resolve(key, receipt: .received)
        #expect(ledger.pendingCount == 1, "Intermediate receipt must keep its bounded observation")
        #expect(throws: Never.self) { try ledger.resolve(key, receipt: .codexQueued) }
        #expect(ledger.pendingCount == 0)
    }
    @Test func stagedQueriesAreBoundedSolicitedAndNonRegressive() throws {
        var ledger = NetworkDeviceResponseLedger()
        let key = NetworkDeviceResponseLedger.Key(grant: UUID(), message: UUID())
        #expect(try ledger.reserveQuery(key))
        #expect(!(try ledger.reserveQuery(key)))
        #expect(try ledger.resolveQuery(key, receipt: .received))
        #expect(!(try ledger.resolve(key, receipt: .received)))
        #expect(try ledger.resolve(key, receipt: .dispatching))
        #expect(throws: CodexDeviceMessagingError.unauthorized) { try ledger.resolve(key, receipt: .received) }
        #expect(throws: CodexDeviceMessagingError.unauthorized) { try ledger.reject(key, reason: "rateLimited") }
        #expect(throws: CodexDeviceMessagingError.unauthorized) {
            try ledger.resolve(.init(grant: UUID(), message: key.message), receipt: .codexQueued)
        }
        for _ in 1..<32 { _ = try ledger.reserveQuery(.init(grant: UUID(), message: UUID())) }
        #expect(ledger.pendingCount == 32)
        #expect(throws: CodexDeviceMessagingError.capacity) { try ledger.reserveQuery(.init(grant: UUID(), message: UUID())) }
        #expect(try ledger.resolve(key, receipt: .uncertain))
        #expect(ledger.pendingCount == 31)
        #expect(throws: CodexDeviceMessagingError.unauthorized) { try ledger.resolve(key, receipt: .delivered) }
        #expect(try ledger.reserveQuery(key))
        #expect(try ledger.resolveQuery(key, receipt: .delivered))
    }
    @Test func authenticatedQueriesReuseGrantBudgetAcrossReconnectWithoutJournalWrites() throws {
        let f = try CodexDeviceMessageServiceTests.Fixture()
        try f.service.setEnabled(true)
        let connection = try f.connect()
        let grant = try f.service.approve(connection: connection, localTaskID: UUID(), expiresAt: 1_000)
        let message = CodexDeviceMessageEnvelope(grantID: grant, text: "query data")
        _ = try f.service.receive(message, connection: connection)
        let writes = f.service.journalWritesForTesting
        for _ in 0..<4 { #expect(try f.service.queryReceipt(grantID: grant, messageID: message.messageID, connection: connection) == .received) }
        f.service.disconnect(connection)
        let fresh = try f.connect()
        #expect(throws: CodexDeviceMessagingError.rateLimited) {
            try f.service.queryReceipt(grantID: grant, messageID: message.messageID, connection: fresh)
        }
        #expect(try f.service.currentReceipt(grantID: grant, messageID: message.messageID, connection: fresh) == .received)
        #expect(f.service.journalWritesForTesting == writes)
        #expect(throws: CodexDeviceMessagingError.unauthorized) {
            try f.service.queryReceipt(grantID: UUID(), messageID: message.messageID, connection: fresh)
        }
        #expect(f.service.queryBudgetCountForTesting == 1)
        try f.service.revoke(grant: grant)
        #expect(f.service.localReceipt(grantID: grant, messageID: message.messageID) == .cancelled)
        let afterRevoke = try f.connect()
        #expect(throws: CodexDeviceMessagingError.unauthorized) {
            try f.service.currentReceipt(grantID: grant, messageID: message.messageID, connection: afterRevoke)
        }
        try f.service.setEnabled(false)
        #expect(f.service.localReceipt(grantID: grant, messageID: message.messageID) == .cancelled)
        #expect(f.service.localReceipt(grantID: grant, messageID: UUID()) == nil)
    }
}
