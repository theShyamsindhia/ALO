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

    @Test("A stalled tap reports failure once and progress resets its deadline")
    @available(macOS 14.2, *)
    func detectsTapStallOnce() {
        var watchdog = TapCaptureLivenessWatchdog(
            startedAtNanos: 1_000,
            timeoutNanos: 2_000
        )

        let beforeStartupDeadline = watchdog.observe(latestFrame: 0, nowNanos: 2_999)
        let firstProgress = watchdog.observe(latestFrame: 64, nowNanos: 3_000)
        let beforeStallDeadline = watchdog.observe(latestFrame: 64, nowNanos: 4_999)
        let atStallDeadline = watchdog.observe(latestFrame: 64, nowNanos: 5_000)
        let repeatedFailure = watchdog.observe(latestFrame: 64, nowNanos: 8_000)
        #expect(!beforeStartupDeadline)
        #expect(!firstProgress)
        #expect(!beforeStallDeadline)
        #expect(atStallDeadline)
        #expect(!repeatedFailure)

        var progressing = TapCaptureLivenessWatchdog(
            startedAtNanos: 10_000,
            timeoutNanos: 2_000
        )
        let progressOne = progressing.observe(latestFrame: 64, nowNanos: 11_000)
        let progressTwo = progressing.observe(latestFrame: 128, nowNanos: 12_500)
        let progressBeforeDeadline = progressing.observe(latestFrame: 128, nowNanos: 14_499)
        let progressAtDeadline = progressing.observe(latestFrame: 128, nowNanos: 14_500)
        #expect(!progressOne)
        #expect(!progressTwo)
        #expect(!progressBeforeDeadline)
        #expect(progressAtDeadline)
    }

    @Test("The real-time ring preserves stereo frames and host timestamps")
    func ringRoundTrip() throws {
        let ring = try #require(ALOTapAudioRingCreate())
        defer { ALOTapAudioRingDestroy(ring) }
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
