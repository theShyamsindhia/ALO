import Foundation
import Testing
@testable import WERAICore

@Suite("Room-scale latency reproduction", .serialized)
struct RoomScaleLatencyReproductionTests {
    @Test("Host queue falls behind capture cadence as receiver fan-out grows")
    func hostQueueBacklogGrowsWithReceiverCount() {
        let oneReceiver = simulateSerialFanout(receiverCount: 1)
        let eightReceivers = simulateSerialFanout(receiverCount: 8)

        print(
            "Simulated final packet age: 1 receiver = \(oneReceiver.finalPacketAgeNanos / 1_000_000) ms, "
                + "8 receivers = \(eightReceivers.finalPacketAgeNanos / 1_000_000) ms"
        )

        #expect(oneReceiver.finalPacketAgeNanos < 25_000_000)
        #expect(eightReceivers.finalPacketAgeNanos > 150_000_000)
        #expect(eightReceivers.backlogSlopeNanosPerPacket > 0)
        #expect(eightReceivers.maximumReceiverSkewNanos == 5_250_000)
    }

    @Test("Queue-delayed pong timestamps put receivers on different clocks")
    func clockOffsetSkewGrowsWithQueueDelay() throws {
        let receiverOffsets = try (0..<8).map { receiverIndex in
            try estimatedOffset(hostQueueDelayNanos: UInt64(receiverIndex) * 20_000_000)
        }
        let skew = try #require(receiverOffsets.last) - #require(receiverOffsets.first)

        print("Clock offset estimates across 8 receivers: \(receiverOffsets.map { $0 / 1_000_000 }) ms")

        #expect(receiverOffsets == [
            0, 10_000_000, 20_000_000, 30_000_000,
            40_000_000, 50_000_000, 60_000_000, 70_000_000
        ])
        #expect(skew == 70_000_000)
    }

    private func simulateSerialFanout(receiverCount: Int) -> FanoutResult {
        // ScreenCaptureKit commonly delivers multiple 5 ms packets in one callback.
        // The virtual queue mirrors HostServer.acceptAudio: packets, then receivers.
        let packetsPerCaptureCallback = 4
        let callbackIntervalNanos: UInt64 = 20_000_000
        let destinationQueueCostNanos: UInt64 = 750_000
        let callbackCount = 80
        let packetizer = AudioPacketizer()
        let callbackSamples = [Int16](
            repeating: 0,
            count: packetsPerCaptureCallback
                * Int(AudioPacket.framesPerPacket)
                * Int(AudioPacket.channelCount)
        )
        var queueAvailableNanos: UInt64 = 0
        var ages = [UInt64]()
        var maximumReceiverSkewNanos: UInt64 = 0

        for callbackIndex in 0..<callbackCount {
            let captureStartNanos = UInt64(callbackIndex) * callbackIntervalNanos
            let callbackArrivalNanos = captureStartNanos + callbackIntervalNanos
            queueAvailableNanos = max(queueAvailableNanos, callbackArrivalNanos)
            let packets = packetizer.append(
                samples: callbackSamples,
                captureTimeNanos: captureStartNanos
            )
            #expect(packets.count == packetsPerCaptureCallback)

            for packet in packets {
                let firstReceiverCompletion = queueAvailableNanos + destinationQueueCostNanos
                queueAvailableNanos += UInt64(receiverCount) * destinationQueueCostNanos
                let lastReceiverCompletion = queueAvailableNanos
                ages.append(lastReceiverCompletion - packet.captureTimeNanos)
                maximumReceiverSkewNanos = max(
                    maximumReceiverSkewNanos,
                    lastReceiverCompletion - firstReceiverCompletion
                )
            }
        }

        let firstAge = ages[packetsPerCaptureCallback - 1]
        let lastAge = ages[ages.count - 1]
        return FanoutResult(
            finalPacketAgeNanos: lastAge,
            backlogSlopeNanosPerPacket: Int64(lastAge - firstAge) / Int64(ages.count - packetsPerCaptureCallback),
            maximumReceiverSkewNanos: maximumReceiverSkewNanos
        )
    }

    private func estimatedOffset(hostQueueDelayNanos: UInt64) throws -> Int64 {
        let synchronizer = ClockSynchronizer()
        let networkOneWayNanos: UInt64 = 2_000_000

        for sampleIndex in 0..<4 {
            let clientSendNanos = 1_000_000_000 + UInt64(sampleIndex) * 100_000_000
            let ping = synchronizer.makePing(at: clientSendNanos)
            let hostStampNanos = clientSendNanos + networkOneWayNanos + hostQueueDelayNanos
            let clientReceiveNanos = hostStampNanos + networkOneWayNanos
            let pong = ControlMessage(
                type: "pong",
                id: ping.id,
                clientNanos: ping.clientNanos,
                hostNanos: hostStampNanos
            )
            #expect(synchronizer.acceptPong(pong, receivedAt: clientReceiveNanos))
        }

        #expect(synchronizer.isReady)
        return try #require(synchronizer.offsetNanos)
    }
}

private struct FanoutResult {
    let finalPacketAgeNanos: UInt64
    let backlogSlopeNanosPerPacket: Int64
    let maximumReceiverSkewNanos: UInt64
}
