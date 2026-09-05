import Foundation
import Testing
@testable import ALO

@Suite("Privacy-conscious diagnostics")
struct DiagnosticsTests {
    @Test func keyDerivedIdentifiersAreRedactedWithoutUUIDVersionAssumptions() {
        #expect(DiagnosticRedactor.redact("peer FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF") == "peer <redacted-id>")
    }

    @Test("Diagnostic reports redact identifiers, addresses, account names, and email")
    func reportRedaction() {
        let room = DiagnosticRoomContext(
            isActive: true,
            role: .listener,
            participantCount: 2,
            remotePeerCount: 1,
            syncLabel: "Synced",
            audioIsRendering: true,
            hasBroadcaster: true,
            timing: nil
        )
        let context = DiagnosticReportContext(
            generatedAt: Date(timeIntervalSince1970: 0),
            appVersion: "1.0",
            appBuild: "1",
            operatingSystem: "macOS",
            architecture: "arm64",
            room: room,
            microphoneSelection: "custom input"
        )
        let privateDetail = "Failure at /Users/alice/Library for 192.168.1.20, 550E8400-E29B-41D4-A716-446655440000 and alice@example.com"
        let report = DiagnosticReportBuilder.build(
            context: context,
            results: [
                .network: DiagnosticCheckResult(outcome: .failed, detail: privateDetail, checkedAt: Date())
            ]
        )

        #expect(!report.contains("alice"))
        #expect(!report.contains("192.168.1.20"))
        #expect(!report.contains("550E8400-E29B-41D4-A716-446655440000"))
        #expect(report.contains("/Users/<redacted>"))
        #expect(report.contains("<redacted-ip>"))
        #expect(report.contains("<redacted-id>"))
        #expect(report.contains("<redacted-email>"))
        #expect(report.contains("Room names, device names, peer identifiers"))
    }

    @Test("Live listener timing produces an actionable ready summary")
    func listenerTimingSummary() {
        let context = DiagnosticRoomContext(
            isActive: true,
            role: .listener,
            participantCount: 3,
            remotePeerCount: 2,
            syncLabel: "Synced",
            audioIsRendering: true,
            hasBroadcaster: true,
            timing: SessionTimingDiagnostics(
                receiver: ReceiverTimingDiagnostics(
                    roundTripMilliseconds: 12.4,
                    clockOffsetMilliseconds: -2.1,
                    jitterMilliseconds: 3.2,
                    recommendedBufferMilliseconds: 250,
                    outputLatencyMilliseconds: 12,
                    renderHeadroomMilliseconds: 25,
                    outputSampleRate: 48_000,
                    outputChannelCount: 2,
                    latenessMilliseconds: 0,
                    latePacketCount: 1,
                    resyncCount: 0
                ),
                host: nil
            )
        )

        let result = context.result
        #expect(result.outcome == .passed)
        #expect(result.detail.contains("RTT 12 ms"))
        #expect(result.detail.contains("buffer 250 ms"))
        #expect(result.detail.contains("output 12 ms + 25 ms render"))
        #expect(result.detail.contains("48000 Hz/2 ch"))
        #expect(result.detail.contains("2 remote peers"))
    }

    @Test("Room diagnostics explain when no live room exists")
    func inactiveRoomGuidance() {
        let context = DiagnosticRoomContext(
            isActive: false,
            role: .none,
            participantCount: 0,
            remotePeerCount: 0,
            syncLabel: "No broadcaster",
            audioIsRendering: false,
            hasBroadcaster: false,
            timing: nil
        )

        #expect(context.result.outcome == .warning)
        #expect(context.result.detail.contains("Open a room"))
    }
}
