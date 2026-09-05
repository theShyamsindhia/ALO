import Foundation
import Testing
@testable import ALONetworking

@Suite("Bounded authenticated receiver timing wire")
struct MediaReceiverTimingReportTests {
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
