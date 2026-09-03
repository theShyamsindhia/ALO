import CoreGraphics
import Foundation
import WERAICore

@MainActor
final class MeshSession {
    let room: RoomConfiguration
    let nodeID: String
    private var displayName: String
    private var deviceIcon: String
    private var deviceColorHex: String
    private let control: MeshControlPlane
    private let statusHandler: (String) -> Void
    private let identityHandler: (String, String) -> Void
    private let mediaStateHandler: (Bool) -> Void
    private let nowPlayingHandler: (NowPlayingMedia) -> Void
    private let queueHandler: ([RoomQueueItem]) -> Void
    private let chatHandler: (String, String, UInt64) -> Void
    private let videoHandler: (CGImage) -> Void
    private let replicaPersistenceHandler: (MeshRoomReplica) -> Void
    private let errorHandler: (Error) -> Void
    private let walkieTalkieStateHandler: (String, String, Bool) -> Void
    private let walkieTalkieMicrophone = WalkieTalkieMicrophone()
    private var walkieTalkiePlayer: WalkieTalkiePlayer?
    private let walkieTransmissionQueue = DispatchQueue(label: "in.werai.walkie-transmission")
    private var walkieTransmission: (id: String, targetID: String?, name: String, sequence: UInt64)?
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
    private var incomingWalkieTalkieMuted = false

    var isBroadcasting: Bool { replica.broadcaster?.nodeID == nodeID }
    var hasBroadcaster: Bool { replica.broadcaster != nil }

    private final class CallbackRelay {
        var replica: (MeshRoomReplica) -> Void = { _ in }
        var participants: ([RoomParticipant]) -> Void = { _ in }
        var mediaCommand: (RoomMediaCommand, String, UInt64) -> Bool = { _, _, _ in false }
        var resyncRequest: (String?, String, UInt64) -> Bool = { _, _, _ in false }
        var walkieTalkie: (WalkieTalkieMessage) -> Void = { _ in }
    }
    private let callbackRelay: CallbackRelay

    init(
        room: RoomConfiguration,
        nodeID: String,
        displayName: String,
        deviceIcon: String? = nil,
        deviceColorHex: String? = nil,
        initialEvents: [MeshRoomEvent] = [],
        statusHandler: @escaping (String) -> Void,
        identityHandler: @escaping (String, String) -> Void,
        participantsHandler: @escaping ([RoomParticipant]) -> Void,
        mediaStateHandler: @escaping (Bool) -> Void,
        nowPlayingHandler: @escaping (NowPlayingMedia) -> Void,
        chatHandler: @escaping (String, String, UInt64) -> Void,
        queueHandler: @escaping ([RoomQueueItem]) -> Void,
        videoHandler: @escaping (CGImage) -> Void,
        peerVersionHandler: @escaping (String) -> Void = { _ in },
        errorHandler: @escaping (Error) -> Void = { _ in },
        walkieTalkieStateHandler: @escaping (String, String, Bool) -> Void = { _, _, _ in },
        replicaPersistenceHandler: @escaping (MeshRoomReplica) -> Void = { _ in }
    ) {
        let relay = CallbackRelay()
        self.room = room
        self.nodeID = nodeID
        self.displayName = displayName
        let appearance = DeviceAppearance.generated(from: nodeID)
        self.deviceIcon = deviceIcon ?? appearance.icon
        self.deviceColorHex = deviceColorHex ?? appearance.colorHex
        self.callbackRelay = relay
        self.statusHandler = statusHandler
        self.identityHandler = identityHandler
        self.mediaStateHandler = mediaStateHandler
        self.nowPlayingHandler = nowPlayingHandler
        self.chatHandler = chatHandler
        self.queueHandler = queueHandler
        self.videoHandler = videoHandler
        self.errorHandler = errorHandler
        self.walkieTalkieStateHandler = walkieTalkieStateHandler
        self.replicaPersistenceHandler = replicaPersistenceHandler
        self.control = MeshControlPlane(
            room: room,
            nodeID: nodeID,
            displayName: displayName,
            deviceIcon: deviceIcon,
            deviceColorHex: deviceColorHex,
            initialEvents: initialEvents,
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
                let accept = {
                    MainActor.assumeIsolated {
                        relay.mediaCommand(command, broadcasterID, broadcasterEpoch)
                    }
                }
                if Thread.isMainThread { return accept() }
                return DispatchQueue.main.sync(execute: accept)
            },
            resyncRequestHandler: { targetID, broadcasterID, broadcasterEpoch in
                let accept = {
                    MainActor.assumeIsolated {
                        relay.resyncRequest(targetID, broadcasterID, broadcasterEpoch)
                    }
                }
                if Thread.isMainThread { return accept() }
                return DispatchQueue.main.sync(execute: accept)
            },
            walkieTalkieHandler: { message in
                DispatchQueue.main.async { relay.walkieTalkie(message) }
            }
        )
        relay.replica = { [weak self] in self?.apply($0) }
        relay.participants = participantsHandler
        relay.mediaCommand = { [weak self] command, broadcasterID, broadcasterEpoch in
            self?.receiveMediaCommand(
                command,
                broadcasterID: broadcasterID,
                broadcasterEpoch: broadcasterEpoch
            ) ?? false
        }
        relay.resyncRequest = { [weak self] targetID, broadcasterID, broadcasterEpoch in
            self?.receiveResyncRequest(
                targetID: targetID,
                broadcasterID: broadcasterID,
                broadcasterEpoch: broadcasterEpoch
            ) ?? false
        }
        relay.walkieTalkie = { [weak self] message in self?.receiveWalkieTalkie(message) }
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
        let service = "WERAI-\(room.id.prefix(8))-\(nodeID.prefix(8))"
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
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !trimmed.isEmpty else { return }
        let appearance = DeviceAppearance(icon: icon, colorHex: colorHex)
        displayName = trimmed
        deviceIcon = appearance.icon
        deviceColorHex = appearance.colorHex
        control.updateIdentity(name: trimmed, icon: appearance.icon, colorHex: appearance.colorHex)
        identityHandler(nodeID, trimmed)
    }

    func beginWalkieTalkie(targetID: String?) async throws {
        guard targetID != nodeID else { return }
        guard await WalkieTalkieMicrophone.requestAccess() else {
            throw WERAIError(
                "Microphone access is needed for push-to-talk. Enable ALO in Privacy & Security → Microphone."
            )
        }
        endWalkieTalkie()
        let sessionID = UUID().uuidString
        let senderName = displayName
        walkieTransmissionQueue.sync {
            walkieTransmission = (sessionID, targetID, senderName, 0)
        }
        do {
            try walkieTalkieMicrophone.start { [weak self] data in
                guard let self else { return }
                let message: WalkieTalkieMessage? = self.walkieTransmissionQueue.sync {
                    guard var active = self.walkieTransmission, active.id == sessionID else { return nil }
                    active.sequence &+= 1
                    self.walkieTransmission = active
                    return WalkieTalkieMessage(
                        kind: .audio,
                        senderID: self.nodeID,
                        senderName: active.name,
                        targetID: active.targetID,
                        sessionID: active.id,
                        sequence: active.sequence,
                        pcm16Mono: data
                    )
                }
                if let message { self.control.publishWalkieTalkie(message) }
            }
            control.publishWalkieTalkie(WalkieTalkieMessage(
                kind: .began,
                senderID: nodeID,
                senderName: senderName,
                targetID: targetID,
                sessionID: sessionID
            ))
        } catch {
            walkieTransmissionQueue.sync { walkieTransmission = nil }
            throw error
        }
    }

    func endWalkieTalkie() {
        walkieTalkieMicrophone.stop()
        let active = walkieTransmissionQueue.sync {
            defer { walkieTransmission = nil }
            return walkieTransmission
        }
        guard let active else { return }
        control.publishWalkieTalkie(WalkieTalkieMessage(
            kind: .ended,
            senderID: nodeID,
            senderName: active.name,
            targetID: active.targetID,
            sessionID: active.id,
            sequence: active.sequence
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
    func setLocalLevel(volume: Double, muted: Bool) { receiver?.setLocalLevel(volume: volume, muted: muted) }
    func setParticipantLevel(id: String, volume: Double, muted: Bool) { hostSession?.setParticipantLevel(id: id, volume: volume, muted: muted) }
    func setIncomingMediaMuted(_ muted: Bool) {
        incomingMediaMuted = muted
        if isBroadcasting { hostSession?.setParticipantLevel(id: nodeID, volume: 1, muted: muted) }
        else { receiver?.setLocalLevel(volume: 1, muted: muted) }
    }
    func setIncomingWalkieTalkieMuted(_ muted: Bool) {
        incomingWalkieTalkieMuted = muted
        walkieTalkiePlayer?.setMuted(muted)
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
        endWalkieTalkie()
        walkieTalkiePlayer?.stop()
        walkieTalkiePlayer = nil
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
        receiver?.stop()
        receiver = nil
        await activeTransition?.value
        await hostSession?.stop()
        hostSession = nil
        control.stop()
    }

    func stopImmediately() {
        guard !isStopped else { return }
        isStopped = true
        endWalkieTalkie()
        walkieTalkiePlayer?.stop()
        walkieTalkiePlayer = nil
        intendsToBroadcast = false
        intendsToBroadcastVideo = false
        transitionGeneration += 1
        transitionTask?.cancel()
        transitionTask = nil
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
                chatHandler(sender, text, event.sentNanos ?? 0)
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
            let service = "WERAI-\(room.id.prefix(8))-\(nodeID.prefix(8))"
            control.publishBroadcaster(active: true, mediaServiceName: service)
        }
    }

    private func transition(to broadcaster: MeshBroadcaster?) {
        guard !isStopped else { return }
        mediaCommandReady = false
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
            guard !Task.isCancelled, generation == transitionGeneration else { return }
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
                        participantID: nodeID,
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
                    host.setParticipantLevel(id: nodeID, volume: 1, muted: incomingMediaMuted)
                } else {
                    statusHandler("Connecting to the room broadcaster")
                    let receiver = try Receiver(
                        requestedRoom: broadcaster.mediaServiceName,
                        roomDisplayName: room.name,
                        participantID: nodeID,
                        roomMediaCommandHandler: { [weak self] command in
                            let send = {
                                MainActor.assumeIsolated {
                                    self?.sendMediaCommand(command) ?? false
                                }
                            }
                            if Thread.isMainThread { return send() }
                            return DispatchQueue.main.sync(execute: send)
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
                    receiver.setLocalLevel(volume: 1, muted: incomingMediaMuted)
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

    private func receiveWalkieTalkie(_ message: WalkieTalkieMessage) {
        if !incomingWalkieTalkieMuted,
           message.kind == .audio,
           walkieTalkiePlayer == nil {
            walkieTalkiePlayer = WalkieTalkiePlayer()
        }
        walkieTalkiePlayer?.accept(message)
        switch message.kind {
        case .began:
            walkieTalkieStateHandler(message.senderID, message.senderName, true)
        case .ended:
            walkieTalkieStateHandler(message.senderID, message.senderName, false)
        case .audio:
            break
        }
    }
}
