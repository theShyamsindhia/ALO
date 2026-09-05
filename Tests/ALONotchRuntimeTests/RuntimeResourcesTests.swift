import Testing
@testable import ALONotchRuntime

struct RuntimeResourcesTests {
    @Test func originalPresetsRemainAvailable() {
        #expect(NotchAnimationPreset.allCases.count == 5)
    }
}
