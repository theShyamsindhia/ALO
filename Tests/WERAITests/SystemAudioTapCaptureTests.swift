import CoreAudio
import Testing
@testable import WERAI
import WERAICore
import WERAISharedAudioClient

@Suite("Unified system-audio tap")
struct SystemAudioTapCaptureTests {
    @Test("44.1 kHz planar tap audio becomes audible 48 kHz stereo packets")
    @available(macOS 14.2, *)
    func convertsAndResamplesTapPCM() throws {
        var input = [Float]()
        input.reserveCapacity(441 * 2)
        for _ in 0..<441 {
            input.append(0.5)
            input.append(-0.5)
        }

        let converter = try TapPCMConverter(inputSampleRate: 44_100)
        let samples = try #require(converter.convert(interleavedSamples: input))

        #expect(samples.count.isMultiple(of: Int(AudioPacket.channelCount)))
        #expect(samples.count >= 900)
        #expect(samples.count <= 1_100)
        #expect(samples.contains { $0 > 10_000 })
        #expect(samples.contains { $0 < -10_000 })
    }

    @Test("Tap conversion preserves interleaved stereo channel order")
    @available(macOS 14.2, *)
    func preservesInterleavedStereo() throws {
        var input = [Float]()
        input.reserveCapacity(240 * 2)
        for _ in 0..<240 {
            input.append(0.25)
            input.append(-0.75)
        }

        let converter = try TapPCMConverter(
            inputSampleRate: Double(AudioPacket.sampleRate)
        )
        let samples = try #require(converter.convert(interleavedSamples: input))

        #expect(samples.count == 480)
        #expect(samples[0] > 7_000)
        #expect(samples[1] < -20_000)
    }

    @Test("A stalled callback stream requests one graph rebuild")
    @available(macOS 14.2, *)
    func detectsTapStallOnce() {
        var watchdog = TapCaptureLivenessWatchdog(
            startedAtNanos: 1_000,
            timeoutNanos: 2_000
        )

        let beforeStartupDeadline = watchdog.observe(
            latestCallback: 0, latestFrame: 0,
            sourcePlaybackIsActive: false, nowNanos: 2_999
        )
        let firstProgress = watchdog.observe(
            latestCallback: 1, latestFrame: 64,
            sourcePlaybackIsActive: false, nowNanos: 3_000
        )
        let beforeStallDeadline = watchdog.observe(
            latestCallback: 1, latestFrame: 64,
            sourcePlaybackIsActive: false, nowNanos: 4_999
        )
        let atStallDeadline = watchdog.observe(
            latestCallback: 1, latestFrame: 64,
            sourcePlaybackIsActive: false, nowNanos: 5_000
        )
        let repeatedFailure = watchdog.observe(
            latestCallback: 1, latestFrame: 64,
            sourcePlaybackIsActive: false, nowNanos: 8_000
        )
        #expect(beforeStartupDeadline == .waiting)
        #expect(firstProgress == .progressed)
        #expect(beforeStallDeadline == .waiting)
        #expect(atStallDeadline == .rebuildGraph)
        #expect(repeatedFailure == .waiting)

        var progressing = TapCaptureLivenessWatchdog(
            startedAtNanos: 10_000,
            timeoutNanos: 2_000
        )
        let progressOne = progressing.observe(
            latestCallback: 1, latestFrame: 64,
            sourcePlaybackIsActive: false, nowNanos: 11_000
        )
        let progressTwo = progressing.observe(
            latestCallback: 2, latestFrame: 128,
            sourcePlaybackIsActive: false, nowNanos: 12_500
        )
        let progressBeforeDeadline = progressing.observe(
            latestCallback: 2, latestFrame: 128,
            sourcePlaybackIsActive: false, nowNanos: 14_499
        )
        let progressAtDeadline = progressing.observe(
            latestCallback: 2, latestFrame: 128,
            sourcePlaybackIsActive: false, nowNanos: 14_500
        )
        #expect(progressOne == .progressed)
        #expect(progressTwo == .progressed)
        #expect(progressBeforeDeadline == .waiting)
        #expect(progressAtDeadline == .rebuildGraph)
    }

    @Test("A temporary Core Audio gap never ends the room broadcast")
    @available(macOS 14.2, *)
    func temporaryTapGapIsRecoverable() {
        var watchdog = TapCaptureLivenessWatchdog(
            startedAtNanos: 1_000_000_000,
            timeoutNanos: 2_000_000_000
        )

        let initialProgress = watchdog.observe(
            latestCallback: 1,
            latestFrame: 4_800,
            sourcePlaybackIsActive: true,
            nowNanos: 1_100_000_000
        )
        #expect(initialProgress == .progressed)

        // Opening or closing the microphone can briefly reconfigure Core
        // Audio. A missing callback interval must not be escalated into the
        // same terminal path as a deliberate Stop Broadcast action.
        let gap = watchdog.observe(
            latestCallback: 1,
            latestFrame: 4_800,
            sourcePlaybackIsActive: true,
            nowNanos: 4_100_000_000
        )
        #expect(gap == .rebuildGraph)

        var rebuiltWatchdog = TapCaptureLivenessWatchdog(
            startedAtNanos: 4_100_000_000,
            timeoutNanos: 2_000_000_000
        )
        let resumedProgress = rebuiltWatchdog.observe(
            latestCallback: 1,
            latestFrame: 4_800,
            sourcePlaybackIsActive: true,
            nowNanos: 4_120_000_000
        )
        #expect(resumedProgress == .progressed)
    }

    @Test("Empty callbacks recover only while the source says it is playing")
    @available(macOS 14.2, *)
    func invalidBuffersUseAuthoritativePlaybackState() {
        var playing = TapCaptureLivenessWatchdog(
            startedAtNanos: 1_000,
            timeoutNanos: 2_000
        )
        let firstEmpty = playing.observe(
            latestCallback: 1, latestFrame: 0,
            sourcePlaybackIsActive: true, nowNanos: 1_100
        )
        let continuedEmpty = playing.observe(
            latestCallback: 20, latestFrame: 0,
            sourcePlaybackIsActive: true, nowNanos: 3_100
        )
        #expect(firstEmpty == .progressed)
        #expect(continuedEmpty == .rebuildGraph)

        var paused = TapCaptureLivenessWatchdog(
            startedAtNanos: 1_000,
            timeoutNanos: 2_000
        )
        _ = paused.observe(
            latestCallback: 1, latestFrame: 0,
            sourcePlaybackIsActive: false, nowNanos: 1_100
        )
        let validSilence = paused.observe(
            latestCallback: 20, latestFrame: 0,
            sourcePlaybackIsActive: false, nowNanos: 3_100
        )
        #expect(validSilence == .progressed)
    }

    @Test("A retry budget resets only after sustained valid frames")
    @available(macOS 14.2, *)
    func sustainedFramesEstablishHealth() {
        let start: UInt64 = 1_000_000_000
        var watchdog = TapCaptureLivenessWatchdog(
            startedAtNanos: start,
            timeoutNanos: 2_000_000_000,
            stableWindowNanos: 3_000_000_000
        )

        var action = watchdog.observe(
            latestCallback: 1,
            latestFrame: 240,
            sourcePlaybackIsActive: true,
            nowNanos: start + 100_000_000
        )
        #expect(action == .progressed)

        for index in 2...31 {
            action = watchdog.observe(
                latestCallback: UInt64(index),
                latestFrame: UInt64(index * 240),
                sourcePlaybackIsActive: true,
                nowNanos: start + UInt64(index) * 100_000_000
            )
        }
        #expect(action == .sustainedProgress)
    }

    @Test("Play after a long pause receives a fresh first-frame grace period")
    @available(macOS 14.2, *)
    func playbackResumeResetsFrameDeadline() {
        let start: UInt64 = 1_000_000_000
        var watchdog = TapCaptureLivenessWatchdog(
            startedAtNanos: start,
            timeoutNanos: 2_000_000_000
        )
        _ = watchdog.observe(
            latestCallback: 1, latestFrame: 240,
            sourcePlaybackIsActive: false, nowNanos: start + 10_000_000
        )
        _ = watchdog.observe(
            latestCallback: 100, latestFrame: 240,
            sourcePlaybackIsActive: false, nowNanos: start + 10_000_000_000
        )

        let resumed = watchdog.observe(
            latestCallback: 101, latestFrame: 240,
            sourcePlaybackIsActive: true, nowNanos: start + 10_005_000_000
        )
        let stillWaiting = watchdog.observe(
            latestCallback: 200, latestFrame: 240,
            sourcePlaybackIsActive: true, nowNanos: start + 12_004_000_000
        )
        let resumeFailed = watchdog.observe(
            latestCallback: 201, latestFrame: 240,
            sourcePlaybackIsActive: true, nowNanos: start + 12_005_000_000
        )
        #expect(resumed == .progressed)
        #expect(stillWaiting == .progressed)
        #expect(resumeFailed == .rebuildGraph)
    }

    @Test("Recovery budget caps unhealthy successful rebuild loops")
    @available(macOS 14.2, *)
    func recoveryBudgetRequiresSustainedHealthToReset() {
        var budget = TapCaptureRecoveryBudget()
        #expect(budget.beginAttempt() == 1)
        #expect(budget.beginAttempt() == 2)
        #expect(budget.beginAttempt() == 3)
        #expect(budget.beginAttempt() == 4)
        #expect(budget.beginAttempt() == nil)

        budget.reset()
        #expect(budget.beginAttempt() == 1)
    }

    @Test("The real-time ring preserves stereo frames and host timestamps")
    func ringRoundTrip() throws {
        let ring = try #require(ALOTapAudioRingCreate())
        defer { ALOTapAudioRingDestroy(ring) }
        ALOTapAudioRingMarkCallback(ring)
        ALOTapAudioRingMarkCallback(ring)
        #expect(ALOTapAudioRingLatestCallback(ring) == 2)
        let input: [Float] = [0.25, -0.25, 0.75, -0.75]
        input.withUnsafeBufferPointer { samples in
            ALOTapAudioRingWriteInterleavedFloat(
                ring,
                samples.baseAddress,
                2,
                1_000,
                10
            )
        }

        var output = [Float](repeating: 0, count: 4)
        var firstHostTime: UInt64 = 0
        let framesRead = output.withUnsafeMutableBufferPointer { samples in
            ALOTapAudioRingRead(
                ring,
                0,
                samples.baseAddress,
                2,
                &firstHostTime
            )
        }

        #expect(ALOTapAudioRingLatestFrame(ring) == 2)
        #expect(framesRead == 2)
        #expect(firstHostTime == 1_000)
        #expect(output == input)
    }

    @Test("A live sample-rate or layout change invalidates tap timing")
    @available(macOS 14.2, *)
    func detectsTapFormatChange() {
        var original = AudioStreamBasicDescription()
        original.mSampleRate = 48_000
        original.mFormatID = kAudioFormatLinearPCM
        original.mFormatFlags = kAudioFormatFlagIsFloat
        original.mBytesPerPacket = 8
        original.mFramesPerPacket = 1
        original.mBytesPerFrame = 8
        original.mChannelsPerFrame = 2
        original.mBitsPerChannel = 32

        var changedRate = original
        changedRate.mSampleRate = 44_100
        var changedLayout = original
        changedLayout.mFormatFlags |= kAudioFormatFlagIsNonInterleaved

        #expect(TapStreamConfiguration(original) == TapStreamConfiguration(original))
        #expect(TapStreamConfiguration(original) != TapStreamConfiguration(changedRate))
        #expect(TapStreamConfiguration(original) != TapStreamConfiguration(changedLayout))
    }
}
