import Foundation
import Darwin
import ALOIdentity

/// Public policy storage in a fresh namespace. Files contain no identity secrets.
/// A directory lock serializes read/compare/write across repository instances and
/// processes; each network, including its conflict evidence, is replaced atomically.
public final class NetworkRepository: @unchecked Sendable {
    public static let storageNamespace = "networks-v1"
    public static let maximumListingDiagnostics = 16

    public struct RecordDiagnostic: Equatable, Sendable {
        public enum Reason: Equatable, Sendable { case unreadableOrInvalid, quarantined }
        public let networkID: UUID
        public let reason: Reason
    }

    /// Diagnostics contain validated record IDs and fixed reasons, never untrusted file contents.
    public struct Listing: Sendable {
        public let networks: [NetworkManifest]
        public let diagnostics: [RecordDiagnostic]
        public let omittedDiagnosticCount: Int
        public var unavailableRecordCount: Int { diagnostics.count + omittedDiagnosticCount }
    }
    public let directoryURL: URL
    private let lock = NSLock()
    // Also fail closed in this instance if persisting conflict evidence fails.
    private var observedConflicts = Set<UUID>()

    private struct Record: Codable {
        let storageVersion: Int
        let manifest: NetworkManifest
        let conflictingManifest: NetworkManifest?

        init(manifest: NetworkManifest, conflictingManifest: NetworkManifest? = nil) {
            storageVersion = 1
            self.manifest = manifest
            self.conflictingManifest = conflictingManifest
        }
    }

    public init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directoryURL = directoryURL.standardizedFileURL
        } else {
            let applicationDirectory = Bundle.main.bundleIdentifier == "in.werai.audio.dev" ? "WERAI-Dev" : "WERAI"
            self.directoryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(applicationDirectory, isDirectory: true)
                .appendingPathComponent(Self.storageNamespace, isDirectory: true)
        }
    }

    @discardableResult
    public func create(name: String, owner: UserIdentity) throws -> NetworkManifest {
        try withLock {
            let manifest = try NetworkManifest.create(name: name, owner: owner)
            guard try readRecord(id: manifest.id) == nil else { throw NetworkAuthorityError.revisionConflict }
            try writeRecord(Record(manifest: manifest))
            return manifest
        }
    }

    /// Unknown networks require an explicit member-bound invitation/import.
    /// For a known network, a newer owner-signed revocation is retained even if it
    /// removes the local user; subsequent access queries then return notMember.
    @discardableResult
    public func accept(_ manifest: NetworkManifest, for localIdentity: PublicUserIdentity) throws -> NetworkManifest {
        try withLock { try acceptLocked(manifest, for: localIdentity) }
    }

    /// Policy inspection for the transport's existing trust anchor. This does not
    /// authorize the caller for a channel; use manifest.authorize for that check.
    public func trustedManifest(id: UUID) throws -> NetworkManifest {
        try withLock { try activeManifest(id: id) }
    }

    /// Transport policy refresh: cannot introduce a network or replace its root.
    /// A cached anchor may be older than disk; disk still determines rollback and
    /// equivocation checks, including updates that revoke the local identity.
    @discardableResult
    public func acceptUpdate(_ manifest: NetworkManifest, anchoredTo anchor: NetworkManifest) throws -> NetworkManifest {
        try withLock {
            try anchor.validateSignature()
            let current = try activeManifest(id: anchor.id)
            guard manifest.id == anchor.id else { throw NetworkAuthorityError.invalidIdentifier }
            guard current.owner == anchor.owner else { throw NetworkAuthorityError.ownerChanged }
            guard current.generation == anchor.generation else { throw NetworkAuthorityError.generationChanged }
            return try acceptLocked(manifest, for: nil, requiresKnownNetwork: true)
        }
    }

    @discardableResult
    public func importInvitation(_ invitation: NetworkInvitation,
                                 for localIdentity: PublicUserIdentity) throws -> NetworkManifest {
        guard invitation.recipient == localIdentity else { throw NetworkAuthorityError.wrongRecipient }
        return try accept(invitation.manifest, for: localIdentity)
    }

    public func network(id: UUID, for authenticatedIdentity: PublicUserIdentity) throws -> NetworkManifest {
        try withLock {
            let manifest = try activeManifest(id: id)
            guard manifest.isMember(authenticatedIdentity) else { throw NetworkAuthorityError.notMember }
            return manifest
        }
    }

    /// Revoked and quarantined networks never appear as usable networks.
    public func networks(for authenticatedIdentity: PublicUserIdentity) throws -> [NetworkManifest] {
        try listing(for: authenticatedIdentity).networks
    }

    /// A failed individual record cannot hide independent verified networks. Directory-level
    /// failures still throw, and direct trusted/active reads retain their strict failure behavior.
    public func listing(for authenticatedIdentity: PublicUserIdentity) throws -> Listing {
        try withLock {
            let files = try FileManager.default.contentsOfDirectory(at: directoryURL,
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            var manifests = [NetworkManifest]()
            var diagnostics = [RecordDiagnostic]()
            var omittedDiagnosticCount = 0
            func recordFailure(_ id: UUID, _ reason: RecordDiagnostic.Reason) {
                if diagnostics.count < Self.maximumListingDiagnostics {
                    diagnostics.append(RecordDiagnostic(networkID: id, reason: reason))
                } else { omittedDiagnosticCount += 1 }
            }
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "json" {
                let stem = file.deletingPathExtension().lastPathComponent
                guard let id = UUID(uuidString: stem), filename(id: id) == file.lastPathComponent else { continue }
                if observedConflicts.contains(id) { recordFailure(id, .quarantined); continue }
                do {
                    guard let record = try readRecord(id: id) else { continue }
                    guard record.conflictingManifest == nil else { recordFailure(id, .quarantined); continue }
                    if record.manifest.isMember(authenticatedIdentity) { manifests.append(record.manifest) }
                } catch { recordFailure(id, .unreadableOrInvalid) }
            }
            let networks = manifests.sorted {
                $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name < $1.name
            }
            return Listing(networks: networks, diagnostics: diagnostics, omittedDiagnosticCount: omittedDiagnosticCount)
        }
    }

    @discardableResult
    public func addMember(_ member: PublicUserIdentity, to networkID: UUID, owner: UserIdentity,
                          expectedRevision: UInt64? = nil) throws -> NetworkManifest {
        try update(id: networkID, owner: owner, expectedRevision: expectedRevision) {
            try $0.addingMember(member, signedBy: owner)
        }
    }

    @discardableResult
    public func removeMember(userID: String, from networkID: UUID, owner: UserIdentity,
                             expectedRevision: UInt64? = nil) throws -> NetworkManifest {
        try update(id: networkID, owner: owner, expectedRevision: expectedRevision) {
            try $0.removingMember(userID: userID, signedBy: owner)
        }
    }

    @discardableResult
    public func createChannel(name: String, in networkID: UUID, owner: UserIdentity,
                              visibility: NetworkChannelVisibility = .publicToMembers,
                              allowedUserIDs: [String] = [], expectedRevision: UInt64? = nil) throws -> NetworkManifest {
        let channel = try NetworkChannel(name: name, visibility: visibility, allowedUserIDs: allowedUserIDs)
        return try update(id: networkID, owner: owner, expectedRevision: expectedRevision) {
            try $0.addingChannel(channel, signedBy: owner)
        }
    }

    @discardableResult
    public func updateChannel(_ channel: NetworkChannel, in networkID: UUID, owner: UserIdentity,
                              expectedRevision: UInt64? = nil) throws -> NetworkManifest {
        try update(id: networkID, owner: owner, expectedRevision: expectedRevision) {
            try $0.updatingChannel(channel, signedBy: owner)
        }
    }

    @discardableResult
    public func removeChannel(id channelID: UUID, from networkID: UUID, owner: UserIdentity,
                              expectedRevision: UInt64? = nil) throws -> NetworkManifest {
        try update(id: networkID, owner: owner, expectedRevision: expectedRevision) {
            try $0.removingChannel(id: channelID, signedBy: owner)
        }
    }

    @discardableResult
    public func rename(id networkID: UUID, to name: String, owner: UserIdentity,
                       expectedRevision: UInt64? = nil) throws -> NetworkManifest {
        try update(id: networkID, owner: owner, expectedRevision: expectedRevision) {
            try $0.renamed(to: name, signedBy: owner)
        }
    }

    /// Exports the current accepted policy, bound to one already-granted member.
    /// The recipient must verify the owner's fingerprint over the exchange channel
    /// on first import; a self-signed manifest cannot establish external trust.
    public func invitation(networkID: UUID, for recipient: PublicUserIdentity,
                           owner: UserIdentity) throws -> NetworkInvitation {
        try withLock {
            let manifest = try activeManifest(id: networkID)
            guard manifest.owner == owner.publicIdentity else { throw NetworkAuthorityError.ownerRequired }
            return try NetworkInvitation(manifest: manifest, recipient: recipient)
        }
    }

    private func update(id: UUID, owner: UserIdentity, expectedRevision: UInt64?,
                        transform: (NetworkManifest) throws -> NetworkManifest) throws -> NetworkManifest {
        try withLock {
            let current = try activeManifest(id: id)
            guard current.owner == owner.publicIdentity else { throw NetworkAuthorityError.ownerRequired }
            if let expectedRevision, expectedRevision != current.revision { throw NetworkAuthorityError.unexpectedRevision }
            let updated = try transform(current)
            return try acceptLocked(updated, for: owner.publicIdentity)
        }
    }

    private func acceptLocked(_ manifest: NetworkManifest, for localIdentity: PublicUserIdentity?,
                              requiresKnownNetwork: Bool = false) throws -> NetworkManifest {
        try manifest.validateSignature()
        guard !observedConflicts.contains(manifest.id) else { throw NetworkAuthorityError.quarantined }
        if let record = try readRecord(id: manifest.id) {
            guard record.conflictingManifest == nil else { throw NetworkAuthorityError.quarantined }
            let current = record.manifest
            guard current.owner == manifest.owner else { throw NetworkAuthorityError.ownerChanged }
            guard current.generation == manifest.generation else { throw NetworkAuthorityError.generationChanged }
            guard manifest.revision >= current.revision else { throw NetworkAuthorityError.rollback }
            if manifest.revision == current.revision {
                // ECDSA may produce distinct valid signatures for the same body.
                // Compare canonical policy, not signature bytes or JSON bytes.
                guard try manifest.canonicalBytes() == current.canonicalBytes() else {
                    observedConflicts.insert(manifest.id)
                    try writeRecord(Record(manifest: current, conflictingManifest: manifest))
                    throw NetworkAuthorityError.revisionConflict
                }
                return current
            }
        } else {
            guard !requiresKnownNetwork else { throw NetworkAuthorityError.networkNotFound }
            guard let localIdentity, manifest.isMember(localIdentity) else { throw NetworkAuthorityError.notMember }
        }
        try writeRecord(Record(manifest: manifest))
        return manifest
    }

    private func activeManifest(id: UUID) throws -> NetworkManifest {
        guard !observedConflicts.contains(id) else { throw NetworkAuthorityError.quarantined }
        guard let record = try readRecord(id: id) else { throw NetworkAuthorityError.networkNotFound }
        guard record.conflictingManifest == nil else { throw NetworkAuthorityError.quarantined }
        return record.manifest
    }

    private func filename(id: UUID) -> String { id.uuidString.lowercased() + ".json" }

    private func recordURL(id: UUID) -> URL { directoryURL.appendingPathComponent(filename(id: id), isDirectory: false) }

    private static let maximumRecordBytes = NetworkManifest.maximumEncodedBytes * 2 + 4096

    private func readRecord(id: UUID) throws -> Record? {
        let descriptor = open(recordURL(id: id).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw NetworkAuthorityError.invalidStorage
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0, metadata.st_size <= Self.maximumRecordBytes else {
            throw NetworkAuthorityError.invalidStorage
        }
        let data = try handle.read(upToCount: Self.maximumRecordBytes + 1) ?? Data()
        guard data.count <= Self.maximumRecordBytes else { throw NetworkAuthorityError.limitExceeded }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.storageVersion == 1, record.manifest.id == id else { throw NetworkAuthorityError.invalidStorage }
        if let conflict = record.conflictingManifest {
            guard conflict.id == id, conflict.owner == record.manifest.owner,
                  conflict.generation == record.manifest.generation,
                  conflict.revision == record.manifest.revision,
                  try conflict.canonicalBytes() != record.manifest.canonicalBytes() else {
                throw NetworkAuthorityError.invalidStorage
            }
        }
        return record
    }

    private func writeRecord(_ record: Record) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        guard data.count <= Self.maximumRecordBytes else { throw NetworkAuthorityError.limitExceeded }
        try data.write(to: recordURL(id: record.manifest.id), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL(id: record.manifest.id).path)
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard directoryURL.isFileURL else { throw NetworkAuthorityError.invalidStorage }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directoryURL.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw NetworkAuthorityError.invalidStorage }
        let descriptor = open(directoryURL.appendingPathComponent(".repository.lock").path,
                              O_RDWR | O_CREAT | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw NetworkAuthorityError.invalidStorage }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw NetworkAuthorityError.invalidStorage
        }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno != EINTR { throw NetworkAuthorityError.invalidStorage }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
