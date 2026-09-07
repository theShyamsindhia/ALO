import AVFoundation
import Foundation
import Testing
import ALOCore
@testable import ALO

private final class HeldVoiceCompletions: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks = [@Sendable () -> Void]()
    var count: Int { lock.withLock { callbacks.count } }
    func hold(_ callback: @escaping @Sendable () -> Void) {
        lock.withLock { callbacks.append(callback) }
    }
    func release() {
        let old = lock.withLock { () -> [@Sendable () -> Void] in
            defer { callbacks.removeAll() }; return callbacks
        }
        old.forEach { $0() }
    }
}

/// Actual offline .dataRendered callbacks, held across the production route
/// notification/debounce path. This does not reproduce a physical route switch.
@Suite(.serialized)
struct VoiceRouteCompletionTests {
    @Test func oldNativeCallbacksCannotConsumeNewRouteCredits() throws {
        let output = RoomAudioOutputEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try output.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 480)
        let held = HeldVoiceCompletions()
        let player = WalkieTalkiePlayer(audioOutput: output, completionDelivery: { held.hold($0) })
        defer { held.release(); player.stop(); output.engine.stop() }
        let sessionID = "route-callback-test"
        func accept(_ sequence: UInt64) {
            player.accept(.init(kind: .audio, senderID: "sender", senderName: "Sender",
                targetID: "receiver", sessionID: sessionID, sequence: sequence,
                sampleRate: 48_000, pcm16Mono: Data(repeating: 0, count: 960)))
        }
        for sequence in UInt64(0)..<4 { accept(sequence) }
        try #require(waitUntil { player.playbackSnapshotForTesting(sessionID: sessionID).scheduledFrames == 1_920 })
        let scratch = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        for _ in 0..<5 {
            try #require(try output.engine.renderOffline(480, to: scratch) == .success)
        }
        try #require(waitUntil { held.count == 4 }, "Must capture four real native completions, not fabricate callbacks")
        try #require(player.playbackSnapshotForTesting(sessionID: sessionID).scheduledFrames == 1_920)

        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: output.engine)
        try #require(waitUntil { player.playbackSnapshotForTesting(sessionID: sessionID).configurationRecoveryPending })
        try #require(waitUntil {
            let snapshot = player.playbackSnapshotForTesting(sessionID: sessionID)
            return !snapshot.configurationRecoveryPending && snapshot.scheduledFrames == 0
        }, "The real route handler must reset and reconnect the existing session")
        for sequence in UInt64(4)..<8 { accept(sequence) }
        try #require(waitUntil { player.playbackSnapshotForTesting(sessionID: sessionID).scheduledFrames == 1_920 })
        try #require(held.count == 4)
        held.release()
        // snapshot synchronizes with the same serial executor used by released
        // completion work. No new PCM is rendered before this credit oracle.
        let remaining = player.playbackSnapshotForTesting(sessionID: sessionID).scheduledFrames
        print("VOICE_ROUTE_CALLBACK oldNativeCallbacks=4 newFrames=1920 remaining=\(String(describing: remaining))")
        #expect(remaining == 1_920, "Retired native callbacks must not spend the new route's frame credits")
        for _ in 0..<5 {
            try #require(try output.engine.renderOffline(480, to: scratch) == .success)
        }
        try #require(waitUntil { held.count == 4 }, "New-route native completions must still arrive")
        held.release()
        #expect(player.playbackSnapshotForTesting(sessionID: sessionID).scheduledFrames == 0,
            "Current-generation callbacks must release their own frame credits")
        let telemetry = try #require(player.playbackSnapshotForTesting(sessionID: sessionID).telemetry)
        #expect(telemetry.configurationResets == 1)
        #expect(telemetry.acceptedAudioBuffers == 8)
        #expect(telemetry.capDrops == 0 && telemetry.concealmentBuffers == 0)
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return condition()
    }
}
