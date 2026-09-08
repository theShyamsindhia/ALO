import Foundation
import Testing
import Darwin
@testable import ALONetworking

struct DeviceMessagingVerticalSliceTests {
    @Test func bundledCLIEndpointMatchesItsAppAndQuotesExactExecutable() throws {
        #expect(try DeviceMessagingLocalEndpoint.applicationDirectory(bundleID: "in.werai.audio.dev", owner: 501)
            == DeviceMessagingLocalEndpoint.directory(bundleID: "in.werai.audio.dev", development: true, owner: 501))
        #expect(throws: LocalDeviceMessageProtocol.Failure.invalidRequest) {
            try DeviceMessagingLocalEndpoint.applicationDirectory(bundleID: nil)
        }
        #expect(DeviceMessagingLocalEndpoint.shellArgument("/Applications/Raj's ALO Dev.app/Contents/MacOS/alo")
            == "'/Applications/Raj'\"'\"'s ALO Dev.app/Contents/MacOS/alo'")
    }
    @Test func ingressPathIsShortAndSeparatedWithoutFilesystemActions() throws {
        let release = try DeviceMessagingLocalEndpoint.directory(bundleID: "in.werai.audio", development: false, owner: 501)
        let dev = try DeviceMessagingLocalEndpoint.directory(bundleID: "in.werai.audio.dev", development: true, owner: 501)
        let other = try DeviceMessagingLocalEndpoint.directory(bundleID: "in.werai.audio", development: false, owner: 502)
        #expect(release != dev && release != other)
        #expect(!release.path.hasPrefix("/private/tmp/"))
        var parent = stat()
        #expect(lstat(release.deletingLastPathComponent().path, &parent) == 0)
        #expect(parent.st_uid == geteuid() && parent.st_mode & 0o077 == 0)
        #expect(release.appendingPathComponent("ingress.sock").path.utf8.count < 104)
        #expect(try DeviceMessagingLocalEndpoint.directory(bundleID: String(repeating: "x", count: 10000), development: false, owner: 501).appendingPathComponent("ingress.sock").path.utf8.count < 104)
    }
    #if os(macOS)
    final class ClockAndCompletion: @unchecked Sendable {
        private let lock = NSLock()
        var now: UInt64 = 1
        var completions = 0
        func read<T>(_ body: (ClockAndCompletion) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(self) }
        func update(_ body: (ClockAndCompletion) -> Void) { lock.lock(); defer { lock.unlock() }; body(self) }
    }
    @Test func expiredCapabilityHistoryDoesNotPermanentlyExhaustThirtyTwoSlots() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("helper")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let state = ClockAndCompletion()
        let probe = try MacDeviceCapabilityProbe(executable: .init(locallyApprovedURL: helper),
            callbackQueue: DispatchQueue(label: "alo.capability.history.test"), now: { state.read { $0.now } })
        defer { probe.stop() }
        for index in 0..<33 {
            let task = UUID(), challenge = UUID(), nonce = UUID(), expiry = state.read { $0.now + 120_000_000_000 }
            let admitted = probe.submit(taskID: task, challengeID: challenge, response: nonce, expiresAt: expiry) { _ in
                state.update { $0.completions += 1 }
            }
            try #require(admitted == .pending)
            #expect(probe.submit(taskID: task, challengeID: challenge, response: nonce, expiresAt: expiry) { _ in } == .duplicate)
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while state.read({ $0.completions <= index }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            try #require(state.read { $0.completions == index + 1 })
            state.update { $0.now = expiry + 1 }
        }
        probe.stop()
        #expect(probe.submit(taskID: UUID(), challengeID: UUID(), response: UUID(), expiresAt: state.read { $0.now + 1 }) { _ in } == .stopped)
    }
    @Test func capabilityTemplateContainsOnlyExactTaskAndFixedNonceMessage() {
        let task = UUID(), challenge = UUID(), nonce = UUID()
        let invocation = MacCodexQueueAdapter.Invocation(capabilityTaskID: task, challengeID: challenge, response: nonce)
        #expect(Array(invocation.arguments.prefix(4)) == ["queue", "--thread", task.uuidString, "--message"])
        #expect(invocation.arguments.count == 5)
        #expect(invocation.arguments[4].contains(challenge.uuidString))
        #expect(invocation.arguments[4].contains(nonce.uuidString))
        #expect(invocation.arguments[4].contains("queued command alone is not confirmation"))
    }
    #endif
}
