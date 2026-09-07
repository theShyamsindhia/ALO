import XCTest
import ALOIdentity
import ALORooms
@testable import ALONetworking

final class NearbyNetworkJoinTests: XCTestCase {
    func testWireRejectsInvalidVersionsOversizedFramesAndMalformedJSON() throws {
        XCTAssertEqual(try NearbyNetworkService.frameLength(Data([0, 0, 32, 0]), limit: 8192), 8192)
        for header in [Data(), Data([0, 0, 0, 0]), Data([0, 0, 32, 1]), Data([255, 255, 255, 255])] {
            XCTAssertThrowsError(try NearbyNetworkService.frameLength(header, limit: 8192))
        }
        let message = NearbyNetworkService.Message(kind: "request", networkID: UUID())
        let valid = try JSONEncoder().encode(message)
        XCTAssertNoThrow(try NearbyNetworkService.decodeMessage(valid, limit: 8192))
        XCTAssertThrowsError(try NearbyNetworkService.decodeMessage(valid, limit: valid.count - 1))
        var future = message; future.version = 2
        XCTAssertThrowsError(try NearbyNetworkService.decodeMessage(JSONEncoder().encode(future), limit: 8192))
        XCTAssertThrowsError(try NearbyNetworkService.decodeMessage(Data("garbage".utf8), limit: 8192))
    }
    private final class Requests: @unchecked Sendable {
        let lock = NSLock()
        var requests = [NearbyNetworkJoinRequest]()
        func set(_ value: [NearbyNetworkJoinRequest]) { lock.lock(); requests = value; lock.unlock() }
        var first: NearbyNetworkJoinRequest? { lock.lock(); defer { lock.unlock() }; return requests.first }
    }

    func testLoopbackOwnerApprovalReturnsSignedInvitation() async throws {
        let owner = UserIdentity.ephemeral(), requester = UserIdentity.ephemeral()
        let manifest = try NetworkManifest.create(name: "Loopback network", owner: owner)
        let received = expectation(description: "Authenticated request arrives"), requests = Requests()
        let ownerService = try NearbyNetworkService(user: owner, displayName: "Owner", changed: { _ in },
            requestsChanged: { value in requests.set(value); if !value.isEmpty { received.fulfill() } }, failed: { _ in })
        let requesterService = try NearbyNetworkService(user: requester, displayName: "Requester", changed: { _ in },
            requestsChanged: { _ in }, failed: { _ in })
        defer { ownerService.stop(); requesterService.stop() }
        let endpoint = try await ownerService.listenOnLoopback(network: manifest)
        let result = Task { try await requesterService.request(network: NearbyNetwork(id: manifest.id,
            name: manifest.name, ownerID: owner.publicIdentity.userID), endpoint: endpoint) }
        defer { result.cancel() }
        await fulfillment(of: [received], timeout: 15)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.identity, requester.publicIdentity)
        XCTAssertEqual(request.displayName, "Requester")
        XCTAssertThrowsError(try manifest.authorize(request.identity, channelID: manifest.mainChannel.id))
        let approved = try manifest.addingMember(request.identity, signedBy: owner)
        ownerService.respond(id: request.id, invitation: try NetworkInvitation(manifest: approved, recipient: request.identity))
        let invitation = try await result.value
        XCTAssertEqual(invitation.manifest, approved)
        XCTAssertEqual(invitation.recipient, requester.publicIdentity)
    }

    func testLoopbackRejectAndCancelDoNotGrantMembership() async throws {
        for cancel in [false, true] {
            let owner = UserIdentity.ephemeral(), requester = UserIdentity.ephemeral()
            let manifest = try NetworkManifest.create(name: "No admission", owner: owner)
            let received = expectation(description: "Authenticated request arrives"), requests = Requests()
            let server = try NearbyNetworkService(user: owner, displayName: "Owner", changed: { _ in },
                requestsChanged: { value in requests.set(value); if !value.isEmpty { received.fulfill() } }, failed: { _ in })
            let client = try NearbyNetworkService(user: requester, displayName: "Requester", changed: { _ in },
                requestsChanged: { _ in }, failed: { _ in })
            defer { server.stop(); client.stop() }
            let endpoint = try await server.listenOnLoopback(network: manifest)
            let result = Task { try await client.request(network: NearbyNetwork(id: manifest.id,
                name: manifest.name, ownerID: owner.publicIdentity.userID), endpoint: endpoint) }
            defer { result.cancel() }
            await fulfillment(of: [received], timeout: 15)
            let request = try XCTUnwrap(requests.first)
            if cancel { result.cancel() } else { server.respond(id: request.id, invitation: nil) }
            do { _ = try await result.value; XCTFail("No invitation should be returned") }
            catch { if cancel { XCTAssertTrue(error is CancellationError) } }
            XCTAssertFalse(manifest.isMember(requester.publicIdentity))
        }
    }

    func testRequestProofRequiresSameNetworkChallengeAndTLSDevice() throws {
        let user = UserIdentity.ephemeral(), network = UUID(), nonce = UUID()
        let hash = Data(repeating: 42, count: 32)
        let device = try DeviceIdentityBinding(user: user, deviceName: "Requester", generation: 1,
            installationPublicKeyHash: hash)
        let proof = try NearbyNetworkJoinProof(user: user, device: device, networkID: network, nonce: nonce)
        try proof.verify(networkID: network, nonce: nonce, installationHash: hash)
        XCTAssertThrowsError(try proof.verify(networkID: UUID(), nonce: nonce, installationHash: hash))
        XCTAssertThrowsError(try proof.verify(networkID: network, nonce: UUID(), installationHash: hash))
        XCTAssertThrowsError(try proof.verify(networkID: network, nonce: nonce, installationHash: Data(repeating: 7, count: 32)))
    }

    func testRequestCannotSubstituteAnotherRoot() throws {
        let owner = UserIdentity.ephemeral(), attacker = UserIdentity.ephemeral()
        let device = try DeviceIdentityBinding(user: owner, deviceName: "Owner", generation: 1,
            installationPublicKeyHash: Data(repeating: 1, count: 32))
        XCTAssertThrowsError(try NearbyNetworkJoinProof(user: attacker, device: device, networkID: UUID(), nonce: UUID()))
    }

    func testRequestProofRoundTripRejectsSignatureTampering() throws {
        let user = UserIdentity.ephemeral(), network = UUID(), nonce = UUID(), hash = Data(repeating: 4, count: 32)
        let device = try DeviceIdentityBinding(user: user, deviceName: "New member", generation: 1, installationPublicKeyHash: hash)
        let proof = try NearbyNetworkJoinProof(user: user, device: device, networkID: network, nonce: nonce)
        let data = try JSONEncoder().encode(proof)
        try JSONDecoder().decode(NearbyNetworkJoinProof.self, from: data).verify(networkID: network, nonce: nonce, installationHash: hash)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["signature"] = Data(repeating: 0, count: 64).base64EncodedString()
        let tampered = try JSONDecoder().decode(NearbyNetworkJoinProof.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try tampered.verify(networkID: network, nonce: nonce, installationHash: hash))
    }

    func testProofAndDiscoveryNeverGrantMainChannelMembership() throws {
        let owner = UserIdentity.ephemeral(), requester = UserIdentity.ephemeral()
        let manifest = try NetworkManifest.create(name: "Nearby", owner: owner)
        let device = try DeviceIdentityBinding(user: requester, deviceName: "Requester", generation: 1,
            installationPublicKeyHash: Data(repeating: 1, count: 32))
        _ = try NearbyNetworkJoinProof(user: requester, device: device, networkID: manifest.id, nonce: UUID())
        _ = NearbyNetwork(id: manifest.id, name: manifest.name, ownerID: owner.publicIdentity.userID)
        XCTAssertThrowsError(try manifest.authorize(requester.publicIdentity, channelID: manifest.mainChannel.id))
        XCTAssertThrowsError(try NetworkInvitation(manifest: manifest, recipient: requester.publicIdentity))
        let approved = try manifest.addingMember(requester.publicIdentity, signedBy: owner)
        let invitation = try NetworkInvitation(manifest: approved, recipient: requester.publicIdentity)
        XCTAssertNoThrow(try invitation.manifest.authorize(requester.publicIdentity, channelID: manifest.mainChannel.id))
    }
}
