import Foundation
import Testing
@testable import ALO

@Suite("Persistent local voice mix")
struct VoiceLevelStoreTests {
    @Test func survivesRelaunchAndKeepsPeersIndependent() {
        let name = "voice-level-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = VoiceLevelStore(defaults: defaults)
        store.set(0.25, for: "alice")
        store.set(0, for: "bob")
        let reopened = VoiceLevelStore(defaults: defaults)
        #expect(reopened.levels["alice"] == 0.25)
        #expect(reopened.levels["bob"] == 0)
        #expect(reopened.levels["unknown"] == nil)
    }

    @Test func duckingPreservesMuteAndUserLevel() {
        #expect(MediaOutputGain.effectiveGain(participantVolume: 0.5, muted: false, duckingGain: 0.3) == 0.15)
        #expect(MediaOutputGain.effectiveGain(participantVolume: 0.5, muted: true, duckingGain: 0.3) == 0)
        #expect(MediaOutputGain.effectiveGain(participantVolume: 0.5, muted: false) == 0.5)
        #expect(MediaOutputGain.effectiveGain(participantVolume: 0.5, muted: false, duckingGain: 2) == 0.5)
    }

    @Test func clampsAndRejectsInvalidLevels() {
        let name = "voice-level-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = VoiceLevelStore(defaults: defaults)
        store.set(2, for: "alice")
        store.set(-1, for: "bob")
        store.set(.nan, for: "alice")
        store.set(.infinity, for: "charlie")
        store.set(0.5, for: "")
        #expect(store.levels == ["alice": 1, "bob": 0])
        defaults.set(["bad": Double.infinity, "high": 4], forKey: "participantVoiceLevels.v1")
        #expect(store.levels == ["high": 1])
    }
}
