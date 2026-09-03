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
            chatHandler: { _, _, _ in },
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
}
