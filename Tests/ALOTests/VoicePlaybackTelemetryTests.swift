import AVFoundation
import Testing
@testable import ALO

struct VoicePlaybackTelemetryTests {
    @Test func countersAndSyntheticSilenceRemainDistinct() {
        var telemetry = VoicePlaybackTelemetry()
        telemetry.received(at: 10)
        telemetry.received(at: 30)
        telemetry.received(at: 20) // Do not underflow a backward observation.
        let levels = VoiceSignalLevels(inputRMS: 0.02, inputPeak: 0.04, outputRMS: 0.04, outputPeak: 0.08)
        telemetry.scheduled(concealment: false, levels: levels)
        telemetry.scheduled(concealment: true, levels: nil)
        telemetry.droppedAtCapacity()
        #expect(telemetry.maximumArrivalGapNanos == 20)
        telemetry.resetForConfiguration()
        #expect(telemetry.maximumArrivalGapNanos == 20, "Route recovery must retain earlier ingress-stall evidence")
        #expect(telemetry.acceptedAudioBuffers == 1 && telemetry.concealmentBuffers == 1)
        #expect(telemetry.capDrops == 1 && telemetry.configurationResets == 1)
        telemetry.received(at: 1_000_000_010)
        #expect(telemetry.maximumArrivalGapNanos == 20, "Recovery deferral must not become an ingress-gap sample")
        telemetry.received(at: 1_000_000_020)
        #expect(telemetry.maximumArrivalGapNanos == 20)
        #expect(telemetry.levels == levels, "Concealment cannot relabel actual audio as a quiet microphone")
        let detail = telemetry.detail(session: 1, queuedFrames: 960, participantGain: 0.5,
            levelerGain: 1.7, playerConfigurationResets: 3)
        #expect(detail.contains("participant_volume=0.5") && detail.contains("last_audio_input_rms=0.02"))
        #expect(detail.contains("leveler_gain=1.7") && detail.contains("player_config_resets=3"))
        #expect(detail.contains("player_ingress_gap_max_ns=20"))
        #expect(detail.utf8.count < 800)
        let freshSession = VoicePlaybackTelemetry().detail(session: 2, queuedFrames: 0, participantGain: 1,
            levelerGain: 1, playerConfigurationResets: 3)
        #expect(freshSession.contains("last_audio_input_rms=unavailable"))
        #expect(freshSession.contains("player_config_resets=3"), "Retiring a session cannot erase the player's reset history")
    }
    @Test func retainedEnergyLoggingRequiresDevOrExplicitOptIn() {
        #expect(!VoiceDiagnosticLoggingPolicy.enabled(bundleIdentifier: "in.werai.audio", explicitOptIn: nil))
        #expect(!VoiceDiagnosticLoggingPolicy.enabled(bundleIdentifier: nil, explicitOptIn: "true"))
        #expect(VoiceDiagnosticLoggingPolicy.enabled(bundleIdentifier: "in.werai.audio.dev", explicitOptIn: nil))
        #expect(VoiceDiagnosticLoggingPolicy.enabled(bundleIdentifier: "in.werai.audio", explicitOptIn: "1"))
    }
    @Test func loggingIsAtMostOncePerSecondIncludingBackwardClock() {
        var throttle = VoiceDiagnosticThrottle()
        let first = throttle.admit(at: 100)
        let early = throttle.admit(at: 1_000_000_099)
        let backward = throttle.admit(at: 99)
        let boundary = throttle.admit(at: 1_000_000_100)
        #expect(first && !early && !backward && boundary)
    }
    @Test func measurementsDoNotChangeLevelingOrTreatConcealmentAsInput() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        let samples = try #require(buffer.floatChannelData?[0])
        samples.initialize(repeating: 0.02, count: 480)
        var leveler = VoicePlaybackLeveler()
        leveler.process(buffer)
        #expect(abs(leveler.gain - 1.7) < 0.000001)
        #expect(abs(samples[0] - 0.02) < 0.000001)
        #expect(abs(samples[479] - 0.034) < 0.000001)
        let measurement = try #require(leveler.lastSignalLevels)
        #expect(abs(measurement.inputRMS - 0.02) < 0.000001)
        #expect(abs(measurement.outputPeak - 0.034) < 0.000001)
        leveler.process(buffer, isConcealment: true)
        #expect(leveler.lastSignalLevels == nil)
        #expect(abs(leveler.gain - 1.7) < 0.000001)
    }
    @Test func quietAndZeroMeasurementsPreserveOriginalRamp() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        let samples = try #require(buffer.floatChannelData?[0])
        samples.initialize(repeating: 0.02, count: 480)
        var leveler = VoicePlaybackLeveler()
        leveler.process(buffer)
        samples.update(repeating: 0.004, count: 480)
        leveler.process(buffer)
        #expect(leveler.gain == 1)
        #expect(abs(samples[0] - 0.0068) < 0.000001)
        #expect(abs(samples[479] - 0.004) < 0.000001)
        let quiet = try #require(leveler.lastSignalLevels)
        #expect(abs(quiet.inputRMS - 0.004) < 0.000001)
        #expect(abs(quiet.outputPeak - 0.0068) < 0.000001)
        samples.update(repeating: 0, count: 480)
        leveler.process(buffer)
        #expect(leveler.lastSignalLevels == .init(inputRMS: 0, inputPeak: 0, outputRMS: 0, outputPeak: 0))
    }
}
