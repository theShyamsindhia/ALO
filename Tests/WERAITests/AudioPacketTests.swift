import Foundation
import Testing
@testable import WERAICore

@Suite("Room protocol")
struct AudioPacketTests {
    @Test func packetRoundTrip() throws {
        let samples = (0..<480).map { Int16($0 - 240) }
        let packet = AudioPacket(
            sequence: 42,
            frameIndex: 10_080,
            captureTimeNanos: 123_456_789,
            samples: samples
        )

        #expect(AudioPacket(data: packet.encoded()) == packet)
        #expect(packet.encoded().count < 1_200)
    }

    @Test func packetizerKeepsRemainderAndTimeline() throws {
        let packetizer = AudioPacketizer()
        let first = packetizer.append(samples: [Int16](repeating: 1, count: 600), captureTimeNanos: 1_000_000_000)
        let second = packetizer.append(samples: [Int16](repeating: 2, count: 360), captureTimeNanos: 1_006_250_000)

        #expect(first.count == 1)
        #expect(second.count == 1)
        #expect(first[0].frameIndex == 0)
        #expect(second[0].frameIndex == 240)
        #expect(second[0].captureTimeNanos == 1_005_000_000)
    }

    @Test func controlMessagesCanArriveInChunks() throws {
        let decoder = ControlLineDecoder()
        let first = try ControlMessage(type: "ping", id: 7, clientNanos: 10).encodedLine()
        let second = try ControlMessage(type: "ping", id: 8, clientNanos: 20).encodedLine()
        let joined = first + second

        #expect(decoder.append(joined.prefix(5)).isEmpty)
        let messages = decoder.append(joined.dropFirst(5))
        #expect(messages.map(\.id) == [7, 8])
    }

    @Test func roomMessagesCarryPresenceAndChat() throws {
        let decoder = ControlLineDecoder()
        let roomParticipants = [
            RoomParticipant(id: "mac-a", name: "Ada’s Mac", volume: 0.72, isMuted: false),
            RoomParticipant(id: "mac-b", name: "Lin’s Mac", volume: 0.31, isMuted: true)
        ]
        let presence = try ControlMessage(
            type: "presence",
            participants: ["Ada’s Mac", "Lin’s Mac"],
            participantDetails: roomParticipants
        ).encodedLine()
        let chat = try ControlMessage(
            type: "chat",
            sender: "Ada’s Mac",
            text: "Ready?",
            sentNanos: 42
        ).encodedLine()

        let messages = decoder.append(presence + chat)
        #expect(messages[0].participants == ["Ada’s Mac", "Lin’s Mac"])
        #expect(messages[0].participantDetails == roomParticipants)
        #expect(messages[1].sender == "Ada’s Mac")
        #expect(messages[1].text == "Ready?")
    }

    @Test func mediaAndMixerStateRoundTrip() throws {
        let decoder = ControlLineDecoder()
        let media = try ControlMessage(type: "media_state", videoEnabled: false).encodedLine()
        let level = try ControlMessage(
            type: "level",
            targetID: "mac-a",
            volume: 0.47,
            muted: true
        ).encodedLine()
        let messages = decoder.append(media + level)

        #expect(messages[0].videoEnabled == false)
        #expect(messages[1].targetID == "mac-a")
        #expect(messages[1].volume == 0.47)
        #expect(messages[1].muted == true)
    }

    @Test func playbackSyncTelemetryRoundTrip() throws {
        let report = PlaybackSyncReport(
            measuredAtNanos: 1_000,
            latenessNanos: 125_000_000,
            latePacketCount: 3,
            resyncCount: 1
        )
        let data = try ControlMessage(
            type: "sync_status",
            participantID: "mac-a",
            syncReport: report
        ).encodedLine()
        let decoded = ControlLineDecoder().append(data).first

        #expect(decoded?.participantID == "mac-a")
        #expect(decoded?.syncReport == report)
    }

    @Test func nowPlayingArtworkRoundTrip() throws {
        let decoder = ControlLineDecoder()
        let nowPlaying = NowPlayingMedia(
            title: "Every Second Every Hour",
            artist: "Iyeoka",
            album: "Gold",
            artworkData: Data([0xFF, 0xD8, 0xFF, 0xD9])
        )
        let data = try ControlMessage(
            type: "now_playing",
            nowPlaying: nowPlaying
        ).encodedLine()

        #expect(decoder.append(data).first?.nowPlaying == nowPlaying)
    }

    @Test func sharedQueueRoundTrip() throws {
        let decoder = ControlLineDecoder()
        let item = RoomQueueItem(
            id: "queue-1",
            title: "A shared track",
            subtitle: "Artist",
            url: "https://open.spotify.com/track/example",
            addedBy: "Ada’s Mac",
            addedByID: "mac-a",
            addedNanos: 42
        )
        let data = try ControlMessage(
            type: "queue_update",
            mediaQueue: [item]
        ).encodedLine()

        #expect(decoder.append(data).first?.mediaQueue == [item])
    }

    @Test func clockOffsetUsesRoundTripMidpoint() throws {
        let clock = ClockSynchronizer()
        let ping = clock.makePing(at: 1_000)
        let pong = ControlMessage(
            type: "pong",
            id: ping.id,
            clientNanos: ping.clientNanos,
            hostNanos: 1_600
        )

        #expect(clock.acceptPong(pong, receivedAt: 1_200))
        #expect(clock.offsetNanos == 500)
        #expect(!clock.isReady)
    }

    @Test func clockModelTracksContinuousDrift() throws {
        let clock = ClockSynchronizer()
        let baseOffset: UInt64 = 20_000_000

        for index in 0..<24 {
            let startedAt = 1_000_000_000 + UInt64(index) * 1_000_000_000
            let ping = clock.makePing(at: startedAt)
            let receivedAt = startedAt + 2_000_000
            let midpoint = startedAt + 1_000_000
            let driftingOffset = baseOffset + UInt64(index) * 20_000
            let pong = ControlMessage(
                type: "pong",
                id: ping.id,
                clientNanos: ping.clientNanos,
                hostNanos: midpoint + driftingOffset
            )
            #expect(clock.acceptPong(pong, receivedAt: receivedAt))
        }

        #expect(clock.isReady)
        #expect(clock.driftPartsPerMillion > 15)
        #expect(clock.driftPartsPerMillion < 22)
        let now = UInt64(24_001_000_000)
        let later = now + 10_000_000_000
        let projectedChange = (clock.offsetNanos(at: later) ?? 0) - (clock.offsetNanos(at: now) ?? 0)
        #expect(projectedChange > 150_000)
        #expect(projectedChange < 220_000)
    }

    @Test func roomTimingGrowsOnlyForUnstableNetwork() throws {
        let stable = NetworkJitterEstimator()
        let unstable = NetworkJitterEstimator()

        for index in 0..<100 {
            let capture = 1_000_000_000 + UInt64(index) * 5_000_000
            stable.observe(
                captureTimeNanos: capture,
                receivedAt: capture + 5_000_000,
                clockOffsetNanos: 0
            )
            unstable.observe(
                captureTimeNanos: capture,
                receivedAt: capture + 5_000_000 + UInt64(index % 20) * 3_000_000,
                clockOffsetNanos: 0
            )
        }

        #expect(stable.recommendedPlayoutDelayNanos(roundTripNanos: 4_000_000) == 250_000_000)
        #expect(unstable.jitterNanos >= 45_000_000)
        #expect(unstable.recommendedPlayoutDelayNanos(roundTripNanos: 20_000_000) > 250_000_000)
        #expect(RoomTiming.clampedPlayoutDelay(1_000_000_000) == 600_000_000)
    }

    @Test func synchronizationReportsRoundTrip() throws {
        let decoder = ControlLineDecoder()
        let report = try ControlMessage(
            type: "sync_report",
            playoutDelayNanos: 315_000_000
        ).encodedLine()

        let decoded = decoder.append(report).first
        #expect(decoded?.playoutDelayNanos == 315_000_000)
    }

    @Test func videoFramesSurviveArbitraryStreamChunks() throws {
        let first = VideoFrame(
            captureTimeNanos: 99,
            width: 1_152,
            height: 720,
            isKeyframe: true,
            parameterSet1: Data([1, 2, 3]),
            parameterSet2: Data([4, 5]),
            payload: Data((0..<250).map(UInt8.init))
        )
        let second = VideoFrame(
            captureTimeNanos: 100,
            width: 1_152,
            height: 720,
            isKeyframe: false,
            payload: Data([9, 8, 7])
        )
        let bytes = first.encoded() + second.encoded()
        let decoder = VideoFrameStreamDecoder()

        #expect(decoder.append(bytes.prefix(17)).isEmpty)
        #expect(decoder.append(bytes.dropFirst(17).prefix(80)).isEmpty)
        #expect(decoder.append(bytes.dropFirst(97)) == [first, second])
    }

    @Test func malformedPacketIsRejected() throws {
        let packet = AudioPacket(
            sequence: 1,
            frameIndex: 0,
            captureTimeNanos: 10,
            samples: [Int16](repeating: 0, count: 480)
        )
        var truncated = packet.encoded()
        truncated.removeLast()

        #expect(AudioPacket(data: truncated) == nil)
        #expect(AudioPacket(data: Data("not audio".utf8)) == nil)
    }
}
