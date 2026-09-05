import Testing
import ALOCore

@Suite struct RoomTimingBudgetTests {
    @Test func hardwareFloorNeverIncludesNetworkDelay() {
        for rtt: UInt64 in [0, 4_000_000, 600_000_000, .max] {
            #expect(RoomTiming.outputLatencyFloor(220_000_000, roundTripNanos: rtt) == 365_000_000)
        }
        #expect(RoomTiming.outputLatencyFloor(.max, renderSchedulingHeadroomNanos: .max) == 600_000_000)
    }
    @Test func liveCalibrationMarginIsBounded() {
        #expect(RoomTiming.liveIncreasePlayoutDelay(required: 300_000_000) == 350_000_000)
        #expect(RoomTiming.liveIncreasePlayoutDelay(required: 305_000_000) == 400_000_000)
        #expect(RoomTiming.liveIncreasePlayoutDelay(required: 590_000_000) == 600_000_000)
        #expect(RoomTiming.liveIncreasePlayoutDelay(required: .max) == 600_000_000)
    }
    @Test func pauseKeepsSmallCalibrationAllowanceButAllowsMaterialReductions() {
        #expect(RoomTiming.pausedPlayoutDelay(required: 315_000_000, current: 350_000_000) == 350_000_000)
        #expect(RoomTiming.pausedPlayoutDelay(required: 300_000_000, current: 600_000_000) == 350_000_000)
        #expect(RoomTiming.pausedPlayoutDelay(required: 250_000_000, current: 600_000_000) == 250_000_000)
    }
}
