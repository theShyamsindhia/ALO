import CryptoKit
import Foundation
import XCTest
@testable import ALOIdentity

final class UserIdentityTests: XCTestCase {
    func testRootIDIsDomainSeparatedAndPublicMetadataRoundTrips() throws {
        let root = UserIdentity.ephemeral()
        let identity = root.publicIdentity
        let digest = SHA256.hash(data: Data("ALO-USER-ROOT-ID-V1\0".utf8) + identity.publicKey)
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(identity.userID, "alo-user-v1:" + digest)
        XCTAssertEqual(identity.publicKey.count, 65)
        XCTAssertEqual(try JSONDecoder().decode(PublicUserIdentity.self, from: JSONEncoder().encode(identity)), identity)
        XCTAssertNotEqual(root.publicIdentity, UserIdentity.ephemeral().publicIdentity)
    }

    func testPublicMetadataRejectsForgedIDAndMalformedKey() throws {
        let root = UserIdentity.ephemeral()
        XCTAssertThrowsError(try PublicUserIdentity(userID: "forged", publicKey: root.publicIdentity.publicKey))
        XCTAssertThrowsError(try PublicUserIdentity(publicKey: Data(repeating: 4, count: 65)))
        XCTAssertThrowsError(try PublicUserIdentity(publicKey: root.publicIdentity.publicKey.prefix(64)))
        let encoded = try JSONEncoder().encode(root.publicIdentity)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["userID"] = "forged"
        XCTAssertThrowsError(try JSONDecoder().decode(PublicUserIdentity.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testSignatureCannotCrossDomainsRootsOrPayloads() throws {
        let root = UserIdentity.ephemeral()
        let payload = Data("network-manifest".utf8)
        let signature = try root.sign(payload, domain: "alo.network.manifest.v1")
        XCTAssertEqual(signature.count, 64)
        XCTAssertTrue(root.publicIdentity.verify(signature: signature, payload: payload, domain: "alo.network.manifest.v1"))
        XCTAssertFalse(root.publicIdentity.verify(signature: signature, payload: payload, domain: "alo.device.identity-binding.v1"))
        XCTAssertFalse(root.publicIdentity.verify(signature: signature, payload: payload + Data([0]), domain: "alo.network.manifest.v1"))
        XCTAssertFalse(UserIdentity.ephemeral().publicIdentity.verify(signature: signature, payload: payload, domain: "alo.network.manifest.v1"))
        XCTAssertFalse(root.publicIdentity.verify(signature: signature.prefix(63), payload: payload, domain: "alo.network.manifest.v1"))
    }

    func testSignatureDomainsAndPayloadsAreBounded() throws {
        let root = UserIdentity.ephemeral()
        for domain in ["", "other.network", "alo.", "alo.bad\0domain", "alo.🔑", "alo." + String(repeating: "a", count: 125)] {
            XCTAssertThrowsError(try root.sign(Data(), domain: domain))
            XCTAssertFalse(root.publicIdentity.verify(signature: Data(repeating: 0, count: 64), payload: Data(), domain: domain))
        }
        XCTAssertThrowsError(try root.sign(Data(repeating: 0, count: 1_048_577), domain: "alo.network.manifest.v1"))
    }

    func testCanonicalLengthPrefixesPreventBoundaryAmbiguity() throws {
        let left = try IdentityCanonicalEncoding.signingMessage(payload: Data("bc".utf8), domain: "alo.a")
        let right = try IdentityCanonicalEncoding.signingMessage(payload: Data("c".utf8), domain: "alo.ab")
        XCTAssertNotEqual(left, right)
    }

    func testOneRecoveredRootCanAuthorizeDistinctInstallations() throws {
        let root = UserIdentity.ephemeral()
        let recovered = try IdentityRecoveryDocument.restore(from: IdentityRecoveryDocument(identity: root).serializedData())
        let firstHash = Data(repeating: 1, count: 32)
        let secondHash = Data(repeating: 2, count: 32)
        let first = try DeviceIdentityBinding(user: root, deviceName: "Mac", generation: 1, installationPublicKeyHash: firstHash)
        let second = try DeviceIdentityBinding(user: recovered, deviceName: "Phone", generation: 2, installationPublicKeyHash: secondHash)
        XCTAssertEqual(first.userIdentity, second.userIdentity)
        XCTAssertNotEqual(first.bindingID, second.bindingID)
        XCTAssertNotEqual(first.installationPublicKeyHash, second.installationPublicKeyHash)
        XCTAssertNoThrow(try first.verify(expectedInstallationPublicKeyHash: firstHash))
        XCTAssertNoThrow(try second.verify(expectedInstallationPublicKeyHash: secondHash))
        XCTAssertThrowsError(try second.verify(expectedInstallationPublicKeyHash: firstHash))
    }

    func testBindingRequiresAll32BytesOfAuthenticatedInstallationHash() throws {
        let hash = Data(repeating: 1, count: 32)
        let binding = try DeviceIdentityBinding(user: .ephemeral(), deviceName: "Mac", generation: 1, installationPublicKeyHash: hash)
        var matchingShortID = hash
        matchingShortID[31] = 2
        XCTAssertThrowsError(try binding.verify(expectedInstallationPublicKeyHash: matchingShortID)) { error in
            XCTAssertEqual(error as? UserIdentityError, .installationKeyMismatch)
        }
        XCTAssertThrowsError(try binding.verify(expectedInstallationPublicKeyHash: hash.prefix(16)))
        let roundTrip = try JSONDecoder().decode(DeviceIdentityBinding.self, from: JSONEncoder().encode(binding))
        XCTAssertEqual(roundTrip, binding)
        XCTAssertNoThrow(try roundTrip.verify(expectedInstallationPublicKeyHash: hash))
    }

    func testEveryBindingAuthorizationFieldIsSigned() throws {
        let hash = Data(repeating: 1, count: 32)
        let binding = try DeviceIdentityBinding(user: .ephemeral(), deviceName: "Mac", generation: 1, installationPublicKeyHash: hash)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(binding)) as? [String: Any])
        let otherRoot = try JSONSerialization.jsonObject(with: JSONEncoder().encode(UserIdentity.ephemeral().publicIdentity))
        let changedHash = Data(repeating: 2, count: 32)
        let mutations: [(String, Any)] = [
            ("bindingID", UUID().uuidString), ("deviceName", "Other Mac"), ("generation", 2),
            ("installationPublicKeyHash", changedHash.base64EncodedString()), ("userIdentity", otherRoot),
            ("signature", Data(repeating: 0, count: 64).base64EncodedString())
        ]
        for (field, value) in mutations {
            var modified = original
            modified[field] = value
            let decoded = try JSONDecoder().decode(DeviceIdentityBinding.self, from: JSONSerialization.data(withJSONObject: modified))
            let expectedHash = field == "installationPublicKeyHash" ? changedHash : hash
            XCTAssertThrowsError(try decoded.verify(expectedInstallationPublicKeyHash: expectedHash), field)
        }
        var future = original
        future["version"] = 2
        XCTAssertThrowsError(try JSONDecoder().decode(DeviceIdentityBinding.self, from: JSONSerialization.data(withJSONObject: future)))
    }

    func testBindingRejectsInvalidMetadata() throws {
        let root = UserIdentity.ephemeral()
        let hash = Data(repeating: 1, count: 32)
        for name in ["", " Mac", "Mac\n", "Ma\0c", String(repeating: "🔑", count: 33)] {
            XCTAssertThrowsError(try DeviceIdentityBinding(user: root, deviceName: name, generation: 1, installationPublicKeyHash: hash))
        }
        XCTAssertThrowsError(try DeviceIdentityBinding(user: root, deviceName: "Mac", generation: 0, installationPublicKeyHash: hash))
        XCTAssertThrowsError(try DeviceIdentityBinding(user: root, deviceName: "Mac", generation: 1, installationPublicKeyHash: hash.prefix(31)))
    }
}
