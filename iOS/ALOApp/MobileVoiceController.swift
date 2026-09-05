import Foundation
import SwiftUI
import ALOCore
import ALOAppleMedia
import ALONetworking

/// Only local button methods call the permission/capture entry point. Signaling
/// may start a receive path, never a microphone or a new recipient snapshot.
@MainActor final class MobileVoiceController: ObservableObject {
    @Published private(set) var ready = false
    @Published private(set) var requesting = false
    @Published private(set) var transmitting = false
    @Published private(set) var openLine: OpenLineState = .idle
    @Published private(set) var status = "Voice is connecting…"
    @Published var selectedRecipients: Set<UUID> = []
    nonisolated let relay = Relay()
    private let audio: iOSAudioSessionCoordinator
    private var mesh: MeshControlPlane?
    private var localID = UUID()
    private var localName = ""
    private var participants: Set<UUID> = []
    private var consent = VoiceTransmissionConsent()
    private var line = OpenLineSessionState(localID: "")
    private var incoming: [UUID: VoiceSessionIdentifier] = [:]
    private var incomingSequence: [UUID: UInt64] = [:]
    private var transmission: VoiceSessionIdentifier?
    private var lastPhase: AudioLifecycle.Phase = .inactive
    private var generation = UUID()
    private var changingMicrophone = false

    fileprivate enum Event: Sendable {
        case ready(Bool)
        case failed
        case talk(WalkieTalkieMessage)
        case line(OpenLineMessage)
        case pcm(UUID, VoiceSessionIdentifier, UInt64, UInt64, Data, UInt64, UInt64)
    }
    final class Relay: @unchecked Sendable {
        private let lock = NSLock()
        private var session: DirectedVoiceSession?
        private var bridge: BoundedMediaEventBridge<Event>?
        private var stopped = true
        private var generation = UUID()
        fileprivate func prepare(_ bridge: BoundedMediaEventBridge<Event>, generation: UUID) {
            lock.lock(); self.bridge = bridge; self.generation = generation; stopped = false; lock.unlock()
        }
        fileprivate func install(_ value: DirectedVoiceSession, generation: UUID) -> Bool {
            lock.lock()
            guard !stopped, self.generation == generation else { lock.unlock(); value.stop(); return false }
            session = value; lock.unlock(); return true
        }
        var current: DirectedVoiceSession? { lock.lock(); defer { lock.unlock() }; return stopped ? nil : session }
        func admit(_ channel: SecurePeerChannel, peer: AuthenticatedPeer, generation: UUID) {
            guard isCurrent(generation), peer.channelRole == .voiceControl, let current else { channel.cancel(); return }
            current.attach(channel: channel)
        }
        func receive(_ message: WalkieTalkieMessage, generation: UUID) { submit(.talk(message), generation: generation) }
        func receive(_ message: OpenLineMessage, generation: UUID) { submit(.line(message), generation: generation) }
        private func isCurrent(_ generation: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return !stopped && self.generation == generation }
        fileprivate func submit(_ event: Event, bytes: Int = 0, generation: UUID) {
            lock.lock(); let bridge = stopped || self.generation != generation ? nil : self.bridge; lock.unlock()
            if let bridge, !bridge.submit(event, byteCount: bytes) {
                // Keep the failed bridge alive until its MainActor overflow
                // callback revokes microphone intent; stop network output now.
                lock.lock()
                let session = self.generation == generation ? self.session : nil
                if self.generation == generation { stopped = true; self.session = nil }
                lock.unlock(); session?.stop()
            }
        }
        func stop() {
            lock.lock(); stopped = true
            let session = self.session; self.session = nil
            let bridge = self.bridge; self.bridge = nil
            lock.unlock(); bridge?.close(); session?.stop()
        }
    }

    init(audio: iOSAudioSessionCoordinator) {
        self.audio = audio
        audio.onMicrophoneChunk = { [weak self] in self?.captured($0) }
    }
    func start(mesh: MeshControlPlane, localID: UUID, name: String, generation token: UUID) {
        stop()
        generation = token
        self.mesh = mesh; self.localID = localID; localName = name
        line = OpenLineSessionState(localID: localID.uuidString)
        let bridge = BoundedMediaEventBridge<Event>(maximumEvents: 128, maximumBytes: 122_880,
            droppable: { event in if case .pcm = event { return true }; return false },
            schedule: { DispatchQueue.main.async(execute: $0) }, receive: { [weak self] events in
                MainActor.assumeIsolated {
                    guard let self, self.generation == token else { return }
                    for event in events where self.generation == token { self.consume(event) }
                }
            }, overflow: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == token else { return }
                    self.stop(); self.status = "Voice fell behind. Rejoin to restore it."
                }
            })
        let relay = self.relay
        relay.prepare(bridge, generation: token)
        mesh.makeVoiceSession(callbacks: .init(pcm: { peer, session, sequence, frame, pcm, capture in
            relay.submit(.pcm(peer, session, sequence, frame, pcm, capture, MonotonicClock.nowNanos()), bytes: pcm.count, generation: token)
        }, failed: { _ in relay.submit(.failed, generation: token) })) { result in
            switch result {
            case .success(let session): if relay.install(session, generation: token) { relay.submit(.ready(true), generation: token) }
            case .failure: relay.submit(.ready(false), generation: token)
            }
        }
    }
    func updateParticipants(_ values: [RoomParticipant]) {
        participants = Set(values.compactMap { UUID(uuidString: $0.id) }.filter { $0 != localID })
        selectedRecipients.formIntersection(participants)
        if !consent.remainsValid(connected: participants) { endTransmission(); endOpenLine() }
        for peer in Array(incoming.keys) where !participants.contains(peer) { retireIncoming(peer) }
        if let invitation = line.state.invitation,
           let peer = UUID(uuidString: invitation.callerID == localID.uuidString ? invitation.inviteeID : invitation.callerID),
           !participants.contains(peer) { endOpenLine() }
    }
    func beginTalk() async {
        guard case .idle = line.state else { status = "End Open Line before starting Talk."; return }
        await begin(recipients: selectedRecipients)
    }
    func invite(_ peer: UUID) async {
        guard !transmitting, !requesting,
              let message = line.invite(peerID: peer.uuidString, localName: localName) else { return }
        let token = generation
        let began = await begin(recipients: [peer])
        guard generation == token, line.state.invitation?.id == message.invitationID else { return }
        if began {
            mesh?.publishOpenLine(message); openLine = line.state
        } else { line = OpenLineSessionState(localID: localID.uuidString); openLine = .idle }
    }
    func respond(accept: Bool) async {
        guard let invitation = line.state.invitation else { return }
        let prior = line
        let message = accept ? line.join(invitationID: invitation.id, localName: localName)
            : line.decline(invitationID: invitation.id, localName: localName)
        guard let message else { return }
        if accept {
            let token = generation
            endTransmission()
            guard let peer = UUID(uuidString: message.targetID), await begin(recipients: [peer]) else {
                if generation == token, line.state.invitation?.id == invitation.id { line = prior; openLine = line.state }
                return
            }
            guard generation == token, line.state.invitation?.id == invitation.id else { return }
        }
        mesh?.publishOpenLine(message); openLine = line.state
    }
    func endOpenLine() {
        if let message = line.end(localName: localName) { mesh?.publishOpenLine(message) }
        openLine = .idle
        endTransmission()
    }
    @discardableResult private func begin(recipients: Set<UUID>) async -> Bool {
        guard ready, relay.current != nil, !requesting, !transmitting else { return false }
        let request: VoiceTransmissionConsent.Request
        do {
            if !audio.lifecycle.canRender { try audio.startListening() }
            request = try consent.request(recipients: recipients, connected: participants, localID: localID)
        } catch { status = "Select up to eight connected recipients."; return false }
        requesting = true; status = "Requesting microphone access…"
        do { try await audio.startMicrophoneFromUserAction() }
        catch {
            if consent.pending?.id == request.id {
                consent.revoke(); requesting = false
                status = "Microphone did not start. Check permission and try again."
            }
            return false
        }
        guard let granted = consent.grant(request.id, connected: participants), let session = relay.current else {
            if consent.pending?.id == request.id || consent.active?.id == request.id {
                consent.revoke(); requesting = false
                changingMicrophone = true
                do { try audio.stopMicrophone() }
                catch { status = "Microphone stopped; audio output needs reconnection." }
                changingMicrophone = false
            }
            return false
        }
        let id = VoiceSessionIdentifier(sessionID: granted.id)
        transmission = id; requesting = false; transmitting = true
        session.beginTransmitting(session: id, recipients: granted.recipients)
        mesh?.publishWalkieTalkie(.init(kind: .began, senderID: localID.uuidString, senderName: localName,
            targetID: nil, targetIDs: Set(granted.recipients.map(\.uuidString)), sessionID: id.sessionID.uuidString, sampleRate: 48_000))
        status = "Microphone on · \(granted.recipients.count) selected recipient(s)"
        return true
    }
    func endTransmission() {
        let previous = consent.revoke()
        if let transmission {
            relay.current?.endTransmitting(session: transmission)
            mesh?.publishWalkieTalkie(.init(kind: .ended, senderID: localID.uuidString, senderName: localName,
                targetID: nil, targetIDs: previous.map { Set($0.recipients.map(\.uuidString)) },
                sessionID: transmission.sessionID.uuidString, sampleRate: 48_000))
        }
        transmission = nil; requesting = false; transmitting = false
        changingMicrophone = true
        var outputFailed = false
        do { try audio.stopMicrophone() }
        catch { outputFailed = true }
        changingMicrophone = false
        status = outputFailed ? "Microphone stopped; audio output needs reconnection."
            : ready ? "Microphone off" : "Voice is unavailable"
    }
    func audioLifecycleChanged(_ value: AudioLifecycle) {
        let previous = lastPhase; lastPhase = value.phase
        guard !changingMicrophone else { return }
        if value.phase == .interrupted || value.phase == .suspended || value.phase == .inactive
            || value.phase == .listening && (previous == .transmitting || previous == .requestingMicrophone) {
            endTransmission()
            if let message = line.end(localName: localName) { mesh?.publishOpenLine(message) }
            openLine = .idle
        }
    }
    func stop() {
        generation = UUID()
        endOpenLine()
        for peer in Array(incoming.keys) { retireIncoming(peer) }
        relay.stop(); mesh = nil; ready = false
        selectedRecipients.removeAll(); participants.removeAll()
    }
    private func captured(_ chunk: VoicePCMChunk) {
        guard transmitting, audio.lifecycle.isMicrophoneActive, let transmission, consent.active != nil else { return }
        let bytes = chunk.samples.withUnsafeBufferPointer { buffer in
            var data = Data(capacity: 960)
            for sample in buffer { let value = UInt16(bitPattern: sample); data.append(UInt8(truncatingIfNeeded: value)); data.append(UInt8(truncatingIfNeeded: value >> 8)) }
            return data
        }
        relay.current?.submitPCM16Mono(bytes, captureTimeNanos: chunk.captureTimeNanos, session: transmission)
    }
    private func consume(_ event: Event) {
        switch event {
        case .failed:
            stop(); status = "Secure voice stopped. Rejoin before talking again."
        case .ready(let value): ready = value; status = value ? "Microphone off" : "Secure voice could not start"
        case .talk(let message):
            guard let peer = UUID(uuidString: message.senderID), participants.contains(peer),
                  message.recipientIDs?.contains(localID.uuidString) == true,
                  let id = UUID(uuidString: message.sessionID), message.pcm16Mono == nil else { return }
            let session = VoiceSessionIdentifier(sessionID: id)
            switch message.kind {
            case .began:
                guard incoming[peer] != session else { return }
                if !audio.lifecycle.canRender {
                    do { try audio.startListening() }
                    catch { status = "Voice output could not start."; return }
                }
                retireIncoming(peer); incoming[peer] = session
                relay.current?.beginReceiving(from: peer, session: session)
            case .ended: if incoming[peer] == session { retireIncoming(peer) }
            case .audio: break // Reliable room-control PCM is not the v2 voice path.
            }
        case .line(let message):
            guard UUID(uuidString: message.senderID).map({ participants.contains($0) }) == true else { return }
            switch line.receive(message) {
            case .declined, .ended: endTransmission()
            case .incomingInvitation: break // Listening is permitted; capture is not.
            case .joined, .ignored: break // Inviter already explicitly started its mic.
            }
            openLine = line.state
        case let .pcm(peer, session, sequence, frame, bytes, capture, arrival):
            guard incoming[peer] == session, bytes.count == 960,
                  incomingSequence[peer].map({ sequence > $0 }) ?? true else { return }
            incomingSequence[peer] = sequence
            let now = MonotonicClock.nowNanos()
            guard now >= arrival, now - arrival <= 80_000_000 else { audio.endVoice(peerID: peer); return }
            var samples: [Int16] = []; samples.reserveCapacity(480)
            for index in stride(from: 0, to: bytes.count, by: 2) {
                samples.append(Int16(bitPattern: UInt16(bytes[bytes.startIndex + index]) | UInt16(bytes[bytes.startIndex + index + 1]) << 8))
            }
            if let chunk = try? VoicePCMChunk(frameIndex: frame, captureTimeNanos: capture, samples: samples) {
                try? audio.enqueueVoice(peerID: peer, chunk: chunk)
            }
        }
    }
    private func retireIncoming(_ peer: UUID) {
        if let session = incoming.removeValue(forKey: peer) { relay.current?.endReceiving(from: peer, session: session) }
        incomingSequence.removeValue(forKey: peer); audio.endVoice(peerID: peer)
    }
    deinit { relay.stop() }
}
