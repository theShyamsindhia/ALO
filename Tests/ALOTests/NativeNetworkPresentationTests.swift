import ALONetworkUI
import AppKit
import SwiftUI
import Testing

extension NativePresentationTests {
    @Suite(.serialized) @MainActor
    struct NativeNetworkPresentationTests {
        @Test("Network browser at compact and regular sizes", arguments: [false, true], ["normal", "long", "empty", "pending", "owner-empty"])
        func browserRenders(dark: Bool, state: String) async throws {
            _ = NSApplication.shared
            let folder = ProcessInfo.processInfo.environment["ALO_NETWORKS_SNAPSHOT_DIR"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
            if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            // Additional below-minimum content stress coverage; actual supported
            // native window sizes are covered by NetworkWindowPresentationTests.
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

        /// Renders every surface restyled to the shared ALO style, for side-by-side review
        /// with the pre-style renders. Files are prefixed `alo-`.
        @Test(arguments: [false, true])
        func aloStyleRenders(dark: Bool) async throws {
            _ = NSApplication.shared
            let folder = ProcessInfo.processInfo.environment["ALO_NETWORKS_SNAPSHOT_DIR"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
            if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            let me = "alo-user-v1:3f9a21c08b7e0d114c2e9a7755b1f0e2d4c6a8b9e1f3a5c7d9e0b2c4d6f8a1b3"
            let owner = "alo-user-v1:a41c77e02b9d5f63c8e1a0b4d7f2e9c6b3a5d8e1f0c2b4a6d8e0f1a3c5b7d9e2"
            let other = "alo-user-v1:0d5be3a9c1f7e2d4b6a8c0e2f4a6b8d0e1c3a5b7d9f0e2c4a6b8d0f1e3a5c7b9"
            let members = [
                ALOMemberSummary(id: me, name: "Raj", fingerprint: me, isCurrentUser: true),
                ALOMemberSummary(id: owner, name: "Network owner", fingerprint: owner, isOwner: true),
                ALOMemberSummary(id: other, name: "Member", fingerprint: other),
            ]
            let sheet = NSSize(width: 540, height: 520)

            try await capture(ALOCreateNetworkView(name: .constant("Studio"), onCreate: {}, onCancel: {}),
                name: "alo-13-create-network", folder: folder, size: NSSize(width: 540, height: 360), dark: dark)
            try await capture(ALOCreateNetworkView(name: .constant(""), errorMessage: "Enter a name for your network.",
                onCreate: {}, onCancel: {}),
                name: "alo-14-create-network-error", folder: folder, size: NSSize(width: 540, height: 400), dark: dark)
            try await capture(ALOImportInvitationView(invitationText: .constant(""), onImport: {}, onImportFile: {}, onCancel: {}),
                name: "alo-15-import-invitation", folder: folder, size: NSSize(width: 540, height: 500), dark: dark)
            try await capture(ALOCreateChannelView(networkName: "Studio", name: .constant("Late night"),
                isPrivate: .constant(false), selectedMemberIDs: .constant([]), members: members,
                onCreate: {}, onCancel: {}),
                name: "alo-16-create-channel", folder: folder, size: NSSize(width: 540, height: 440), dark: dark)
            try await capture(ALOCreateChannelView(networkName: "Studio", name: .constant("Late night"),
                isPrivate: .constant(true), selectedMemberIDs: .constant([other]), members: members,
                onCreate: {}, onCancel: {}),
                name: "alo-17-create-channel-private", folder: folder, size: NSSize(width: 540, height: 600), dark: dark)
            try await capture(ALOAddMemberView(networkName: "Studio", publicIdentityText: .constant(""),
                onCreateInvitation: {}, onImportPublicIdentityFile: {}, onExportInvitation: {}, onCancel: {}),
                name: "alo-18-add-member", folder: folder, size: NSSize(width: 540, height: 540), dark: dark)
            try await capture(ALOAddMemberView(networkName: "Studio", publicIdentityText: .constant(""),
                recipient: ALOMemberSummary(id: other, name: "Invited member", fingerprint: other),
                invitationText: "{\"invitation\":\"fixture\"}",
                onCreateInvitation: {}, onImportPublicIdentityFile: {}, onExportInvitation: {}, onCancel: {}),
                name: "alo-19-add-member-ready", folder: folder, size: NSSize(width: 540, height: 600), dark: dark)
            try await capture(ALOMembersView(networkName: "Studio", members: members, canManage: true,
                onRemove: { _ in }, onAddMember: {}, onDone: {}),
                name: "alo-20-members", folder: folder, size: sheet, dark: dark)

            let state = NSSize(width: 640, height: 420)
            try await capture(ALOStateView(.loading, title: "Opening Main…",
                message: "Finding the people here and lining up the clock so you hear the same moment."),
                name: "alo-21-state-opening", folder: folder, size: state, dark: dark)
            try await capture(ALOStateView(.problem, systemImage: "wifi.exclamationmark", title: "Couldn't open Main",
                message: "Make sure you're on the same Wi-Fi as the others, then try again.") {
                    Button {} label: { ALOActionLabel(title: "Try again", systemImage: "arrow.clockwise") }
                        .buttonStyle(.aloPrimary)
                },
                name: "alo-22-state-failed", folder: folder, size: state, dark: dark)
            try await capture(ALOStateView(systemImage: "headphones", title: "Pick a channel",
                message: "Join a channel to hear what's playing and chat with everyone in it.") {
                    Button {} label: { ALOActionLabel(title: "Join Main", systemImage: "number") }
                        .buttonStyle(.aloPrimary)
                },
                name: "alo-23-state-pick-channel", folder: folder, size: state, dark: dark)
            try await capture(ALOStateView(systemImage: "person.2.wave.2.fill", title: "Listen together",
                message: "Start a network for your group, or join one nearby from the sidebar.") {
                    Button("Open invitation…") {}.buttonStyle(.aloSecondary)
                    Button {} label: { ALOActionLabel(title: "Create network", systemImage: "plus") }
                        .buttonStyle(.aloPrimary)
                },
                name: "alo-24-state-no-network", folder: folder, size: state, dark: dark)

            let emptySidebar = ALONetworkSidebar(
                networks: [], selectedNetworkID: .constant(nil),
                identityName: "Raj", identityFingerprint: me, onCreateNetwork: {}, onImportNetwork: {},
                onExportPublicIdentity: {}, onEditProfile: {})
            try await capture(emptySidebar, name: "alo-25-sidebar-empty", folder: folder,
                size: NSSize(width: 320, height: 600), dark: dark)
            let network = ALONetworkSummary(id: "studio", name: "Studio", memberCount: 3, isOwner: true)
            let ownerNoChannels = ALONetworkSidebar(
                networks: [network], selectedNetworkID: .constant("studio"),
                identityName: "Raj", identityFingerprint: me, onCreateNetwork: {}, onImportNetwork: {},
                onExportPublicIdentity: {}, onEditProfile: {}, onCreateChannel: {})
            try await capture(ownerNoChannels, name: "alo-26-sidebar-no-channels", folder: folder,
                size: NSSize(width: 320, height: 600), dark: dark)
            try await capture(ALOInlineError(message: "ALO couldn't verify this network's details. Ask the owner for a fresh invitation."),
                name: "alo-27-inline-error", folder: folder, size: NSSize(width: 440, height: 120), dark: dark)
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
