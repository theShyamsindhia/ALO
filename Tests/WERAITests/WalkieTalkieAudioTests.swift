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

    @Test("Voice backlog is reset before it becomes audibly stale")
    func boundedVoiceBacklog() {
        #expect(!WalkieTalkiePlaybackTracker.shouldResetBuffer(
            scheduledFrames: 2_000,
            incomingFrames: 640,
            maximumFrames: 2_880
        ))
        #expect(WalkieTalkiePlaybackTracker.shouldResetBuffer(
            scheduledFrames: 2_500,
            incomingFrames: 640,
            maximumFrames: 2_880
        ))
    }
}
