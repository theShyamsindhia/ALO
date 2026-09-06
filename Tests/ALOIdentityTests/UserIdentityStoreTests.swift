import Foundation
import XCTest
@testable import ALOIdentity

private final class MemoryIdentityStorage: UserIdentityKeyStorage {
    var bytes: Data?
    var readError: Error?
    var insertionError: Error?
    var reads = 0
    var insertions = 0
    var raceWinner: Data?
    var simulateMissingRaceWinner = false

    func loadPrivateKey() throws -> Data? {
        reads += 1
        if let readError { throw readError }
        return bytes
    }

    func insertPrivateKeyIfAbsent(_ candidate: Data) throws -> Bool {
        insertions += 1
        if let insertionError { throw insertionError }
        if simulateMissingRaceWinner { return false }
        if let raceWinner { bytes = raceWinner; return false }
        if bytes != nil { return false }
        bytes = candidate
        return true
    }
}

final class UserIdentityStoreTests: XCTestCase {
    func testStoreConstructionAndMissingLoadHaveNoCreationSideEffects() throws {
        let memory = MemoryIdentityStorage()
        let store = UserIdentityStore(storage: memory)
        XCTAssertEqual(memory.reads, 0)
        XCTAssertEqual(memory.insertions, 0)
        XCTAssertNil(try store.load())
        XCTAssertEqual(memory.insertions, 0)
    }

    func testOnboardingCreationIsStableAcrossStoreInstances() throws {
        let memory = MemoryIdentityStorage()
        let first = try UserIdentityStore(storage: memory).loadOrCreateForOnboarding()
        let second = try UserIdentityStore(storage: memory).loadOrCreateForOnboarding()
        XCTAssertEqual(first.publicIdentity, second.publicIdentity)
        XCTAssertEqual(memory.insertions, 1)
    }

    func testNonMissingReadErrorsFailClosedWithoutCreatingAReplacement() {
        let memory = MemoryIdentityStorage()
        memory.readError = UserIdentityError.keychain(-25308)
        XCTAssertThrowsError(try UserIdentityStore(storage: memory).loadOrCreateForOnboarding()) { error in
            XCTAssertEqual(error as? UserIdentityError, .keychain(-25308))
        }
        XCTAssertEqual(memory.insertions, 0)
        XCTAssertNil(memory.bytes)
    }

    func testCorruptStoredRootFailsClosed() {
        let memory = MemoryIdentityStorage()
        memory.bytes = Data(repeating: 0, count: 31)
        XCTAssertThrowsError(try UserIdentityStore(storage: memory).loadOrCreateForOnboarding())
        XCTAssertEqual(memory.insertions, 0)
        XCTAssertEqual(memory.bytes?.count, 31)
    }

    func testInsertionFailureDoesNotReturnAnUnpersistedIdentity() {
        let memory = MemoryIdentityStorage()
        memory.insertionError = UserIdentityError.keychain(-34018)
        XCTAssertThrowsError(try UserIdentityStore(storage: memory).loadOrCreateForOnboarding()) { error in
            XCTAssertEqual(error as? UserIdentityError, .keychain(-34018))
        }
        XCTAssertNil(memory.bytes)
    }

    func testConcurrentCreatorReturnsThePersistedWinner() throws {
        let memory = MemoryIdentityStorage()
        let winner = UserIdentity.ephemeral()
        memory.raceWinner = winner.rawPrivateKeyRepresentation
        let result = try UserIdentityStore(storage: memory).loadOrCreateForOnboarding()
        XCTAssertEqual(result.publicIdentity, winner.publicIdentity)
        XCTAssertEqual(memory.reads, 2)
    }

    func testMissingConcurrentWinnerFailsClosed() {
        let memory = MemoryIdentityStorage()
        memory.simulateMissingRaceWinner = true
        XCTAssertThrowsError(try UserIdentityStore(storage: memory).loadOrCreateForOnboarding()) { error in
            XCTAssertEqual(error as? UserIdentityError, .storageRace)
        }
    }

    func testRecoveryRestoresRootAndIsIdempotent() throws {
        let memory = MemoryIdentityStorage()
        let root = UserIdentity.ephemeral()
        let bytes = IdentityRecoveryDocument(identity: root).serializedData()
        let store = UserIdentityStore(storage: memory)
        XCTAssertEqual(try store.restoreForOnboarding(from: bytes).publicIdentity, root.publicIdentity)
        XCTAssertEqual(try store.restoreForOnboarding(from: bytes).publicIdentity, root.publicIdentity)
        XCTAssertEqual(memory.insertions, 1)
    }

    func testRecoveryNeverReplacesDifferentLocalRootIncludingInsertionRace() throws {
        let existing = UserIdentity.ephemeral()
        let recovery = IdentityRecoveryDocument(identity: .ephemeral()).serializedData()
        for simulateRace in [false, true] {
            let memory = MemoryIdentityStorage()
            if simulateRace { memory.raceWinner = existing.rawPrivateKeyRepresentation }
            else { memory.bytes = existing.rawPrivateKeyRepresentation }
            XCTAssertThrowsError(try UserIdentityStore(storage: memory).restoreForOnboarding(from: recovery)) { error in
                XCTAssertEqual(error as? UserIdentityError, .identityAlreadyExists)
            }
            XCTAssertEqual(try UserIdentityStore(storage: memory).load()?.publicIdentity, existing.publicIdentity)
        }
    }

    func testInvalidRecoveryDoesNotAccessStorage() {
        let memory = MemoryIdentityStorage()
        XCTAssertThrowsError(try UserIdentityStore(storage: memory).restoreForOnboarding(from: Data("invalid".utf8)))
        XCTAssertEqual(memory.reads, 0)
        XCTAssertEqual(memory.insertions, 0)
    }

    func testNamespacesAreExplicitSeparateAndValidatedWithoutKeychainAccess() throws {
        let production = try UserIdentityKeychainNamespace(applicationID: "in.alo.identity-test", environment: .production)
        let development = try UserIdentityKeychainNamespace(applicationID: "in.alo.identity-test", environment: .development)
        XCTAssertNotEqual(production.service, development.service)
        XCTAssertTrue(production.service.hasSuffix(".alo.user-root-v1"))
        XCTAssertThrowsError(try UserIdentityKeychainNamespace(applicationID: "bad namespace", environment: .development))
        XCTAssertThrowsError(try UserIdentityKeychainNamespace(applicationID: "ab", environment: .development))
        // Merely constructing a production backend has no Keychain side effect.
        _ = KeychainUserIdentityStorage(namespace: development)
    }
}
