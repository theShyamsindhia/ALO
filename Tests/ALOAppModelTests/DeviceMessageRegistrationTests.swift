import Foundation
import Testing
@testable import ALOAppModel

@Suite("Local task registration is not consent")
struct DeviceMessageRegistrationTests {
    private let digest = Data(repeating: 7, count: 32)
    @Test func registrationIsPendingAndBounded() throws {
        var registry = DeviceMessageRegistration()
        let task = UUID(), id = try registry.register(taskID: task, title: "Own task")
        #expect(try registry.register(taskID: task, title: "Untrusted replacement label") == id)
        #expect(registry.registrations.first?.title == "Own task")
        #expect(registry.registrations.first?.state == .pendingApproval)
        #expect(throws: DeviceMessageRegistration.Failure.unavailable) {
            try registry.verifiedTask(registration: id, approvedDigest: digest)
        }
        for index in 1..<32 { _ = try registry.register(taskID: UUID(), title: "Task \(index)") }
        #expect(throws: DeviceMessageRegistration.Failure.capacity) { try registry.register(taskID: UUID(), title: "Full") }
    }
    @Test func exactLocalConfirmationOnly() throws {
        var registry = DeviceMessageRegistration()
        let task = UUID(), id = try registry.register(taskID: task, title: "Own task")
        let challenge = try registry.beginCapabilityTest(registration: id, approvedDigest: digest, now: 100)
        #expect(throws: DeviceMessageRegistration.Failure.unavailable) { try registry.verifiedTask(registration: id, approvedDigest: digest) }
        #expect(throws: DeviceMessageRegistration.Failure.invalidConfirmation) {
            try registry.confirm(challenge, response: UUID(), approvedDigest: digest, now: 101)
        }
        try registry.confirm(challenge, response: challenge.nonce, approvedDigest: digest, now: 101)
        #expect(try registry.verifiedTask(registration: id, approvedDigest: digest) == task)
        #expect(throws: DeviceMessageRegistration.Failure.invalidConfirmation) {
            try registry.confirm(challenge, response: challenge.nonce, approvedDigest: digest, now: 102)
        }
        #expect(throws: DeviceMessageRegistration.Failure.unavailable) {
            try registry.verifiedTask(registration: id, approvedDigest: Data(repeating: 8, count: 32))
        }
    }
    @Test func expiredOrReplacedChallengeCannotActivate() throws {
        var registry = DeviceMessageRegistration()
        let id = try registry.register(taskID: UUID(), title: "Own task")
        let old = try registry.beginCapabilityTest(registration: id, approvedDigest: digest, now: 100)
        let current = try registry.beginCapabilityTest(registration: id, approvedDigest: digest, now: 101)
        #expect(throws: DeviceMessageRegistration.Failure.invalidConfirmation) {
            try registry.confirm(current, response: current.nonce, approvedDigest: digest, now: 100)
        }
        #expect(throws: DeviceMessageRegistration.Failure.invalidConfirmation) {
            try registry.confirm(old, response: old.nonce, approvedDigest: digest, now: 102)
        }
        #expect(throws: DeviceMessageRegistration.Failure.invalidConfirmation) {
            try registry.confirm(current, response: current.nonce, approvedDigest: digest, now: current.expiresAt)
        }
        registry.invalidate()
        #expect(throws: DeviceMessageRegistration.Failure.invalidConfirmation) {
            try registry.confirm(current, response: current.nonce, approvedDigest: digest, now: 102)
        }
    }
    @Test func revocationAndDigestReplacementFailClosed() throws {
        var registry = DeviceMessageRegistration()
        let id = try registry.register(taskID: UUID(), title: "Own task")
        let challenge = try registry.beginCapabilityTest(registration: id, approvedDigest: digest, now: 0)
        #expect(throws: DeviceMessageRegistration.Failure.invalidConfirmation) {
            try registry.confirm(challenge, response: challenge.nonce, approvedDigest: Data(repeating: 8, count: 32), now: 1)
        }
        registry.revoke(id)
        #expect(throws: DeviceMessageRegistration.Failure.invalidConfirmation) {
            try registry.confirm(challenge, response: challenge.nonce, approvedDigest: digest, now: 1)
        }
    }
    @Test(arguments: [false, true])
    func explicitForgetRequiresFreshApprovalAfterRevocationOrDisable(disabled: Bool) throws {
        var registry = DeviceMessageRegistration()
        let task = UUID(), oldID = try registry.register(taskID: task, title: "Task")
        let old = try registry.beginCapabilityTest(registration: oldID, approvedDigest: digest, now: 1)
        if disabled { registry.invalidate() } else { registry.revoke(oldID) }
        // Repeating CLI registration alone must not undo the revocation.
        #expect(try registry.register(taskID: task, title: "Task") == oldID)
        #expect(throws: DeviceMessageRegistration.Failure.unavailable) {
            try registry.beginCapabilityTest(registration: oldID, approvedDigest: digest, now: 2)
        }
        registry.forget(oldID)
        let freshID = try registry.register(taskID: task, title: "Task")
        #expect(freshID != oldID)
        #expect(registry.registrations.first?.state == .pendingApproval)
        let fresh = try registry.beginCapabilityTest(registration: freshID, approvedDigest: digest, now: 3)
        #expect(fresh.nonce != old.nonce)
        #expect(throws: DeviceMessageRegistration.Failure.invalidConfirmation) {
            try registry.confirm(old, response: old.nonce, approvedDigest: digest, now: 4)
        }
        try registry.confirm(fresh, response: fresh.nonce, approvedDigest: digest, now: 4)
        #expect(try registry.verifiedTask(registration: freshID, approvedDigest: digest) == task)
        #expect(throws: DeviceMessageRegistration.Failure.unavailable) {
            try registry.verifiedTask(registration: oldID, approvedDigest: digest)
        }
    }
    @Test func explicitForgetRecoversBoundedCapacity() throws {
        var registry = DeviceMessageRegistration()
        var ids: [UUID] = []
        for index in 0..<32 { ids.append(try registry.register(taskID: UUID(), title: "Task \(index)")) }
        registry.invalidate()
        #expect(throws: DeviceMessageRegistration.Failure.capacity) {
            try registry.register(taskID: UUID(), title: "Full")
        }
        registry.forget(ids[0])
        _ = try registry.register(taskID: UUID(), title: "New pending task")
        #expect(registry.registrations.count == 32)
        #expect(registry.registrations.filter { $0.state == .pendingApproval }.count == 1)
    }
}
