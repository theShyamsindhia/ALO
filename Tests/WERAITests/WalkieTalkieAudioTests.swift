import Foundation
import Testing
@testable import WERAI
import WERAICore

struct WalkieTalkieAudioTests {
    @Test("Walkie-talkie playback uses an AVAudioEngine-compatible format")
    func playerConstructionUsesSupportedFormat() {
        let player = WalkieTalkiePlayer()

        withExtendedLifetime(player) {}
    }

    @Test("A room can be constructed without configuring walkie-talkie audio")
    @MainActor
    func roomConstructionDoesNotStartAudioPlayback() {
        let session = MeshSession(
            room: RoomConfiguration(name: "Construction test"),
            nodeID: "local",
            displayName: "Local Mac",
            statusHandler: { _ in },
            identityHandler: { _, _ in },
            participantsHandler: { _ in },
            mediaStateHandler: { _ in },
            nowPlayingHandler: { _ in },
            chatHandler: { _, _, _, _ in },
            queueHandler: { _ in },
            videoHandler: { _ in }
        )

        withExtendedLifetime(session) {}
    }

    @Test("Wire PCM converts to the Float32 format required by AVAudioEngine")
    func pcm16Conversion() throws {
        let wireBytes = Data([
            0x00, 0x80,
            0x00, 0x00,
            0xFF, 0x7F,
        ])
        let buffer = try #require(
            WalkieTalkiePlayer.makePlaybackBuffer(fromPCM16Mono: wireBytes)
        )
        let samples = try #require(buffer.floatChannelData?[0])

        #expect(buffer.format.commonFormat == .pcmFormatFloat32)
        #expect(buffer.frameLength == 3)
        #expect(samples[0] == -1)
        #expect(samples[1] == 0)
        #expect(abs(samples[2] - (32_767 / 32_768)) < 0.000_001)
    }

    @Test("Microphones are ordered with the default first and stable name ties")
    func microphoneOrdering() {
        let devices = VoiceInputCatalog.sorted([
            VoiceInputDevice(id: "z", name: "Studio Mic", isSystemDefault: false),
            VoiceInputDevice(id: "b", name: "Built-in Mic", isSystemDefault: true),
            VoiceInputDevice(id: "a", name: "studio mic", isSystemDefault: false),
        ])

        #expect(devices.map(\.id) == ["b", "a", "z"])
    }

    @Test("CoreAudio input catalog has unique live device identifiers")
    func microphoneCatalogIdentifiersAreUnique() {
        let devices = VoiceInputCatalog.availableDevices()

        #expect(Set(devices.map(\.id)).count == devices.count)
        #expect(devices.filter(\.isSystemDefault).count <= 1)
        #expect(!devices.contains { $0.id == VirtualAudioDevice.uid })
        #expect(VoiceInputCatalog.usesSystemDefault(nil))
        if let systemDefault = devices.first(where: \.isSystemDefault) {
            #expect(VoiceInputCatalog.usesSystemDefault(systemDefault.id))
        }
    }

    @Test("Concurrent talkers receive independent Float32 playback buffers")
    func concurrentTalkerBuffersAreIndependent() throws {
        let alice = try #require(WalkieTalkiePlayer.makePlaybackBuffer(
            fromPCM16Mono: Data([0x00, 0x40])
        ))
        let bob = try #require(WalkieTalkiePlayer.makePlaybackBuffer(
            fromPCM16Mono: Data([0x00, 0xC0])
        ))
        let aliceSamples = try #require(alice.floatChannelData?[0])
        let bobSamples = try #require(bob.floatChannelData?[0])

        #expect(alice.format.commonFormat == .pcmFormatFloat32)
        #expect(bob.format.commonFormat == .pcmFormatFloat32)
        #expect(aliceSamples[0] == 0.5)
        #expect(bobSamples[0] == -0.5)
    }

    @Test("Voice metering follows PCM amplitude without reacting to silence")
    func voiceLevelMetering() {
        let silence = Data(repeating: 0, count: 640)
        let quiet = Data(Array(repeating: [UInt8(0xCD), UInt8(0x0C)], count: 320).flatMap { $0 })
        let loud = Data(Array(repeating: [UInt8(0x00), UInt8(0x40)], count: 320).flatMap { $0 })

        let silenceLevel = VoiceLevelMeter.normalizedLevel(fromPCM16Mono: silence)
        let quietLevel = VoiceLevelMeter.normalizedLevel(fromPCM16Mono: quiet)
        let loudLevel = VoiceLevelMeter.normalizedLevel(fromPCM16Mono: loud)

        #expect(silenceLevel == 0)
        #expect(quietLevel > 0)
        #expect(loudLevel > quietLevel)
        #expect(loudLevel <= 1)
    }

    @Test("Voice level envelope rises faster than it falls")
    func voiceLevelEnvelope() {
        var envelope = VoiceLevelEnvelope()
        let attack = envelope.update(target: 1)
        let release = envelope.update(target: 0)

        #expect(attack == 0.5)
        #expect(release > 0)
        #expect(release < attack)
        envelope.reset()
        #expect(envelope.level == 0)
    }

    @Test("Interleaved talkers keep independent sequence state")
    func independentTalkerSequences() {
        var tracker = WalkieTalkiePlaybackTracker()
        tracker.begin("alice")
        tracker.begin("bob")

        let aliceFirst = tracker.accepts(sessionID: "alice", sequence: 1)
        let bobFirst = tracker.accepts(sessionID: "bob", sequence: 1)
        let aliceSecond = tracker.accepts(sessionID: "alice", sequence: 2)
        let bobDuplicate = tracker.accepts(sessionID: "bob", sequence: 1)
        #expect(aliceFirst)
        #expect(bobFirst)
        #expect(aliceSecond)
        #expect(!bobDuplicate)

        tracker.end("alice")
        #expect(tracker.lastSequences["alice"] == nil)
        #expect(tracker.lastSequences["bob"] == 1)
    }

    @Test("Incoming voice is dropped before queued audio becomes stale")
    func boundedVoiceBacklog() {
        #expect(!WalkieTalkiePlaybackTracker.shouldDropIncomingBuffer(
            scheduledFrames: 2_000,
            incomingFrames: 640,
            maximumFrames: 2_880
        ))
        #expect(WalkieTalkiePlaybackTracker.shouldDropIncomingBuffer(
            scheduledFrames: 2_500,
            incomingFrames: 640,
            maximumFrames: 2_880
        ))
    }

    @Test("A rapid began after ended replaces the draining receiver session")
    func endedSessionRequiresFreshReceiverState() {
        var lifecycle = VoicePlaybackSessionLifecycle()

        let initialBeginNeedsReplacement = lifecycle.beginRequiresReplacement()
        #expect(!initialBeginNeedsReplacement)
        lifecycle.markEnding()
        #expect(lifecycle.isEnding)
        let revivedBeginNeedsReplacement = lifecycle.beginRequiresReplacement()
        #expect(revivedBeginNeedsReplacement)
        #expect(!lifecycle.isEnding)
    }

    @Test("Microphone chunks are packetized into exact 20 ms frames")
    func exactVoicePacketization() throws {
        let packetizer = VoicePacketizer()
        let source = Data((0..<1_280).map { UInt8($0 % 251) })

        #expect(packetizer.append(source.prefix(117)).isEmpty)
        let first = packetizer.append(source[117..<790])
        let second = packetizer.append(source[790...])

        #expect(first.count == 1)
        #expect(second.count == 1)
        #expect(first[0].count == 640)
        #expect(second[0].count == 640)
        #expect(first[0] + second[0] == source)
        #expect(packetizer.pendingByteCount == 0)
    }

    @Test("Voice jitter buffer waits 80 ms and restores packet order")
    func jitterBufferStartupAndOrdering() {
        var jitter = VoiceJitterBuffer()
        let p1 = Data([1, 0])
        let p2 = Data([2, 0])
        let p3 = Data([3, 0])
        let p4 = Data([4, 0])

        #expect(jitter.insert(sequence: 2, data: p2).isEmpty)
        #expect(jitter.insert(sequence: 1, data: p1).isEmpty)
        #expect(jitter.insert(sequence: 4, data: p4).isEmpty)
        let output = jitter.insert(sequence: 3, data: p3)

        #expect(output == [.audio(p1), .audio(p2), .audio(p3), .audio(p4)])
        #expect(jitter.isStarted)
        #expect(jitter.expectedSequence == 5)
    }

    @Test("Voice jitter buffer conceals a small gap and rejects its late packet")
    func jitterBufferGapConcealment() {
        var jitter = VoiceJitterBuffer(startupPacketCount: 1)
        let packet = Data([1, 0])

        #expect(jitter.insert(sequence: 1, data: packet) == [.audio(packet)])
        #expect(jitter.insert(sequence: 3, data: packet).isEmpty)
        #expect(jitter.insert(sequence: 4, data: packet) == [
            .silence(frames: 320), .audio(packet), .audio(packet),
        ])
        #expect(jitter.concealedPacketCount == 1)
        #expect(jitter.insert(sequence: 2, data: packet).isEmpty)
        #expect(jitter.lateDropCount == 1)
    }

    @Test("Voice jitter buffer bounds a session that never becomes contiguous")
    func jitterBufferPendingBound() {
        var jitter = VoiceJitterBuffer(startupPacketCount: 4, maximumPendingPackets: 4)
        for sequence in stride(from: UInt64(1), through: 11, by: 2) {
            _ = jitter.insert(sequence: sequence, data: Data([UInt8(sequence), 0]))
        }

        #expect(jitter.pending.count == 4)
        #expect(jitter.pending.keys.min() == 5)
        #expect(jitter.lateDropCount == 2)
    }
}
