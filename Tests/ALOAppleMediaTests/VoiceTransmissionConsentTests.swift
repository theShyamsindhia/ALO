import Foundation
import Testing
@testable import ALOAppleMedia

struct VoiceTransmissionConsentTests {
    @Test func permissionResultCannotReopenRevokedOrReplacementRequest() throws {
        let local = UUID(), peer = UUID()
        var consent = VoiceTransmissionConsent()
        let first = try consent.request(recipients: [peer], connected: [peer], localID: local)
        consent.revoke()
        let second = try consent.request(recipients: [peer], connected: [peer], localID: local)
        #expect(consent.grant(first.id, connected: [peer]) == nil)
        #expect(consent.grant(second.id, connected: [peer])?.id == second.id)
        consent.revoke()
        #expect(consent.grant(second.id, connected: [peer]) == nil)
    }
    @Test func newlyJoinedPeersDoNotEnterFixedRecipientSnapshot() throws {
        let local = UUID(), selected = UUID(), newcomer = UUID()
        var consent = VoiceTransmissionConsent()
        let request = try consent.request(recipients: [selected], connected: [selected], localID: local)
        #expect(consent.grant(request.id, connected: [selected, newcomer])?.recipients == [selected])
        #expect(!consent.remainsValid(connected: [newcomer]))
        #expect(throws: AppleMediaError.invalidState) {
            try consent.request(recipients: [newcomer], connected: [selected, newcomer], localID: local)
        }
    }
    @Test func departingPeerInvalidatesPendingPermission() throws {
        let local = UUID(), peer = UUID()
        var consent = VoiceTransmissionConsent()
        let request = try consent.request(recipients: [peer], connected: [peer], localID: local)
        #expect(consent.grant(request.id, connected: []) == nil)
        #expect(consent.active == nil)
    }
}
