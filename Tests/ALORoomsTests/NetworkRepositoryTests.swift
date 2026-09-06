import Foundation
import Darwin
import Testing
import ALOIdentity
@testable import ALORooms

@Suite("Offline network repository")
struct NetworkRepositoryTests {
    @Test func corruptRecordDoesNotHideAnotherVerifiedNetwork() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = UserIdentity.ephemeral()
        let repository = NetworkRepository(directoryURL: directory)
        let broken = try repository.create(name: "Broken", owner: owner)
        let healthy = try repository.create(name: "Healthy", owner: owner)
        let brokenURL = directory.appendingPathComponent(broken.id.uuidString.lowercased() + ".json")
        try Data("truncated record".utf8).write(to: brokenURL)
        #expect(try repository.networks(for: owner.publicIdentity) == [healthy])
        let listing = try repository.listing(for: owner.publicIdentity)
        #expect(listing.networks == [healthy])
        #expect(listing.diagnostics.map(\.networkID) == [broken.id])
        #expect(listing.diagnostics.first?.reason == .unreadableOrInvalid)
        #expect(listing.unavailableRecordCount == 1 && listing.omittedDiagnosticCount == 0)
        #expect(throws: (any Error).self) { try repository.trustedManifest(id: broken.id) }
        #expect(throws: (any Error).self) { try repository.network(id: broken.id, for: owner.publicIdentity) }
        #expect(try repository.trustedManifest(id: healthy.id) == healthy)
    }

    @Test func listingSkipsSymlinksDirectoriesFIFOsOversizedAndInvalidSignatureRecords() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = UserIdentity.ephemeral()
        let repository = NetworkRepository(directoryURL: directory)
        let healthy = try repository.create(name: "Healthy", owner: owner)
        let signatureFailure = try repository.create(name: "Bad signature", owner: owner)
        let badSignatureURL = directory.appendingPathComponent(signatureFailure.id.uuidString.lowercased() + ".json")
        var record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: badSignatureURL)) as? [String: Any])
        var manifest = try #require(record["manifest"] as? [String: Any])
        manifest["signature"] = Data(repeating: 0, count: 64).base64EncodedString()
        record["manifest"] = manifest
        try JSONSerialization.data(withJSONObject: record).write(to: badSignatureURL)
        let otherFailures = (0..<4).map { _ in UUID() }
        let locations = otherFailures.map { directory.appendingPathComponent($0.uuidString.lowercased() + ".json") }
        try FileManager.default.createSymbolicLink(at: locations[0], withDestinationURL: badSignatureURL)
        try FileManager.default.createDirectory(at: locations[1], withIntermediateDirectories: false)
        #expect(mkfifo(locations[2].path, mode_t(0o600)) == 0)
        try Data(repeating: 0, count: 600_000).write(to: locations[3])

        let listing = try repository.listing(for: owner.publicIdentity)
        #expect(listing.networks == [healthy])
        #expect(Set(listing.diagnostics.map(\.networkID)) == Set(otherFailures + [signatureFailure.id]))
        #expect(listing.diagnostics.allSatisfy { $0.reason == .unreadableOrInvalid })
        for id in otherFailures + [signatureFailure.id] {
            #expect(throws: (any Error).self) { try repository.trustedManifest(id: id) }
        }
    }

    @Test func listingDiagnosticsAreBoundedAndDoNotPersistAcrossARepairedScan() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = UserIdentity.ephemeral()
        let repository = NetworkRepository(directoryURL: directory)
        let healthy = try repository.create(name: "Healthy", owner: owner)
        let count = NetworkRepository.maximumListingDiagnostics + 5
        let files = (0..<count).map { _ in directory.appendingPathComponent(UUID().uuidString.lowercased() + ".json") }
        for file in files { try Data("invalid fixture record".utf8).write(to: file) }
        let listing = try repository.listing(for: owner.publicIdentity)
        #expect(listing.networks == [healthy])
        #expect(listing.diagnostics.count == NetworkRepository.maximumListingDiagnostics)
        #expect(listing.omittedDiagnosticCount == 5 && listing.unavailableRecordCount == count)
        for file in files { try FileManager.default.removeItem(at: file) }
        let repaired = try repository.listing(for: owner.publicIdentity)
        #expect(repaired.networks == [healthy] && repaired.diagnostics.isEmpty && repaired.omittedDiagnosticCount == 0)
    }

    @Test func storesOnlyNewNamespaceAndRoundTripsThroughFreshRepository() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyURL = directory.appendingPathComponent("rooms.json")
        let legacy = Data("legacy data must remain untouched".utf8)
        try legacy.write(to: legacyURL)
        let owner = UserIdentity.ephemeral()
        let repository = NetworkRepository(directoryURL: directory.appendingPathComponent(NetworkRepository.storageNamespace))
        let created = try repository.create(name: "Local", owner: owner)
        let reloaded = NetworkRepository(directoryURL: repository.directoryURL)
        #expect(try reloaded.network(id: created.id, for: owner.publicIdentity) == created)
        #expect(try reloaded.networks(for: owner.publicIdentity) == [created])
        #expect(try Data(contentsOf: legacyURL) == legacy)
        let filenames = try FileManager.default.contentsOfDirectory(atPath: repository.directoryURL.path)
        #expect(Set(filenames) == Set([".repository.lock", created.id.uuidString.lowercased() + ".json"]))
    }

    @Test func importsRequireExplicitMembershipAndCorrectInvitationRecipient() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = UserIdentity.ephemeral()
        let member = UserIdentity.ephemeral()
        let outsider = UserIdentity.ephemeral()
        let repository = NetworkRepository(directoryURL: directory)
        let manifest = try NetworkManifest.create(name: "Invite", owner: owner)
            .addingMember(member.publicIdentity, signedBy: owner)
        let invitation = try NetworkInvitation(manifest: manifest, recipient: member.publicIdentity)
        #expect(throws: NetworkAuthorityError.notMember) { try repository.accept(manifest, for: outsider.publicIdentity) }
        #expect(throws: NetworkAuthorityError.wrongRecipient) {
            try repository.importInvitation(invitation, for: outsider.publicIdentity)
        }
        #expect(try repository.importInvitation(invitation, for: member.publicIdentity) == manifest)
    }

    @Test func rejectsRollbackOwnerSubstitutionAndGenerationResetAfterReload() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = UserIdentity.ephemeral()
        let attacker = UserIdentity.ephemeral()
        let repository = NetworkRepository(directoryURL: directory)
        let first = try repository.create(name: "Pinned", owner: owner)
        let current = try repository.rename(id: first.id, to: "Current", owner: owner)
        let reloaded = NetworkRepository(directoryURL: directory)
        #expect(throws: NetworkAuthorityError.rollback) { try reloaded.accept(first, for: owner.publicIdentity) }
        let replacedOwner = try NetworkManifest.signed(id: first.id, generation: first.generation, revision: 3,
            name: "Substitution", owner: attacker,
            members: [NetworkMember(identity: attacker.publicIdentity, role: .owner)], channels: first.channels)
        #expect(throws: NetworkAuthorityError.ownerChanged) {
            try reloaded.accept(replacedOwner, for: attacker.publicIdentity)
        }
        let replacedGeneration = try NetworkManifest.signed(id: first.id, generation: UUID(), revision: 3,
            name: "Reset", owner: owner, members: first.members, channels: first.channels)
        #expect(throws: NetworkAuthorityError.generationChanged) {
            try reloaded.accept(replacedGeneration, for: owner.publicIdentity)
        }
        #expect(try reloaded.trustedManifest(id: first.id) == current)
    }

    @Test func equalPolicyWithDifferentSignatureIsIdempotent() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = UserIdentity.ephemeral()
        let repository = NetworkRepository(directoryURL: directory)
        let first = try repository.create(name: "Same policy", owner: owner)
        let resigned = try NetworkManifest.signed(id: first.id, generation: first.generation, revision: first.revision,
            name: first.name, owner: owner, members: first.members, channels: first.channels)
        #expect(try repository.accept(resigned, for: owner.publicIdentity) == first)
        #expect(try repository.networks(for: owner.publicIdentity) == [first])
    }

    @Test func concurrentConflictingRevisionQuarantinesPersistently() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = UserIdentity.ephemeral()
        let firstRepository = NetworkRepository(directoryURL: directory)
        let secondRepository = NetworkRepository(directoryURL: directory)
        let initial = try firstRepository.create(name: "Initial", owner: owner)
        let firstBranch = try initial.renamed(to: "First device", signedBy: owner)
        let secondBranch = try initial.renamed(to: "Second device", signedBy: owner)
        let publicIdentity = owner.publicIdentity
        let errors = await withTaskGroup(of: NetworkAuthorityError?.self) { group in
            for (repository, branch) in [(firstRepository, firstBranch), (secondRepository, secondBranch)] {
                group.addTask {
                    do { try repository.accept(branch, for: publicIdentity); return nil }
                    catch let error as NetworkAuthorityError { return error }
                    catch { return .invalidStorage }
                }
            }
            var results = [NetworkAuthorityError?]()
            for await result in group { results.append(result) }
            return results
        }
        #expect(errors.filter { $0 == nil }.count == 1)
        #expect(errors.compactMap { $0 } == [.revisionConflict])
        let reloaded = NetworkRepository(directoryURL: directory)
        #expect(throws: NetworkAuthorityError.quarantined) { try reloaded.trustedManifest(id: initial.id) }
        #expect(try reloaded.networks(for: owner.publicIdentity).isEmpty)
        let listing = try reloaded.listing(for: owner.publicIdentity)
        #expect(listing.diagnostics.map(\.networkID) == [initial.id])
        #expect(listing.diagnostics.first?.reason == .quarantined)
        let higher = try firstBranch.renamed(to: "Cannot clear conflict", signedBy: owner)
        #expect(throws: NetworkAuthorityError.quarantined) { try reloaded.accept(higher, for: owner.publicIdentity) }
    }

    @Test func knownNetworkPersistsRevocationAndDeniesSubsequentAccess() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = UserIdentity.ephemeral()
        let member = UserIdentity.ephemeral()
        let repository = NetworkRepository(directoryURL: directory)
        let granted = try NetworkManifest.create(name: "Revocation", owner: owner)
            .addingMember(member.publicIdentity, signedBy: owner)
        try repository.accept(granted, for: member.publicIdentity)
        let revoked = try granted.removingMember(userID: member.publicIdentity.userID, signedBy: owner)
        #expect(try repository.acceptUpdate(revoked, anchoredTo: granted) == revoked)
        let reloaded = NetworkRepository(directoryURL: directory)
        #expect(try reloaded.trustedManifest(id: granted.id) == revoked)
        #expect(try reloaded.networks(for: member.publicIdentity).isEmpty)
        #expect(throws: NetworkAuthorityError.notMember) { try reloaded.network(id: granted.id, for: member.publicIdentity) }
        #expect(throws: NetworkAuthorityError.rollback) { try reloaded.accept(granted, for: member.publicIdentity) }
    }

    @Test func transportUpdatesNeverEstablishNewTrustAndCannotUseForeignAnchor() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = UserIdentity.ephemeral()
        let attacker = UserIdentity.ephemeral()
        let repository = NetworkRepository(directoryURL: directory)
        let unknown = try NetworkManifest.create(name: "Unknown", owner: owner)
        #expect(throws: NetworkAuthorityError.networkNotFound) { try repository.acceptUpdate(unknown, anchoredTo: unknown) }
        try repository.accept(unknown, for: owner.publicIdentity)
        let foreign = try NetworkManifest.signed(id: unknown.id, generation: unknown.generation, revision: 2,
            name: "Forged anchor", owner: attacker,
            members: [NetworkMember(identity: attacker.publicIdentity, role: .owner)], channels: unknown.channels)
        #expect(throws: NetworkAuthorityError.ownerChanged) { try repository.acceptUpdate(foreign, anchoredTo: foreign) }
        #expect(throws: NetworkAuthorityError.ownerChanged) { try repository.acceptUpdate(foreign, anchoredTo: unknown) }
        let other = try NetworkManifest.create(name: "Another network", owner: owner)
        #expect(throws: NetworkAuthorityError.invalidIdentifier) { try repository.acceptUpdate(other, anchoredTo: unknown) }
    }

    @Test func ownerMutationsCheckExpectedRevisionAndPersistPrivateAccessChanges() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = UserIdentity.ephemeral()
        let member = UserIdentity.ephemeral()
        let repository = NetworkRepository(directoryURL: directory)
        let initial = try repository.create(name: "Edits", owner: owner)
        let granted = try repository.addMember(member.publicIdentity, to: initial.id, owner: owner, expectedRevision: 1)
        #expect(throws: NetworkAuthorityError.unexpectedRevision) {
            try repository.createChannel(name: "Stale", in: initial.id, owner: owner, expectedRevision: 1)
        }
        let privatePolicy = try repository.createChannel(name: "Private", in: initial.id, owner: owner,
            visibility: .privateMembers, allowedUserIDs: [member.publicIdentity.userID], expectedRevision: granted.revision)
        let privateChannel = try #require(privatePolicy.channels.first(where: { $0.isPrivate }))
        #expect(try privatePolicy.authorize(member.publicIdentity, channelID: privateChannel.id) == privateChannel)
        let ownerOnly = try NetworkChannel(id: privateChannel.id, name: privateChannel.name, visibility: .privateMembers)
        let updated = try repository.updateChannel(ownerOnly, in: initial.id, owner: owner)
        #expect(throws: NetworkAuthorityError.channelAccessDenied) {
            try updated.authorize(member.publicIdentity, channelID: privateChannel.id)
        }
        #expect(throws: NetworkAuthorityError.ownerRequired) {
            try repository.rename(id: initial.id, to: "Member edit", owner: member)
        }
        #expect(try repository.removeChannel(id: privateChannel.id, from: initial.id, owner: owner).channels.count == 1)
    }

    @Test func symbolicLinkRecordsDoNotBecomeNetworkAuthority() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = UserIdentity.ephemeral()
        let manifest = try NetworkManifest.create(name: "Links", owner: owner)
        let target = directory.appendingPathComponent("outside.json")
        let sentinel = Data("do not replace".utf8)
        try sentinel.write(to: target)
        let networkDirectory = directory.appendingPathComponent("networks")
        try FileManager.default.createDirectory(at: networkDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: networkDirectory.appendingPathComponent(manifest.id.uuidString.lowercased() + ".json"),
                                                  withDestinationURL: target)
        let repository = NetworkRepository(directoryURL: networkDirectory)
        #expect(throws: NetworkAuthorityError.invalidStorage) { try repository.accept(manifest, for: owner.publicIdentity) }
        #expect(try Data(contentsOf: target) == sentinel)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("alo-network-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
