import Foundation
import Testing
import ALOIdentity
import ALORooms
@testable import ALONetworking

struct CodexDeviceMessagingPolicyTests {
    private final class Rig {
        let owner: UserIdentity
        let sender: UserIdentity
        let manifest: NetworkManifest
        let center: NetworkPolicyCenter
        let authorization: NetworkDeviceAuthorization
        let session: NetworkDeviceAuthorization.Session
        let directory: URL
        init(owner: UserIdentity = .ephemeral(), sender: UserIdentity = .ephemeral(),
             networkID: UUID = UUID(), generation: UUID = UUID(),
             senderHash: Data = Data(repeating: 1, count: 32),
             receiverHash: Data = Data(repeating: 2, count: 32)) throws {
            self.owner = owner; self.sender = sender
            manifest = try NetworkManifest.create(name: "Consent fixture", owner: owner,
                id: networkID, generation: generation).addingMember(sender.publicIdentity, signedBy: owner)
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("alo-consent-test-\(UUID())")
            let repository = NetworkRepository(directoryURL: directory)
            try repository.accept(manifest, for: owner.publicIdentity)
            center = try NetworkPolicyCenter(repository: repository, networkID: manifest.id)
            let local = try DeviceIdentityBinding(user: owner, deviceName: "Receiver", generation: 1,
                                                 installationPublicKeyHash: receiverHash)
            let remote = try DeviceIdentityBinding(user: sender, deviceName: "Sender", generation: 1,
                                                  installationPublicKeyHash: senderHash)
            authorization = try NetworkDeviceAuthorization(policy: center, localDevice: local, actualLocalTLSHash: receiverHash)
            let challenge = try authorization.challenge(nowNanos: 0)
            let claim = try NetworkDeviceAuthorization.Claim.signed(challenge: challenge, sender: remote,
                user: sender, policy: center, actualSenderTLSHash: senderHash, actualReceiverTLSHash: receiverHash)
            session = try authorization.accept(claim, actualSenderTLSHash: senderHash, nowNanos: 0)
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        func withContext<T>(at now: UInt64 = 0, _ body: (NetworkDeviceAuthorization.Context) throws -> T) throws -> T {
            try authorization.withCurrentContext(session: session, nowNanos: now, body: body)
        }
    }

    @Test func disabledByDefaultAndDestinationIsReceiverChosen() throws {
        let rig = try Rig()
        var policy = CodexDeviceMessagingPolicy()
        let task = UUID()
        try rig.withContext { context in
            #expect(throws: CodexDeviceMessagingError.disabled) {
                try policy.grant(context: context, localTaskID: task, now: 0, expiresAt: 100)
            }
            policy.setEnabled(true)
            let grant = try policy.grant(context: context, localTaskID: task, now: 0, expiresAt: 100)
            let message = CodexDeviceMessageEnvelope(grantID: grant, text: "Attributed peer text")
            let admitted = try policy.receive(message, context: context, now: 0)
            #expect(admitted == .received)
            let bytes = try JSONEncoder().encode(message)
            #expect(!String(decoding: bytes, as: UTF8.self).contains(task.uuidString))
            let dispatch = try policy.beginDispatch(message, context: context, now: 1)
            #expect(dispatch.localTaskID == task)
            #expect(dispatch.peerText == message.text)
            try policy.completeDispatch(grantID: grant, messageID: message.messageID, result: .queued)
            #expect(policy.receipt(grantID: grant, messageID: message.messageID) == .codexQueued)
            try policy.confirmDelivery(grantID: grant, messageID: message.messageID)
            #expect(policy.receipt(grantID: grant, messageID: message.messageID) == .delivered)
        }
    }

    @Test func explicitLocalRetirementReclaimsCapacityWithoutRevivingCapabilities() throws {
        let rig = try Rig()
        var policy = CodexDeviceMessagingPolicy(); policy.setEnabled(true)
        try rig.withContext { context in
            let grant = try policy.grant(context: context, localTaskID: UUID(), now: 0, expiresAt: 100)
            let message = CodexDeviceMessageEnvelope(grantID: grant, text: "receipt evidence")
            _ = try policy.receive(message, context: context, now: 1)
            _ = try policy.beginDispatch(message, context: context, now: 2)
            policy.revoke(grantID: grant)
            #expect(throws: (any Error).self) {
                try policy.retireGrant(grantID: grant, now: 3, acknowledgeReceiptLoss: false)
            }
            try policy.retireGrant(grantID: grant, now: 3, acknowledgeReceiptLoss: true)
            #expect(throws: (any Error).self) { try policy.receive(message, context: context, now: 4) }
            var restored = try CodexDeviceMessagingPolicy(restoring: policy.checkpoint)
            restored.setEnabled(true)
            #expect(throws: (any Error).self) { try restored.receive(message, context: context, now: 5) }
            for _ in 0..<40 {
                let id = try policy.grant(context: context, localTaskID: UUID(), now: 6, expiresAt: 100)
                policy.revoke(grantID: id)
                try policy.retireGrant(grantID: id, now: 6, acknowledgeReceiptLoss: true)
            }
        }
    }

    @Test func scopeCannotBeReusedAcrossNetworkGenerationRootOrInstallation() throws {
        let rig = try Rig()
        var policy = CodexDeviceMessagingPolicy(); policy.setEnabled(true)
        let grant = try rig.withContext { try policy.grant(context: $0, localTaskID: UUID(), now: 0, expiresAt: 100) }
        let message = CodexDeviceMessageEnvelope(grantID: grant, text: "Only approved scope")
        let variants = [
            try Rig(owner: rig.owner, sender: rig.sender, generation: rig.manifest.generation),
            try Rig(owner: rig.owner, sender: rig.sender, networkID: rig.manifest.id),
            try Rig(owner: rig.owner, networkID: rig.manifest.id, generation: rig.manifest.generation),
            try Rig(sender: rig.sender, networkID: rig.manifest.id, generation: rig.manifest.generation),
            try Rig(owner: rig.owner, sender: rig.sender, networkID: rig.manifest.id,
                    generation: rig.manifest.generation, senderHash: Data(repeating: 9, count: 32)),
            try Rig(owner: rig.owner, sender: rig.sender, networkID: rig.manifest.id,
                    generation: rig.manifest.generation, receiverHash: Data(repeating: 9, count: 32))
        ]
        for other in variants {
            try other.withContext { context in
                #expect(throws: CodexDeviceMessagingError.unauthorized) { try policy.receive(message, context: context, now: 0) }
            }
        }
    }

    @Test func revocationExpiryDisableAndMembershipFenceQueuedDispatch() throws {
        let rig = try Rig()
        for action in ["revoke", "expire", "disable"] {
            var policy = CodexDeviceMessagingPolicy(); policy.setEnabled(true)
            try rig.withContext { context in
                let grant = try policy.grant(context: context, localTaskID: UUID(), now: 0, expiresAt: 10)
                let message = CodexDeviceMessageEnvelope(grantID: grant, text: "Waiting")
                _ = try policy.receive(message, context: context, now: 0)
                if action == "revoke" { policy.revoke(grantID: grant) }
                if action == "disable" { policy.setEnabled(false) }
                #expect(throws: (any Error).self) {
                    try policy.beginDispatch(message, context: context, now: action == "expire" ? 10 : 1)
                }
            }
        }
        var policy = CodexDeviceMessagingPolicy(); policy.setEnabled(true)
        let grant = try rig.withContext { try policy.grant(context: $0, localTaskID: UUID(), now: 0, expiresAt: 100) }
        let message = CodexDeviceMessageEnvelope(grantID: grant, text: "Membership required at dispatch")
        _ = try rig.withContext { try policy.receive(message, context: $0, now: 0) }
        try rig.center.receive(rig.manifest.removingMember(userID: rig.sender.publicIdentity.userID, signedBy: rig.owner))
        #expect(throws: (any Error).self) {
            try rig.withContext(at: 1) { try policy.beginDispatch(message, context: $0, now: 1) }
        }
    }

    @Test func retriesAreIdempotentAndUncertainDispatchIsNeverRetried() throws {
        let rig = try Rig()
        var policy = CodexDeviceMessagingPolicy(); policy.setEnabled(true)
        try rig.withContext { context in
            let grant = try policy.grant(context: context, localTaskID: UUID(), now: 0, expiresAt: 100)
            let message = CodexDeviceMessageEnvelope(grantID: grant, text: "one")
            _ = try policy.receive(message, context: context, now: 0)
            let repeated = try policy.receive(message, context: context, now: 0)
            #expect(repeated == .received && policy.queuedMessageCount == 1)
            let changed = CodexDeviceMessageEnvelope(grantID: grant, messageID: message.messageID, text: "two")
            #expect(throws: CodexDeviceMessagingError.duplicateConflict) { try policy.receive(changed, context: context, now: 0) }
            _ = try policy.beginDispatch(message, context: context, now: 1)
            try policy.completeDispatch(grantID: grant, messageID: message.messageID, result: .uncertain)
            let uncertain = try policy.receive(message, context: context, now: 2)
            #expect(uncertain == .uncertain)
            #expect(throws: CodexDeviceMessagingError.invalidTransition) { try policy.beginDispatch(message, context: context, now: 2) }
        }
    }

    @Test func crashRestorationRevokesConsentAndQuarantinesDispatch() throws {
        let rig = try Rig()
        var policy = CodexDeviceMessagingPolicy(); policy.setEnabled(true)
        try rig.withContext { context in
            let grant = try policy.grant(context: context, localTaskID: UUID(), now: 0, expiresAt: 100)
            let message = CodexDeviceMessageEnvelope(grantID: grant, text: "Potentially queued before crash")
            _ = try policy.receive(message, context: context, now: 0)
            _ = try policy.beginDispatch(message, context: context, now: 1)
            let bytes = try JSONEncoder().encode(policy.checkpoint)
            let checkpoint = try JSONDecoder().decode(CodexDeviceMessagingPolicy.Checkpoint.self, from: bytes)
            var restored = try CodexDeviceMessagingPolicy(restoring: checkpoint)
            #expect(!restored.isEnabled && restored.queuedByteCount == 0)
            #expect(restored.receipt(grantID: grant, messageID: message.messageID) == .uncertain)
            restored.setEnabled(true)
            #expect(throws: CodexDeviceMessagingError.unauthorized) { try restored.receive(message, context: context, now: 0) }
        }
    }

    @Test func failedAndRevokedInFlightDispatchesDoNotBecomeDelivered() throws {
        let rig = try Rig()
        for revoke in [false, true] {
            var policy = CodexDeviceMessagingPolicy(); policy.setEnabled(true)
            try rig.withContext { context in
                let grant = try policy.grant(context: context, localTaskID: UUID(), now: 0, expiresAt: 100)
                let message = CodexDeviceMessageEnvelope(grantID: grant, text: "No automatic retry")
                _ = try policy.receive(message, context: context, now: 0)
                #expect(throws: CodexDeviceMessagingError.invalidTransition) {
                    try policy.confirmDelivery(grantID: grant, messageID: message.messageID)
                }
                _ = try policy.beginDispatch(message, context: context, now: 1)
                if revoke {
                    policy.revoke(grantID: grant)
                    #expect(policy.receipt(grantID: grant, messageID: message.messageID) == .uncertain)
                    #expect(throws: CodexDeviceMessagingError.invalidTransition) {
                        try policy.completeDispatch(grantID: grant, messageID: message.messageID, result: .queued)
                    }
                } else {
                    try policy.completeDispatch(grantID: grant, messageID: message.messageID, result: .definitelyNotQueued)
                    #expect(policy.receipt(grantID: grant, messageID: message.messageID) == .cancelled)
                    #expect(throws: CodexDeviceMessagingError.invalidTransition) {
                        try policy.beginDispatch(message, context: context, now: 2)
                    }
                }
            }
        }
    }

    @Test func sessionExpiryAndGrantResourceLimitsFailClosed() throws {
        let rig = try Rig()
        var policy = CodexDeviceMessagingPolicy(); policy.setEnabled(true)
        try rig.withContext { context in
            #expect(throws: CodexDeviceMessagingError.expired) {
                try policy.grant(context: context, localTaskID: UUID(), now: 0,
                                 expiresAt: CodexDeviceMessagingPolicy.maximumGrantLifetimeNanos + 1)
            }
            let grant = try policy.grant(context: context, localTaskID: UUID(), now: 0, expiresAt: 400_000_000_000)
            for _ in 1..<32 { _ = try policy.grant(context: context, localTaskID: UUID(), now: 0, expiresAt: 400_000_000_000) }
            #expect(throws: CodexDeviceMessagingError.capacity) {
                try policy.grant(context: context, localTaskID: UUID(), now: 0, expiresAt: 400_000_000_000)
            }
            #expect(throws: CodexDeviceMessagingError.expired) {
                try policy.receive(.init(grantID: grant, text: "Session expired"), context: context, now: 300_000_000_000)
            }
        }
    }

    @Test func unicodeBytesBurstAndSustainedRateAreBounded() throws {
        let rig = try Rig()
        var policy = CodexDeviceMessagingPolicy(); policy.setEnabled(true)
        try rig.withContext { context in
            let grant = try policy.grant(context: context, localTaskID: UUID(), now: 0, expiresAt: 60_000_000_000)
            let tooLarge = CodexDeviceMessageEnvelope(grantID: grant, text: String(repeating: "界", count: 5_462))
            #expect(throws: CodexDeviceMessagingError.invalidEnvelope) { try policy.receive(tooLarge, context: context, now: 0) }
            let escapedFrame = CodexDeviceMessageEnvelope(grantID: grant, text: String(repeating: "\u{0001}", count: 5_000))
            #expect(throws: CodexDeviceMessagingError.invalidEnvelope) { try policy.receive(escapedFrame, context: context, now: 0) }
            for _ in 0..<5 { _ = try policy.receive(.init(grantID: grant, text: "x"), context: context, now: 0) }
            #expect(throws: CodexDeviceMessagingError.rateLimited) { try policy.receive(.init(grantID: grant, text: "x"), context: context, now: 5_999_999_999) }
            let next = try policy.receive(.init(grantID: grant, text: "x"), context: context, now: 6_000_000_000)
            #expect(next == .received)
            #expect(throws: CodexDeviceMessagingError.clockRegressed) { try policy.receive(.init(grantID: grant, text: "x"), context: context, now: 1) }
            #expect(!policy.isEnabled)
        }
    }

    @Test func queueCountAndByteLimitsAreIndependent() throws {
        let rig = try Rig()
        for bytes in [1, CodexDeviceMessagingPolicy.maximumTextBytes] {
            var policy = CodexDeviceMessagingPolicy(); policy.setEnabled(true)
            try rig.withContext { context in
                var grants: [UUID] = []
                for _ in 0..<7 { grants.append(try policy.grant(context: context, localTaskID: UUID(), now: 0, expiresAt: 100)) }
                let capacity = bytes == 1 ? 32 : 16
                for index in 0..<capacity {
                    let message = CodexDeviceMessageEnvelope(grantID: grants[index / 5], text: String(repeating: "x", count: bytes))
                    _ = try policy.receive(message, context: context, now: 0)
                    if index == 0 { _ = try policy.beginDispatch(message, context: context, now: 0) }
                }
                #expect(throws: CodexDeviceMessagingError.capacity) {
                    try policy.receive(.init(grantID: grants[6], text: String(repeating: "x", count: bytes)), context: context, now: 0)
                }
            }
        }
    }

    @Test func dedupeJournalNeverEvictsEarlierDeliveryToAdmitReplay() throws {
        let rig = try Rig()
        var policy = CodexDeviceMessagingPolicy(); policy.setEnabled(true)
        try rig.withContext { context in
            var grants: [UUID] = []
            for _ in 0..<32 { grants.append(try policy.grant(context: context, localTaskID: UUID(), now: 0, expiresAt: 299_000_000_000)) }
            var first: CodexDeviceMessageEnvelope?
            for index in 0..<1_024 {
                let now = UInt64(index / 32) * 6_000_000_000
                let message = CodexDeviceMessageEnvelope(grantID: grants[index % 32], text: "bounded")
                if first == nil { first = message }
                _ = try policy.receive(message, context: context, now: now)
                _ = try policy.beginDispatch(message, context: context, now: now)
                try policy.completeDispatch(grantID: message.grantID, messageID: message.messageID, result: .queued)
            }
            let replay = try policy.receive(try #require(first), context: context, now: 192_000_000_000)
            #expect(replay == .codexQueued)
            #expect(throws: CodexDeviceMessagingError.capacity) { try policy.receive(.init(grantID: grants[0], text: "new"), context: context, now: 192_000_000_000) }
        }
    }
}
