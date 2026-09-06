import Foundation
import Darwin
import XCTest
import ALOIdentity
import ALORooms
@testable import ALONetworking

final class NetworkAuthorizationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alo-network-authorization-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    private struct Fixture {
        let owner: UserIdentity
        let member: UserIdentity
        let manifest: NetworkManifest
        let repository: NetworkRepository
        let center: NetworkPolicyCenter
    }

    private func fixture() throws -> Fixture {
        let owner = UserIdentity.ephemeral()
        let member = UserIdentity.ephemeral()
        let manifest = try NetworkManifest.create(name: "Test Network", owner: owner)
            .addingMember(member.publicIdentity, signedBy: owner)
        let repository = NetworkRepository(directoryURL: directory.appendingPathComponent(UUID().uuidString))
        try repository.accept(manifest, for: owner.publicIdentity)
        return try Fixture(owner: owner, member: member, manifest: manifest, repository: repository,
                           center: NetworkPolicyCenter(repository: repository, networkID: manifest.id))
    }

    func testMediaAuthorizationReadsDoNotWaitForPolicyDiskPersistence() throws {
        let fixture = try fixture()
        let updated = try fixture.manifest.renamed(to: "Updated network", signedBy: fixture.owner)
        let descriptor = open(fixture.repository.directoryURL.appendingPathComponent(".repository.lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX), 0)
        let started = DispatchSemaphore(value: 0)
        let updateFinished = DispatchSemaphore(value: 0)
        DispatchQueue(label: "alo.policy.blocked-write-test").async {
            started.signal()
            defer { updateFinished.signal() }
            do { try fixture.center.receive(updated) }
            catch { XCTFail("Policy update failed: \(error)") }
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        // Hold the actual repository's flock, not a fake storage implementation.
        // Give its separate executor time to enter the blocked persistence call.
        Thread.sleep(forTimeInterval: 0.1)
        let snapshotFinished = DispatchSemaphore(value: 0)
        DispatchQueue(label: "alo.policy.audio-read-test").async {
            _ = try? fixture.center.snapshot()
            snapshotFinished.signal()
        }
        let readWasIndependent = snapshotFinished.wait(timeout: .now() + 0.5) == .success
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        XCTAssertEqual(updateFinished.wait(timeout: .now() + 5), .success)
        if !readWasIndependent { _ = snapshotFinished.wait(timeout: .now() + 2) }
        XCTAssertTrue(readWasIndependent, "A policy disk write must not block media authorization reads")
        XCTAssertEqual(try fixture.center.snapshot().revision, updated.revision)
    }

    /// Deterministic stand-ins for full hashes obtained from an authenticated TLS connection.
    private func installationHash(_ byte: UInt8) -> Data { Data(repeating: byte, count: 32) }

    private func binding(_ root: UserIdentity, device: UInt8) throws -> DeviceIdentityBinding {
        try DeviceIdentityBinding(user: root, deviceName: "Test device \(device)", generation: 1,
                                  installationPublicKeyHash: installationHash(device))
    }

    private func authorization(_ fixture: Fixture, local: UserIdentity? = nil,
                               channelID: UUID? = nil, device: UInt8 = 1) throws -> NetworkChannelAuthorization {
        try NetworkChannelAuthorization(policy: fixture.center,
            channelID: channelID ?? fixture.manifest.mainChannel.id,
            localDevice: binding(local ?? fixture.owner, device: device))
    }

    private func claim(_ manifest: NetworkManifest, root: UserIdentity, channelID: UUID? = nil,
                       device: UInt8 = 2) throws -> NetworkPeerClaim {
        try NetworkPeerClaim(manifest: manifest, channelID: channelID ?? manifest.mainChannel.id,
                             device: binding(root, device: device))
    }

    func testPublicChannelRequiresMembershipForRemoteAndLocalUsers() throws {
        let fixture = try fixture()
        let outsider = UserIdentity.ephemeral()
        let authorization = try authorization(fixture)
        let outsiderClaim = try claim(fixture.manifest, root: outsider)

        XCTAssertThrowsError(try authorization.validate(outsiderClaim, installationKeyHash: installationHash(2))) { error in
            XCTAssertEqual(error as? NetworkAuthorityError, .notMember)
        }
        XCTAssertThrowsError(try self.authorization(fixture, local: outsider)) { error in
            XCTAssertEqual(error as? NetworkAuthorityError, .notMember)
        }
        let memberClaim = try claim(fixture.manifest, root: fixture.member)
        XCTAssertEqual(try authorization.validate(memberClaim, installationKeyHash: installationHash(2)), fixture.member.publicIdentity)
        XCTAssertEqual(try fixture.center.snapshot().revision, fixture.manifest.revision)
    }

    func testPrivateChannelRequiresAnExplicitGrantForMembers() throws {
        let fixture = try fixture()
        let ungranted = UserIdentity.ephemeral()
        let privateChannel = try NetworkChannel(name: "Private", visibility: .privateMembers,
                                               allowedUserIDs: [fixture.member.publicIdentity.userID])
        let updated = try fixture.manifest.addingMember(ungranted.publicIdentity, signedBy: fixture.owner)
            .addingChannel(privateChannel, signedBy: fixture.owner)
        try fixture.center.receive(updated)
        let authorization = try authorization(fixture, channelID: privateChannel.id)

        let allowedClaim = try claim(updated, root: fixture.member, channelID: privateChannel.id)
        XCTAssertEqual(try authorization.validate(allowedClaim, installationKeyHash: installationHash(2)), fixture.member.publicIdentity)
        let deniedClaim = try claim(updated, root: ungranted, channelID: privateChannel.id)
        XCTAssertThrowsError(try authorization.validate(deniedClaim, installationKeyHash: installationHash(2))) { error in
            XCTAssertEqual(error as? NetworkAuthorityError, .channelAccessDenied)
        }
        XCTAssertThrowsError(try self.authorization(fixture, local: ungranted, channelID: privateChannel.id))
        XCTAssertNoThrow(try self.authorization(fixture, local: fixture.member, channelID: privateChannel.id))
    }

    func testFullTLSHashMismatchRejectsClaimBeforeAcceptingItsNewerPolicy() throws {
        let fixture = try fixture()
        let authorization = try authorization(fixture)
        let newer = try fixture.manifest.renamed(to: "New policy", signedBy: fixture.owner)
        let remote = try claim(newer, root: fixture.member)
        var sameTruncatedNodeID = installationHash(2)
        sameTruncatedNodeID[31] = 9

        XCTAssertThrowsError(try authorization.validate(remote, installationKeyHash: sameTruncatedNodeID)) { error in
            XCTAssertEqual(error as? UserIdentityError, .installationKeyMismatch)
        }
        XCTAssertThrowsError(try authorization.validate(remote, installationKeyHash: installationHash(2).prefix(16)))
        XCTAssertEqual(try fixture.center.snapshot().revision, fixture.manifest.revision)
        XCTAssertEqual(try fixture.repository.trustedManifest(id: fixture.manifest.id).revision, fixture.manifest.revision)
        XCTAssertThrowsError(try authorization.claim(installationKeyHash: sameTruncatedNodeID))
        XCTAssertNoThrow(try authorization.claim(installationKeyHash: installationHash(1)))
    }

    func testHigherSignedRemoteRevocationPersistsBeforeDenyingAndSurvivesRestart() throws {
        let fixture = try fixture()
        let authorization = try authorization(fixture)
        let revoked = try fixture.manifest.removingMember(userID: fixture.member.publicIdentity.userID, signedBy: fixture.owner)
        let remote = try claim(revoked, root: fixture.member)

        XCTAssertThrowsError(try authorization.validate(remote, installationKeyHash: installationHash(2))) { error in
            XCTAssertEqual(error as? NetworkAuthorityError, .notMember)
        }
        XCTAssertEqual(try fixture.center.snapshot().revision, revoked.revision)
        let reopenedRepository = NetworkRepository(directoryURL: fixture.repository.directoryURL)
        let reopened = try NetworkPolicyCenter(repository: reopenedRepository, networkID: revoked.id)
        XCTAssertEqual(try reopened.snapshot().revision, revoked.revision)
        XCTAssertThrowsError(try reopenedRepository.network(id: revoked.id, for: fixture.member.publicIdentity))
        let reopenedAuthorization = try NetworkChannelAuthorization(policy: reopened, channelID: revoked.mainChannel.id,
                                                                    localDevice: binding(fixture.owner, device: 1))
        XCTAssertThrowsError(try reopenedAuthorization.validateCurrentAccess(fixture.member.publicIdentity))
    }

    func testHigherSignedLocalRevocationPersistsBeforeDenyingAndPreventsNewClaims() throws {
        let fixture = try fixture()
        let authorization = try authorization(fixture, local: fixture.member)
        let revoked = try fixture.manifest.removingMember(userID: fixture.member.publicIdentity.userID, signedBy: fixture.owner)
        let ownerClaim = try claim(revoked, root: fixture.owner)

        XCTAssertThrowsError(try authorization.validate(ownerClaim, installationKeyHash: installationHash(2))) { error in
            XCTAssertEqual(error as? NetworkAuthorityError, .notMember)
        }
        XCTAssertEqual(try fixture.repository.trustedManifest(id: revoked.id).revision, revoked.revision)
        XCTAssertThrowsError(try authorization.claim(installationKeyHash: installationHash(1)))
        XCTAssertThrowsError(try self.authorization(fixture, local: fixture.member))
    }

    func testStalePeerCannotRestoreRevokedMembershipOrPrivateGrant() throws {
        let fixture = try fixture()
        let privateChannel = try NetworkChannel(name: "Private", visibility: .privateMembers,
                                               allowedUserIDs: [fixture.member.publicIdentity.userID])
        let granted = try fixture.manifest.addingChannel(privateChannel, signedBy: fixture.owner)
        try fixture.center.receive(granted)
        let authorization = try authorization(fixture, channelID: privateChannel.id)
        let staleGrant = try claim(granted, root: fixture.member, channelID: privateChannel.id)
        XCTAssertNoThrow(try authorization.validate(staleGrant, installationKeyHash: installationHash(2)))

        let closedChannel = try NetworkChannel(id: privateChannel.id, name: privateChannel.name, visibility: .privateMembers)
        let removedGrant = try granted.updatingChannel(closedChannel, signedBy: fixture.owner)
        try fixture.center.receive(removedGrant)
        XCTAssertThrowsError(try authorization.validate(staleGrant, installationKeyHash: installationHash(2))) { error in
            XCTAssertEqual(error as? NetworkAuthorityError, .channelAccessDenied)
        }
        XCTAssertEqual(try fixture.center.snapshot().revision, removedGrant.revision)

        let removedMember = try removedGrant.removingMember(userID: fixture.member.publicIdentity.userID, signedBy: fixture.owner)
        try fixture.center.receive(removedMember)
        XCTAssertThrowsError(try authorization.validate(staleGrant, installationKeyHash: installationHash(2))) { error in
            XCTAssertEqual(error as? NetworkAuthorityError, .notMember)
        }
        XCTAssertEqual(try fixture.repository.trustedManifest(id: removedMember.id).revision, removedMember.revision)
    }

    func testCrossNetworkGenerationOwnerAndChannelClaimsAreRejected() throws {
        let fixture = try fixture()
        let authorization = try authorization(fixture)
        let otherNetwork = try NetworkManifest.create(name: "Other Network", owner: fixture.owner)
            .addingMember(fixture.member.publicIdentity, signedBy: fixture.owner)
        let otherGeneration = try NetworkManifest.create(name: "Other Generation", owner: fixture.owner,
            id: fixture.manifest.id, generation: UUID()).addingMember(fixture.member.publicIdentity, signedBy: fixture.owner)
        let otherOwner = UserIdentity.ephemeral()
        let substitutedOwner = try NetworkManifest.create(name: "Other Owner", owner: otherOwner,
            id: fixture.manifest.id, generation: fixture.manifest.generation)
            .addingMember(fixture.member.publicIdentity, signedBy: otherOwner)

        for incompatible in [otherNetwork, otherGeneration, substitutedOwner] {
            // Use the expected channel ID to reach the network trust-anchor check.
            let remote = try claim(incompatible, root: fixture.member, channelID: fixture.manifest.mainChannel.id)
            XCTAssertThrowsError(try authorization.validate(remote, installationKeyHash: installationHash(2)))
        }
        let wrongChannel = try claim(fixture.manifest, root: fixture.member, channelID: UUID())
        XCTAssertThrowsError(try authorization.validate(wrongChannel, installationKeyHash: installationHash(2))) { error in
            XCTAssertEqual(error as? SecureTransportError, .wrongContext)
        }
        XCTAssertEqual(try fixture.center.snapshot().canonicalBytes(), try fixture.manifest.canonicalBytes())
        XCTAssertEqual(try fixture.repository.trustedManifest(id: fixture.manifest.id).canonicalBytes(), try fixture.manifest.canonicalBytes())
    }

    func testTwoDistinctDevicesWithTheSameUserRootAreAuthorized() throws {
        let fixture = try fixture()
        let recovery = IdentityRecoveryDocument(identity: fixture.member).serializedData()
        let recoveredRoot = try IdentityRecoveryDocument.restore(from: recovery)
        let firstDevice = try authorization(fixture, local: fixture.member, device: 3)
        let secondDevice = try authorization(fixture, local: recoveredRoot, device: 4)
        let firstClaim = try firstDevice.claim(installationKeyHash: installationHash(3))
        let secondClaim = try secondDevice.claim(installationKeyHash: installationHash(4))

        XCTAssertEqual(try firstDevice.validate(secondClaim, installationKeyHash: installationHash(4)), fixture.member.publicIdentity)
        XCTAssertEqual(try secondDevice.validate(firstClaim, installationKeyHash: installationHash(3)), fixture.member.publicIdentity)
        XCTAssertNotEqual(firstClaim.device.bindingID, secondClaim.device.bindingID)
        XCTAssertNotEqual(firstClaim.device.installationPublicKeyHash, secondClaim.device.installationPublicKeyHash)
        XCTAssertThrowsError(try firstDevice.validate(secondClaim, installationKeyHash: installationHash(3)))
    }

    func testSignedEquivocationQuarantinesCenterAndPersistentRepository() throws {
        let fixture = try fixture()
        let authorization = try authorization(fixture)
        let fork = try NetworkManifest.signed(id: fixture.manifest.id, generation: fixture.manifest.generation,
            revision: fixture.manifest.revision, name: "Conflicting policy", owner: fixture.owner,
            members: fixture.manifest.members, channels: fixture.manifest.channels)
        var notifications = 0
        let observer = fixture.center.observe { notifications += 1 }
        defer { fixture.center.removeObserver(observer) }

        XCTAssertThrowsError(try fixture.center.receive(fork)) { error in
            XCTAssertEqual(error as? NetworkAuthorityError, .revisionConflict)
        }
        XCTAssertEqual(notifications, 1)
        XCTAssertThrowsError(try fixture.center.snapshot()) { error in
            XCTAssertEqual(error as? NetworkAuthorityError, .quarantined)
        }
        XCTAssertThrowsError(try authorization.validateCurrentAccess(fixture.member.publicIdentity))
        XCTAssertThrowsError(try authorization.claim(installationKeyHash: installationHash(1)))
        let reopened = NetworkRepository(directoryURL: fixture.repository.directoryURL)
        XCTAssertThrowsError(try NetworkPolicyCenter(repository: reopened, networkID: fixture.manifest.id))
        XCTAssertThrowsError(try reopened.trustedManifest(id: fixture.manifest.id))
    }

    func testRevocationObserverSeesNewPolicyAndRemovedObserverIsNotCalledAgain() throws {
        let fixture = try fixture()
        let authorization = try authorization(fixture)
        var notifications = 0
        var accessAtNotification: Result<Void, Error>?
        let observer = fixture.center.observe {
            notifications += 1
            accessAtNotification = Result { try authorization.validateCurrentAccess(fixture.member.publicIdentity) }
        }
        let revoked = try fixture.manifest.removingMember(userID: fixture.member.publicIdentity.userID, signedBy: fixture.owner)
        try fixture.center.receive(revoked)
        XCTAssertEqual(notifications, 1)
        switch try XCTUnwrap(accessAtNotification) {
        case .failure(let error): XCTAssertEqual(error as? NetworkAuthorityError, .notMember)
        default: XCTFail("Revocation observers must see access denied by the newly accepted policy")
        }

        // No observer notification for an unchanged or stale policy.
        try fixture.center.receive(revoked)
        try fixture.center.receive(fixture.manifest)
        XCTAssertEqual(notifications, 1)
        fixture.center.removeObserver(observer)
        try fixture.center.receive(revoked.renamed(to: "Renamed", signedBy: fixture.owner))
        XCTAssertEqual(notifications, 1)
    }

    func testLocalRepositoryRevocationReloadNotifiesAndRevokesAccess() throws {
        let fixture = try fixture()
        let authorization = try authorization(fixture)
        var notifications = 0
        let observer = fixture.center.observe { notifications += 1 }
        defer { fixture.center.removeObserver(observer) }
        let revoked = try fixture.repository.removeMember(userID: fixture.member.publicIdentity.userID,
            from: fixture.manifest.id, owner: fixture.owner)
        try fixture.center.reload()

        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(try fixture.center.snapshot().revision, revoked.revision)
        XCTAssertThrowsError(try authorization.validateCurrentAccess(fixture.member.publicIdentity))
    }

    func testSameCanonicalPolicyWithANewECDSASignatureIsNotEquivocation() throws {
        let fixture = try fixture()
        let resigned = try NetworkManifest.signed(id: fixture.manifest.id, generation: fixture.manifest.generation,
            revision: fixture.manifest.revision, name: fixture.manifest.name, owner: fixture.owner,
            members: fixture.manifest.members, channels: fixture.manifest.channels)
        var notifications = 0
        let observer = fixture.center.observe { notifications += 1 }
        defer { fixture.center.removeObserver(observer) }

        XCTAssertNoThrow(try fixture.center.receive(resigned))
        XCTAssertEqual(try fixture.center.snapshot().canonicalBytes(), try resigned.canonicalBytes())
        XCTAssertEqual(notifications, 0)
    }

    func testClaimsAndPolicyStorageContainNoUserRootCredentials() throws {
        let fixture = try fixture()
        let authorization = try authorization(fixture)
        let remote = try claim(fixture.manifest, root: fixture.member)
        XCTAssertNoThrow(try authorization.validate(remote, installationKeyHash: installationHash(2)))
        let wireData = try JSONEncoder().encode(remote)
        let diskURL = fixture.repository.directoryURL.appendingPathComponent(fixture.manifest.id.uuidString.lowercased() + ".json")
        let diskData = try Data(contentsOf: diskURL)

        for root in [fixture.owner, fixture.member] {
            // Export only newly generated in-memory test roots; no real Keychain is queried.
            let recovery = IdentityRecoveryDocument(identity: root).serializedData()
            let recoveryText = try XCTUnwrap(String(data: recovery, encoding: .utf8))
            let prefix = "Private-Key-P256-Raw-Base64: "
            let line = try XCTUnwrap(recoveryText.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }))
            let encodedSecret = Data(line.dropFirst(prefix.count).utf8)
            let rawSecret = try XCTUnwrap(Data(base64Encoded: encodedSecret))
            for publicPayload in [wireData, diskData] {
                XCTAssertNil(publicPayload.range(of: encodedSecret))
                XCTAssertNil(publicPayload.range(of: rawSecret))
                XCTAssertNil(publicPayload.range(of: Data(prefix.utf8)))
            }
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: wireData) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["manifest", "channelID", "device"])
        let decoded = try JSONDecoder().decode(NetworkPeerClaim.self, from: wireData)
        XCTAssertEqual(try authorization.validate(decoded, installationKeyHash: installationHash(2)), fixture.member.publicIdentity)
    }
}
