import Testing
import ALOCore
@testable import ALO

struct ParticipantMediaControlPolicyTests {
    @Test func secureBroadcasterCannotPretendToSetRemoteOutput() {
        #expect(!ParticipantMediaControlPolicy.allows(policy: .secureV2, isBroadcaster: true, isLocal: false))
        #expect(ParticipantMediaControlPolicy.allows(policy: .secureV2, isBroadcaster: true, isLocal: true))
        #expect(ParticipantMediaControlPolicy.allows(policy: .secureV2, isBroadcaster: false, isLocal: true))
        #expect(!ParticipantMediaControlPolicy.allows(policy: nil, isBroadcaster: true, isLocal: false))
    }
    @Test func legacyBroadcasterRetainsItsImplementedRemoteCommand() {
        #expect(ParticipantMediaControlPolicy.allows(policy: .legacyOnly, isBroadcaster: true, isLocal: false))
        #expect(!ParticipantMediaControlPolicy.allows(policy: .legacyOnly, isBroadcaster: false, isLocal: false))
        #expect(!ParticipantMediaControlPolicy.allows(policy: .migrationRequired, isBroadcaster: true, isLocal: false))
    }
}
