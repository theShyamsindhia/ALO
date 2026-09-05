import Testing
import Foundation
import ALOCore
@testable import ALONetworking

@Suite struct SecureRoomTimingPolicyTests {
    private func report(_ network: UInt64 = 250_000_000, floor: UInt64 = 250_000_000) throws -> MediaReceiverTimingReport {
        try .init(hardwareOutputFloorNanos: floor, networkRecommendedDelayNanos: max(network, floor))
    }
    @Test func lateSlowJoinCannotRetimeHealthyRoomButBluetoothFloorCan() throws {
        var policy = SecureRoomTimingPolicy()
        policy.captureStarted(at: 0)
        policy.record(peer: UUID(), report: try report(), receivedAt: 100_000_000)
        let late = UUID()
        policy.record(peer: late, report: try report(600_000_000), receivedAt: 1_200_000_000)
        let slowDelay = policy.desiredDelay(now: 1_200_000_000, current: 250_000_000,
            localHardwareFloor: 250_000_000, playing: true)
        #expect(slowDelay == 250_000_000)
        policy.record(peer: late, report: try report(600_000_000, floor: 320_000_000), receivedAt: 1_300_000_000)
        let bluetoothDelay = policy.desiredDelay(now: 1_300_000_000, current: 250_000_000,
            localHardwareFloor: 250_000_000, playing: true)
        #expect(bluetoothDelay == 400_000_000)
    }
    @Test func emptyStartupCohortDoesNotBecomeLateJoinerNetworkVote() throws {
        var policy = SecureRoomTimingPolicy()
        policy.captureStarted(at: 0)
        policy.record(peer: UUID(), report: try report(600_000_000), receivedAt: 10_000_000_000)
        let delay = policy.desiredDelay(now: 10_000_000_000, current: 250_000_000,
            localHardwareFloor: 250_000_000, playing: true)
        #expect(delay == 250_000_000)
    }
    @Test func staleReportsNeverMoveLivePlaybackBackward() throws {
        var policy = SecureRoomTimingPolicy()
        policy.record(peer: UUID(), report: try report(floor: 400_000_000), receivedAt: 0)
        let live = policy.desiredDelay(now: 3_000_000_000, current: 450_000_000,
            localHardwareFloor: 250_000_000, playing: true)
        let paused = policy.desiredDelay(now: 3_000_000_000, current: 450_000_000,
            localHardwareFloor: 250_000_000, playing: false)
        #expect(live == 450_000_000)
        #expect(paused == 250_000_000)
    }
    @Test func diagnosticSamplesAgeWithoutBecomingFreshWhenPolled() throws {
        var policy = SecureRoomTimingPolicy()
        let peer = UUID()
        let report = try MediaReceiverTimingReport(hardwareOutputFloorNanos: 250_000_000,
            networkRecommendedDelayNanos: 250_000_000, sampleAgeNanos: 200_000_000)
        policy.record(peer: peer, report: report, receivedAt: 1_000_000_000)
        let first = try #require(policy.measurements(at: 1_300_000_000).first)
        #expect(first.ageNanos == 500_000_000)
        #expect(first.receivedElapsedNanos == 300_000_000)
        #expect(policy.measurements(at: 2_900_000_000).isEmpty)
        #expect(policy.measurements(at: 900_000_000).isEmpty)
        policy.remove(peer: peer)
        #expect(policy.measurements(at: 1_300_000_000).isEmpty)
    }
}
