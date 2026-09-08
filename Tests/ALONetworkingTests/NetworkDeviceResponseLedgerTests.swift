import Foundation
import Testing
@testable import ALONetworking

struct NetworkDeviceResponseLedgerTests {
    @Test func productionAdmissionThresholdsReserveEstablishedCapacity() {
        #expect(NetworkDeviceAdmissionLimits.acceptsConnection(total: 7, admitted: 0))
        #expect(!NetworkDeviceAdmissionLimits.acceptsConnection(total: 8, admitted: 0))
        #expect(NetworkDeviceAdmissionLimits.acceptsConnection(total: 23, admitted: 16))
        #expect(!NetworkDeviceAdmissionLimits.acceptsConnection(total: 24, admitted: 16))
        #expect(!NetworkDeviceAdmissionLimits.acceptsConnection(total: 1, admitted: 2))
        #expect(NetworkDeviceAdmissionLimits.acceptsTLS(known: false, unknownCount: 3))
        #expect(!NetworkDeviceAdmissionLimits.acceptsTLS(known: false, unknownCount: 4))
        #expect(NetworkDeviceAdmissionLimits.acceptsTLS(known: true, unknownCount: 4))
    }
    @Test func pendingSamenessAndSolicitedRejectionAreStrict() throws {
        var ledger = NetworkDeviceResponseLedger()
        let key = NetworkDeviceResponseLedger.Key(grant: UUID(), message: UUID())
        let first = try ledger.reserve(key, digest: Data(repeating: 1, count: 32))
        #expect(first)
        let duplicate = try ledger.reserve(key, digest: Data(repeating: 1, count: 32))
        #expect(!duplicate && ledger.pendingCount == 1)
        #expect(throws: CodexDeviceMessagingError.duplicateConflict) { try ledger.reserve(key, digest: Data(repeating: 2, count: 32)) }
        #expect(throws: CodexDeviceMessagingError.unauthorized) { try ledger.reject(key, reason: "unauthorized") }
        #expect(ledger.pendingCount == 1)
        try ledger.reject(key, reason: "rateLimited")
        #expect(ledger.pendingCount == 0)
        #expect(throws: CodexDeviceMessagingError.unauthorized) { try ledger.reject(key, reason: "rateLimited") }
        #expect(throws: CodexDeviceMessagingError.unauthorized) { try ledger.resolve(key) }
    }
    @Test func duplicateOrExcessGrantFramesCannotDriveCallbacks() throws {
        var ledger = NetworkDeviceResponseLedger()
        let first = UUID()
        try ledger.receivedGrant(first)
        #expect(throws: CodexDeviceMessagingError.unauthorized) { try ledger.receivedGrant(first) }
        for _ in 1..<32 { try ledger.receivedGrant(UUID()) }
        #expect(throws: CodexDeviceMessagingError.unauthorized) { try ledger.receivedGrant(UUID()) }
    }
    @Test func canonicalWireSamenessDoesNotDependOnEncoderOrdering() throws {
        let message = CodexDeviceMessageEnvelope(grantID: UUID(), text: "\"🌍\n")
        #expect(try NetworkDeviceTextTransport.textFrame(message) == NetworkDeviceTextTransport.textFrame(message))
    }
}
