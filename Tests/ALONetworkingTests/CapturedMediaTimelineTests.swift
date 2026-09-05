import Foundation
import Testing
import ALOCore
@testable import ALONetworking

@Suite struct CapturedMediaTimelineTests {
    private func stream(_ generation: UInt64 = 1) -> MediaStreamIdentifier {
        .init(sessionID: UUID(), broadcasterEpoch: 3, generation: generation)
    }
    private func packet(_ frame: UInt64 = 0, time: UInt64 = 1_000_000_000) -> AudioPacket {
        .init(sequence: UInt32(frame / 240), frameIndex: frame, captureTimeNanos: time,
              samples: .init(repeating: 1, count: 480))
    }

    @Test func firstJoinRequiresCapture() {
        let timeline = CapturedMediaTimeline()
        #expect(timeline.anchor(for: stream(), issuedAtHostNanos: 1_000_000_000) == nil)
        timeline.observe([packet()])
        let anchor = timeline.anchor(for: stream(), issuedAtHostNanos: 1_010_000_000)
        #expect(anchor?.hostPlaybackTimeNanos == 1_250_000_000)
        #expect(anchor?.frameIndex == 0)
    }

    @Test func joiningAndRenewingNeverReanchorExistingOutputs() {
        let timeline = CapturedMediaTimeline()
        timeline.observe([packet()])
        let first = timeline.anchor(for: stream(), issuedAtHostNanos: 1_010_000_000)
        let joined = timeline.anchor(for: stream(2), issuedAtHostNanos: 1_030_000_000)
        #expect(first?.captureTimeNanos == joined?.captureTimeNanos)
        #expect(first?.hostPlaybackTimeNanos == joined?.hostPlaybackTimeNanos)
        #expect(first?.frameIndex == joined?.frameIndex)
    }

    @Test func pauseAndResumeCannotReuseOldAudio() {
        let timeline = CapturedMediaTimeline()
        timeline.observe([packet()])
        timeline.setPlaying(false)
        #expect(timeline.anchor(for: stream(), issuedAtHostNanos: 2_000_000_000)?.state == .paused)
        timeline.setPlaying(true)
        #expect(timeline.anchor(for: stream(), issuedAtHostNanos: 2_000_000_000) == nil)
        timeline.observe([packet(480, time: 2_000_000_000)])
        #expect(timeline.anchor(for: stream(), issuedAtHostNanos: 2_010_000_000)?.frameIndex == 480)
    }

    @Test func staleOrReorderedCaptureDoesNotCreateAnUnplayableAnchor() {
        let timeline = CapturedMediaTimeline()
        timeline.observe([packet(480, time: 1_010_000_000), packet()])
        #expect(timeline.anchor(for: stream(), issuedAtHostNanos: 1_020_000_000)?.frameIndex == 480)
        #expect(timeline.anchor(for: stream(), issuedAtHostNanos: 1_200_000_000) == nil)
        #expect(timeline.anchor(for: stream(), issuedAtHostNanos: 900_000_000) == nil)
    }

    @Test func firstFreshCaptureRequestsResumeAnchorExactlyOnce() {
        let timeline = CapturedMediaTimeline()
        #expect(timeline.observe([packet()]))
        timeline.setPlaying(false)
        #expect(timeline.anchor(for: stream(), issuedAtHostNanos: 2_000_000_000)?.state == .paused)
        timeline.setPlaying(true)
        // Control arrives before new capture. Do not invent an anchor or wait
        // until ticket renewal: the first actual PCM reference requests refresh.
        #expect(timeline.anchor(for: stream(), issuedAtHostNanos: 2_000_000_000) == nil)
        #expect(!timeline.observe([]))
        #expect(timeline.observe([packet(480, time: 2_000_000_000)]))
        #expect(timeline.anchor(for: stream(), issuedAtHostNanos: 2_010_000_000)?.state == .running)
        #expect(!timeline.observe([packet(720, time: 2_005_000_000)]))
        timeline.invalidateCaptureReference()
        #expect(timeline.observe([packet(960, time: 3_000_000_000)]))
    }
}
