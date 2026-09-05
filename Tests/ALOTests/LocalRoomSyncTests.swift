import Testing
@testable import ALO

struct LocalRoomSyncTests {
    @Test("The local Sync action sends exactly the local ID")
    func localOnly() {
        var targets: [String] = []
        let accepted = ALOViewModel.performLocalResync(currentParticipantID: "this-mac") { target in
            targets.append(target)
            return true
        }
        #expect(accepted)
        #expect(targets == ["this-mac"])
    }

    @Test("Missing local identity never requests the all-listeners fallback")
    func absentIdentity() {
        let identities: [String?] = [nil, ""]
        for identity in identities {
            var didSend = false
            #expect(!ALOViewModel.performLocalResync(currentParticipantID: identity) { _ in didSend = true; return true })
            #expect(!didSend)
        }
    }

    @Test("Unavailable targeted synchronization is reported to the UI")
    func unavailable() {
        #expect(!ALOViewModel.performLocalResync(currentParticipantID: "this-mac") { _ in false })
    }
}
