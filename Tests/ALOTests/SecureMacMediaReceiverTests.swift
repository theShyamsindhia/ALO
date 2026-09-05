import Foundation
import Testing
import ALOCore
import ALONetworking
@testable import ALO

@Suite struct SecureMacMediaReceiverTests {
    private func connectionToken() throws -> TransportToken {
        var supervisor = ConnectionSupervisor()
        _ = supervisor.start(now: 0)
        let actions = supervisor.resolved(lifecycle: supervisor.lifecycle, now: 0)
        for action in actions { if case .connect(let token) = action { return token } }
        throw NSError(domain: "Missing connection token", code: 1)
    }

    @Test func packetBurstUsesOneExecutorHop() throws {
        let inbox = SecureMacMediaReceiver.PacketInbox()
        let token = try connectionToken()
        var hops = 0
        for n in 0..<16 {
            let packet = AudioPacket(sequence: UInt32(n), frameIndex: UInt64(n * 240),
                captureTimeNanos: UInt64(n * 5_000_000), samples: .init(repeating: 1, count: 480))
            if inbox.append(.init(packet: packet, token: token)) { hops += 1 }
        }
        #expect(hops == 1)
        #expect(inbox.take().map(\.packet.sequence) == Array(0..<16).map(UInt32.init))
        #expect(inbox.take().isEmpty)
    }

    @Test func stalledPlaybackKeepsOnlyBoundedFreshPackets() throws {
        let inbox = SecureMacMediaReceiver.PacketInbox()
        let token = try connectionToken()
        for n in 0..<300 {
            let packet = AudioPacket(sequence: UInt32(n), frameIndex: UInt64(n * 240),
                captureTimeNanos: UInt64(n * 5_000_000), samples: .init(repeating: 1, count: 480))
            _ = inbox.append(.init(packet: packet, token: token))
        }
        let batch = inbox.take()
        #expect(batch.count == 128)
        #expect(batch.first?.packet.sequence == 172)
        #expect(batch.last?.packet.sequence == 299)
        #expect(batch.allSatisfy { $0.token == token })
        #expect(inbox.append(.init(packet: batch[0].packet, token: token)))
    }
}
