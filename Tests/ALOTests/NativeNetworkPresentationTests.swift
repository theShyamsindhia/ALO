import ALONetworkUI
import AppKit
import SwiftUI
import Testing

extension NativePresentationTests {
    @Suite(.serialized) @MainActor
    struct NativeNetworkPresentationTests {
        @Test("Network browser at compact and regular sizes", arguments: [false, true], ["normal", "long", "empty", "pending"])
        func browserRenders(dark: Bool, state: String) async throws {
            _ = NSApplication.shared
            let folder = ProcessInfo.processInfo.environment["ALO_NETWORKS_SNAPSHOT_DIR"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
            if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            for size in [NSSize(width: 600, height: 420), NSSize(width: 800, height: 550)] {
                try await capture(NetworkBrowserFixture(state: state),
                    name: "browser-\(state)-\(Int(size.width))", folder: folder, size: size, dark: dark)
            }
        }

        @Test(arguments: [false, true])
        func onboardingRenders(dark: Bool) async throws {
            _ = NSApplication.shared
            let folder = ProcessInfo.processInfo.environment["ALO_NETWORKS_SNAPSHOT_DIR"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
            if let folder {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            for (name, stage, saved, busy, error) in [
                ("04-identity", ALOIdentitySetupStage.identity, false, false, Optional<String>.none),
                ("05-recovery", .recovery, false, false, nil),
                ("06-recovery-saved", .recovery, true, false, nil),
                ("07-identity-error", .identity, false, false, "Enter your name to continue."),
                ("10-identity-busy", .identity, false, true, nil),
            ] {
                let view = ALOIdentitySetupView(
                    stage: stage, displayName: .constant("Raj"),
                    recoveryImportText: .constant(""), recoveryExported: saved, isBusy: busy, errorMessage: error,
                    onCreateIdentity: {}, onRestoreIdentity: {}, onImportRecoveryFile: {},
                    onExportRecovery: {}, onContinue: {})
                try await capture(view, name: name, folder: folder, size: NSSize(width: 440, height: 390), dark: dark)
            }
            let nearby = ALONetworkSidebar(
                networks: [], selectedNetworkID: .constant(nil),
                identityName: "Raj", identityFingerprint: "", onCreateNetwork: {}, onImportNetwork: {},
                onExportPublicIdentity: {}, nearbyNetworks: [.init(id: UUID(), name: "Studio")])
            try await capture(
                nearby, name: "08-nearby", folder: folder, size: NSSize(width: 440, height: 600), dark: dark)
            let requests = ALONetworkSidebar(
                networks: [], selectedNetworkID: .constant(nil),
                identityName: "Raj", identityFingerprint: "", onCreateNetwork: {}, onImportNetwork: {},
                onExportPublicIdentity: {},
                joinRequests: [.init(id: UUID(), name: "Alex", networkName: "Studio", fingerprint: "test-public-identity")])
            try await capture(
                requests, name: "09-join-request", folder: folder, size: NSSize(width: 320, height: 600), dark: dark)
            let denied = ALONetworkSidebar(
                networks: [], selectedNetworkID: .constant(nil),
                identityName: "Raj", identityFingerprint: "", onCreateNetwork: {}, onImportNetwork: {},
                onExportPublicIdentity: {}, nearbyError: "Allow Local Network access in Settings, then try again.")
            try await capture(denied, name: "11-nearby-denied", folder: folder, size: NSSize(width: 320, height: 600), dark: dark)
            let waiting = ALONetworkSidebar(
                networks: [], selectedNetworkID: .constant(nil),
                identityName: "Raj", identityFingerprint: "", onCreateNetwork: {}, onImportNetwork: {},
                onExportPublicIdentity: {},
                nearbyNetworks: [.init(id: UUID(), name: "Studio", status: .waitingForApproval)])
            try await capture(waiting, name: "12-nearby-waiting-cancel", folder: folder,
                size: NSSize(width: 320, height: 600), dark: dark)
        }

        private func capture<V: View>(_ content: V, name: String, folder: URL?, size: NSSize, dark: Bool)
            async throws
        {
            let window = NSWindow(
                contentRect: NSRect(origin: NSPoint(x: -2000, y: 0), size: size),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let view = NSHostingView(
                rootView: content.environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.controlActiveState, .active)
                    .transaction { $0.disablesAnimations = true }
                    .frame(width: size.width, height: size.height)
                    .background(Color(nsColor: .windowBackgroundColor)))
            window.contentView = view
            defer { window.close() }
            window.orderBack(nil)
            try await Task.sleep(for: .milliseconds(300))
            view.layoutSubtreeIfNeeded()
            #expect(view.bounds.width == size.width)
            #expect(view.bounds.height == size.height)
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(data.count > 1000)
            if let folder {
                try data.write(to: folder.appendingPathComponent(name + (dark ? "-dark.png" : "-light.png")))
            }
        }
    }
}
