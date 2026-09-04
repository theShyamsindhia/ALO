import Testing
import ALOCore

struct DeviceDisplayNameTests {
    @Test("Generated device names are stable and Docker-style")
    func stableGeneratedName() {
        let first = DeviceDisplayName.generated(from: "stable-node-id")
        let second = DeviceDisplayName.generated(from: "stable-node-id")

        #expect(first == second)
        #expect(first.split(separator: "-").count == 3)
        #expect(first != DeviceDisplayName.generated(from: "another-node-id"))
    }

    @Test("Generated device icons and colors are stable and customizable")
    func stableGeneratedAppearance() {
        let first = DeviceAppearance.generated(from: "stable-node-id")
        #expect(first == DeviceAppearance.generated(from: "stable-node-id"))
        #expect(DeviceAppearance.icons.contains(first.icon))
        #expect(DeviceAppearance.colors.contains(first.colorHex))
        #expect(DeviceAppearance(icon: "sparkles", colorHex: "e45b69") == .init(
            icon: "sparkles",
            colorHex: "E45B69"
        ))
    }
}
