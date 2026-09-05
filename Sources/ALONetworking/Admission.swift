import Foundation
import CryptoKit
@_exported import ALOCore

public struct PeerCapabilities: OptionSet, Codable, Equatable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let receiveAudio = Self(rawValue: 1 << 0)
    public static let receiveVideo = Self(rawValue: 1 << 1)
    public static let chat = Self(rawValue: 1 << 2)
    public static let voice = Self(rawValue: 1 << 3)
    public static let broadcast = Self(rawValue: 1 << 4)
    public static let editQueue = Self(rawValue: 1 << 5)
    public static let playbackControl = Self(rawValue: 1 << 6)
    public static let mobile: Self = [.receiveAudio, .receiveVideo, .chat, .voice]
    public static let desktop: Self = [.mobile, .broadcast, .editQueue, .playbackControl]
}

public enum ReliableChannelRole: UInt8, Codable, CaseIterable, Sendable { case roomControl = 1, mediaControl = 2, video = 3 }
public enum RoomAdmissionKind: UInt8, Codable, Sendable { case publicRoom = 1, privateRoom = 2 }

public struct ProtocolOffer: Equatable, Sendable {
    public let wireVersions: [UInt16]
    public let stateSyncVersions: [UInt16]
    public let capabilities: PeerCapabilities
    public init(wireVersions: [UInt16], stateSyncVersions: [UInt16], capabilities: PeerCapabilities) throws {
        guard !wireVersions.isEmpty, wireVersions.count <= 8,
              !stateSyncVersions.isEmpty, stateSyncVersions.count <= 8,
              Set(wireVersions).count == wireVersions.count, Set(stateSyncVersions).count == stateSyncVersions.count,
              !wireVersions.contains(0), !stateSyncVersions.contains(0) else { throw SecureTransportError.malformed }
        self.wireVersions = wireVersions.sorted(); self.stateSyncVersions = stateSyncVersions.sorted()
        self.capabilities = capabilities
    }
    var binding: Data {
        var wire = WireBytes(); wire.append(UInt8(wireVersions.count))
        for version in wireVersions { wire.append(version) }
        wire.append(UInt8(stateSyncVersions.count))
        for version in stateSyncVersions { wire.append(version) }
        wire.append(capabilities.rawValue)
        return wire.data
    }
}

public struct NegotiatedProtocol: Equatable, Sendable {
    public let wireVersion: UInt16
    public let stateSyncVersion: UInt16
    public let initiatorCapabilities: PeerCapabilities
    public let responderCapabilities: PeerCapabilities
    public static func negotiate(initiator: ProtocolOffer, responder: ProtocolOffer,
                                 policy: RoomTransportPolicy, requiresV2: Bool = false) throws -> Self {
        guard policy != .migrationRequired, !(requiresV2 && policy != .secureV2) else {
            throw SecureTransportError.downgradeForbidden
        }
        let version: UInt16 = policy == .secureV2 ? 2 : 1
        guard initiator.wireVersions.contains(version), responder.wireVersions.contains(version) else {
            throw SecureTransportError.downgradeForbidden
        }
        guard let sync = Set(initiator.stateSyncVersions).intersection(responder.stateSyncVersions).max() else {
            throw SecureTransportError.unsupportedProtocol
        }
        return Self(wireVersion: version, stateSyncVersion: sync,
                    initiatorCapabilities: initiator.capabilities, responderCapabilities: responder.capabilities)
    }
}

public enum AdmissionProofRole: UInt8, Sendable { case initiator = 1, responder = 2 }

/// Both sides use the same role-ordered transcript. Key hashes refer to identities verified
/// by the TLS adapter, not display names or untrusted Bonjour TXT records.
public struct AdmissionTranscript: Sendable {
    public let roomID: UUID
    public let initiatorID: UUID
    public let responderID: UUID
    public let connectionID: UUID
    public let initiatorKeyHash: Data
    public let responderKeyHash: Data
    public let admissionKind: RoomAdmissionKind
    public let channelRole: ReliableChannelRole
    public let negotiated: NegotiatedProtocol
    let binding: Data

    public init(roomID: UUID, initiatorID: UUID, responderID: UUID, connectionID: UUID,
                initiatorKeyHash: Data, responderKeyHash: Data, initiatorNonce: Data, responderNonce: Data,
                initiatorOffer: ProtocolOffer, responderOffer: ProtocolOffer, policy: RoomTransportPolicy,
                channelRole: ReliableChannelRole = .roomControl, admissionKind: RoomAdmissionKind = .privateRoom,
                initiatorIncarnationID: UUID? = nil, responderIncarnationID: UUID? = nil) throws {
        guard policy == .secureV2 else { throw SecureTransportError.downgradeForbidden }
        guard initiatorID != responderID, initiatorKeyHash.count == 32, responderKeyHash.count == 32,
              initiatorNonce.count == 32, responderNonce.count == 32 else { throw SecureTransportError.malformed }
        negotiated = try .negotiate(initiator: initiatorOffer, responder: responderOffer, policy: policy)
        self.roomID = roomID; self.initiatorID = initiatorID; self.responderID = responderID
        self.connectionID = connectionID
        self.initiatorKeyHash = initiatorKeyHash; self.responderKeyHash = responderKeyHash
        self.channelRole = channelRole; self.admissionKind = admissionKind
        var wire = WireBytes(); wire.append(Data("ALO/admission/transcript/v2".utf8))
        wire.append(roomID); wire.append(initiatorID); wire.append(responderID); wire.append(connectionID)
        wire.append(initiatorKeyHash); wire.append(responderKeyHash); wire.append(initiatorNonce); wire.append(responderNonce)
        wire.append(channelRole.rawValue); wire.append(admissionKind.rawValue)
        wire.append(initiatorIncarnationID ?? initiatorID); wire.append(responderIncarnationID ?? responderID)
        wire.field(initiatorOffer.binding); wire.field(responderOffer.binding)
        wire.append(negotiated.wireVersion); wire.append(negotiated.stateSyncVersion)
        binding = wire.data
    }
}

/// TLS plumbing must supply 32 bytes from the actual connection's exporter. There is
/// deliberately no nonce-only, empty-exporter, or plaintext admission mode here.
public enum TLSBoundAdmissionProof {
    public static let exporterLabel = "EXPORTER-ALO-admission-v2"
    public static let exporterLength = 32

    public static func exporterContext(for transcript: AdmissionTranscript) -> Data {
        Data(SHA256.hash(data: transcript.binding))
    }

    private static func message(transcript: AdmissionTranscript, exporter: Data, role: AdmissionProofRole) throws -> Data {
        guard exporter.count == exporterLength else { throw SecureTransportError.missingTLSExporter }
        var wire = WireBytes(); wire.append(Data("ALO/admission/proof/v2".utf8)); wire.append(role.rawValue)
        wire.field(transcript.binding); wire.append(exporter)
        return wire.data
    }

    public static func make(roomSecret: Data, transcript: AdmissionTranscript, exporter: Data,
                            role: AdmissionProofRole) throws -> Data {
        guard roomSecret.count == 32 else { throw SecureTransportError.invalidCredentials }
        return Data(HMAC<SHA256>.authenticationCode(for: try message(transcript: transcript, exporter: exporter, role: role),
                                                    using: SymmetricKey(data: roomSecret)))
    }

    public static func verify(_ proof: Data, roomSecret: Data, transcript: AdmissionTranscript,
                              exporter: Data, role: AdmissionProofRole) throws -> Bool {
        guard roomSecret.count == 32, proof.count == 32 else { throw SecureTransportError.invalidCredentials }
        return HMAC<SHA256>.isValidAuthenticationCode(proof,
            authenticating: try message(transcript: transcript, exporter: exporter, role: role),
            using: SymmetricKey(data: roomSecret))
    }

    /// Fresh exporter material and transcript bind channel material to this admitted TLS connection.
    public static func channelSecret(roomSecret: Data, transcript: AdmissionTranscript, exporter: Data) throws -> SymmetricKey {
        guard roomSecret.count == 32 else { throw SecureTransportError.invalidCredentials }
        guard exporter.count == exporterLength else { throw SecureTransportError.missingTLSExporter }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: roomSecret), salt: exporter,
                                     info: transcript.binding + Data("/channels".utf8), outputByteCount: 32)
    }

    static func publicProof(transcript: AdmissionTranscript, exporter: Data, role: AdmissionProofRole) throws -> Data {
        guard transcript.admissionKind == .publicRoom else { throw SecureTransportError.invalidCredentials }
        guard exporter.count == exporterLength else { throw SecureTransportError.missingTLSExporter }
        return Data(HMAC<SHA256>.authenticationCode(for: Data("ALO/public-admission/v2".utf8) + transcript.binding + Data([role.rawValue]),
                                                    using: SymmetricKey(data: exporter)))
    }

    static func verifyPublicProof(_ proof: Data, transcript: AdmissionTranscript, exporter: Data,
                                   role: AdmissionProofRole) throws -> Bool {
        guard transcript.admissionKind == .publicRoom, proof.count == 32 else { throw SecureTransportError.invalidCredentials }
        guard exporter.count == exporterLength else { throw SecureTransportError.missingTLSExporter }
        return HMAC<SHA256>.isValidAuthenticationCode(proof,
            authenticating: Data("ALO/public-admission/v2".utf8) + transcript.binding + Data([role.rawValue]),
            using: SymmetricKey(data: exporter))
    }
}
