import Foundation
import SwiftUI
import ALOCore

/// One authoritative simulation per activity, independent of the room's owner.
@MainActor
final class BreachRoomSession: ObservableObject {
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
    typealias Slot = BreachSlot
    @Published private(set) var mode: Mode = .picker { didSet { configureTimer() } }
    @Published private(set) var simulation = BreachMatch()
    @Published private(set) var slots: [Slot] = []
    @Published private(set) var lobbies: [Lobby] = []
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
    private var localInput = BreachInput()
    private var buffered = BreachInput()
    private var realtime = GameRealtimeEngine<BreachInput>()
    private let loop = GameRealtimeLoop()
    var clock: () -> Double = { ProcessInfo.processInfo.systemUptime }
    private struct Member {
        var slot: Int
        var joinsAtRound = 0
        var ready = false
        var seen: Double
        var input = BreachInput()
        var buffered = BreachInput()
        var inputAt = 0.0
        var sequence = -1
        var lastInputSequence = -1
        var acknowledgedInput = -1
    }
    private var members: [String: Member] = [:]
    private var peerSequences: [String: (sequence: Int, seen: Double)] = [:]
    private var spectators: [String: Double] = [:]
    private var bots = Set<Int>()
    private var lastHeartbeat = 0.0
    private var lastRemote = 0.0
    private var panels = 0
    private var ticks = 0
    private var wantsSpectate = false
    @Published private(set) var waitingForRound = false
    private var lobbySequences: [String: Int] = [:]
    private var suspended = false
    var isActivityHost: Bool { mode == .hosting || mode == .host }
    var playing: Bool { [.practice, .host, .guest, .spectator].contains(mode) }
    var canReadyUp: Bool { mode == .hosting ? slots.count == 4 : mode == .guest && !started }
    var availableSlots: Int { bots.count }
    @Published private(set) var started = false { didSet { configureTimer() } }
    var playerNames: [String] { slots.map(\.name) }
    var canJoinCurrentLobby: Bool { mode == .spectator && !started && lobbies.contains { $0.peerID == hostID && $0.availableSlots > 0 } }
    func joinCurrentLobby() {
        guard let lobby = lobbies.first(where: { $0.peerID == hostID }) else { return }
        join(lobby)
    }
    func practice() {
        leave(); simulation = BreachMatch(); bots = Set(1..<4)
        mode = .practice; started = true; refreshSlots(); configureTimer()
    }
    func host() {
        guard roomConnected else { notice = "Join a room to host Breach, or play practice now."; return }
        leave(); sessionID = UUID().uuidString; simulation = BreachMatch(); bots = Set(1..<4)
        mode = .hosting; notice = "Room match open. Ready up to start; bots fill empty seats."
        refreshSlots(); configureTimer(); advertise()
    }
    func join(_ lobby: Lobby, spectate: Bool = false) {
        guard roomConnected else { notice = "Join the room before joining its match."; return }
        leave(); hostID = lobby.peerID; sessionID = lobby.sessionID
        wantsSpectate = spectate; mode = .joining; lastRemote = clock()
        notice = "Connecting to \(names[lobby.peerID] ?? "room host")…"
        configureTimer(); transmit(spectate ? .spectate : .join)
    }
    func readyUp() {
        guard canReadyUp else { return }; localReady.toggle()
        if isActivityHost { refreshSlots(); startIfReady(); broadcastState() }
        else { transmit(.ready, ready: localReady) }
    }
    private func startIfReady() {
        guard mode == .hosting, slots.count == 4, localReady, members.values.allSatisfy(\.ready) else { return }
        started = true; mode = .host; notice = ""; advertise()
    }
    func rematch() {
        guard simulation.winner != nil else { return }
        if mode == .practice { practice(); return }
        if mode == .guest { transmit(.rematch); notice = "Rematch requested."; return }
        guard isActivityHost else { return }
        simulation = BreachMatch()
        started = false; mode = .hosting; localReady = false
        for id in members.keys { members[id]?.ready = false; members[id]?.joinsAtRound = 1; members[id]?.input = BreachInput(); members[id]?.buffered = BreachInput() }
        refreshSlots(); broadcastState(); advertise()
    }
    func leave(message: String = "") {
        if isActivityHost { transmit(.leave, target: "") }
        else if hostID != nil { transmit(.leave) }
        mode = .picker; started = false; hostID = nil; localIndex = 0; localReady = false
        members.removeAll(); peerSequences.removeAll(); spectators.removeAll(); bots.removeAll(); slots.removeAll(); realtime.clearPrediction()
        remoteSequence = -1; waitingForRound = false; clearInput(); showsMenu = false; suspended = false; notice = message; realtime.reset()
        configureTimer()
    }
    func disconnect() { leave(message: "Room disconnected. Practice is available offline."); send = nil; lobbies.removeAll(); loop.stop() }
    func panelAppeared() { panels += 1; configureTimer() }
    func panelDisappeared() { panels = max(0, panels - 1); clearInput(); if mode == .practice { showsMenu = true }; configureTimer() }
    func togglePause() { showsMenu.toggle(); clearInput() }
    func focusLost() { clearInput(); if mode == .practice { showsMenu = true } }
    func setInput(_ input: BreachInput) {
        guard input.isValid, playing, mode != .spectator, !showsMenu else { clearInput(); return }
        buffered.fire = buffered.fire || (input.fire && !localInput.fire)
        buffered.reload = buffered.reload || (input.reload && !localInput.reload)
        buffered.buy = input.buy ?? buffered.buy
        buffered.buyArmor = buffered.buyArmor || (input.buyArmor && !localInput.buyArmor)
        localInput = input
    }
    func clearInput() {
        let changed = localInput != BreachInput() || buffered != BreachInput()
        localInput = BreachInput(); buffered = BreachInput()
        if changed, mode == .guest, started { transmit(.input, input: localInput) }
    }
    private func refreshSlots() {
        slots = simulation.players.indices.map { i in
            let member = members.first { $0.value.slot == i }
            return Slot(index: i, name: String((i == 0 ? localName : member.map { names[$0.key] ?? "Room player" } ?? "Bot \(i)").prefix(40)), isBot: bots.contains(i), ready: i == 0 ? localReady : bots.contains(i) || member?.value.ready == true)
        }
    }
    private func configureTimer() {
        let active = roomConnected || mode != .picker || panels > 0
        let running = playing && started && mode != .spectator && !GameRealtimePolicy.pausesWorld(multiplayer: mode != .practice, menuOpen: showsMenu)
        if loop.configure(active: active, realtime: running, update: { [weak self] in self?.update(at: $0) }) {
            realtime.rebaseClock(at: clock())
        }
    }
    func presentationPosition(for index: Int, at time: Double) -> GameMotion {
        guard simulation.players.indices.contains(index) else { return GameMotion(x: 0, y: 0, vx: 0, vy: 0) }
        let f = simulation.players[index]
        return realtime.position(for: index, at: time, fallback: Self.motion(f), remote: mode == .spectator || (mode == .guest && index != localIndex))
    }
    private static func motion(_ f: BreachPlayer) -> GameMotion {
        GameMotion(x: f.position.x, y: f.position.z, vx: 0, vy: 0, continuity: f.alive ? 1 : 0)
    }
    private func advertise() { transmit(.lobby, target: "") }
    private func broadcastState() {
        for id in Set(members.keys).union(spectators.keys) { transmit(.state, target: id) }
    }
    @discardableResult
    private func transmit(_ kind: BreachPacket.Kind, target: String? = nil, input: BreachInput? = nil, ready: Bool? = nil) -> Int {
        sequence += 1; var packet = BreachPacket(kind: kind, session: sessionID, sequence: sequence)
        let destination = target == "" ? nil : target ?? hostID
        packet.input = input; packet.ready = ready
        if kind == .lobby { packet.started = started; packet.availableSlots = availableSlots; packet.slots = slots }
        if kind == .state {
            packet.waitingForRound = destination.flatMap { members[$0] }.map { $0.joinsAtRound > simulation.round } ?? false
            packet.state = simulation.networkSnapshot; packet.slots = slots; packet.started = started
            packet.assignedSlot = destination.flatMap { members[$0]?.slot }
            packet.spectating = destination.map { spectators[$0] != nil } ?? false
            packet.acknowledgedInput = destination.flatMap { members[$0]?.acknowledgedInput }
        }
        if let data = try? JSONEncoder().encode(packet), data.count <= GameRealtimePolicy.maximumPacketBytes { send?(data, destination) }
        return sequence
    }
    func receive(from sender: String, data: Data) {
        guard !sender.isEmpty, sender.utf8.count <= 256, roomConnected, data.count <= GameRealtimePolicy.maximumPacketBytes, let packet = try? JSONDecoder().decode(BreachPacket.self, from: data), packet.isValid else { return }
        let now = clock()
        if packet.kind == .lobby {
            let key = sender + "/" + packet.session
            guard packet.sequence > (lobbySequences[key] ?? -1) else { return }
            if lobbySequences.count > 128 { lobbySequences.removeAll() }
            lobbySequences[key] = packet.sequence
            lobbies.removeAll { $0.peerID == sender }
            if lobbies.count < 32 { lobbies.append(Lobby(peerID: sender, sessionID: packet.session, started: packet.started!, availableSlots: packet.availableSlots!, humanCount: packet.slots?.filter { !$0.isBot }.count ?? 1, seen: now)) }
            return
        }
        if packet.kind == .leave { lobbies.removeAll { $0.peerID == sender && $0.sessionID == packet.session } }
        guard packet.session == sessionID else { return }
        if isActivityHost { receiveHost(sender, packet, now); return }
        guard sender == hostID, packet.sequence > remoteSequence else { return }
        if packet.kind == .leave { leave(message: "The match host left. Your room is still open; host a new match or join another."); return }
        if packet.kind == .busy { leave(message: "This match and its spectator seats are full. Try another match or host one."); return }
        guard packet.kind == .state, let state = packet.state, let roster = packet.slots else { return }
        if packet.spectating != true { guard let slot = packet.assignedSlot, roster.indices.contains(slot), !roster[slot].isBot else { return }; localIndex = packet.assignedSlot! }
        remoteSequence = packet.sequence; lastRemote = now; suspended = false
        started = packet.started!; waitingForRound = packet.waitingForRound ?? false; slots = roster; simulation = state
        mode = packet.spectating == true ? .spectator : .guest
        localReady = mode == .guest ? roster[localIndex].ready : false
        notice = mode == .spectator ? (started ? "Round in progress · spectating. Return to the lobby after the match to take a seat." : "All player seats are occupied · spectating.") : (started ? "" : "You joined. Ready up when everyone is here.")
        if waitingForRound { notice = "Seat reserved. You join the next round; the current bot finishes this round." }
        // Replay only local movement after the host's acknowledged input. Damage,
        // shots and round results always remain the host's authoritative state.
        realtime.receiveSnapshot(frame: state.frame, epoch: sessionID + "/" + String(state.round), at: now, motion: state.players.map(Self.motion))
        let replay = realtime.acknowledge(packet.acknowledgedInput)
        if !started { realtime.clearPrediction(); clearInput(); realtime.rebaseClock(at: now) }
        if mode == .guest, started, !waitingForRound {
            for input in replay {
                simulation.predictMovement(slot: localIndex, input: input)
            }
        }
        revision &+= 1
    }
    private func receiveHost(_ sender: String, _ packet: BreachPacket, _ now: Double) {
        guard packet.kind == .join || packet.kind == .spectate || members[sender] != nil || spectators[sender] != nil else { return }
        // Keep a short-lived tombstone after leave so reordered lifecycle packets
        // cannot reclaim a seat. Expiry permits a restarted client to reconnect.
        if let previous = peerSequences[sender], now - previous.seen < 60 {
            guard packet.sequence > previous.sequence else { return }
        }
        guard peerSequences[sender] != nil || peerSequences.count < 128 else { return }
        peerSequences[sender] = (packet.sequence, now)

        if packet.kind == .join || packet.kind == .spectate {
            if var member = members[sender] { member.seen = now; members[sender] = member; transmit(.state, target: sender); return }
            if packet.kind == .join, let slot = bots.min() {
                bots.remove(slot); spectators.removeValue(forKey: sender)
                members[sender] = Member(slot: slot, joinsAtRound: started ? simulation.round + 1 : simulation.round, ready: started, seen: now, sequence: packet.sequence)
                if !started { localReady = false }; refreshSlots(); broadcastState(); advertise(); return
            }
            guard spectators[sender] != nil || spectators.count < 8 else { transmit(.busy, target: sender); return }
            spectators[sender] = now; transmit(.state, target: sender); return
        }
        if packet.kind == .leave, spectators.removeValue(forKey: sender) != nil { return }
        guard var member = members[sender], packet.sequence > member.sequence else { return }
        member.sequence = packet.sequence; member.seen = now
        switch packet.kind {
        case .action where started && member.joinsAtRound <= simulation.round:
            member.buffered = mergingActions(member.buffered, packet.input!)
            member.inputAt = now; member.lastInputSequence = packet.sequence
        case .input where started && member.joinsAtRound <= simulation.round:
            let input = packet.input!
            member.buffered = mergingActions(member.buffered, input)
            member.input = input; member.inputAt = now; member.lastInputSequence = packet.sequence
        case .ready where !started: member.ready = packet.ready!
        case .leave: members.removeValue(forKey: sender); bots.insert(member.slot); refreshSlots(); broadcastState(); advertise(); return
        case .rematch where simulation.winner != nil: members[sender] = member; rematch(); return
        default: break
        }
        members[sender] = member
        if packet.kind == .ready { refreshSlots(); startIfReady(); broadcastState() }
    }
    private func mergingActions(_ held: BreachInput, _ edges: BreachInput) -> BreachInput {
        var input = held
        input.fire = input.fire || edges.fire; input.reload = input.reload || edges.reload
        input.buy = edges.buy ?? input.buy; input.buyArmor = input.buyArmor || edges.buyArmor
        return input
    }
    /// Exposed to deterministic session tests; real callbacks use monotonic uptime.
    func update(at now: Double) {
        ticks &+= 1
        let frame = realtime.advance(at: now, running: playing && started && mode != .spectator && !suspended && !GameRealtimePolicy.pausesWorld(multiplayer: mode != .practice, menuOpen: showsMenu))
        if now - lastHeartbeat >= 1 {
            lastHeartbeat = now; lobbies.removeAll { now - $0.seen > 4 }
            if isActivityHost {
                peerSequences = peerSequences.filter { now - $0.value.seen < 60 }
                for id in members.keys.filter({ now - members[$0]!.seen > GameRealtimePolicy.memberTimeout }) { if let member = members.removeValue(forKey: id) { bots.insert(member.slot) } }
                spectators = spectators.filter { now - $0.value < GameRealtimePolicy.memberTimeout }; refreshSlots(); advertise(); if !started { broadcastState() }
            } else if mode == .joining { transmit(wantsSpectate ? .spectate : .join) }
            else if mode == .spectator { transmit(.spectate) }
            else if mode == .guest && !started { transmit(.ready, ready: localReady) }
        }
        if [.joining, .guest, .spectator].contains(mode) {
            let age = now - lastRemote
            if age > GameRealtimePolicy.connectionTimeout { leave(message: "Match connection lost. Your room is still open. Join again or host a new match."); return }
            if age > GameRealtimePolicy.reconnectAfter { suspended = true; notice = "Reconnecting to match host…"; if ticks % 30 == 0 { transmit(mode == .spectator ? .spectate : .join) } }
        }
        guard playing, started, mode != .spectator, !suspended else { return }
        if GameRealtimePolicy.pausesWorld(multiplayer: mode != .practice, menuOpen: showsMenu) { return }
        var input = showsMenu ? BreachInput() : localInput
        input = mergingActions(input, buffered)
        if mode == .guest && frame.steps > 0 {
            // Discrete actions use bounded priority traffic, never the replaceable
            // movement queue, so a short tap survives a stalled connection.
            if buffered.fire || buffered.reload || buffered.buy != nil || buffered.buyArmor {
                var action = buffered; action.yaw = localInput.yaw; action.pitch = localInput.pitch
                transmit(.action, input: action)
            }
            var held = localInput
            held.buy = nil; held.buyArmor = false; held.reload = false
            let seq = transmit(.input, input: held)
            realtime.recordInput(sequence: seq, input: input, steps: frame.steps)
        }
        for stepIndex in 0..<frame.steps {
            let inputs = simulation.players.indices.map { slot -> BreachInput in
                if slot == localIndex {
                    var sampled = waitingForRound ? BreachInput() : input
                    if stepIndex > 0 { sampled.buy = nil; sampled.buyArmor = false; sampled.reload = false; sampled.fire = localInput.fire }
                    return sampled
                }
                if mode == .guest { return BreachInput() }
                if bots.contains(slot) || members.values.contains(where: { $0.slot == slot && $0.joinsAtRound > simulation.round }) { return simulation.botInput(for: slot) }
                guard let member = members.values.first(where: { $0.slot == slot }), now - member.inputAt < GameRealtimePolicy.staleInputAfter else { return BreachInput() }
                var sampled = mergingActions(member.input, member.buffered)
                if stepIndex > 0 { sampled.buy = nil; sampled.buyArmor = false; sampled.reload = false; sampled.fire = member.input.fire }
                return sampled
            }
            if mode == .guest { if !waitingForRound { simulation.predictMovement(slot: localIndex, input: input) } }
            else { simulation.tick(inputs) }
        }
        if frame.steps > 0 {
            buffered = BreachInput(); localInput.buy = nil; localInput.buyArmor = false; localInput.reload = false
            for id in members.keys {
                members[id]?.buffered = BreachInput(); members[id]?.input.buy = nil; members[id]?.input.buyArmor = false; members[id]?.input.reload = false
                let acknowledged = members[id]?.lastInputSequence ?? -1
                members[id]?.acknowledgedInput = acknowledged
            }
            revision &+= 1
        }
        if mode == .host && frame.publishSnapshot { broadcastState() }
    }
}
