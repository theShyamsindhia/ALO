import Foundation
import Darwin
import Testing
import ALOCore
import ALOIdentity
import ALORooms
import ALONetworking
@testable import ALOAppModel

@Suite("Shared network account model")
@MainActor
struct NetworkAccountModelTests {
    @Test func blockedRepositoryAuthorizationLeavesMainActorResponsive() async throws {
        let fixture = try AccountModelFixture()
        defer { fixture.cleanup() }
        try await fixture.finishNewIdentity(name: "Owner")
        let network = try await fixture.model.createNetwork(name: "Blocked disk")
        let gate = RepositoryFlockGate()
        try gate.hold(fixture.repository.directoryURL.appendingPathComponent(".repository.lock"))
        defer { gate.release.signal() }
        var started = false
        var completed = false
        let request = Task { @MainActor in
            started = true
            defer { completed = true }
            return try await fixture.model.authorization(channelID: network.mainChannel.id.uuidString,
                installationHash: Data(repeating: 6, count: 32), deviceName: "Fixture device")
        }
        while !started { await Task.yield() }
        #expect(!gate.expired, "The MainActor must run while repository flock remains held")
        #expect(!completed, "Authorization must still wait for a fresh disk policy, off-main")
        gate.release.signal()
        let authorization = try await request.value
        #expect(authorization.channelID == network.mainChannel.id)
        #expect(authorization.localDevice.userIdentity == fixture.model.identity?.publicIdentity)
    }

    @Test func pendingAuthorizationCannotPublishAfterIdentityResumeFails() async throws {
        let fixture = try AccountModelFixture()
        defer { fixture.cleanup() }
        try await fixture.finishNewIdentity(name: "Owner")
        let network = try await fixture.model.createNetwork(name: "Pending authorization")
        let gate = RepositoryFlockGate()
        try gate.hold(fixture.repository.directoryURL.appendingPathComponent(".repository.lock"))
        defer { gate.release.signal() }
        var started = false
        let request = Task { @MainActor in
            started = true
            return try await fixture.model.authorization(channelID: network.mainChannel.id.uuidString,
                installationHash: Data(repeating: 7, count: 32), deviceName: "Fixture device")
        }
        while !started { await Task.yield() }
        fixture.storage.loadError = .invalidPrivateKey
        await fixture.model.resume()
        #expect(!fixture.model.identityReady && fixture.model.networks.isEmpty)
        gate.release.signal()
        await #expect(throws: NetworkAccountError.setupRequired) { try await request.value }
        #expect(fixture.model.identity == nil && fixture.model.networks.isEmpty)
    }

    @Test func existingPolicyReloadWaitsForStableCommitOffMain() async throws {
        let fixture = try AccountModelFixture()
        defer { fixture.cleanup() }
        try await fixture.finishNewIdentity(name: "Owner")
        let network = try await fixture.model.createNetwork(name: "Original")
        let first = try await fixture.model.authorization(channelID: network.mainChannel.id.uuidString,
            installationHash: Data(repeating: 9, count: 32), deviceName: "Fixture device")
        let owner = try #require(fixture.model.identity)
        _ = try fixture.repository.rename(id: network.id, to: "Updated", owner: owner)
        let gate = RepositoryFlockGate()
        try gate.holdPolicy(first.policy)
        defer { gate.release.signal() }
        var started = false
        var completed = false
        let request = Task { @MainActor in
            started = true
            defer { completed = true }
            return try await fixture.model.authorization(channelID: network.mainChannel.id.uuidString,
                installationHash: Data(repeating: 9, count: 32), deviceName: "Fixture device")
        }
        while !started { await Task.yield() }
        #expect(!gate.expired && !completed, "A stable durable commit must not hold MainActor")
        gate.release.signal()
        let reloaded = try await request.value
        #expect(reloaded.policy === first.policy)
        #expect(try reloaded.policy.snapshot().name == "Updated")
    }

    @Test func selectedRevocationNoticePrecedesUnrelatedListingDamage() async throws {
        let fixture = try AccountModelFixture()
        defer { fixture.cleanup() }
        try await fixture.finishNewIdentity(name: "Member")
        let owner = UserIdentity.ephemeral()
        let member = try #require(fixture.model.identity)
        let joined = try NetworkManifest.create(name: "Selected network", owner: owner)
            .addingMember(member.publicIdentity, signedBy: owner)
        let invitation = try NetworkInvitation(manifest: joined, recipient: member.publicIdentity)
        try await fixture.model.importInvitation(data: invitation.encoded())
        let unrelated = try await fixture.model.createNetwork(name: "Unreadable network")
        fixture.model.selectedNetworkID = joined.id.uuidString
        let revoked = try joined.removingMember(userID: member.publicIdentity.userID, signedBy: owner)
        try fixture.repository.acceptUpdate(revoked, anchoredTo: joined)
        let record = fixture.repository.directoryURL.appendingPathComponent(unrelated.id.uuidString.lowercased() + ".json")
        try Data("invalid fixture policy".utf8).write(to: record)

        await fixture.model.refresh()
        let message = try #require(fixture.model.errorMessage)
        #expect(message.hasPrefix(NetworkAccountModel.describe(NetworkAuthorityError.notMember)))
        #expect(message.contains(unrelated.id.uuidString.lowercased()))
        #expect(fixture.model.networks.isEmpty)
        #expect(fixture.model.room(channelID: joined.mainChannel.id.uuidString) == nil)
        await fixture.model.refresh()
        #expect(fixture.model.errorMessage?.hasPrefix(NetworkAccountModel.describe(NetworkAuthorityError.notMember)) == true)
    }

    @Test func freshGenerationIgnoresLegacyOnboardingRoomsAndSelectionWithoutLoadingKeys() async throws {
        let fixture = try AccountModelFixture()
        defer { fixture.cleanup() }
        let legacyRoomID = UUID().uuidString
        fixture.defaults.set(true, forKey: "hasCompletedOnboarding")
        fixture.defaults.set(legacyRoomID, forKey: "lastActivelyJoinedRoomID")
        fixture.defaults.set("Old account", forKey: "displayName")
        let legacyURL = fixture.directory.appendingPathComponent("rooms.json")
        let legacyData = try JSONSerialization.data(withJSONObject: [["id": legacyRoomID, "name": "Old Space"]])
        try legacyData.write(to: legacyURL)

        await fixture.model.resume()
        await fixture.model.refresh()
        #expect(fixture.storage.loadCount == 0)
        #expect(fixture.storage.insertCount == 0)
        #expect(fixture.model.identity == nil)
        #expect(!fixture.model.identityReady)
        #expect(fixture.model.networks.isEmpty)
        #expect(fixture.model.channels.isEmpty)
        #expect(fixture.model.selectedNetworkID == nil)
        #expect(fixture.model.room(channelID: legacyRoomID) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.repository.directoryURL.path))

        try await fixture.finishNewIdentity(name: "New account")
        #expect(fixture.model.networks.isEmpty)
        #expect(fixture.model.room(channelID: legacyRoomID) == nil)
        #expect(try Data(contentsOf: legacyURL) == legacyData)
        #expect(fixture.defaults.string(forKey: "lastActivelyJoinedRoomID") == legacyRoomID)
    }

    @Test func storedKeyWithoutNewGenerationSetupFlagsCannotResumeAnAccount() async throws {
        let fixture = try AccountModelFixture()
        defer { fixture.cleanup() }
        _ = try fixture.store.loadOrCreateForOnboarding()
        fixture.storage.resetCounters()
        await fixture.model.resume()
        #expect(fixture.model.identity == nil)
        #expect(!fixture.model.identityReady)
        #expect(fixture.storage.loadCount == 0)
        #expect(fixture.storage.insertCount == 0)
        await #expect(throws: NetworkAccountError.self) { try await fixture.model.createNetwork(name: "Blocked") }
    }

    @Test func explicitCreationRemainsGatedUntilCompletionAndResumesTheSamePreparedRoot() async throws {
        let fixture = try AccountModelFixture()
        defer { fixture.cleanup() }
        await #expect(throws: NetworkAccountError.self) { try await fixture.model.completeIdentitySetup() }
        fixture.model.displayName = "  Alice  "
        try fixture.model.createIdentity()
        let original = try #require(fixture.model.identity?.publicIdentity)
        #expect(fixture.model.displayName == "Alice")
        #expect(!fixture.model.identityReady)
        #expect(fixture.storage.insertCount == 1)
        let recovery = try fixture.model.recoveryData()
        #expect(try IdentityRecoveryDocument.restore(from: recovery).publicIdentity == original)
        #expect(String(decoding: recovery, as: UTF8.self).contains(IdentityRecoveryDocument.warning))
        await #expect(throws: NetworkAccountError.self) { try await fixture.model.createNetwork(name: "Too soon") }
        #expect(throws: NetworkAccountError.self) { try fixture.model.publicIdentityData() }

        let prepared = fixture.anotherModel()
        await prepared.resume()
        #expect(prepared.identity?.publicIdentity == original)
        #expect(!prepared.identityReady)
        #expect(prepared.networks.isEmpty)
        #expect(try prepared.recoveryData() == recovery)
        try prepared.createIdentity()
        #expect(prepared.identity?.publicIdentity == original)
        #expect(fixture.storage.insertCount == 1)

        try await prepared.completeIdentitySetup()
        #expect(prepared.identityReady)
        let resumed = fixture.anotherModel()
        await resumed.resume()
        #expect(resumed.identityReady)
        #expect(resumed.identity?.publicIdentity == original)
        #expect(resumed.displayName == "Alice")
        #expect(fixture.storage.insertCount == 1)
    }

    @Test func invalidDisplayNameAndRecoveryDoNotCreateOrCompleteIdentity() async throws {
        let fixture = try AccountModelFixture()
        defer { fixture.cleanup() }
        for name in ["", " \n ", "A\nB", String(repeating: "A", count: 81)] {
            fixture.model.displayName = name
            #expect(throws: NetworkAccountError.self) { try fixture.model.createIdentity() }
            #expect(fixture.model.identity == nil)
            #expect(!fixture.model.identityReady)
        }
        #expect(fixture.storage.insertCount == 0)
        fixture.model.displayName = "Alice"
        #expect(throws: UserIdentityError.invalidRecoveryDocument) {
            try fixture.model.restoreIdentity(data: Data("Not an identity recovery file".utf8))
        }
        #expect(fixture.model.identity == nil)
        #expect(!fixture.model.identityReady)
        #expect(fixture.storage.insertCount == 0)
    }

    @Test func unicodeDisplayNameIsBoundedBeforeKeyCreationAndAcceptedAtBindingLimit() async throws {
        let fixture = try AccountModelFixture()
        defer { fixture.cleanup() }
        fixture.model.displayName = String(repeating: "📱", count: 33)
        #expect(throws: NetworkAccountError.self) { try fixture.model.createIdentity() }
        #expect(fixture.storage.loadCount == 0 && fixture.storage.insertCount == 0)
        #expect(fixture.model.identity == nil)
        let accepted = String(repeating: "📱", count: 32)
        try await fixture.finishNewIdentity(name: accepted)
        let network = try await fixture.model.createNetwork(name: "Unicode identity")
        let authorization = try await fixture.model.authorization(channelID: network.mainChannel.id.uuidString,
            installationHash: Data(repeating: 1, count: 32), deviceName: fixture.model.displayName)
        #expect(fixture.model.displayName == accepted)
        #expect(authorization.localDevice.deviceName == accepted)
        #expect(authorization.localDevice.deviceName.utf8.count == 128)
    }

    @Test func deviceLabelsAreNormalizedAndBoundedWithoutBreakingAdmission() async throws {
        let fixture = try AccountModelFixture()
        defer { fixture.cleanup() }
        try await fixture.finishNewIdentity(name: "Owner")
        let network = try await fixture.model.createNetwork(name: "Device labels")
        let hash = Data(repeating: 8, count: 32)
        let samples: [(String, String)] = [
            ("  Owner's iPhone\n\t", "Owner's iPhone"),
            (String(repeating: "📱", count: 80), String(repeating: "📱", count: 32)),
            (" \n\0\t ", "ALO device"),
            ("e\u{301}", "é"),
            ("a" + String(repeating: "\u{301}", count: 100), "ALO device")
        ]
        for (input, expected) in samples {
            let authorization = try await fixture.model.authorization(channelID: network.mainChannel.id.uuidString,
                installationHash: hash, deviceName: input)
            #expect(authorization.localDevice.deviceName == expected)
            #expect(authorization.localDevice.deviceName.utf8.count <= 128)
            try authorization.localDevice.verify(expectedInstallationPublicKeyHash: hash)
        }
    }

    @Test func failedResumeClearsPreviouslyLoadedIdentityAndUsableNetworkState() async throws {
        let fixture = try AccountModelFixture()
        defer { fixture.cleanup() }
        try await fixture.finishNewIdentity(name: "Owner")
        let network = try await fixture.model.createNetwork(name: "Previously available")
        fixture.storage.loadError = .keychain(-25308)
        await fixture.model.resume()
        #expect(fixture.model.identity == nil)
        #expect(!fixture.model.identityReady)
        #expect(fixture.model.networks.isEmpty && fixture.model.channels.isEmpty)
        #expect(fixture.model.selectedNetworkID == nil)
        #expect(fixture.model.room(channelID: network.mainChannel.id.uuidString) == nil)
        #expect(fixture.model.errorMessage != nil)
        #expect(throws: NetworkAccountError.self) { try fixture.model.recoveryData() }
        #expect(fixture.storage.insertCount == 1)
    }

    @Test func restoringAnEphemeralRecoveryIsExplicitAndCannotReplaceAnotherPreparedRoot() async throws {
        let fixture = try AccountModelFixture()
        defer { fixture.cleanup() }
        let original = UserIdentity.ephemeral()
        let recovery = IdentityRecoveryDocument(identity: original).serializedData()
        fixture.model.displayName = "Restored user"
        try fixture.model.restoreIdentity(data: recovery)
        #expect(fixture.model.identity?.publicIdentity == original.publicIdentity)
        #expect(!fixture.model.identityReady)
        #expect(fixture.model.networks.isEmpty)
        try fixture.model.restoreIdentity(data: recovery)
        #expect(fixture.storage.insertCount == 1)
        let other = IdentityRecoveryDocument(identity: UserIdentity.ephemeral()).serializedData()
        #expect(throws: UserIdentityError.identityAlreadyExists) { try fixture.model.restoreIdentity(data: other) }
        #expect(fixture.model.identity?.publicIdentity == original.publicIdentity)
        #expect(!fixture.model.identityReady)
        try await fixture.model.completeIdentitySetup()
        #expect(fixture.model.identityReady)
        #expect(fixture.model.networks.isEmpty)
    }

    @Test func completedAccountCreatesAndSelectsNetworkWithMainChannel() async throws {
        let fixture = try AccountModelFixture()
        defer { fixture.cleanup() }
        try await fixture.finishNewIdentity(name: "Owner")
        let manifest = try await fixture.model.createNetwork(name: "  Friends  ")
        #expect(manifest.name == "Friends")
        #expect(manifest.members.count == 1)
        #expect(manifest.owner == fixture.model.identity?.publicIdentity)
        #expect(fixture.model.selectedNetwork?.id == manifest.id)
        #expect(fixture.model.channels == [manifest.mainChannel])
        let room = try #require(fixture.model.room(channelID: manifest.mainChannel.id.uuidString))
        #expect(room.id == manifest.mainChannel.id.uuidString)
        #expect(room.name == "Friends / #Main")
        #expect(room.creatorPeerID == manifest.owner.userID)
        #expect(room.transportPolicy == .secureV2)
        #expect(fixture.model.room(channelID: "untrusted-room-name") == nil)
        #expect(fixture.model.room(channelID: UUID().uuidString) == nil)
        let resumed = fixture.anotherModel()
        await resumed.resume()
        #expect(resumed.networks == [manifest])
        #expect(resumed.selectedNetwork?.id == manifest.id)
        #expect(resumed.channels == [manifest.mainChannel])
    }

    @Test func requestGrantAndInvitationImportAreBoundToSpecificRecipient() async throws {
        let owner = try AccountModelFixture()
        let member = try AccountModelFixture()
        let outsider = try AccountModelFixture()
        defer { owner.cleanup(); member.cleanup(); outsider.cleanup() }
        try await owner.finishNewIdentity(name: "Owner")
        try await member.finishNewIdentity(name: "Member")
        try await outsider.finishNewIdentity(name: "Outsider")
        let created = try await owner.model.createNetwork(name: "Friends")
        let request = try member.model.publicIdentityData()
        let publicRequest = try NetworkMembershipRequest.decode(request)
        #expect(publicRequest.identity == member.model.identity?.publicIdentity)
        let invitation = try await owner.model.addMember(data: request, networkID: created.id)
        #expect(invitation.recipient == publicRequest.identity)
        #expect(invitation.manifest.members.count == 2)
        #expect(member.model.networks.isEmpty)
        await #expect(throws: NetworkAuthorityError.wrongRecipient) {
            try await outsider.model.importInvitation(data: invitation.encoded())
        }
        #expect(outsider.model.networks.isEmpty)
        #expect(outsider.model.room(channelID: created.mainChannel.id.uuidString) == nil)
        let imported = try await member.model.importInvitation(data: invitation.encoded())
        #expect(imported == invitation.manifest)
        #expect(member.model.selectedNetwork?.id == created.id)
        #expect(member.model.channels == [created.mainChannel])
        #expect(member.model.room(channelID: created.mainChannel.id.uuidString) != nil)
        await #expect(throws: NetworkAuthorityError.ownerRequired) {
            try await member.model.addMember(data: outsider.model.publicIdentityData(), networkID: created.id)
        }
    }

    @Test func channelsShowMemberPublicAndAllowedPrivateAccessWithOwnerAccess() async throws {
        let owner = try AccountModelFixture()
        let alice = try AccountModelFixture()
        let bob = try AccountModelFixture()
        defer { owner.cleanup(); alice.cleanup(); bob.cleanup() }
        try await owner.finishNewIdentity(name: "Owner")
        try await alice.finishNewIdentity(name: "Alice")
        try await bob.finishNewIdentity(name: "Bob")
        let created = try await owner.model.createNetwork(name: "Channels")
        _ = try await owner.model.addMember(data: alice.model.publicIdentityData(), networkID: created.id)
        _ = try await owner.model.addMember(data: bob.model.publicIdentityData(), networkID: created.id)
        try await owner.model.createChannel(name: " Public ", networkID: created.id, isPrivate: false,
                                      allowedUserIDs: ["irrelevant-public-allowlist-entry"])
        let aliceIdentity = try #require(alice.model.identity?.publicIdentity)
        try await owner.model.createChannel(name: "Planning", networkID: created.id, isPrivate: true,
                                      allowedUserIDs: [aliceIdentity.userID, aliceIdentity.userID])
        try await owner.model.createChannel(name: "Owner only", networkID: created.id, isPrivate: true, allowedUserIDs: [])
        let ownerIdentity = try #require(owner.model.identity)
        let aliceInvitation = try owner.repository.invitation(networkID: created.id, for: aliceIdentity, owner: ownerIdentity)
        let bobIdentity = try #require(bob.model.identity?.publicIdentity)
        let bobInvitation = try owner.repository.invitation(networkID: created.id, for: bobIdentity, owner: ownerIdentity)
        try await alice.model.importInvitation(data: aliceInvitation.encoded())
        try await bob.model.importInvitation(data: bobInvitation.encoded())
        #expect(Set(owner.model.channels.map(\.name)) == Set(["Main", "Public", "Planning", "Owner only"]))
        #expect(Set(alice.model.channels.map(\.name)) == Set(["Main", "Public", "Planning"]))
        #expect(Set(bob.model.channels.map(\.name)) == Set(["Main", "Public"]))
        let privateChannel = try #require(owner.model.channels.first(where: { $0.name == "Planning" }))
        #expect(alice.model.room(channelID: privateChannel.id.uuidString) != nil)
        #expect(bob.model.room(channelID: privateChannel.id.uuidString) == nil)
        await #expect(throws: NetworkAuthorityError.channelAccessDenied) {
            try await bob.model.authorization(channelID: privateChannel.id.uuidString,
                installationHash: Data(repeating: 7, count: 32), deviceName: "Bob's test device")
        }
        await #expect(throws: NetworkAuthorityError.ownerRequired) {
            try await bob.model.createChannel(name: "Member cannot create", networkID: created.id,
                                        isPrivate: false, allowedUserIDs: [])
        }
    }

    @Test func sameRootOnSecondDeviceSharesMembershipWithIndependentFullTLSHash() async throws {
        let owner = try AccountModelFixture()
        let firstDevice = try AccountModelFixture()
        let secondDevice = try AccountModelFixture()
        defer { owner.cleanup(); firstDevice.cleanup(); secondDevice.cleanup() }
        try await owner.finishNewIdentity(name: "Owner")
        try await firstDevice.finishNewIdentity(name: "Member")
        secondDevice.model.displayName = "Member on second device"
        try secondDevice.model.restoreIdentity(data: firstDevice.model.recoveryData())
        try await secondDevice.model.completeIdentitySetup()
        #expect(firstDevice.model.identity?.publicIdentity == secondDevice.model.identity?.publicIdentity)
        let network = try await owner.model.createNetwork(name: "Multiple devices")
        let invitation = try await owner.model.addMember(data: firstDevice.model.publicIdentityData(), networkID: network.id)
        try await firstDevice.model.importInvitation(data: invitation.encoded())
        try await secondDevice.model.importInvitation(data: invitation.encoded())
        let firstHash = Data(repeating: 0x42, count: 32)
        var secondHash = firstHash
        secondHash[31] = 0x43 // Same truncated node-ID prefix; different full TLS key hash.
        let first = try await firstDevice.model.authorization(channelID: network.mainChannel.id.uuidString,
            installationHash: firstHash, deviceName: "First test device")
        let second = try await secondDevice.model.authorization(channelID: network.mainChannel.id.uuidString,
            installationHash: secondHash, deviceName: "Second test device")
        #expect(first.localDevice.userIdentity == second.localDevice.userIdentity)
        #expect(first.localDevice.bindingID != second.localDevice.bindingID)
        #expect(first.localDevice.installationPublicKeyHash == firstHash)
        #expect(second.localDevice.installationPublicKeyHash == secondHash)
        try first.localDevice.verify(expectedInstallationPublicKeyHash: firstHash)
        try second.localDevice.verify(expectedInstallationPublicKeyHash: secondHash)
        #expect(throws: UserIdentityError.installationKeyMismatch) {
            try first.localDevice.verify(expectedInstallationPublicKeyHash: secondHash)
        }
        await #expect(throws: UserIdentityError.invalidBinding) {
            try await secondDevice.model.authorization(channelID: network.mainChannel.id.uuidString,
                installationHash: firstHash.prefix(16), deviceName: "Truncated hash")
        }
        #expect(try first.policy.snapshot().members.count == 2)
        #expect(try second.policy.snapshot().members.count == 2)
    }

    @Test func knownNetworkRevocationDeniesFreshAuthorizationBeforeUIRefreshAndSurvivesResume() async throws {
        let owner = try AccountModelFixture()
        let member = try AccountModelFixture()
        defer { owner.cleanup(); member.cleanup() }
        try await owner.finishNewIdentity(name: "Owner")
        try await member.finishNewIdentity(name: "Member")
        let network = try await owner.model.createNetwork(name: "Revocation")
        let invitation = try await owner.model.addMember(data: member.model.publicIdentityData(), networkID: network.id)
        try await member.model.importInvitation(data: invitation.encoded())
        let existingAuthorization = try await member.model.authorization(channelID: network.mainChannel.id.uuidString,
            installationHash: Data(repeating: 9, count: 32), deviceName: "Member test device")
        let memberIdentity = try #require(member.model.identity?.publicIdentity)
        try await owner.model.removeMember(userID: memberIdentity.userID, networkID: network.id)
        let revoked = try owner.repository.trustedManifest(id: network.id)
        try existingAuthorization.policy.receive(revoked)
        // Presentation is cached; it cannot grant access before asynchronous UI refresh.
        #expect(member.model.room(channelID: network.mainChannel.id.uuidString) != nil)
        await #expect(throws: NetworkAuthorityError.notMember) {
            try await member.model.authorization(channelID: network.mainChannel.id.uuidString,
                installationHash: Data(repeating: 9, count: 32), deviceName: "Member test device")
        }
        await member.model.refresh()
        #expect(member.model.networks.isEmpty)
        #expect(member.model.channels.isEmpty)
        #expect(member.model.selectedNetworkID == nil)
        #expect(member.model.errorMessage?.contains("not allowed") == true)
        await #expect(throws: NetworkAuthorityError.rollback) { try await member.model.importInvitation(data: invitation.encoded()) }
        let resumed = member.anotherModel()
        await resumed.resume()
        #expect(resumed.identityReady)
        #expect(resumed.networks.isEmpty)
        #expect(resumed.room(channelID: network.mainChannel.id.uuidString) == nil)
    }

    @Test func lostPrivateAllowlistAccessDeniesFreshAuthorizationWithoutRemovingNetwork() async throws {
        let owner = try AccountModelFixture()
        let member = try AccountModelFixture()
        defer { owner.cleanup(); member.cleanup() }
        try await owner.finishNewIdentity(name: "Owner")
        try await member.finishNewIdentity(name: "Member")
        let network = try await owner.model.createNetwork(name: "Private revocation")
        _ = try await owner.model.addMember(data: member.model.publicIdentityData(), networkID: network.id)
        let memberIdentity = try #require(member.model.identity?.publicIdentity)
        try await owner.model.createChannel(name: "Private", networkID: network.id, isPrivate: true,
                                      allowedUserIDs: [memberIdentity.userID])
        let ownerIdentity = try #require(owner.model.identity)
        let invitation = try owner.repository.invitation(networkID: network.id, for: memberIdentity, owner: ownerIdentity)
        try await member.model.importInvitation(data: invitation.encoded())
        let privateChannel = try #require(member.model.channels.first(where: { $0.name == "Private" }))
        #expect(member.model.room(channelID: privateChannel.id.uuidString) != nil)
        let ownerOnly = try NetworkChannel(id: privateChannel.id, name: privateChannel.name, visibility: .privateMembers)
        let updated = try owner.repository.updateChannel(ownerOnly, in: network.id, owner: ownerIdentity)
        try member.repository.acceptUpdate(updated, anchoredTo: invitation.manifest)
        #expect(member.model.room(channelID: privateChannel.id.uuidString) != nil)
        await #expect(throws: NetworkAuthorityError.channelAccessDenied) {
            try await member.model.authorization(channelID: privateChannel.id.uuidString,
                installationHash: Data(repeating: 8, count: 32), deviceName: "Fixture member")
        }
        #expect(member.model.room(channelID: network.mainChannel.id.uuidString) != nil)
        await member.model.refresh()
        #expect(member.model.networks.count == 1)
        #expect(member.model.channels == [network.mainChannel])
    }

    @Test func corruptPolicyAndIdentityStorageFailClosed() async throws {
        let fixture = try AccountModelFixture()
        defer { fixture.cleanup() }
        try await fixture.finishNewIdentity(name: "Owner")
        let network = try await fixture.model.createNetwork(name: "Storage error")
        let networkURL = fixture.repository.directoryURL.appendingPathComponent(network.id.uuidString.lowercased() + ".json")
        try Data("invalid network policy".utf8).write(to: networkURL, options: .atomic)
        #expect(fixture.model.room(channelID: network.mainChannel.id.uuidString) != nil)
        await #expect(throws: (any Error).self) {
            try await fixture.model.authorization(channelID: network.mainChannel.id.uuidString,
                installationHash: Data(repeating: 8, count: 32), deviceName: "Fixture owner")
        }
        await fixture.model.refresh()
        #expect(fixture.model.networks.isEmpty)
        #expect(fixture.model.channels.isEmpty)
        #expect(fixture.model.selectedNetworkID == nil)
        #expect(fixture.model.errorMessage != nil)

        fixture.storage.loadError = .invalidPrivateKey
        let resumed = fixture.anotherModel()
        await resumed.resume()
        #expect(!resumed.identityReady)
        #expect(resumed.identity == nil)
        #expect(resumed.networks.isEmpty)
        #expect(resumed.errorMessage != nil)
        await #expect(throws: NetworkAccountError.self) { try await resumed.createNetwork(name: "Cannot bypass setup") }
    }

    @Test func damagedNetworkRecordDoesNotHideHealthyNetworkAndShowsBoundedDiagnostics() async throws {
        let fixture = try AccountModelFixture()
        defer { fixture.cleanup() }
        try await fixture.finishNewIdentity(name: "Owner")
        let healthy = try await fixture.model.createNetwork(name: "Healthy")
        let damaged = try await fixture.model.createNetwork(name: "Damaged")
        let record = fixture.repository.directoryURL.appendingPathComponent(damaged.id.uuidString.lowercased() + ".json")
        let original = try Data(contentsOf: record)
        try Data("invalid fixture policy".utf8).write(to: record)
        await fixture.model.refresh()
        #expect(fixture.model.networks == [healthy])
        #expect(fixture.model.selectedNetwork?.id == healthy.id)
        #expect(fixture.model.channels == [healthy.mainChannel])
        #expect(fixture.model.room(channelID: healthy.mainChannel.id.uuidString) != nil)
        #expect(fixture.model.room(channelID: damaged.mainChannel.id.uuidString) == nil)
        #expect(fixture.model.networkRecordDiagnostics.map(\.networkID) == [damaged.id])
        #expect(fixture.model.additionalNetworkRecordDiagnosticCount == 0)
        let warning = try #require(fixture.model.errorMessage)
        #expect(warning.contains(damaged.id.uuidString.lowercased()))
        #expect(warning.contains("Verified networks remain available"))
        #expect(warning.utf8.count < 1_024)
        let resumed = fixture.anotherModel()
        await resumed.resume()
        #expect(resumed.networks == [healthy] && resumed.errorMessage != nil)

        // Repair only the disposable test record, retaining its originally verified signed bytes.
        try original.write(to: record, options: .atomic)
        await fixture.model.refresh()
        #expect(fixture.model.networks.count == 2)
        #expect(fixture.model.networkRecordDiagnostics.isEmpty)
        #expect(fixture.model.errorMessage == nil)
    }

    @Test func conflictingSignedPolicyQuarantinesAccountChannelsUntilFreshStart() async throws {
        let fixture = try AccountModelFixture()
        defer { fixture.cleanup() }
        try await fixture.finishNewIdentity(name: "Owner")
        let network = try await fixture.model.createNetwork(name: "Conflict")
        let owner = try #require(fixture.model.identity)
        let first = try network.renamed(to: "First owner device", signedBy: owner)
        let second = try network.renamed(to: "Second owner device", signedBy: owner)
        try fixture.repository.acceptUpdate(first, anchoredTo: network)
        #expect(throws: NetworkAuthorityError.revisionConflict) {
            try fixture.repository.acceptUpdate(second, anchoredTo: network)
        }
        #expect(fixture.model.room(channelID: network.mainChannel.id.uuidString) != nil)
        await #expect(throws: NetworkAuthorityError.quarantined) {
            try await fixture.model.authorization(channelID: network.mainChannel.id.uuidString,
                installationHash: Data(repeating: 4, count: 32), deviceName: "Owner test device")
        }
        await fixture.model.refresh()
        #expect(fixture.model.networks.isEmpty)
        #expect(fixture.model.channels.isEmpty)
        #expect(fixture.model.selectedNetworkID == nil)
        #expect(fixture.model.errorMessage?.contains("new network") == true)
        let resumed = fixture.anotherModel()
        await resumed.resume()
        #expect(resumed.identityReady)
        #expect(resumed.room(channelID: network.mainChannel.id.uuidString) == nil)
        #expect(resumed.networks.isEmpty)
    }
}

private final class RepositoryFlockGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didExpire = false
    private var acquired = false
    var expired: Bool { lock.withLock { didExpire } }

    func hold(_ url: URL) throws {
        let descriptor = open(url.path, O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        let entered = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { flock(descriptor, LOCK_UN); close(descriptor) }
            guard flock(descriptor, LOCK_EX) == 0 else { entered.signal(); return }
            self.lock.withLock { self.acquired = true }
            entered.signal()
            if self.release.wait(timeout: .now() + 1) == .timedOut {
                self.lock.withLock { self.didExpire = true }
            }
        }
        try #require(entered.wait(timeout: .now() + 1) == .success)
        try #require(lock.withLock { acquired })
    }

    func holdPolicy(_ policy: NetworkPolicyCenter) throws {
        let entered = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            policy.withStablePolicy {
                entered.signal()
                if self.release.wait(timeout: .now() + 1) == .timedOut {
                    self.lock.withLock { self.didExpire = true }
                }
            }
        }
        try #require(entered.wait(timeout: .now() + 1) == .success)
    }
}

@MainActor
private final class AccountModelFixture {
    let directory: URL
    let defaults: UserDefaults
    let suiteName: String
    let storage = AppModelMemoryIdentityStorage()
    let repository: NetworkRepository
    let store: UserIdentityStore
    let model: NetworkAccountModel

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("alo-account-model-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "in.alo.tests.account-model.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        repository = NetworkRepository(directoryURL: directory.appendingPathComponent(NetworkRepository.storageNamespace))
        store = UserIdentityStore(storage: storage)
        model = NetworkAccountModel(defaults: defaults, repository: repository, identityStore: store)
    }

    func anotherModel() -> NetworkAccountModel {
        NetworkAccountModel(defaults: defaults, repository: repository, identityStore: store)
    }

    func finishNewIdentity(name: String) async throws {
        model.displayName = name
        try model.createIdentity()
        _ = try model.recoveryData()
        try await model.completeIdentitySetup()
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Test-only storage. Never delegates to Keychain or reads an installed identity.
private final class AppModelMemoryIdentityStorage: UserIdentityKeyStorage {
    private var bytes: Data?
    var loadError: UserIdentityError?
    private(set) var loadCount = 0
    private(set) var insertCount = 0

    func loadPrivateKey() throws -> Data? {
        loadCount += 1
        if let loadError { throw loadError }
        return bytes
    }

    func insertPrivateKeyIfAbsent(_ value: Data) throws -> Bool {
        insertCount += 1
        guard bytes == nil else { return false }
        bytes = value
        return true
    }

    func resetCounters() { loadCount = 0; insertCount = 0 }
}
