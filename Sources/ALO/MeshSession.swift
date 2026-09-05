import CoreGraphics
import Foundation
import ALOCore

struct IncomingAudioMuteRouting: Equatable {
    var participantMediaMuted: Bool
    var incomingMediaMuted: Bool
    var incomingVoiceMuted: Bool

    var publishedParticipantMediaMuted: Bool { participantMediaMuted }
    var localMediaPlaybackMuted: Bool { participantMediaMuted || incomingMediaMuted }
    var voicePlaybackMuted: Bool { incomingVoiceMuted }
}

@MainActor
final class MeshSession {
    let room: RoomConfiguration
    let nodeID: String
    private var displayName: String
    private var deviceIcon: String
    private var deviceColorHex: String
    private var profileImageData: Data?
    private let control: MeshControlPlane
    private let statusHandler: (String) -> Void
    private let identityHandler: (String, String) -> Void
    private let mediaStateHandler: (Bool) -> Void
    private let nowPlayingHandler: (NowPlayingMedia) -> Void
    private let queueHandler: ([RoomQueueItem]) -> Void
    private let chatHandler: (String, String, String, UInt64) -> Void
    private let videoHandler: (CGImage) -> Void
    private let replicaPersistenceHandler: (MeshRoomReplica) -> Void
    private let errorHandler: (Error) -> Void
    private let walkieTalkieStateHandler: (String, String, Bool, Double) -> Void
    private let walkieTalkieTransmissionEndedHandler: (Error) -> Void
    private let incomingOpenLineInvitationHandler: (OpenLineInvitation) -> Void
    private let openLineStateHandler: (OpenLineState) -> Void
    private let walkieTalkieMicrophone = WalkieTalkieMicrophone()
    private let walkieTalkiePlayer: WalkieTalkiePlayer
    private let audioOutput: RoomAudioOutputEngine
    private final class WalkieTransmissionState: @unchecked Sendable {
        struct Active {
            let id: String
            var targetIDs: Set<String>?
            let name: String
            var sequence: UInt64
        }

        private let lock = NSLock()
        private var active: Active?

        func begin(id: String, targetIDs: Set<String>?, name: String) {
            lock.withLock { active = Active(id: id, targetIDs: targetIDs, name: name, sequence: 0) }
        }

        func activeID() -> String? { lock.withLock { active?.id } }

        func current() -> Active? { lock.withLock { active } }

        func take(expectedID: String?) -> Active? {
            lock.withLock {
                guard expectedID == nil || active?.id == expectedID else { return nil }
                defer { active = nil }
                return active
            }
        }

        func updateTargets(_ targetIDs: Set<String>) -> (active: Active, removed: Set<String>, added: Set<String>)? {
            lock.withLock {
                guard var current = active else { return nil }
                let previous = current.targetIDs ?? []
                current.targetIDs = targetIDs
                active = current
                return (current, previous.subtracting(targetIDs), targetIDs.subtracting(previous))
            }
        }

        func nextMessage(nodeID: String, sessionID: String, data: Data) -> WalkieTalkieMessage? {
            lock.withLock {
                guard var current = active, current.id == sessionID else { return nil }
                current.sequence &+= 1
                active = current
                return WalkieTalkieMessage(
                    kind: .audio,
                    senderID: nodeID,
                    senderName: current.name,
                    targetID: nil,
                    targetIDs: current.targetIDs,
                    sessionID: current.id,
                    sequence: current.sequence,
                    sampleRate: UInt32(WalkieTalkieMicrophone.sampleRate),
                    pcm16Mono: data
                )
            }
        }
    }
    private let walkieTransmissionState = WalkieTransmissionState()
    private var hostSession: HostSession?
    private var receiver: Receiver?
    private var replica = MeshRoomReplica()
    private var appliedBroadcaster: MeshBroadcaster?
    private var transitionGeneration = 0
    private var intendsToBroadcast = false
    private var intendsToBroadcastVideo = false
    private var mediaCommandReady = false
    private var transitionTask: Task<Void, Never>?
    private var isStopped = true
    private var incomingMediaMuted = false
    private var incomingVoiceMuted = false
    private var localVolume = 1.0
    private var localParticipantMuted = false
    private var walkieStartGeneration: Int?
    private var walkieTalkieTargets = Set<String>()
    private var activeIncomingVoiceSessions = [String: String]()
    private var incomingVoiceSessionLevels = [String: Double]()
    private var openLineSessionState: OpenLineSessionState

    var isBroadcasting: Bool { replica.broadcaster?.nodeID == nodeID }
    var hasBroadcaster: Bool { replica.broadcaster != nil }
    private var incomingAudioMuteRouting: IncomingAudioMuteRouting {
        IncomingAudioMuteRouting(
            participantMediaMuted: localParticipantMuted,
            incomingMediaMuted: incomingMediaMuted,
            incomingVoiceMuted: incomingVoiceMuted
        )
    }

    func diagnosticsSnapshot() -> SessionTimingDiagnostics? {
        if let hostSession { return hostSession.diagnosticsSnapshot() }
        if let receiver {
            return SessionTimingDiagnostics(receiver: receiver.diagnosticsSnapshot(), host: nil)
        }
        return nil
    }

    private final class CallbackRelay {
        var replica: (MeshRoomReplica) -> Void = { _ in }
        var participants: ([RoomParticipant]) -> Void = { _ in }
        var openLine: (OpenLineMessage) -> Void = { _ in }
        var walkieTalkie: (String, String, String, Bool, Double) -> Void = { _, _, _, _, _ in }
    }
    private let callbackRelay: CallbackRelay

    private final class MediaActionRelay: @unchecked Sendable {
        typealias MediaHandler = (RoomMediaCommand, String, UInt64) -> Bool
        typealias ResyncHandler = (String?, String, UInt64) -> Bool

        private let lock = NSLock()
        private var mediaHandler: MediaHandler = { _, _, _ in false }
        private var resyncHandler: ResyncHandler = { _, _, _ in false }

        func update(media: @escaping MediaHandler, resync: @escaping ResyncHandler) {
            lock.withLock {
                mediaHandler = media
                resyncHandler = resync
            }
        }

        func clear() {
            update(media: { _, _, _ in false }, resync: { _, _, _ in false })
        }

        func handleMedia(_ command: RoomMediaCommand, broadcasterID: String, epoch: UInt64) -> Bool {
            let handler = lock.withLock { mediaHandler }
            return handler(command, broadcasterID, epoch)
        }

        func handleResync(_ targetID: String?, broadcasterID: String, epoch: UInt64) -> Bool {
            let handler = lock.withLock { resyncHandler }
            return handler(targetID, broadcasterID, epoch)
        }
    }
    private let mediaActionRelay: MediaActionRelay

    init(
        room: RoomConfiguration,
        nodeID: String,
        displayName: String,
        deviceIcon: String? = nil,
        deviceColorHex: String? = nil,
        profileImageData: Data? = nil,
        audioOutput: RoomAudioOutputEngine = RoomAudioOutputEngine(),
        initialEvents: [MeshRoomEvent] = [],
        initialRoomStateDocument: Data? = nil,
        statusHandler: @escaping (String) -> Void,
        identityHandler: @escaping (String, String) -> Void,
        participantsHandler: @escaping ([RoomParticipant]) -> Void,
        mediaStateHandler: @escaping (Bool) -> Void,
        nowPlayingHandler: @escaping (NowPlayingMedia) -> Void,
        chatHandler: @escaping (String, String, String, UInt64) -> Void,
        queueHandler: @escaping ([RoomQueueItem]) -> Void,
        videoHandler: @escaping (CGImage) -> Void,
        peerVersionHandler: @escaping (String) -> Void = { _ in },
        errorHandler: @escaping (Error) -> Void = { _ in },
        walkieTalkieStateHandler: @escaping (String, String, Bool, Double) -> Void = { _, _, _, _ in },
        walkieTalkieTransmissionEndedHandler: @escaping (Error) -> Void = { _ in },
        incomingOpenLineInvitationHandler: @escaping (OpenLineInvitation) -> Void = { _ in },
        openLineStateHandler: @escaping (OpenLineState) -> Void = { _ in },
        replicaPersistenceHandler: @escaping (MeshRoomReplica) -> Void = { _ in },
        roomStatePersistenceHandler: @escaping (Data) -> Void = { _ in }
    ) {
        let relay = CallbackRelay()
        let mediaRelay = MediaActionRelay()
        self.room = room
        self.nodeID = nodeID
        self.displayName = displayName
        let generatedAppearance = DeviceAppearance.generated(from: nodeID)
        let appearance = DeviceAppearance(
            icon: deviceIcon ?? generatedAppearance.icon,
            colorHex: deviceColorHex ?? generatedAppearance.colorHex
        )
        self.deviceIcon = appearance.icon
        self.deviceColorHex = appearance.colorHex
        self.profileImageData = DeviceAppearance.sanitizedProfileImageData(profileImageData)
        self.callbackRelay = relay
        self.mediaActionRelay = mediaRelay
        self.statusHandler = statusHandler
        self.identityHandler = identityHandler
        self.mediaStateHandler = mediaStateHandler
        self.nowPlayingHandler = nowPlayingHandler
        self.chatHandler = chatHandler
        self.queueHandler = queueHandler
        self.videoHandler = videoHandler
        self.errorHandler = errorHandler
        self.walkieTalkieStateHandler = walkieTalkieStateHandler
        self.walkieTalkieTransmissionEndedHandler = walkieTalkieTransmissionEndedHandler
        self.incomingOpenLineInvitationHandler = incomingOpenLineInvitationHandler
        self.openLineStateHandler = openLineStateHandler
        self.openLineSessionState = OpenLineSessionState(localID: nodeID)
        let walkieTalkiePlayer = WalkieTalkiePlayer(
            audioOutput: audioOutput,
            stateHandler: { sessionID, senderID, senderName, active, level in
                DispatchQueue.main.async {
                    relay.walkieTalkie(sessionID, senderID, senderName, active, level)
                }
            }
        )
        self.audioOutput = audioOutput
        self.walkieTalkiePlayer = walkieTalkiePlayer
        self.replicaPersistenceHandler = replicaPersistenceHandler
        self.control = MeshControlPlane(
            room: room,
            nodeID: nodeID,
            displayName: displayName,
            deviceIcon: appearance.icon,
            deviceColorHex: appearance.colorHex,
            profileImageData: self.profileImageData,
            initialEvents: initialEvents,
            initialRoomStateDocument: initialRoomStateDocument,
            replicaHandler: { replica in
                DispatchQueue.main.async { relay.replica(replica) }
            },
            participantsHandler: { participants in
                DispatchQueue.main.async { relay.participants(participants) }
            },
            peerVersionHandler: { version in
                DispatchQueue.main.async { peerVersionHandler(version) }
            },
            mediaCommandHandler: { command, broadcasterID, broadcasterEpoch in
                mediaRelay.handleMedia(command, broadcasterID: broadcasterID, epoch: broadcasterEpoch)
            },
            resyncRequestHandler: { targetID, broadcasterID, broadcasterEpoch in
                mediaRelay.handleResync(targetID, broadcasterID: broadcasterID, epoch: broadcasterEpoch)
            },
            walkieTalkieHandler: { message in
                walkieTalkiePlayer.accept(message)
            },
            openLineHandler: { message in
                DispatchQueue.main.async { relay.openLine(message) }
            },
            roomStatePersistenceHandler: roomStatePersistenceHandler
        )
        relay.replica = { [weak self] in self?.apply($0) }
        relay.participants = participantsHandler
        relay.openLine = { [weak self] in self?.receiveOpenLine($0) }
        relay.walkieTalkie = { [weak self] in
            self?.updateIncomingVoiceActivity(
                sessionID: $0,
                senderID: $1,
                senderName: $2,
                active: $3,
                level: $4
            )
        }
    }

    func start(broadcastInitially: Bool) throws {
        do {
            try control.start()
            isStopped = false
        } catch {
            isStopped = true
            throw error
        }
        identityHandler(nodeID, displayName)
        if broadcastInitially { beginBroadcasting() }
        else { statusHandler("Room open · waiting for a broadcaster") }
    }

    func beginBroadcasting(videoEnabled: Bool = false) {
        intendsToBroadcast = true
        intendsToBroadcastVideo = videoEnabled
        let service = "ALO-\(room.id.prefix(8))-\(nodeID.prefix(8))"
        control.publishBroadcaster(active: true, mediaServiceName: service)
    }

    func stopBroadcasting() {
        intendsToBroadcast = false
        intendsToBroadcastVideo = false
        guard let broadcaster = replica.broadcaster, broadcaster.nodeID == nodeID else { return }
        control.publishVideo(false, broadcasterID: nodeID, broadcasterEpoch: broadcaster.epoch)
        control.publishBroadcaster(active: false)
    }

    func sendChat(_ text: String) { control.publishChat(text) }
    func addQueueItem(_ item: RoomQueueItem) {
        control.publishQueueAdd(RoomQueueItem(
            id: item.id,
            title: item.title,
            subtitle: item.subtitle,
            url: item.url,
            addedBy: displayName,
            addedByID: nodeID,
            addedNanos: MonotonicClock.nowNanos()
        ))
    }
    func removeQueueItem(_ id: String) { control.publishQueueRemove(id) }
    func updateIdentity(name: String, icon: String, colorHex: String) {
        updateIdentity(name: name, icon: icon, colorHex: colorHex, profileImageData: profileImageData)
    }

    func updateIdentity(name: String, icon: String, colorHex: String, profileImageData: Data?) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !trimmed.isEmpty else { return }
        let appearance = DeviceAppearance(icon: icon, colorHex: colorHex)
        displayName = trimmed
        deviceIcon = appearance.icon
        deviceColorHex = appearance.colorHex
        self.profileImageData = DeviceAppearance.sanitizedProfileImageData(profileImageData)
        control.updateIdentity(
            name: trimmed,
            icon: appearance.icon,
            colorHex: appearance.colorHex,
            profileImageData: self.profileImageData
        )
        identityHandler(nodeID, trimmed)
    }

    func beginWalkieTalkie(
        targetID: String?,
        generation: Int,
        inputDeviceUID: String? = nil
    ) async throws -> String? {
        if let targetID {
            return try await updateWalkieTalkieTargets(
                [targetID], generation: generation, inputDeviceUID: inputDeviceUID
            )
        }
        // Compatibility for the old call site. New UI should pass an explicit
        // snapshot to updateWalkieTalkieTargets(_:generation:inputDeviceUID:).
        return try await beginVoiceCapture(
            targetIDs: nil, generation: generation, inputDeviceUID: inputDeviceUID
        )
    }

    func updateWalkieTalkieTargets(
        _ targetIDs: Set<String>,
        generation: Int,
        inputDeviceUID: String? = nil
    ) async throws -> String? {
        walkieTalkieTargets = targetIDs.subtracting([nodeID])
        return try await reconcileVoiceCapture(
            generation: generation, inputDeviceUID: inputDeviceUID
        )
    }

    /// Rebuilds the microphone engine while retaining every active reason for
    /// capture (latched Talk, push-to-talk, and either side of an Open Line).
    func reconfigureVoiceInput(
        generation: Int,
        inputDeviceUID: String?
    ) async throws -> String? {
        let targets = effectiveVoiceTargets()
        guard !targets.isEmpty else { return nil }
        forceEndVoiceCapture()
        return try await beginVoiceCapture(
            targetIDs: targets,
            generation: generation,
            inputDeviceUID: inputDeviceUID
        )
    }

    private func beginVoiceCapture(
        targetIDs: Set<String>?,
        generation: Int,
        inputDeviceUID: String?
    ) async throws -> String? {
        if let targetIDs, targetIDs.isEmpty { return nil }
        walkieStartGeneration = generation
        guard await WalkieTalkieMicrophone.requestAccess() else {
            throw ALOError(
                "Microphone access is needed for Talk and Open Line. Enable ALO in Privacy & Security → Microphone."
            )
        }
        guard walkieStartGeneration == generation else { throw CancellationError() }
        if let active = walkieTransmissionState.current() {
            endWalkieTalkie(sessionID: active.id)
        }
        let sessionID = UUID().uuidString
        let senderName = displayName
        walkieTransmissionState.begin(id: sessionID, targetIDs: targetIDs, name: senderName)
        let transmissionState = walkieTransmissionState
        let controlPlane = control
        let localNodeID = nodeID
        do {
            try await walkieTalkieMicrophone.start(
                sessionID: sessionID,
                inputDeviceUID: inputDeviceUID,
                handler: { data in
                    if let message = transmissionState.nextMessage(
                        nodeID: localNodeID,
                        sessionID: sessionID,
                        data: data
                    ) {
                        controlPlane.publishWalkieTalkie(message)
                    }
                },
                failureHandler: { [weak self] error in
                    Task { @MainActor in
                        guard let self,
                              self.walkieTransmissionState.activeID() == sessionID
                        else { return }
                        self.endOpenLine()
                        self.endWalkieTalkie(sessionID: sessionID)
                        self.statusHandler("Talk stopped: \(error.localizedDescription)")
                        self.walkieTalkieTransmissionEndedHandler(error)
                    }
                }
            )
            guard walkieStartGeneration == generation,
                  walkieTransmissionState.activeID() == sessionID
            else {
                walkieTalkieMicrophone.stop(sessionID: sessionID)
                endWalkieTalkie(sessionID: sessionID)
                throw CancellationError()
            }
            control.publishWalkieTalkie(WalkieTalkieMessage(
                kind: .began,
                senderID: nodeID,
                senderName: senderName,
                targetID: nil,
                targetIDs: targetIDs,
                sessionID: sessionID,
                sampleRate: UInt32(WalkieTalkieMicrophone.sampleRate)
            ))
            return sessionID
        } catch {
            walkieTalkieMicrophone.stop(sessionID: sessionID)
            _ = walkieTransmissionState.take(expectedID: sessionID)
            throw error
        }
    }

    private func effectiveVoiceTargets() -> Set<String> {
        Self.effectiveVoiceTargets(
            talkTargetIDs: walkieTalkieTargets,
            openLineState: openLineSessionState.state,
            localID: nodeID
        )
    }

    nonisolated static func effectiveVoiceTargets(
        talkTargetIDs: Set<String>,
        openLineState: OpenLineState,
        localID: String
    ) -> Set<String> {
        var targets = talkTargetIDs
        switch openLineState {
        case .inviting(let invitation), .connected(let invitation):
            let peerID = invitation.callerID == localID ? invitation.inviteeID : invitation.callerID
            targets.insert(peerID)
        case .idle, .invited:
            break
        }
        targets.remove(localID)
        return targets
    }

    private func reconcileVoiceCapture(
        generation: Int,
        inputDeviceUID: String?
    ) async throws -> String? {
        let targets = effectiveVoiceTargets()
        guard !targets.isEmpty else {
            forceEndVoiceCapture()
            return nil
        }
        if let update = walkieTransmissionState.updateTargets(targets) {
            publishTargetDelta(update)
            return update.active.id
        }
        return try await beginVoiceCapture(
            targetIDs: targets, generation: generation, inputDeviceUID: inputDeviceUID
        )
    }

    private func reconcileExistingVoiceCapture() {
        let targets = effectiveVoiceTargets()
        guard !targets.isEmpty else {
            forceEndVoiceCapture()
            return
        }
        if let update = walkieTransmissionState.updateTargets(targets) {
            publishTargetDelta(update)
        }
    }

    private func publishTargetDelta(
        _ update: (active: WalkieTransmissionState.Active, removed: Set<String>, added: Set<String>)
    ) {
        if !update.removed.isEmpty {
            control.publishWalkieTalkie(WalkieTalkieMessage(
                kind: .ended,
                senderID: nodeID,
                senderName: update.active.name,
                targetID: nil,
                targetIDs: update.removed,
                sessionID: update.active.id,
                sequence: update.active.sequence,
                sampleRate: UInt32(WalkieTalkieMicrophone.sampleRate)
            ))
        }
        if !update.added.isEmpty {
            control.publishWalkieTalkie(WalkieTalkieMessage(
                kind: .began,
                senderID: nodeID,
                senderName: update.active.name,
                targetID: nil,
                targetIDs: update.added,
                sessionID: update.active.id,
                sequence: update.active.sequence,
                sampleRate: UInt32(WalkieTalkieMicrophone.sampleRate)
            ))
        }
    }

    func sendOpenLineInvitation(
        to targetID: String,
        generation: Int,
        inputDeviceUID: String? = nil
    ) async throws -> String? {
        guard let message = openLineSessionState.invite(peerID: targetID, localName: displayName) else {
            return nil
        }
        let previous = OpenLineSessionState(localID: nodeID)
        do {
            _ = try await reconcileVoiceCapture(
                generation: generation, inputDeviceUID: inputDeviceUID
            )
        } catch {
            openLineSessionState = previous
            openLineStateHandler(.idle)
            throw error
        }
        control.publishOpenLine(message)
        openLineStateHandler(openLineSessionState.state)
        return message.invitationID
    }

    func respondToOpenLine(
        invitationID: String,
        accept: Bool,
        generation: Int,
        inputDeviceUID: String? = nil
    ) async throws {
        let prior = openLineSessionState
        let message = accept
            ? openLineSessionState.join(invitationID: invitationID, localName: displayName)
            : openLineSessionState.decline(invitationID: invitationID, localName: displayName)
        guard let message else { return }
        if accept {
            do {
                _ = try await reconcileVoiceCapture(
                    generation: generation, inputDeviceUID: inputDeviceUID
                )
            } catch {
                openLineSessionState = prior
                throw error
            }
        } else {
            reconcileExistingVoiceCapture()
        }
        control.publishOpenLine(message)
        openLineStateHandler(openLineSessionState.state)
    }

    func endOpenLine() {
        guard let message = openLineSessionState.end(localName: displayName) else { return }
        control.publishOpenLine(message)
        reconcileExistingVoiceCapture()
        openLineStateHandler(.idle)
    }

    private func receiveOpenLine(_ message: OpenLineMessage) {
        let transition = openLineSessionState.receive(message)
        guard transition != .ignored else { return }
        // Remote signaling may remove an existing capture reason, but can never
        // add one: only the local Join line action starts the invitee microphone.
        reconcileExistingVoiceCapture()
        if case .incomingInvitation(let invitation) = transition {
            incomingOpenLineInvitationHandler(invitation)
        }
        openLineStateHandler(openLineSessionState.state)
    }

    func endWalkieTalkie(sessionID: String? = nil) {
        if sessionID == nil {
            walkieTalkieTargets.removeAll()
            reconcileExistingVoiceCapture()
            return
        }
        forceEndVoiceCapture(sessionID: sessionID)
    }

    private func forceEndVoiceCapture(sessionID: String? = nil) {
        if sessionID == nil { walkieStartGeneration = nil }
        let active = walkieTransmissionState.take(expectedID: sessionID)
        guard let active else { return }
        walkieTalkieMicrophone.stop(sessionID: active.id)
        control.publishWalkieTalkie(WalkieTalkieMessage(
            kind: .ended,
            senderID: nodeID,
            senderName: active.name,
            targetID: nil,
            targetIDs: active.targetIDs,
            sessionID: active.id,
            sequence: active.sequence,
            sampleRate: UInt32(WalkieTalkieMicrophone.sampleRate)
        ))
    }
    @discardableResult
    func sendMediaCommand(_ command: RoomMediaCommand) -> Bool {
        guard let broadcaster = replica.broadcaster else { return false }
        if broadcaster.nodeID == nodeID {
            return receiveMediaCommand(
                command,
                broadcasterID: broadcaster.nodeID,
                broadcasterEpoch: broadcaster.epoch
            )
        }
        return control.publishMediaCommand(
            command,
            broadcasterID: broadcaster.nodeID,
            broadcasterEpoch: broadcaster.epoch
        )
    }
    func requestResync(participantID: String? = nil) -> Bool {
        guard let broadcaster = replica.broadcaster else { return false }
        if broadcaster.nodeID == nodeID {
            return receiveResyncRequest(
                targetID: participantID,
                broadcasterID: broadcaster.nodeID,
                broadcasterEpoch: broadcaster.epoch
            )
        }
        return control.publishResyncRequest(
            targetID: participantID,
            broadcasterID: broadcaster.nodeID,
            broadcasterEpoch: broadcaster.epoch
        )
    }
    func setLocalLevel(volume: Double, muted: Bool) {
        localVolume = min(max(volume, 0), 1)
        localParticipantMuted = muted
        let routing = incomingAudioMuteRouting
        receiver?.setLocalLevel(volume: localVolume, muted: routing.publishedParticipantMediaMuted)
        receiver?.setLocalPlaybackMuted(routing.incomingMediaMuted)
    }
    func setParticipantLevel(id: String, volume: Double, muted: Bool) {
        if id == nodeID {
            localVolume = min(max(volume, 0), 1)
            localParticipantMuted = muted
        }
        hostSession?.setParticipantLevel(
            id: id,
            volume: volume,
            muted: id == nodeID
                ? incomingAudioMuteRouting.publishedParticipantMediaMuted
                : muted
        )
    }
    func setIncomingMediaMuted(_ muted: Bool) {
        incomingMediaMuted = muted
        let routing = incomingAudioMuteRouting
        if isBroadcasting {
            hostSession?.setLocalPlaybackMuted(routing.incomingMediaMuted)
        } else {
            receiver?.setLocalPlaybackMuted(routing.incomingMediaMuted)
        }
    }
    func setIncomingWalkieTalkieMuted(_ muted: Bool) {
        incomingVoiceMuted = muted
        walkieTalkiePlayer.setMuted(incomingAudioMuteRouting.voicePlaybackMuted)
    }

    private func updateIncomingVoiceActivity(
        sessionID: String,
        senderID: String,
        senderName: String,
        active: Bool,
        level: Double
    ) {
        let senderWasActive = activeIncomingVoiceSessions.values.contains(senderID)
        let previousLevel = incomingVoiceLevel(for: senderID)
        if active {
            activeIncomingVoiceSessions[sessionID] = senderID
            incomingVoiceSessionLevels[sessionID] = level
        } else {
            activeIncomingVoiceSessions.removeValue(forKey: sessionID)
            incomingVoiceSessionLevels.removeValue(forKey: sessionID)
        }
        let senderIsActive = activeIncomingVoiceSessions.values.contains(senderID)
        let currentLevel = incomingVoiceLevel(for: senderID)
        if senderWasActive != senderIsActive || abs(previousLevel - currentLevel) >= 0.001 {
            walkieTalkieStateHandler(senderID, senderName, senderIsActive, currentLevel)
        }
    }

    private func incomingVoiceLevel(for senderID: String) -> Double {
        activeIncomingVoiceSessions.compactMap { sessionID, activeSenderID in
            activeSenderID == senderID ? incomingVoiceSessionLevels[sessionID] : nil
        }.max() ?? 0
    }

    func setVideoEnabled(_ enabled: Bool) async throws {
        guard let hostSession,
              let broadcaster = replica.broadcaster,
              broadcaster.nodeID == nodeID
        else { return }
        try await hostSession.setVideoEnabled(enabled)
        guard replica.broadcaster == broadcaster, self.hostSession === hostSession else {
            if enabled { try? await hostSession.setVideoEnabled(false) }
            return
        }
        intendsToBroadcastVideo = enabled
        control.publishVideo(enabled, broadcasterID: nodeID, broadcasterEpoch: broadcaster.epoch)
    }

    func stop() async {
        guard !isStopped else { return }
        isStopped = true
        endOpenLine()
        endWalkieTalkie()
        walkieTalkiePlayer.stop()
        intendsToBroadcast = false
        intendsToBroadcastVideo = false
        if let broadcaster = replica.broadcaster, broadcaster.nodeID == nodeID {
            control.publishVideo(false, broadcasterID: nodeID, broadcasterEpoch: broadcaster.epoch)
            control.publishBroadcaster(active: false)
        }
        transitionGeneration += 1
        transitionTask?.cancel()
        let activeTransition = transitionTask
        transitionTask = nil
        mediaCommandReady = false
        mediaActionRelay.clear()
        receiver?.stop()
        receiver = nil
        await activeTransition?.value
        await hostSession?.stop()
        hostSession = nil
        await withCheckedContinuation { continuation in
            control.stop { continuation.resume() }
        }
    }

    func stopImmediately() {
        guard !isStopped else { return }
        isStopped = true
        endOpenLine()
        endWalkieTalkie()
        walkieTalkiePlayer.stop()
        intendsToBroadcast = false
        intendsToBroadcastVideo = false
        transitionGeneration += 1
        transitionTask?.cancel()
        transitionTask = nil
        mediaActionRelay.clear()
        receiver?.stop()
        hostSession?.stopImmediately()
        control.stop()
    }

    private func apply(_ next: MeshRoomReplica) {
        guard !isStopped else { return }
        let oldChatIDs = Set(replica.chatEvents.map(\.id))
        replica = next
        replicaPersistenceHandler(next)
        for event in next.chatEvents where !oldChatIDs.contains(event.id) {
            if let sender = event.sender, let text = event.text {
                chatHandler(event.senderID ?? event.version.nodeID, sender, text, event.sentNanos ?? 0)
            }
        }
        queueHandler(next.queue)
        nowPlayingHandler(next.nowPlaying)
        receiver?.updateNowPlaying(next.nowPlaying)
        mediaStateHandler(next.videoEnabled)
        guard next.broadcaster != appliedBroadcaster else { return }
        let wasLocalBroadcaster = appliedBroadcaster?.nodeID == nodeID
        appliedBroadcaster = next.broadcaster
        transition(to: next.broadcaster)
        if next.broadcaster == nil, intendsToBroadcast, wasLocalBroadcaster {
            let service = "ALO-\(room.id.prefix(8))-\(nodeID.prefix(8))"
            control.publishBroadcaster(active: true, mediaServiceName: service)
        }
    }

    private func transition(to broadcaster: MeshBroadcaster?) {
        guard !isStopped else { return }
        mediaCommandReady = false
        mediaActionRelay.clear()
        transitionGeneration += 1
        let generation = transitionGeneration
        let previousTransition = transitionTask
        previousTransition?.cancel()
        let oldReceiver = receiver
        receiver = nil
        oldReceiver?.stop()
        let oldHost = hostSession
        hostSession = nil

        transitionTask = Task {
            await previousTransition?.value
            // Detached resources belong to this task even if a newer transition cancels it.
            await oldHost?.stop()
            guard !Task.isCancelled, generation == transitionGeneration else { return }
            guard let broadcaster else {
                statusHandler("Room open · no one is broadcasting")
                return
            }
            do {
                if broadcaster.nodeID == nodeID {
                    statusHandler("Taking over room audio")
                    let host = HostSession()
                    let initialVideoEnabled = intendsToBroadcastVideo
                    hostSession = host
                    try await host.start(
                        roomName: broadcaster.mediaServiceName,
                        mediaSecurity: try RoomMediaSecurity.forRoom(room, serviceName: broadcaster.mediaServiceName),
                        participantID: nodeID,
                        audioOutput: audioOutput,
                        statusHandler: statusHandler,
                        receiverCountHandler: { _ in },
                        initialVideoEnabled: initialVideoEnabled,
                        identityHandler: { _, _ in },
                        participantsHandler: { _ in },
                        mediaStateHandler: mediaStateHandler,
                        nowPlayingHandler: { [weak self] media in
                            self?.nowPlayingHandler(media)
                            self?.control.publishPlayback(media)
                        },
                        chatHandler: { _, _, _ in },
                        queueHandler: { _ in },
                        videoHandler: videoHandler,
                        audioStoppedHandler: { [weak self, weak host] error in
                            Task { @MainActor in
                                guard let self, let host,
                                      self.hostSession === host,
                                      let current = self.replica.broadcaster,
                                      current.nodeID == self.nodeID,
                                      current.epoch == broadcaster.epoch
                                else { return }
                                self.intendsToBroadcast = false
                                self.control.publishBroadcaster(active: false)
                                self.statusHandler("Broadcast stopped: \(error.localizedDescription)")
                            }
                        },
                        videoStoppedHandler: { [weak self] _ in
                            guard let self,
                                  let current = self.replica.broadcaster,
                                  current.nodeID == self.nodeID,
                                  current.epoch == broadcaster.epoch
                            else { return }
                            self.intendsToBroadcastVideo = false
                            self.control.publishVideo(
                                false,
                                broadcasterID: self.nodeID,
                                broadcasterEpoch: current.epoch
                            )
                        }
                    )
                    guard !Task.isCancelled, generation == transitionGeneration,
                          replica.broadcaster?.nodeID == nodeID else {
                        await host.stop()
                        return
                    }
                    if initialVideoEnabled,
                       let current = replica.broadcaster,
                       current.nodeID == nodeID {
                        control.publishVideo(
                            true,
                            broadcasterID: nodeID,
                            broadcasterEpoch: current.epoch
                        )
                    }
                    mediaCommandReady = true
                    let localNodeID = nodeID
                    let broadcasterEpoch = broadcaster.epoch
                    mediaActionRelay.update(
                        media: { [weak host] command, broadcasterID, epoch in
                            guard broadcasterID == localNodeID, epoch == broadcasterEpoch else { return false }
                            return host?.sendRoomMediaCommand(command) ?? false
                        },
                        resync: { [weak host] targetID, broadcasterID, epoch in
                            guard broadcasterID == localNodeID, epoch == broadcasterEpoch else { return false }
                            return host?.requestResync(participantID: targetID) ?? false
                        }
                    )
                    let routing = incomingAudioMuteRouting
                    host.setParticipantLevel(
                        id: nodeID,
                        volume: localVolume,
                        muted: routing.publishedParticipantMediaMuted
                    )
                    host.setLocalPlaybackMuted(routing.incomingMediaMuted)
                } else {
                    statusHandler("Connecting to the room broadcaster")
                    let receiver = try Receiver(
                        requestedRoom: broadcaster.mediaServiceName,
                        mediaSecurity: try RoomMediaSecurity.forRoom(room, serviceName: broadcaster.mediaServiceName),
                        roomDisplayName: room.name,
                        audioOutput: audioOutput,
                        participantID: nodeID,
                        roomMediaCommandHandler: { [weak self] command in
                            let send = {
                                MainActor.assumeIsolated {
                                    self?.sendMediaCommand(command) ?? false
                                }
                            }
                            if Thread.isMainThread { return send() }
                            DispatchQueue.main.async { _ = send() }
                            return true
                        },
                        statusHandler: { [weak self] status in
                            if status == .connected {
                                DispatchQueue.main.async {
                                    self?.mediaCommandReady = true
                                }
                            }
                            if status == .playing { self?.statusHandler("Listening in sync") }
                            if status == .silent { self?.statusHandler("Connected · waiting for audio") }
                        },
                        identityHandler: { _, _ in },
                        participantsHandler: { _ in },
                        mediaStateHandler: mediaStateHandler,
                        nowPlayingHandler: nowPlayingHandler,
                        chatHandler: { _, _, _ in },
                        queueHandler: { _ in },
                        videoHandler: videoHandler
                    )
                    self.receiver = receiver
                    try receiver.start()
                    let routing = incomingAudioMuteRouting
                    receiver.setLocalLevel(
                        volume: localVolume,
                        muted: routing.publishedParticipantMediaMuted
                    )
                    receiver.setLocalPlaybackMuted(routing.incomingMediaMuted)
                    guard generation == transitionGeneration,
                          replica.broadcaster == broadcaster else {
                        receiver.stop()
                        if self.receiver === receiver { self.receiver = nil }
                        return
                    }
                    receiver.updateNowPlaying(replica.nowPlaying)
                }
            } catch {
                guard generation == transitionGeneration else { return }
                if broadcaster.nodeID == nodeID {
                    intendsToBroadcast = false
                    await hostSession?.stop()
                    hostSession = nil
                    control.publishBroadcaster(active: false)
                    statusHandler("Media connection failed: \(error.localizedDescription)")
                    errorHandler(error)
                } else {
                    receiver?.stop()
                    receiver = nil
                    statusHandler("Media connection failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func receiveMediaCommand(
        _ command: RoomMediaCommand,
        broadcasterID: String,
        broadcasterEpoch: UInt64
    ) -> Bool {
        guard let broadcaster = replica.broadcaster,
              broadcaster.nodeID == nodeID,
              broadcaster.nodeID == broadcasterID,
              broadcaster.epoch == broadcasterEpoch
        else { return false }
        guard mediaCommandReady, let hostSession else { return false }
        return hostSession.sendRoomMediaCommand(command)
    }

    private func receiveResyncRequest(
        targetID: String?,
        broadcasterID: String,
        broadcasterEpoch: UInt64
    ) -> Bool {
        guard let broadcaster = replica.broadcaster,
              broadcaster.nodeID == nodeID,
              broadcaster.nodeID == broadcasterID,
              broadcaster.epoch == broadcasterEpoch
        else { return false }
        guard mediaCommandReady, let hostSession else { return false }
        return hostSession.requestResync(participantID: targetID)
    }

}
