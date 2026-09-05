import Foundation
import Testing
@testable import ALONetworking

@Suite("Bounded authenticated receiver timing wire")
struct MediaReceiverTimingReportTests {
    @Test func playbackTelemetryUsesRelativeFreshnessAndPreservesStaticScreenAge() throws {
        let playback = PlaybackSyncReport(measuredAtNanos: 900_000_000_000,
            latenessNanos: 10_000_000, latePacketCount: 3, resyncCount: 4,
            driftNanos: 40_000_000, driftSampleAgeNanos: 1_500_000_000,
            screenTiming: .init(latestHandoffAgeNanos: 90_000_000_000, latestDeadlineMissNanos: 0,
                oldestPendingDeadlineMissNanos: 30_000_000))
        let report = try MediaReceiverTimingReport(hardwareOutputFloorNanos: 250_000_000,
            networkRecommendedDelayNanos: 300_000_000, playback: playback)
        #expect(report.playback?.measuredAtNanos == 0)
        #expect(report.playback?.driftNanos == 40_000_000)
        let aged = try #require(report.aged(by: 1_000_000_000))
        #expect(aged.sampleAgeNanos == 1_000_000_000)
        #expect(aged.playback?.driftNanos == nil && aged.playback?.driftSampleAgeNanos == nil)
        #expect(aged.playback?.screenTiming?.latestHandoffAgeNanos == 60_000_000_000)
        #expect(aged.playback?.screenTiming?.oldestPendingDeadlineMissNanos == 30_000_000)
        #expect(aged.playback?.latePacketCount == 3)
    }
    @Test func wirePreservesIndependentHardwareFloorAndNetworkMeasurement() throws {
        let stream = MediaStreamIdentifier(sessionID: UUID(), broadcasterEpoch: 7, generation: 8)
        let report = try MediaReceiverTimingReport(hardwareOutputFloorNanos: 300_000_000,
            networkRecommendedDelayNanos: 600_000_000, roundTripNanos: 900_000_000, sampleAgeNanos: 50_000_000)
        let bytes = try MediaControlWireMessage.timingReport(stream: stream, report: report).encoded()
        guard case let .timingReport(decodedStream, decodedReport) = try MediaControlWireMessage(encoded: bytes) else {
            Issue.record("Timing message decoded as another control kind"); return
        }
        #expect(decodedStream == stream && decodedReport == report)
        #expect(decodedReport.hardwareOutputFloorNanos == 300_000_000) // RTT is not added.
        #expect(report.aged(by: 2_000_000_000) == nil)
    }
    @Test func invalidMeasurementsCannotPassInboundValidation() throws {
        #expect(throws: SecureTransportError.self) {
            try MediaReceiverTimingReport(hardwareOutputFloorNanos: 1, networkRecommendedDelayNanos: 250_000_000)
        }
        let report = try MediaReceiverTimingReport(hardwareOutputFloorNanos: 250_000_000, networkRecommendedDelayNanos: 300_000_000)
        let wire = try MediaControlWireMessage.timingReport(stream: .init(sessionID: UUID(), broadcasterEpoch: 7, generation: 1), report: report).encoded()
        let json = try #require(String(data: wire, encoding: .utf8))
        let invalid = Data(json.replacingOccurrences(of: "\"sampleAgeNanos\":0", with: "\"sampleAgeNanos\":2000000001").utf8)
        #expect(invalid != wire)
        #expect(throws: SecureTransportError.self) { try MediaControlWireMessage(encoded: invalid) }
    }
}
