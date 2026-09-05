import Foundation
import Testing
import ALOCore

@Suite("Local automatic audio synchronization")
struct LocalAudioSyncPolicyTests {
    @Test func sustainedDriftTriggersOnceAndHonorsCooldown() {
        var policy = LocalAudioSyncPolicy()
        for tick in 0..<20 {
            let result = policy.shouldRealign(driftNanos: 45_000_000, now: UInt64(tick) * 50_000_000)
            #expect(!result)
        }
        let trigger = policy.shouldRealign(driftNanos: 45_000_000, now: 1_000_000_000)
        #expect(trigger)
        for tick in 21..<180 {
            let result = policy.shouldRealign(driftNanos: 90_000_000, now: UInt64(tick) * 50_000_000)
            #expect(!result)
        }
        for tick in 180..<200 {
            let result = policy.shouldRealign(driftNanos: 90_000_000, now: UInt64(tick) * 50_000_000)
            #expect(!result)
        }
        let again = policy.shouldRealign(driftNanos: 90_000_000, now: 10_000_000_000)
        #expect(again)
    }

    @Test func spikesUnknownAndInterruptedMeasurementsDoNotTrigger() {
        var policy = LocalAudioSyncPolicy()
        let start = policy.shouldRealign(driftNanos: 50_000_000, now: 0)
        let spike = policy.shouldRealign(driftNanos: 0, now: 50_000_000)
        let unknown = policy.shouldRealign(driftNanos: nil, now: 100_000_000)
        let resumed = policy.shouldRealign(driftNanos: 100_000_000, now: 5_000_000_000)
        #expect(!start && !spike && !unknown && !resumed)
        let gap = policy.shouldRealign(driftNanos: 100_000_000, now: 6_000_000_000)
        #expect(!gap)
    }

    @Test func optOutAndMandatoryRecoveryResetEvidence() {
        var policy = LocalAudioSyncPolicy()
        policy.setEnabled(false)
        for tick in 0..<30 {
            let result = policy.shouldRealign(driftNanos: 500_000_000, now: UInt64(tick) * 50_000_000)
            #expect(!result)
        }
        policy.didRealign(at: 2_000_000_000)
        policy.setEnabled(true)
        #expect(policy.isCoolingDown(at: 3_000_000_000))
        #expect(!policy.isCoolingDown(at: 10_000_000_000))
    }

    @Test func reportsAdvertiseReceiverOwnershipAndDecodeLegacy() throws {
        let report = PlaybackSyncReport(measuredAtNanos: 1, latenessNanos: 0,
            latePacketCount: 0, resyncCount: 0, automaticSyncEnabled: false)
        let decoded = try JSONDecoder().decode(PlaybackSyncReport.self, from: JSONEncoder().encode(report))
        #expect(decoded.automaticSyncEnabled == false)
        let legacy = Data(#"{"measuredAtNanos":1,"latenessNanos":0,"latePacketCount":0,"resyncCount":0}"#.utf8)
        #expect(try JSONDecoder().decode(PlaybackSyncReport.self, from: legacy).automaticSyncEnabled == nil)
    }
}
