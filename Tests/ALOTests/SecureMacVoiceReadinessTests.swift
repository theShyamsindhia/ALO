import Foundation
import Testing
import ALONetworking
@testable import ALO

@MainActor
struct SecureMacVoiceReadinessTests {
    private final class Gate: @unchecked Sendable {
        let lock = NSLock()
        var completion: ((Result<Void, Error>) -> Void)?
        var observer: CheckedContinuation<Void, Never>?
        var ended: [VoiceSessionIdentifier] = []
        var requested: (VoiceSessionIdentifier, Set<UUID>)?
        func request(_ wire: VoiceSessionIdentifier, _ peers: Set<UUID>, _ reply: @escaping (Result<Void, Error>) -> Void) {
            let observer = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                requested = (wire, peers); completion = reply
                defer { self.observer = nil }; return self.observer
            }
            observer?.resume()
        }
        func waitForRequest() async {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    if requested != nil { continuation.resume() }
                    else { observer = continuation }
                }
            }
        }
        func resolve(_ result: Result<Void, Error>) {
            let reply = lock.withLock { () -> ((Result<Void, Error>) -> Void)? in
                defer { completion = nil }; return completion
            }
            reply?(result)
        }
        func end(_ wire: VoiceSessionIdentifier) {
            lock.withLock { ended.append(wire) }
            resolve(.failure(SecureTransportError.invalidState))
        }
    }

    @Test(arguments: [0, 1, 2, 3, 4, 5])
    func actualBridgeWaitBindsIdentityAndCancellationBeforeCapture(mode: Int) async {
        let gate = Gate(), peer = UUID()
        let wire = VoiceSessionIdentifier(sessionID: UUID())
        let bridge = SecureMacVoiceBridge(testingReadiness: .init(wait: gate.request, end: gate.end),
            captureID: "capture", wire: wire, recipients: [peer.uuidString])
        var captured = false, retired = false
        let task = Task { () -> Error? in
            do {
                try await VoiceCaptureStartup.perform(start: { captured = true }, validate: {},
                    publishBegan: {}, awaitReadiness: {
                        try await bridge.waitUntilReady(captureID: "capture", recipients: [peer.uuidString])
                    }, retireAnnounced: { retired = true })
                return nil
            } catch { return error }
        }
        await gate.waitForRequest()
        #expect(!captured)
        #expect(gate.lock.withLock { gate.requested?.0 == wire && gate.requested?.1 == [peer] })
        if mode == 1 { task.cancel() }
        else {
            if [2, 4, 5].contains(mode) {
                bridge.replaceOutgoingForTesting(captureID: mode == 4 ? "replacement" : "capture",
                    wire: mode == 2 ? .init(sessionID: UUID()) : wire,
                    recipients: mode == 5 ? [UUID().uuidString] : [peer.uuidString])
            }
            gate.resolve(mode == 3 ? .failure(SecureTransportError.expired) : .success(()))
        }
        let error = await task.value
        if mode == 0 { #expect(error == nil && captured && !retired) }
        else if mode == 3 {
            #expect(error?.localizedDescription == "Voice could not connect to every selected device. Try Talk again.")
            #expect(!captured && retired)
        } else { #expect(error is CancellationError && !captured && retired) }
        if mode == 1 { #expect(gate.lock.withLock { gate.ended == [wire] }) }
    }
}
