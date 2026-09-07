import Testing
import ALOAppModel

struct NetworkJoinAttentionGateTests {
    @Test func burstsAndCancelledRequestChurnCannotRepeatedlyDemandAttention() {
        var gate = NetworkJoinAttentionGate()
        func notify(_ pending: Bool, _ now: Double) -> Bool { gate.shouldNotify(pending: pending, now: now) }
        #expect(!notify(false, 0))
        #expect(notify(true, 1))
        #expect(!notify(true, 70))
        #expect(!notify(false, 71))
        #expect(notify(true, 72))
        #expect(!notify(false, 73))
        #expect(!notify(true, 74))
        #expect(!notify(false, 75))
        #expect(!notify(true, .nan))
    }
}
