import Foundation
import XCTest
@testable import ALOIdentity

final class IdentityRecoveryDocumentTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("alo-identity-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testRecoveryHasProminentWarningAndRestoresSameSigningRoot() throws {
        let root = UserIdentity.ephemeral()
        let bytes = IdentityRecoveryDocument(identity: root).serializedData()
        let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertTrue(text.contains(IdentityRecoveryDocument.warning))
        XCTAssertTrue(text.contains("**WARNING: THIS UNENCRYPTED FILE IS YOUR ACCOUNT CREDENTIAL.**"))
        XCTAssertTrue(text.contains("**Anyone with this file can impersonate you on every device.**"))
        XCTAssertTrue(text.contains("your identity cannot be recovered.**"))
        XCTAssertFalse(text.contains("<"))
        XCTAssertFalse(text.contains("https://"))
        XCTAssertLessThan(bytes.count, IdentityRecoveryDocument.maximumByteCount)
        let recovered = try IdentityRecoveryDocument.restore(from: bytes)
        XCTAssertEqual(root.publicIdentity, recovered.publicIdentity)
        let payload = Data("restored-device".utf8)
        XCTAssertTrue(root.publicIdentity.verify(signature: try recovered.sign(payload, domain: "alo.recovery.test.v1"),
                                                payload: payload, domain: "alo.recovery.test.v1"))
    }

    func testRecoveryRejectsRootMetadataThatDoesNotMatchPrivateKey() throws {
        let first = UserIdentity.ephemeral()
        let second = UserIdentity.ephemeral()
        let text = try XCTUnwrap(String(data: IdentityRecoveryDocument(identity: first).serializedData(), encoding: .utf8))
        let wrongID = text.replacingOccurrences(of: first.publicIdentity.userID, with: second.publicIdentity.userID)
        let wrongKey = text.replacingOccurrences(of: first.publicIdentity.publicKey.base64EncodedString(),
                                                with: second.publicIdentity.publicKey.base64EncodedString())
        let differentMetadata = wrongID.replacingOccurrences(of: first.publicIdentity.publicKey.base64EncodedString(),
                                                            with: second.publicIdentity.publicKey.base64EncodedString())
        for changed in [wrongID, wrongKey, differentMetadata] {
            XCTAssertThrowsError(try IdentityRecoveryDocument.restore(from: Data(changed.utf8)))
        }
    }

    func testRecoveryRejectsUnknownDuplicateMalformedAndOversizedContent() throws {
        let root = UserIdentity.ephemeral()
        let text = try XCTUnwrap(String(data: IdentityRecoveryDocument(identity: root).serializedData(), encoding: .utf8))
        let invalid = [
            text + "User-ID: duplicate\n", text + "<script>alert(1)</script>",
            text.replacingOccurrences(of: "recovery-v1", with: "recovery-v2"),
            text.replacingOccurrences(of: "User-ID: ", with: "Unknown: "),
            text.replacingOccurrences(of: IdentityRecoveryDocument.warning, with: "No warning"),
            text.replacingOccurrences(of: "\n", with: "\r\n"), String(text.dropLast()),
            text.replacingOccurrences(of: root.publicIdentity.publicKey.base64EncodedString(), with: "%%%"),
            text.replacingOccurrences(of: root.rawPrivateKeyRepresentation.base64EncodedString(), with: Data(repeating: 0, count: 32).base64EncodedString())
        ]
        for changed in invalid { XCTAssertThrowsError(try IdentityRecoveryDocument.restore(from: Data(changed.utf8))) }
        XCTAssertThrowsError(try IdentityRecoveryDocument.restore(from: Data(repeating: 65, count: 8_193)))
        XCTAssertThrowsError(try IdentityRecoveryDocument.restore(from: Data([0xff])))
    }

    func testExportCreatesOwnerOnlyCompleteFileAndRemovesTemporarySibling() throws {
        let root = UserIdentity.ephemeral()
        let destination = directory.appendingPathComponent("recovery.txt")
        let temporary = directory.appendingPathComponent("injected.tmp")
        let document = IdentityRecoveryDocument(identity: root)
        try document.export(to: destination, temporaryURL: temporary)
        XCTAssertEqual(try Data(contentsOf: destination), document.serializedData())
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertEqual(try IdentityRecoveryDocument.restore(fromFile: destination).publicIdentity, root.publicIdentity)
    }

    func testExportNeverOverwritesAnExistingFileAndCleansTemporaryCredential() throws {
        let destination = directory.appendingPathComponent("existing.txt")
        let temporary = directory.appendingPathComponent("injected.tmp")
        let original = Data("existing document".utf8)
        try original.write(to: destination)
        XCTAssertThrowsError(try IdentityRecoveryDocument(identity: .ephemeral()).export(to: destination, temporaryURL: temporary)) { error in
            XCTAssertEqual(error as? RecoveryExportError, .destinationExists)
        }
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
    }

    func testExportRejectsTemporaryCollisionsWithoutDeletingThem() throws {
        let destination = directory.appendingPathComponent("recovery.txt")
        let temporary = directory.appendingPathComponent("injected.tmp")
        let original = Data("reserved".utf8)
        try original.write(to: temporary)
        XCTAssertThrowsError(try IdentityRecoveryDocument(identity: .ephemeral()).export(to: destination, temporaryURL: temporary))
        XCTAssertEqual(try Data(contentsOf: temporary), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testExportDoesNotFollowDestinationOrTemporarySymlinks() throws {
        let victim = directory.appendingPathComponent("victim.txt")
        let destination = directory.appendingPathComponent("recovery.txt")
        let temporary = directory.appendingPathComponent("injected.tmp")
        let original = Data("unchanged".utf8)
        try original.write(to: victim)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: victim)
        XCTAssertThrowsError(try IdentityRecoveryDocument(identity: .ephemeral()).export(to: destination, temporaryURL: temporary))
        XCTAssertEqual(try Data(contentsOf: victim), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        try FileManager.default.createSymbolicLink(at: temporary, withDestinationURL: victim)
        XCTAssertThrowsError(try IdentityRecoveryDocument(identity: .ephemeral()).export(to: directory.appendingPathComponent("second.txt"), temporaryURL: temporary))
        XCTAssertEqual(try Data(contentsOf: victim), original)
    }

    func testFileImportRejectsSymlinksDirectoriesAndOversizedFiles() throws {
        let destination = directory.appendingPathComponent("recovery.txt")
        let link = directory.appendingPathComponent("link.txt")
        try IdentityRecoveryDocument(identity: .ephemeral()).export(to: destination)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        XCTAssertThrowsError(try IdentityRecoveryDocument.restore(fromFile: link))
        XCTAssertThrowsError(try IdentityRecoveryDocument.restore(fromFile: directory))
        let oversized = directory.appendingPathComponent("oversized.txt")
        try Data(repeating: 65, count: 8_193).write(to: oversized)
        XCTAssertThrowsError(try IdentityRecoveryDocument.restore(fromFile: oversized))
    }

    func testExportRejectsInvalidOrNonSiblingURLs() throws {
        let document = IdentityRecoveryDocument(identity: .ephemeral())
        let destination = directory.appendingPathComponent("recovery.txt")
        XCTAssertThrowsError(try document.export(to: URL(string: "https://example.invalid/recovery")!))
        XCTAssertThrowsError(try document.export(to: destination, temporaryURL: destination))
        XCTAssertThrowsError(try document.export(to: destination, temporaryURL: directory.deletingLastPathComponent().appendingPathComponent("elsewhere.tmp")))
    }
}
