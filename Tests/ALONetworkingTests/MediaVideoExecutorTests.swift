import Foundation
import Network
import Testing
@testable import ALONetworking

@Suite("Video attachment executor isolation")
struct MediaVideoExecutorTests {
    @Test func wrongExecutorFailureReturnsOnReceiverOwnerQueue() async throws {
        let foreign = DispatchQueue(label: "alo.test.foreign-channel")
        let owner = DispatchQueue(label: "alo.test.video-owner")
        let key = DispatchSpecificKey<Bool>(); owner.setSpecific(key: key, value: true)
        let configuration = try SecurePeerConfiguration(roomID: UUID(), incarnationID: UUID(), admission: .publicRoom,
            offer: ProtocolOffer(wireVersions: [2], stateSyncVersions: [1], capabilities: .desktop), direction: .initiator(.video))
        // No connection starts: this is the rejected-executor branch before
        // credentials can be adopted, not a simulated successful admission.
        let channel = SecurePeerChannel(connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp),
            identity: try .ephemeral(), configuration: configuration, pins: MemoryPeerPinStore(), queue: foreign)
        let correct: Bool = await withCheckedContinuation { done in
            MediaVideoConnection.attach(channel, queue: owner) { result in
                let isOwner = DispatchQueue.getSpecific(key: key) == true
                if case .failure(let error) = result {
                    #expect((error as? SecureTransportError) == .invalidState)
                    done.resume(returning: isOwner)
                } else { done.resume(returning: false) }
            }
        }
        #expect(correct)
    }
}
