import Foundation
import Network
import Security
import CryptoKit

/// Actual Network.framework TLS profile, separate from the explicitly legacy plaintext
/// adapter. Mutual certificate authentication is mandatory; no TLS/authentication error
/// enables a plaintext retry. The room admission exchange follows NWConnection.ready.
public enum SecureNetworkParameters {
    public static let applicationProtocol = "alo-peer/2"

    public static func tcp(identity: InstallationIdentity, expectedPeerID: UUID?, pins: PeerPinStore,
                           firstContact: FirstContactPolicy, verificationQueue: DispatchQueue) throws -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        guard let local = sec_identity_create(identity.identity) else { throw IdentityError.identityCreation }
        sec_protocol_options_set_local_identity(options, local)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_peer_authentication_required(options, true)
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        sec_protocol_options_add_tls_application_protocol(options, applicationProtocol)
        sec_protocol_options_set_verify_block(options, { _, trust, completion in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let certificates = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                  certificates.count == 1, let leaf = certificates.first,
                  CFDataGetLength(SecCertificateCopyData(leaf)) <= 4_096 else { completion(false); return }
            do {
                _ = try PeerTrustVerifier.evaluate(certificate: leaf, expectedNodeID: expectedPeerID,
                                                   pins: pins, firstContact: firstContact)
                // This is an installation certificate profile, not Web PKI. Anchor the exact
                // checked leaf, then let Security validate its X.509 structure and usage.
                guard SecTrustSetPolicies(secTrust, SecPolicyCreateBasicX509()) == errSecSuccess,
                      SecTrustSetNetworkFetchAllowed(secTrust, false) == errSecSuccess,
                      SecTrustSetAnchorCertificates(secTrust, [leaf] as CFArray) == errSecSuccess,
                      SecTrustSetAnchorCertificatesOnly(secTrust, true) == errSecSuccess else { completion(false); return }
                completion(SecTrustEvaluateWithError(secTrust, nil))
            } catch { completion(false) }
        }, verificationQueue)
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        return parameters
    }

    public static func udp() -> NWParameters {
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        return parameters
    }

    /// Only call on a ready, mutually authenticated TLS connection made with this profile.
    /// Security derives connection-specific exporter bytes with the full admission context.
    public static func exporter(connection: NWConnection, transcript: AdmissionTranscript) throws -> Data {
        guard case .ready = connection.state,
              let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            throw SecureTransportError.missingTLSExporter
        }
        let context = TLSBoundAdmissionProof.exporterContext(for: transcript)
        let label = TLSBoundAdmissionProof.exporterLabel
        let secret = label.withCString { labelBytes in
            context.withUnsafeBytes { contextBytes in
                sec_protocol_metadata_create_secret_with_context(metadata.securityProtocolMetadata,
                    label.utf8.count, labelBytes, context.count, contextBytes.bindMemory(to: UInt8.self).baseAddress!,
                    TLSBoundAdmissionProof.exporterLength)
            }
        }
        guard let secret else { throw SecureTransportError.missingTLSExporter }
        let bytes = Data(secret as DispatchData)
        guard bytes.count == TLSBoundAdmissionProof.exporterLength else { throw SecureTransportError.missingTLSExporter }
        return bytes
    }

    public static func peerIdentity(connection: NWConnection) throws -> PeerPublicIdentity {
        guard case .ready = connection.state,
              let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            throw IdentityError.invalidCertificate
        }
        var certificates = [SecCertificate]()
        let found = sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { certificate in
            if certificates.count < 2 { certificates.append(sec_certificate_copy_ref(certificate).takeRetainedValue()) }
        }
        guard found, certificates.count == 1, let certificate = certificates.first else { throw IdentityError.invalidCertificate }
        return try PeerPublicIdentity.from(certificate: certificate)
    }
}

/// Binds the application transcript to the identities on the actual TLS connection before
/// constructing/verifying a room proof. Pin persistence follows successful room admission.
public final class TLSAdmissionSession {
    public let peer: PeerPublicIdentity
    public let transcript: AdmissionTranscript
    public let localRole: AdmissionProofRole
    private let exporter: Data
    private let pins: PeerPinStore
    private var admitted = false
    private var privateAdmission = false

    public init(connection: NWConnection, identity: InstallationIdentity, transcript: AdmissionTranscript,
                localRole: AdmissionProofRole, pins: PeerPinStore) throws {
        peer = try SecureNetworkParameters.peerIdentity(connection: connection)
        let local = identity.publicIdentity
        let initiator = localRole == .initiator ? local : peer
        let responder = localRole == .responder ? local : peer
        guard transcript.initiatorID == initiator.nodeID, transcript.responderID == responder.nodeID,
              transcript.initiatorKeyHash == initiator.publicKeyHash,
              transcript.responderKeyHash == responder.publicKeyHash else { throw IdentityError.peerIdentityMismatch }
        self.transcript = transcript; self.localRole = localRole; self.pins = pins
        exporter = try SecureNetworkParameters.exporter(connection: connection, transcript: transcript)
    }

    public func makePrivateProof(roomSecret: Data) throws -> Data {
        try TLSBoundAdmissionProof.make(roomSecret: roomSecret, transcript: transcript, exporter: exporter, role: localRole)
    }
    public func admitPrivatePeer(proof: Data, roomSecret: Data) throws {
        guard transcript.admissionKind == .privateRoom else { throw SecureTransportError.invalidCredentials }
        guard try TLSBoundAdmissionProof.verify(proof, roomSecret: roomSecret, transcript: transcript,
            exporter: exporter, role: localRole == .initiator ? .responder : .initiator) else {
            throw SecureTransportError.invalidCredentials
        }
        try pins.recordAfterAdmission(peer); admitted = true; privateAdmission = true
    }
    /// Invoke only after the room's explicit public-join transaction was accepted. Public-room
    /// first contact provides encryption and key continuity, not verified human identity.
    public func admitPublicPeerAfterExplicitJoin() throws {
        guard transcript.admissionKind == .publicRoom else { throw SecureTransportError.invalidCredentials }
        try pins.recordAfterAdmission(peer); admitted = true
    }
    public func makePublicProof() throws -> Data {
        try TLSBoundAdmissionProof.publicProof(transcript: transcript, exporter: exporter, role: localRole)
    }
    public func admitPublicPeer(proof: Data) throws {
        guard try TLSBoundAdmissionProof.verifyPublicProof(proof, transcript: transcript, exporter: exporter,
            role: localRole == .initiator ? .responder : .initiator) else { throw SecureTransportError.invalidCredentials }
        try admitPublicPeerAfterExplicitJoin()
    }
    public func privateChannelSecret(roomSecret: Data) throws -> CryptoKit.SymmetricKey {
        guard admitted, privateAdmission else { throw SecureTransportError.invalidCredentials }
        return try TLSBoundAdmissionProof.channelSecret(roomSecret: roomSecret, transcript: transcript, exporter: exporter)
    }
    func publicChannelSecret() throws -> SymmetricKey {
        guard admitted, !privateAdmission, transcript.admissionKind == .publicRoom else { throw SecureTransportError.invalidCredentials }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: exporter),
            salt: Data("ALO/public-channel-root/v2".utf8), info: transcript.binding, outputByteCount: 32)
    }
}
