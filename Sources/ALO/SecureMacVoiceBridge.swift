import Foundation
import ALONetworking

/// Bridges explicit Mac Talk intent to directed voice. The capture session is
/// stable while a fresh wire session is used for every recipient-set change.
/// This prevents an old recipient's ticket from authorizing a new conversation.
final class SecureMacVoiceBridge: @unchecked Sendable {
    private struct Outgoing {
        let captureID: String
        let wire: VoiceSessionIdentifier
        let name: String
        let recipients: Set<String>
    }
    private let lock = NSRecursiveLock()
    private let player: WalkieTalkiePlayer
    private let localID: String
    private let failure: (Error) -> Void
    private var runtime: DirectedVoiceSession?
    private var generation = UUID()
    private var outgoing: Outgoing?
    private var incoming: [UUID: WalkieTalkieMessage] = [:]
    private var stopped = true

    init(player: WalkieTalkiePlayer, localID: String, failure: @escaping (Error) -> Void = { _ in }) {
        self.player = player; self.localID = localID; self.failure = failure
    }

    var isReady: Bool { lock.withLock { !stopped && runtime != nil } }
    var needsRestart: Bool { lock.withLock { stopped } }

    func start(mesh: MeshControlPlane) {
        stop()
        let token = lock.withLock { stopped = false; return generation }
        mesh.makeVoiceSession(callbacks: .init(pcm: { [weak self] peer, session, sequence, _, pcm, _ in
            self?.receivedPCM(peer: peer, session: session, sequence: sequence, pcm: pcm, token: token)
        }, failed: { [weak self] error in self?.failed(error, token: token) })) { [weak self] result in
            guard let self else { if case .success(let value) = result { value.stop() }; return }
            self.lock.withLock {
                guard !self.stopped, self.generation == token else {
                    if case .success(let value) = result { value.stop() }; return
                }
                if case .success(let value) = result {
                    self.runtime = value
                    for (peer, message) in self.incoming {
                        if let id = UUID(uuidString: message.sessionID) {
                            value.beginReceiving(from: peer, session: .init(sessionID: id))
                        }
                    }
                } else if case .failure(let error) = result { self.failed(error, token: token) }
            }
        }
    }

    private func failed(_ error: Error, token: UUID) {
        let failedGeneration: UUID? = lock.withLock {
            guard !stopped, generation == token else { return nil }
            stop()
            return generation
        }
        guard let failedGeneration else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lock.withLock({ self.stopped && self.generation == failedGeneration }) else { return }
            self.failure(error)
        }
    }

    func admit(_ channel: SecurePeerChannel) {
        lock.withLock {
            guard !stopped, let runtime else { channel.cancel(); return }
            runtime.attach(channel: channel)
        }
    }

    /// Signaling only. PCM never travels on the reliable room-control channel.
    func receive(_ message: WalkieTalkieMessage) {
        lock.withLock {
            guard !stopped, message.kind != .audio,
                  let peer = UUID(uuidString: message.senderID),
                  let id = UUID(uuidString: message.sessionID) else { return }
            switch message.kind {
            case .began:
                guard incoming[peer] != nil || incoming.count < 32 else { return }
                if let old = incoming[peer], old.sessionID != message.sessionID {
                    player.accept(ended(old))
                }
                incoming[peer] = message
                runtime?.beginReceiving(from: peer, session: .init(sessionID: id))
                player.accept(message)
            case .ended:
                guard incoming[peer]?.sessionID == message.sessionID else { return }
                incoming.removeValue(forKey: peer)
                runtime?.endReceiving(from: peer, session: .init(sessionID: id))
                player.accept(message)
            case .audio: break
            }
        }
    }

    func publish(_ message: WalkieTalkieMessage, mesh: MeshControlPlane) {
        lock.withLock {
            guard !stopped, let runtime else { return }
            if message.kind == .audio {
                guard let current = outgoing, current.captureID == message.sessionID,
                      let pcm = message.pcm16Mono, !pcm.isEmpty,
                      pcm.count <= 8_192, pcm.count.isMultiple(of: 960) else { return }
                let now = MonotonicClock.nowNanos()
                let duration = UInt64(pcm.count / 960) * 10_000_000
                let start = now >= duration ? now - duration : 0
                for offset in stride(from: 0, to: pcm.count, by: 960) {
                    runtime.submitPCM16Mono(pcm.subdata(in: offset..<(offset + 960)),
                        captureTimeNanos: start + UInt64(offset / 960) * 10_000_000, session: current.wire)
                }
                return
            }
            let old = outgoing
            if message.kind == .ended, old?.captureID != message.sessionID { return }
            let previous = old?.captureID == message.sessionID ? old?.recipients ?? [] : []
            let requested = message.recipientIDs ?? []
            let recipients = (message.kind == .began ? previous.union(requested) : previous.subtracting(requested))
                .filter { $0 != localID && UUID(uuidString: $0) != nil }
            // The runtime rejects oversized intent; do so BEFORE retiring the
            // old wire, otherwise a bad update silently stops healthy speech.
            guard VoiceCaptureIntent.acceptsAudience(recipients) else { return }
            if old?.captureID == message.sessionID, recipients == previous { return }
            if let old {
                runtime.endTransmitting(session: old.wire)
                mesh.publishWalkieTalkie(signal(.ended, old))
            }
            outgoing = nil
            guard !recipients.isEmpty else { return }
            let next = Outgoing(captureID: message.sessionID, wire: .init(sessionID: UUID()),
                name: message.senderName, recipients: recipients)
            outgoing = next
            runtime.beginTransmitting(session: next.wire, recipients: Set(recipients.compactMap(UUID.init(uuidString:))))
            mesh.publishWalkieTalkie(signal(.began, next))
        }
    }

    func stop() {
        lock.withLock {
            stopped = true; generation = UUID(); outgoing = nil
            runtime?.stop(); runtime = nil
            for message in incoming.values { player.accept(ended(message)) }
            incoming.removeAll()
        }
    }

    func removeDeparted(_ peers: Set<String>) {
        lock.withLock {
            for peer in peers.compactMap(UUID.init(uuidString:)) {
                guard let message = incoming.removeValue(forKey: peer),
                      let id = UUID(uuidString: message.sessionID) else { continue }
                runtime?.endReceiving(from: peer, session: .init(sessionID: id))
                player.accept(ended(message))
            }
        }
    }

    private func receivedPCM(peer: UUID, session: VoiceSessionIdentifier, sequence: UInt64, pcm: Data, token: UUID) {
        lock.withLock {
            guard !stopped, generation == token, let message = incoming[peer],
                  UUID(uuidString: message.sessionID) == session.sessionID, pcm.count == 960 else { return }
            player.accept(WalkieTalkieMessage(kind: .audio, senderID: message.senderID,
                senderName: message.senderName, targetID: localID, sessionID: message.sessionID,
                sequence: sequence, sampleRate: 48_000, pcm16Mono: pcm))
        }
    }
    private func signal(_ kind: WalkieTalkieKind, _ value: Outgoing) -> WalkieTalkieMessage {
        WalkieTalkieMessage(kind: kind, senderID: localID, senderName: value.name,
            targetID: nil, targetIDs: value.recipients, sessionID: value.wire.sessionID.uuidString, sampleRate: 48_000)
    }
    private func ended(_ message: WalkieTalkieMessage) -> WalkieTalkieMessage {
        WalkieTalkieMessage(kind: .ended, senderID: message.senderID, senderName: message.senderName,
            targetID: localID, sessionID: message.sessionID, sampleRate: 48_000)
    }
}
