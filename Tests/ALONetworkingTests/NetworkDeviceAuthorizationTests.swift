import Foundation
import Testing
import ALOIdentity
import ALORooms
@testable import ALONetworking

@Suite struct NetworkDeviceAuthorizationTests {
    private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let owner = UserIdentity.ephemeral()
        let sender = UserIdentity.ephemeral()
        let receiverHash = Data(repeating: 1, count: 32)
        let senderHash = Data(repeating: 2, count: 32)
        let center: NetworkPolicyCenter
        let authorization: NetworkDeviceAuthorization
        let senderBinding: DeviceIdentityBinding
        init() throws {
            let repository = NetworkRepository(directoryURL: directory)
            let manifest = try repository.create(name: "Fixture", owner: owner)
            center = try NetworkPolicyCenter(repository: repository, networkID: manifest.id)
            try center.receive(manifest.addingMember(sender.publicIdentity, signedBy: owner))
            let local = try DeviceIdentityBinding(user: owner, deviceName: "Receiver", generation: 1,
                                                 installationPublicKeyHash: receiverHash)
            senderBinding = try DeviceIdentityBinding(user: sender, deviceName: "Sender", generation: 1,
                                                      installationPublicKeyHash: senderHash)
            authorization = try NetworkDeviceAuthorization(policy: center, localDevice: local,
                                                            actualLocalTLSHash: receiverHash)
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        func claim() throws -> NetworkDeviceAuthorization.Claim {
            try .signed(challenge: authorization.challenge(nowNanos: 1), sender: senderBinding,
                        user: sender, policy: center, actualSenderTLSHash: senderHash,
                        actualReceiverTLSHash: receiverHash)
        }
    }

    @Test func networkMemberNeedsNoChannelSelectionAndReplayFails() throws {
        let f = try Fixture(), claim = try f.claim()
        let session = try f.authorization.accept(claim, actualSenderTLSHash: f.senderHash, nowNanos: 2)
        try f.authorization.withCurrentContext(session: session, nowNanos: 3) { context in
            #expect(context.sender == f.sender.publicIdentity)
            #expect(context.receiver == f.owner.publicIdentity)
            #expect(context.senderSPKIHash == f.senderHash)
            #expect(context.purpose == NetworkDeviceAuthorization.purpose)
        }
        #expect(throws: (any Error).self) {
            try f.authorization.accept(claim, actualSenderTLSHash: f.senderHash, nowNanos: 3)
        }
    }

    @Test func membershipRemovalFencesPreviouslyAdmittedSession() throws {
        let f = try Fixture()
        let session = try f.authorization.accept(f.claim(), actualSenderTLSHash: f.senderHash, nowNanos: 2)
        try f.center.receive(f.center.snapshot().removingMember(userID: f.sender.publicIdentity.userID,
                                                               signedBy: f.owner))
        #expect(throws: (any Error).self) {
            try f.authorization.withCurrentContext(session: session, nowNanos: 3) { _ in
                Issue.record("Removed member reached dispatch")
            }
        }
    }

    @Test func policyPublicationCannotInterleaveWithDispatchAdmissionFence() throws {
        let f = try Fixture()
        let session = try f.authorization.accept(f.claim(), actualSenderTLSHash: f.senderHash, nowNanos: 2)
        let removal = try f.center.snapshot().removingMember(userID: f.sender.publicIdentity.userID, signedBy: f.owner)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0), updating = DispatchSemaphore(value: 0)
        let published = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { done.signal() }
            do {
                try f.authorization.withCurrentContext(session: session, nowNanos: 3) { _ in
                    entered.signal()
                    _ = release.wait(timeout: .now() + 3)
                }
            } catch { Issue.record("Unexpected admission failure: \(error)") }
        }
        defer { release.signal() }
        try #require(entered.wait(timeout: .now() + 3) == .success)
        DispatchQueue.global().async {
            updating.signal()
            do { try f.center.receive(removal) } catch { Issue.record("Removal failed: \(error)") }
            published.signal()
        }
        try #require(updating.wait(timeout: .now() + 3) == .success)
        #expect(published.wait(timeout: .now() + 0.05) == .timedOut)
        release.signal()
        try #require(done.wait(timeout: .now() + 3) == .success)
        try #require(published.wait(timeout: .now() + 3) == .success)
        #expect(throws: (any Error).self) {
            try f.authorization.withCurrentContext(session: session, nowNanos: 4) { _ in
                Issue.record("Dispatch reached locally removed membership")
            }
        }
    }

    @Test func removedAndReaddedMembershipCannotRevivePriorAuthorizationWithoutObserver() throws {
        let f = try Fixture()
        let session = try f.authorization.accept(f.claim(), actualSenderTLSHash: f.senderHash, nowNanos: 2)
        try f.center.receive(f.center.snapshot().removingMember(userID: f.sender.publicIdentity.userID, signedBy: f.owner))
        try f.center.receive(f.center.snapshot().addingMember(f.sender.publicIdentity, signedBy: f.owner))
        // Authorization owns no observer: dispatch must detect the published
        // revision synchronously, not depend on callback scheduling/order.
        #expect(throws: (any Error).self) {
            try f.authorization.withCurrentContext(session: session, nowNanos: 3) { _ in
                Issue.record("An old session survived removal and re-addition")
            }
        }
    }

    @Test func actualTLSMismatchConsumesChallengeAndExpiryFails() throws {
        let f = try Fixture(), claim = try f.claim()
        #expect(throws: (any Error).self) {
            try f.authorization.accept(claim, actualSenderTLSHash: f.receiverHash, nowNanos: 2)
        }
        #expect(throws: (any Error).self) {
            try f.authorization.accept(claim, actualSenderTLSHash: f.senderHash, nowNanos: 3)
        }
        let fresh = try f.claim()
        #expect(throws: (any Error).self) {
            try f.authorization.accept(fresh, actualSenderTLSHash: f.senderHash, nowNanos: 30_000_000_001)
        }
        let session = try f.authorization.accept(f.claim(), actualSenderTLSHash: f.senderHash, nowNanos: 2)
        #expect(throws: (any Error).self) {
            try f.authorization.withCurrentContext(session: session, nowNanos: 300_000_000_002) { _ in }
        }
    }

    @Test func modifiedPurposeOrPeerFailsAndPendingChallengesAreBounded() throws {
        let f = try Fixture(), claim = try f.claim()
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(claim)) as? [String: Any])
        var challenge = try #require(object["challenge"] as? [String: Any])
        challenge["purpose"] = "alo.audio.v1"; object["challenge"] = challenge
        let modified = try JSONDecoder().decode(NetworkDeviceAuthorization.Claim.self,
                                               from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: (any Error).self) {
            try f.authorization.accept(modified, actualSenderTLSHash: f.senderHash, nowNanos: 2)
        }
        for _ in 0..<64 { _ = try f.authorization.challenge(nowNanos: 3) }
        #expect(throws: (any Error).self) { try f.authorization.challenge(nowNanos: 4) }
    }

    @Test func senderRejectsUntrustedNetworkGenerationOwnerAndRemovedMembership() throws {
        let f = try Fixture()
        let original = try f.authorization.challenge(nowNanos: 1)
        for field in ["networkID", "generation", "owner"] {
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
            if field == "owner" {
                object[field] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(UserIdentity.ephemeral().publicIdentity))
            } else { object[field] = UUID().uuidString }
            let changed = try JSONDecoder().decode(NetworkDeviceAuthorization.Challenge.self,
                                                   from: JSONSerialization.data(withJSONObject: object))
            #expect(throws: (any Error).self) {
                try NetworkDeviceAuthorization.Claim.signed(challenge: changed, sender: f.senderBinding,
                    user: f.sender, policy: f.center, actualSenderTLSHash: f.senderHash,
                    actualReceiverTLSHash: f.receiverHash)
            }
        }
        #expect(throws: (any Error).self) {
            try NetworkDeviceAuthorization.Claim.signed(challenge: original, sender: f.senderBinding,
                user: f.sender, policy: f.center, actualSenderTLSHash: f.receiverHash,
                actualReceiverTLSHash: f.receiverHash)
        }
        try f.center.receive(f.center.snapshot().removingMember(userID: f.sender.publicIdentity.userID, signedBy: f.owner))
        #expect(throws: (any Error).self) {
            try NetworkDeviceAuthorization.Claim.signed(challenge: original, sender: f.senderBinding,
                user: f.sender, policy: f.center, actualSenderTLSHash: f.senderHash,
                actualReceiverTLSHash: f.receiverHash)
        }
    }
}
