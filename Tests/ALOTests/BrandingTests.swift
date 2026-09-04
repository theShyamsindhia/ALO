import Foundation
import Testing
@testable import ALO

struct BrandingTests {
    @Test("ALO branding preserves the installed app and discovery identities")
    func installedCompatibility() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let plist = try #require(PropertyListSerialization.propertyList(
            from: data, format: nil
        ) as? [String: Any])
        #expect(plist["CFBundleDisplayName"] as? String == "ALO")
        #expect(plist["CFBundleName"] as? String == "ALO")
        #expect(plist["CFBundleExecutable"] as? String == "alo")
        #expect(plist["CFBundleIdentifier"] as? String == AppUpdater.bundleID)
        #expect(AppUpdater.bundleID == "in.werai.audio")
        let services = try #require(plist["NSBonjourServices"] as? [String])
        #expect(services.contains(HostServer.serviceType))
        #expect(services.contains(MeshRoomBrowser.serviceType))
        #expect(HostServer.serviceType == "_werai-audio._tcp")
        #expect(MeshRoomBrowser.serviceType == "_werai-mesh._tcp")
    }
}
