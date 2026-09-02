import Testing
import WERAICore

struct DeviceDisplayNameTests {
    @Test("Generated device names are stable and Docker-style")
    func stableGeneratedName() {
        let first = DeviceDisplayName.generated(from: "stable-node-id")
        let second = DeviceDisplayName.generated(from: "stable-node-id")

        #expect(first == second)
        #expect(first.split(separator: "-").count == 3)
        #expect(first != DeviceDisplayName.generated(from: "another-node-id"))
    }
}
