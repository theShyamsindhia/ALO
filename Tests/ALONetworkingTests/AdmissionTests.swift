import Foundation
import CryptoKit
import Testing
@testable import ALONetworking

@Suite("TLS-bound v2 admission")
struct AdmissionTests {
    @Test func currentRoomGenerationRejectsOldClientsInBothDirections() throws {
        let current = try ProtocolOffer.current(capabilities: .desktop)
        let old = try ProtocolOffer(wireVersions: [2], stateSyncVersions: [1], capabilities: .desktop)
        #expect(throws: SecureTransportError.unsupportedProtocol) {
            try NegotiatedProtocol.negotiate(initiator: old, responder: current, policy: .secureV2)
        }
        #expect(throws: SecureTransportError.unsupportedProtocol) {
            try NegotiatedProtocol.negotiate(initiator: current, responder: old, policy: .secureV2)
        }
        #expect(try NegotiatedProtocol.negotiate(initiator: current, responder: current, policy: .secureV2).stateSyncVersion == ProtocolOffer.currentRoomGeneration)
    }
    @Test func proofRequiresActualConnectionExporterAndMatchingRole() throws {
        let transcript = try NetworkFixture.transcript()
        let proof = try TLSBoundAdmissionProof.make(roomSecret: NetworkFixture.secret, transcript: transcript,
                                                    exporter: NetworkFixture.exporter, role: .initiator)
        #expect(proof.count == 32)
        #expect(try TLSBoundAdmissionProof.verify(proof, roomSecret: NetworkFixture.secret, transcript: transcript,
                                                 exporter: NetworkFixture.exporter, role: .initiator))
        #expect(try !TLSBoundAdmissionProof.verify(proof, roomSecret: NetworkFixture.secret, transcript: transcript,
                                                  exporter: Data(repeating: 7, count: 32), role: .initiator))
        #expect(try !TLSBoundAdmissionProof.verify(proof, roomSecret: NetworkFixture.secret, transcript: transcript,
                                                  exporter: NetworkFixture.exporter, role: .responder))
        #expect(try !TLSBoundAdmissionProof.verify(proof, roomSecret: Data(repeating: 7, count: 32), transcript: transcript,
                                                  exporter: NetworkFixture.exporter, role: .initiator))
        #expect(throws: SecureTransportError.missingTLSExporter) {
            try TLSBoundAdmissionProof.make(roomSecret: NetworkFixture.secret, transcript: transcript, exporter: Data(), role: .initiator)
        }
        #expect(throws: SecureTransportError.missingTLSExporter) {
            try TLSBoundAdmissionProof.verify(proof, roomSecret: NetworkFixture.secret, transcript: transcript,
                                              exporter: Data(), role: .initiator)
        }
        #expect(throws: SecureTransportError.missingTLSExporter) {
            try TLSBoundAdmissionProof.channelSecret(roomSecret: NetworkFixture.secret, transcript: transcript, exporter: Data())
        }
    }

    @Test func proofBindsRoomPeerNonceAndUnselectedOfferVersions() throws {
        let original = try NetworkFixture.transcript()
        let proof = try TLSBoundAdmissionProof.make(roomSecret: NetworkFixture.secret, transcript: original,
                                                    exporter: NetworkFixture.exporter, role: .initiator)
        let changes = try [NetworkFixture.transcript(room: UUID()), NetworkFixture.transcript(initiator: UUID()),
                           NetworkFixture.transcript(responder: UUID()), NetworkFixture.transcript(nonce: 8),
                           NetworkFixture.transcript(capabilities: .desktop), NetworkFixture.transcript(wireVersions: [1,2])]
        for changed in changes {
            #expect(try !TLSBoundAdmissionProof.verify(proof, roomSecret: NetworkFixture.secret, transcript: changed,
                                                      exporter: NetworkFixture.exporter, role: .initiator))
        }
    }

    @Test func securePolicyNeverDowngradesAndStateSyncVersionIsSeparate() throws {
        let old = try ProtocolOffer(wireVersions: [1], stateSyncVersions: [1], capabilities: .desktop)
        let both = try ProtocolOffer(wireVersions: [1,2], stateSyncVersions: [1], capabilities: .mobile)
        #expect(throws: SecureTransportError.downgradeForbidden) {
            try NegotiatedProtocol.negotiate(initiator: both, responder: old, policy: .secureV2)
        }
        #expect(throws: SecureTransportError.downgradeForbidden) {
            try NegotiatedProtocol.negotiate(initiator: both, responder: old, policy: .legacyOnly, requiresV2: true)
        }
        #expect(throws: SecureTransportError.downgradeForbidden) {
            try NegotiatedProtocol.negotiate(initiator: both, responder: both, policy: .migrationRequired)
        }
        let negotiated = try NegotiatedProtocol.negotiate(initiator: both, responder: both, policy: .secureV2)
        #expect(negotiated.wireVersion == 2)
        #expect(negotiated.stateSyncVersion == 1)
        #expect(!negotiated.initiatorCapabilities.contains(.broadcast))
        #expect(try NegotiatedProtocol.negotiate(initiator: both, responder: old, policy: .legacyOnly).wireVersion == 1)
        #expect(!RoomTransportPolicy.secureV2.permits(wireVersion: 1))
        #expect(!RoomTransportPolicy.migrationRequired.permits(wireVersion: 2))
    }

    @Test func offersRejectUnboundedDuplicateAndEmptyVersions() throws {
        for versions: [UInt16] in [[], [2,2], Array(1...9), [0]] {
            #expect(throws: SecureTransportError.malformed) {
                try ProtocolOffer(wireVersions: versions, stateSyncVersions: [1], capabilities: .mobile)
            }
        }
    }
}
