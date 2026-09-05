import Foundation
import Security
import ALOCore

/// An event's author must have been admitted independently of the peer relaying it.
/// The installation signature survives gossip and durable-state synchronization.
final class SecureRoomEventPolicy: @unchecked Sendable {
    private struct Proof: Codable { let certificate: Data; let signature: Data }
    private struct Grant: Codable { let hash: Data; let capabilities: PeerCapabilities }
    private let lock = NSLock()
    private var grants = [String: Grant]()
    private let identity: InstallationIdentity?
    private let roomID: String

    init(roomID: String, identity: InstallationIdentity?, capabilities: PeerCapabilities) {
        self.roomID = roomID; self.identity = identity
        if let identity {
            grants[identity.publicIdentity.nodeID.uuidString] = Grant(hash: identity.publicIdentity.publicKeyHash, capabilities: capabilities)
        }
    }

    private struct Archive: Codable { let body: Data; let signature: Data }
    private struct SavedState: Codable {
        let roomID: String
        let localPeerID: UUID
        let grants: [String: Grant]
        let document: Data
    }
    private static let archiveMagic = Data("ALOARCH2".utf8)
    private static let archiveDomain = Data("ALO/local-state-archive/v2\0".utf8)

    /// Admission grants are local trust decisions. Sign them with this
    /// installation's key; a remote sync document cannot manufacture grants.
    func archive(document: Data) throws -> Data {
        guard let identity else { throw SecureTransportError.invalidCredentials }
        let state = lock.withLock {
            SavedState(roomID: roomID, localPeerID: identity.publicIdentity.nodeID, grants: grants, document: document)
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let body = try encoder.encode(state)
        let signature = try identity.signRoomEvent(Self.archiveDomain + body)
        return Self.archiveMagic + (try encoder.encode(Archive(body: body, signature: signature)))
    }

    func restoreArchive(_ data: Data) -> Data? {
        guard data.count <= 8 * 1_024 * 1_024, data.starts(with: Self.archiveMagic),
              let identity, let key = SecCertificateCopyKey(identity.certificate),
              let archive = try? PropertyListDecoder().decode(Archive.self, from: data.dropFirst(Self.archiveMagic.count)),
              SecKeyVerifySignature(key, .ecdsaSignatureMessageX962SHA256, (Self.archiveDomain + archive.body) as CFData,
                                    archive.signature as CFData, nil),
              let saved = try? PropertyListDecoder().decode(SavedState.self, from: archive.body),
              saved.roomID == roomID, saved.localPeerID == identity.publicIdentity.nodeID,
              saved.grants.count <= 1_024 else { return nil }
        lock.withLock {
            let localID = identity.publicIdentity.nodeID.uuidString
            let currentLocalGrant = grants[localID]
            grants = saved.grants
            grants[localID] = currentLocalGrant
        }
        return saved.document
    }

    @discardableResult
    func admit(_ peer: AuthenticatedPeer, initiated: Bool) -> Bool {
        lock.withLock {
            let id = peer.nodeID.uuidString
            guard grants[id] != nil || grants.count < 1_024 else { return false }
            grants[id] = Grant(hash: peer.publicKeyHash, capabilities: initiated
                ? peer.negotiated.responderCapabilities : peer.negotiated.initiatorCapabilities)
            return true
        }
    }

    static func capability(for kind: MeshRoomEventKind) -> PeerCapabilities {
        switch kind {
        case .chat: return .chat
        case .queueAdd, .queueRemove, .queueReorder: return .editQueue
        case .broadcaster, .playback, .video: return .broadcast
        }
    }

    func sign(_ event: MeshRoomEvent) -> MeshRoomEvent? {
        guard let identity, event.roomID == roomID,
              event.version.nodeID == identity.publicIdentity.nodeID.uuidString,
              permits(author: event.version.nodeID, capability: Self.capability(for: event.kind)),
              let bytes = try? event.signingBytes(),
              let signature = try? identity.signRoomEvent(bytes),
              let proof = try? JSONEncoder().encode(Proof(certificate: SecCertificateCopyData(identity.certificate) as Data,
                                                         signature: signature)) else { return nil }
        return event.authorized(with: proof)
    }

    func permits(author: String, capability: PeerCapabilities) -> Bool {
        lock.withLock { grants[author]?.capabilities.contains(capability) == true }
    }

    func accepts(_ event: MeshRoomEvent) -> Bool {
        guard event.roomID == roomID, let signer = Self.verifiedSigner(event) else { return false }
        // A signature authenticates its key, not an arbitrary claimed chat
        // author. Rich edits/deletes/reactions must use that authenticated author.
        if event.kind == .chat, let sender = event.senderID,
           sender != event.version.nodeID { return false }
        if event.kind == .broadcaster || event.kind == .video {
            guard event.broadcasterID == event.version.nodeID else { return false }
        }
        return lock.withLock {
            guard let grant = grants[event.version.nodeID] else { return false }
            return grant.hash == signer.publicKeyHash && grant.capabilities.contains(Self.capability(for: event.kind))
        }
    }

    /// Durable storage can retain a signed event before its author reconnects.
    /// It is projected into live state only after accepts() confirms admission.
    static func hasValidSignature(_ event: MeshRoomEvent) -> Bool { verifiedSigner(event) != nil }

    private static func verifiedSigner(_ event: MeshRoomEvent) -> PeerPublicIdentity? {
        guard let encoded = event.authorization, encoded.count <= 4_096,
              let proof = try? JSONDecoder().decode(Proof.self, from: encoded),
              let certificate = SecCertificateCreateWithData(nil, proof.certificate as CFData),
              let publicKey = SecCertificateCopyKey(certificate),
              let signer = try? PeerPublicIdentity.from(publicKey: publicKey),
              signer.nodeID.uuidString == event.version.nodeID,
              let bytes = try? event.signingBytes(),
              SecKeyVerifySignature(publicKey, .ecdsaSignatureMessageX962SHA256, bytes as CFData,
                                    proof.signature as CFData, nil) else { return nil }
        return signer
    }
}
