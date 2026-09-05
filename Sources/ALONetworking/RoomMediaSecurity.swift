import Foundation
import CryptoKit
import Network
import Security
import ALOCore

/// Protects the desktop media path for private legacy rooms. This is deliberately
/// separate from v2 admission: a v2 room must use its authenticated media adapter.
public struct RoomMediaSecurity: Sendable {
    private let secret: SymmetricKey
    private let roomID: UUID
    private let senderID: UUID

    public static func forRoom(_ room: RoomConfiguration, serviceName: String) throws -> Self? {
        guard room.transportPolicy == .legacyOnly else { throw SecureTransportError.wrongContext }
        guard room.isPrivate else { return nil }
        guard let key = room.accessKey, key.utf8.count >= 32 else { throw SecureTransportError.invalidCredentials }
        return Self(key: key, room: room.id, service: serviceName)
    }

    private init(key: String, room: String, service: String) {
        let binding = Data((room + "/" + service).utf8)
        secret = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(key.utf8)),
            salt: Data("WERAI/private-media/1".utf8), info: binding, outputByteCount: 32)
        roomID = Self.identifier(Data(room.utf8))
        senderID = Self.identifier(binding)
    }

    private static func identifier(_ data: Data) -> UUID {
        let b = Array(SHA256.hash(data: data).prefix(16))
        return UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
    }

    public func tcp(video: Bool = false) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        // Network.framework requires an explicit external-PSK cipher suite.
        // RFC 5487 PSK-AES128-GCM-SHA256; certificate ciphers are not enabled.
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: 0x00a8)!)
        let purpose = Data((video ? "video" : "control").utf8)
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: secret, salt: purpose, info: Data(), outputByteCount: 32)
        let bytes = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = purpose.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, bytes as __DispatchData, identity as __DispatchData)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    private func context(sessionID: UUID) -> SecureDatagramContext {
        .init(roomID: roomID, senderID: senderID, receiverID: sessionID, broadcasterEpoch: 0,
              sessionID: sessionID, generation: 0, channel: .audio)
    }
    public func audioSealer(sessionID: UUID) throws -> DatagramSealer {
        try DatagramSealer(secret: secret, context: context(sessionID: sessionID))
    }
    public func audioOpener(sessionID: UUID) throws -> DatagramOpener {
        try DatagramOpener(secret: secret, context: context(sessionID: sessionID))
    }
}
