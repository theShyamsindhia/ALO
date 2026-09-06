import Foundation
import SwiftUI
import ALOCore

/// One authoritative simulation per activity, independent of the room's owner.
@MainActor
final class StickFightSession: ObservableObject {
    enum Mode { case picker, practice, hosting, joining, host, guest, spectator }
    struct Lobby: Identifiable {
        var id: String { peerID }
        let peerID: String
        let sessionID: String
        let started: Bool
        let availableSlots: Int
        let humanCount: Int
        var seen: Double
    }
    typealias Slot = StickFightSlot
    @Published private(set) var mode: Mode = .picker { didSet { configureTimer() } }
    @Published private(set) var simulation = StickFightSimulation(playerCount: 2)
    @Published private(set) var slots: [Slot] = []
    @Published private(set) var lobbies: [Lobby] = []
    @Published var selectedMap: StickFightMap = .crimsonKeep
    @Published private(set) var localReady = false
    @Published private(set) var notice = ""
    @Published var showsMenu = false { didSet { configureTimer() } }
    @Published private(set) var revision = 0
    @Published var roomConnected = false
    var send: ((Data, String?) -> Void)? { didSet { roomConnected = send != nil; configureTimer() } }
    var names: [String: String] = [:]
    var localName = "You"
    var localParticipantID = "local"
    private(set) var localIndex = 0
    private var hostID: String?
    private var sessionID = UUID().uuidString
    private var sequence = 0
    private var remoteSequence = -1
    private var localInput = StickFightInput()
    private var buffered = StickFightInput()
    private var realtime = GameRealtimeEngine<StickFightInput>()
    private let loop = GameRealtimeLoop()
    private struct Member {
        var slot: Int
        var ready = false
        var seen: Double
        var input = StickFightInput()
        var buffered = StickFightInput()
        var inputAt = 0.0
        var sequence = -1
        var lastInputSequence = -1
        var acknowledgedInput = -1
    }
    private var members: [String: Member] = [:]
    private var spectators: [String: Double] = [:]
    private var bots = Set<Int>()
    private var lastHeartbeat = 0.0
    private var lastRemote = 0.0
    private var panels = 0
    private var ticks = 0
    private var wantsSpectate = false
    private var suspended = false
    var isActivityHost: Bool { mode == .hosting || mode == .host }
    var playing: Bool { [.practice, .host, .guest, .spectator].contains(mode) }
    var canReadyUp: Bool { mode == .hosting ? slots.count >= 2 : mode == .guest && !started }
    var availableSlots: Int { started ? 0 : max(0, 4 - slots.count) + bots.count }
    @Published private(set) var started = false { didSet { configureTimer() } }
    var playerNames: [String] { slots.map(\.name) }
    var canAddBot: Bool { mode == .hosting && slots.count < 4 }
    var canJoinCurrentLobby: Bool {
        mode == .spectator && !started && lobbies.contains { $0.peerID == hostID && $0.sessionID == sessionID && $0.availableSlots > 0 }
    }
    func joinCurrentLobby() {
        guard canJoinCurrentLobby else { return }
        notice = "Requesting an open fighter seat…"; transmit(.join)
    }

    func practice(botCount: Int = 3) {
        leave(); let count = min(4, max(2, botCount + 1))
        simulation = StickFightSimulation(playerCount: count, map: selectedMap)
        bots = Set(1..<count); mode = .practice; started = true; refreshSlots(); configureTimer()
    }
    func host(botCount: Int = 0) {
        guard roomConnected else { notice = "Join a room to host a fight, or play practice now."; return }
        leave(); sessionID = UUID().uuidString
        let count = min(4, max(1, botCount + 1))
        simulation = StickFightSimulation(playerCount: count, map: selectedMap)
        bots = Set(1..<count); mode = .hosting
        notice = "Room fight open. Everyone readies up to begin."
        refreshSlots(); configureTimer(); advertise()
    }
    func addBot() {
        guard canAddBot else { return }
        bots.insert(slots.count); simulation = StickFightSimulation(playerCount: slots.count + 1, map: selectedMap)
        localReady = false; refreshSlots(); broadcastState(); advertise()
    }
    func join(_ lobby: Lobby, spectate: Bool = false) {
        guard roomConnected else { notice = "Join the room before joining its fight."; return }
        leave(); hostID = lobby.peerID; sessionID = lobby.sessionID
        wantsSpectate = spectate; mode = .joining; lastRemote = ProcessInfo.processInfo.systemUptime
        notice = "Connecting to \(names[lobby.peerID] ?? "room host")…"
        configureTimer(); transmit(spectate ? .spectate : .join)
    }
    func readyUp() {
        guard canReadyUp else { return }; localReady.toggle()
        if isActivityHost { refreshSlots(); startIfReady(); broadcastState() }
        else { transmit(.ready, ready: localReady) }
    }
    private func startIfReady() {
        guard mode == .hosting, slots.count >= 2, localReady, members.values.allSatisfy(\.ready) else { return }
        started = true; mode = .host; notice = ""; advertise()
    }
    func rematch() {
        guard simulation.winner != nil else { return }
        if mode == .practice { practice(botCount: bots.count); return }
        if mode == .guest { transmit(.rematch); notice = "Rematch requested."; return }
        guard isActivityHost else { return }
        simulation = StickFightSimulation(playerCount: slots.count, map: selectedMap)
        started = false; mode = .hosting; localReady = false
        for id in members.keys { members[id]?.ready = false; members[id]?.input = StickFightInput() }
        refreshSlots(); broadcastState(); advertise()
    }
    func leave(message: String = "") {
        if isActivityHost { transmit(.leave, target: "") }
        else if hostID != nil { transmit(.leave) }
        mode = .picker; started = false; hostID = nil; localIndex = 0; localReady = false
        members.removeAll(); spectators.removeAll(); bots.removeAll(); slots.removeAll(); realtime.clearPrediction()
        remoteSequence = -1; clearInput(); showsMenu = false; suspended = false; notice = message; realtime.reset()
        configureTimer()
    }
    func disconnect() { leave(message: "Room disconnected. Practice is available offline."); send = nil; lobbies.removeAll(); loop.stop() }
    func panelAppeared() { panels += 1; configureTimer() }
    func panelDisappeared() { panels = max(0, panels - 1); clearInput(); if mode == .practice { showsMenu = true }; configureTimer() }
    func togglePause() { showsMenu.toggle(); clearInput() }
    func focusLost() { clearInput(); if mode == .practice { showsMenu = true } }
    func setInput(_ input: StickFightInput) {
        guard input.isValid, playing, mode != .spectator, !showsMenu else { clearInput(); return }
        buffered.jump = buffered.jump || (input.jump && !localInput.jump)
        buffered.punch = buffered.punch || (input.punch && !localInput.punch)
        buffered.shoot = buffered.shoot || (input.shoot && !localInput.shoot)
        buffered.throwWeapon = buffered.throwWeapon || (input.throwWeapon && !localInput.throwWeapon)
        if (input.shoot && !localInput.shoot) || (input.throwWeapon && !localInput.throwWeapon) { buffered.aimAngle = input.aimAngle }
        localInput = input
    }
    func clearInput() {
        let changed = localInput != StickFightInput() || buffered != StickFightInput()
        localInput = StickFightInput(); buffered = StickFightInput()
        if changed, mode == .guest, started { transmit(.input, input: localInput) }
    }
    private func refreshSlots() {
        slots = simulation.fighters.indices.map { i in
            let member = members.first { $0.value.slot == i }
            return Slot(index: i, name: String((i == 0 ? localName : member.map { names[$0.key] ?? "Room player" } ?? "Bot \(i)").prefix(40)), isBot: bots.contains(i), ready: i == 0 ? localReady : bots.contains(i) || member?.value.ready == true)
        }
    }
    private func configureTimer() {
        let active = roomConnected || mode != .picker || panels > 0
        let running = playing && started && mode != .spectator && !GameRealtimePolicy.pausesWorld(multiplayer: mode != .practice, menuOpen: showsMenu)
        if loop.configure(active: active, realtime: running, update: { [weak self] in self?.update(at: $0) }) {
            realtime.rebaseClock(at: ProcessInfo.processInfo.systemUptime)
        }
    }
    func presentationPosition(for index: Int, at time: Double) -> GameMotion {
        let f = simulation.fighters[index]
        return realtime.position(for: index, at: time, fallback: Self.motion(f), remote: mode == .spectator || (mode == .guest && index != localIndex))
    }
    private static func motion(_ f: StickFightFighter) -> GameMotion {
        GameMotion(x: f.x, y: f.y, vx: f.alive ? f.vx : 0, vy: f.alive ? f.vy : 0, continuity: f.alive ? 1 : 0)
    }
    private func advertise() { transmit(.lobby, target: "") }
    private func broadcastState() {
        for id in Set(members.keys).union(spectators.keys) { transmit(.state, target: id) }
    }
    @discardableResult
    private func transmit(_ kind: StickFightPacket.Kind, target: String? = nil, input: StickFightInput? = nil, ready: Bool? = nil) -> Int {
        sequence += 1; var packet = StickFightPacket(kind: kind, session: sessionID, sequence: sequence)
        let destination = target == "" ? nil : target ?? hostID
        packet.input = input; packet.ready = ready
        if kind == .lobby { packet.started = started; packet.availableSlots = availableSlots; packet.slots = slots }
        if kind == .state {
            packet.state = simulation; packet.slots = slots; packet.started = started
            packet.assignedSlot = destination.flatMap { members[$0]?.slot }
            packet.spectating = destination.map { spectators[$0] != nil } ?? false
            packet.acknowledgedInput = destination.flatMap { members[$0]?.acknowledgedInput }
        }
        if let data = try? JSONEncoder().encode(packet), data.count <= GameRealtimePolicy.maximumPacketBytes { send?(data, destination) }
        return sequence
    }
    func receive(from sender: String, data: Data) {
        guard roomConnected, data.count <= GameRealtimePolicy.maximumPacketBytes, let packet = try? JSONDecoder().decode(StickFightPacket.self, from: data), packet.isValid else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if packet.kind == .lobby {
            lobbies.removeAll { $0.peerID == sender }
            if lobbies.count < 32 { lobbies.append(Lobby(peerID: sender, sessionID: packet.session, started: packet.started!, availableSlots: packet.availableSlots!, humanCount: packet.slots?.filter { !$0.isBot }.count ?? 1, seen: now)) }
            return
        }
        if packet.kind == .leave { lobbies.removeAll { $0.peerID == sender && $0.sessionID == packet.session } }
        guard packet.session == sessionID else { return }
        if isActivityHost { receiveHost(sender, packet, now); return }
        guard sender == hostID, packet.sequence > remoteSequence else { return }
        if packet.kind == .leave { leave(message: "The fight host left. Your room is still open; host a new fight or join another."); return }
        if packet.kind == .busy { leave(message: "This fight and its spectator seats are full. Try another fight or host one."); return }
        guard packet.kind == .state, let state = packet.state, let roster = packet.slots else { return }
        if packet.spectating != true { guard let slot = packet.assignedSlot, roster.indices.contains(slot), !roster[slot].isBot else { return }; localIndex = packet.assignedSlot! }
        remoteSequence = packet.sequence; lastRemote = now; suspended = false
        started = packet.started!; slots = roster; simulation = state; selectedMap = state.map
        mode = packet.spectating == true ? .spectator : .guest
        localReady = mode == .guest ? roster[localIndex].ready : false
        notice = mode == .spectator ? (started ? "Fight in progress · spectating. Join the next lobby when seats open." : "All fighter seats are occupied · spectating.") : (started ? "" : "You joined. Ready up when everyone is here.")
        // Replay only local movement after the host's acknowledged input. Damage,
        // shots and round results always remain the host's authoritative state.
        realtime.receiveSnapshot(frame: state.frame, epoch: sessionID + "/" + String(state.round), at: now, motion: state.fighters.map(Self.motion))
        let replay = realtime.acknowledge(packet.acknowledgedInput)
        if !started { realtime.clearPrediction(); clearInput(); realtime.rebaseClock(at: now) }
        if mode == .guest, started {
            for input in replay {
                simulation.predictMovement(slot: localIndex, input: input)
            }
        }
        revision &+= 1
    }
    private func receiveHost(_ sender: String, _ packet: StickFightPacket, _ now: Double) {
        if packet.kind == .join || packet.kind == .spectate {
            if var member = members[sender] { member.seen = now; members[sender] = member; transmit(.state, target: sender); return }
            if packet.kind == .join, !started, let slot = bots.min() ?? (slots.count < 4 ? slots.count : nil) {
                if slot == simulation.fighters.count { simulation = StickFightSimulation(playerCount: slot + 1, map: selectedMap) }
                bots.remove(slot); spectators.removeValue(forKey: sender)
                members[sender] = Member(slot: slot, seen: now, sequence: packet.sequence)
                localReady = false; refreshSlots(); broadcastState(); advertise(); return
            }
            guard spectators[sender] != nil || spectators.count < 8 else { transmit(.busy, target: sender); return }
            spectators[sender] = now; transmit(.state, target: sender); return
        }
        if packet.kind == .leave, spectators.removeValue(forKey: sender) != nil { return }
        guard var member = members[sender], packet.sequence > member.sequence else { return }
        member.sequence = packet.sequence; member.seen = now
        switch packet.kind {
        case .input where started:
            let input = packet.input!
            member.buffered.jump = member.buffered.jump || (input.jump && !member.input.jump)
            member.buffered.punch = member.buffered.punch || (input.punch && !member.input.punch)
            member.buffered.shoot = member.buffered.shoot || (input.shoot && !member.input.shoot)
            member.buffered.throwWeapon = member.buffered.throwWeapon || (input.throwWeapon && !member.input.throwWeapon)
            if (input.shoot && !member.input.shoot) || (input.throwWeapon && !member.input.throwWeapon) { member.buffered.aimAngle = input.aimAngle }
            member.input = input; member.inputAt = now; member.lastInputSequence = packet.sequence
        case .ready where !started: member.ready = packet.ready!
        case .leave: members.removeValue(forKey: sender); bots.insert(member.slot); refreshSlots(); broadcastState(); advertise(); return
        case .rematch where simulation.winner != nil: members[sender] = member; rematch(); return
        default: break
        }
        members[sender] = member
        if packet.kind == .ready { refreshSlots(); startIfReady(); broadcastState() }
    }
    private func mergingActions(_ held: StickFightInput, _ edges: StickFightInput) -> StickFightInput {
        var input = held
        input.jump = input.jump || edges.jump; input.punch = input.punch || edges.punch
        input.shoot = input.shoot || edges.shoot; input.throwWeapon = input.throwWeapon || edges.throwWeapon
        if edges.shoot || edges.throwWeapon, let aim = edges.aimAngle { input.aimAngle = aim }
        return input
    }
    /// Exposed to deterministic session tests; real callbacks use monotonic uptime.
    func update(at now: Double) {
        ticks &+= 1
        let frame = realtime.advance(at: now, running: playing && started && mode != .spectator && !suspended && !GameRealtimePolicy.pausesWorld(multiplayer: mode != .practice, menuOpen: showsMenu))
        if now - lastHeartbeat >= 1 {
            lastHeartbeat = now; lobbies.removeAll { now - $0.seen > 4 }
            if isActivityHost {
                for id in members.keys.filter({ now - members[$0]!.seen > GameRealtimePolicy.memberTimeout }) { if let member = members.removeValue(forKey: id) { bots.insert(member.slot) } }
                spectators = spectators.filter { now - $0.value < GameRealtimePolicy.memberTimeout }; refreshSlots(); advertise(); if !started { broadcastState() }
            } else if mode == .joining { transmit(wantsSpectate ? .spectate : .join) }
            else if mode == .spectator { transmit(.spectate) }
            else if mode == .guest && !started { transmit(.ready, ready: localReady) }
        }
        if [.joining, .guest, .spectator].contains(mode) {
            let age = now - lastRemote
            if age > GameRealtimePolicy.connectionTimeout { leave(message: "Fight connection lost. Your room is still open. Join again or host a new fight."); return }
            if age > GameRealtimePolicy.reconnectAfter { suspended = true; notice = "Reconnecting to fight host…"; if ticks % 30 == 0 { transmit(mode == .spectator ? .spectate : .join) } }
        }
        guard playing, started, mode != .spectator, !suspended else { return }
        if GameRealtimePolicy.pausesWorld(multiplayer: mode != .practice, menuOpen: showsMenu) { return }
        var input = showsMenu ? StickFightInput() : localInput
        input = mergingActions(input, buffered)
        if mode == .guest && frame.steps > 0 {
            let seq = transmit(.input, input: input)
            realtime.recordInput(sequence: seq, input: input, steps: frame.steps)
        }
        for _ in 0..<frame.steps {
            let inputs = simulation.fighters.indices.map { slot -> StickFightInput in
                if slot == localIndex { return input }
                if mode == .guest { return StickFightInput() }
                if bots.contains(slot) { return simulation.botInput(for: slot) }
                guard let member = members.values.first(where: { $0.slot == slot }), now - member.inputAt < GameRealtimePolicy.staleInputAfter else { return StickFightInput() }
                return mergingActions(member.input, member.buffered)
            }
            if mode == .guest { simulation.predictMovement(slot: localIndex, input: input) }
            else { simulation.tick(inputs) }
        }
        if frame.steps > 0 {
            buffered = StickFightInput()
            for id in members.keys {
                members[id]?.buffered = StickFightInput()
                let acknowledged = members[id]?.lastInputSequence ?? -1
                members[id]?.acknowledgedInput = acknowledged
            }
            revision &+= 1
        }
        if mode == .host && frame.publishSnapshot { broadcastState() }
    }
}
