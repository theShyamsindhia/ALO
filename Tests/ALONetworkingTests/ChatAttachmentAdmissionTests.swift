import Testing
@testable import ALONetworking

struct ChatAttachmentAdmissionTests {
    @Test func boundsBytesAndCompletedTransfersWithinWindow() {
        var admission = ChatAttachmentReceiveAdmission()
        let start: UInt64 = 10
        let first = admission.permits(packetBytes: 1_024, now: start)
        #expect(first)
        for _ in 0..<ChatAttachmentReceiveAdmission.maximumTransfers {
            admission.completedTransfer()
        }
        let capped = admission.permits(packetBytes: 1_024, now: start + 1)
        #expect(!capped)
        let reset = admission.permits(
            packetBytes: 1_024,
            now: start + ChatAttachmentReceiveAdmission.windowNanos
        )
        #expect(reset)
    }

    @Test func rejectsPacketsThatExceedByteBudget() {
        var admission = ChatAttachmentReceiveAdmission()
        let packet = 64 * 1_024
        var accepted = 0
        while admission.permits(packetBytes: packet, now: 1) { accepted += packet }
        #expect(accepted <= ChatAttachmentReceiveAdmission.maximumBytes)
        let beyondBudget = admission.permits(packetBytes: packet, now: 2)
        #expect(!beyondBudget)
    }
}
