import AppKit
import Testing
@testable import ALO

@MainActor
struct AppIconTests {
    @Test func catalogAndAssets() throws {
        #expect(AppIconOption.all.count == 16)
        #expect(Set(AppIconOption.all.map(\.id)).count == 16)
        for icon in AppIconOption.all {
            let image = try #require(icon.image)
            #expect(image.isValid)
            #expect(image.size == NSSize(width: 1024, height: 1024))
        }
    }

    @Test func unknownChoiceFallsBackToOriginal() {
        #expect(AppIconOption.resolvedID(nil) == "original")
        #expect(AppIconOption.resolvedID("removed-icon") == "original")
        #expect(AppIconOption.resolvedID("frosted-orange") == "frosted-orange")
    }

    @Test func selectionPersistsAndRestoresDefault() throws {
        let suite = "ALO.AppIconTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppIconPreferences(defaults: defaults)
        #expect(preferences.selectedID == "original")
        preferences.select("midnight")
        #expect(preferences.error == nil)
        #expect(AppIconPreferences(defaults: defaults).selectedID == "midnight")
        preferences.select("original")
        #expect(AppIconPreferences(defaults: defaults).selectedID == "original")
        #expect(defaults.string(forKey: AppIconPreferences.defaultsKey) == nil)
    }
}
