import AppKit
import SwiftUI
import ALOCore
import GameController

struct ArenaMatchResult {
    let sessionID: String
    let round: Int
    let participantIDs: [String?]
    let playerNames: [String]
    let winner: Int
    let botSlots: Set<Int>
}

@MainActor
final class ArenaSession: ObservableObject {
    enum Mode { case picker, practice, hosting, joining, readyHost, readyGuest, host, guest, spectator }
    struct Lobby: Identifiable {
        var id: String { peerID }
        let peerID: String
        let sessionID: String
        let fighter: ArenaFighterKind
        let map: ArenaMap
        let round: Int
        let started: Bool
        var availableSlots: Int = 1
        var humanCount: Int = 1
        var botCount: Int = 0
        var seen: TimeInterval
    }
    @Published var mode: Mode = .picker { didSet { configureTimer() } }
    @Published var localReady = false
    @Published var remoteReady = false
    @Published var spectatorCount = 0
    let library = GameLibraryStore()
    let fourfold = FourfoldSession()
    @Published var selectedGameID: String?
    @Published var loadingGame = false
    @Published var gameLoadError: String?
    @Published var showsMenu = false
    @Published var effectsEnabled = true
    private(set) var gameBackground: NSImage?
    private(set) var expandedFighterArtwork: NSImage?
    @Published var botDifficulty: ArenaBotDifficulty = .normal
    private(set) var fighterArtwork: NSImage?
    private(set) var gardenBackground: NSImage?
    private(set) var midgroundArtwork: NSImage?
    private(set) var platformArtwork: NSImage?
    var arenaBackground: NSImage? { selectedMap == .observatory ? gameBackground : gardenBackground ?? gameBackground }
    private var loadTask: Task<Void, Never>?
    @Published var selectedMap: ArenaMap = .observatory
    @Published private(set) var latencyMilliseconds: Int?
    private var sentProbe: Double?
    private var peerProbe: Double?
    private var measuredProbe: Double?
    @Published var selected: ArenaFighterKind = .nova
    @Published var notice = ""
    @Published var lobbies: [Lobby] = []
    @Published var paused = false { didSet { configureTimer() } }
    @Published var expanded = false
    @Published var revision = 0
    @Published var gameVolume: Double = UserDefaults.standard.object(forKey: "arenaVolume") as? Double ?? 0.35 {
        didSet { UserDefaults.standard.set(gameVolume, forKey: "arenaVolume"); sound.volume = Float(gameVolume) }
    }
    var controlsFocused = false
    @Published private(set) var inputFocusRequest = 0
    private let sound = ArenaSoundPlayer()
    private var priorSoundHits = [0, 0]
    private var priorSoundStocks = [3, 3]
    private var controllerPausePressed = false
    var simulation = ArenaSimulation()
    var send: ((Data, String?) -> Void)?
    var names: [String: String] = [:]
    var localName = "You"
    var localParticipantID = "local"
    var onMatchFinished: ((ArenaMatchResult) -> Void)?
    var onLobbyDiscovered: ((Lobby) -> Void)?
    var onLobbyRemoved: ((String) -> Void)?
    @Published private(set) var botSlots = Set<Int>()
    @Published private(set) var playerSlots: [ArenaPlayerSlot] = []
    private struct Member {
        var slot: Int
        var ready = false
        var input = ArenaInput()
        var lastInput = 0.0
        var lastSeen: Double
        var sequence = -1
        var probe: Double?
        var latency: Int?
        var measuredProbe: Double?
    }
    private var members: [String: Member] = [:]
    private var spectatorProbes: [String: Double] = [:]
    private var assignedSlot = 0
    private var reportedResultKeys = Set<String>()
    private var reportedRound: Int?
    private var remoteParticipantIDs: [String?]?
    private var announcedSessions = Set<String>()
    var canAddBot: Bool { [.hosting, .readyHost].contains(mode) && simulation.fighters.count < 4 }
    var canRemoveBot: Bool { [.hosting, .readyHost].contains(mode) && !botSlots.isEmpty }
    var readyPlayerCount: Int { playerSlots.filter(\.ready).count }
    var isActivityHost: Bool { [.hosting, .readyHost, .host].contains(mode) }
    var availableSlots: Int {
        if mode == .host { return simulation.winner == nil ? botSlots.filter { simulation.fighters[$0].stocks > 0 }.count : 0 }
        return max(0, 4 - simulation.fighters.count) + botSlots.count
    }
    private(set) var peerID: String?
    private var round = 0
    private var sessionID = UUID().uuidString
    private var timer: Timer?
    private var previousTime: TimeInterval = 0
    private var accumulator = 0.0
    private var tickCount = 0
    private var sequence = 0
    private var remoteSequence = -1
    private var lastRemote = 0.0
    private var lastInput = 0.0
    private var lastAdvertise = 0.0
    private var remotePlayerNames: [String]?
    private var spectators: [String: TimeInterval] = [:]
    private var visiblePanels = 0
    private var visibleSurfaces = Set<UUID>()
    private var localInput = ArenaInput()
    private var bufferedActions = ArenaInput()
    private var remoteInput = ArenaInput()
    private var window: NSWindow?
    private var windowDelegate: ArenaWindowDelegate?
    var scene: ArenaScene?
    var localIndex: Int { [.joining, .readyGuest, .guest].contains(mode) ? assignedSlot : 0 }
    var playing: Bool { [.practice, .host, .guest, .spectator].contains(mode) }
    var networked: Bool { [.host, .guest, .hosting, .joining, .readyHost, .readyGuest, .spectator].contains(mode) }
    var playerNames: [String] {
        if [.joining, .readyGuest, .guest, .spectator].contains(mode), let remotePlayerNames,
           remotePlayerNames.count == simulation.fighters.count { return remotePlayerNames }
        return simulation.fighters.indices.map { slot in
            if slot == 0 { return localName }
            if let peer = members.first(where: { $0.value.slot == slot })?.key { return names[peer] ?? "Room player" }
            return "Bot \(slot)"
        }
    }
    private func refreshSlots() {
        playerSlots = simulation.fighters.indices.map { slot in
            ArenaPlayerSlot(index: slot, name: String(playerNames[slot].prefix(40)), isBot: botSlots.contains(slot),
                ready: slot == 0 ? localReady : botSlots.contains(slot) || members.values.first(where: { $0.slot == slot })?.ready == true)
        }
        remoteReady = members.values.allSatisfy(\.ready)
        revision += 1
    }

    func openGame(_ pack: InstalledGamePack) {
        leave(); selectedGameID = pack.descriptor.id; loadingGame = true; gameLoadError = nil
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            if pack.descriptor.engine == "fourfold-v1" {
                fourfold.subtitle = pack.content.subtitle; fourfold.accentHex = pack.content.accentHex
            }
            gameBackground = pack.content.backgroundImageData.flatMap(NSImage.init(data:))
            gardenBackground = pack.content.gardenImageData.flatMap(NSImage.init(data:))
            midgroundArtwork = pack.content.midgroundImageData.flatMap(NSImage.init(data:))
            platformArtwork = pack.content.platformImageData.flatMap(NSImage.init(data:))
            fighterArtwork = pack.content.fighterImageData.flatMap(NSImage.init(data:))
            expandedFighterArtwork = pack.content.expandedFighterImageData.flatMap(NSImage.init(data:))
            if (pack.content.backgroundImageBase64 != nil && gameBackground == nil) || (pack.content.platformImageBase64 != nil && platformArtwork == nil) {
                gameLoadError = "The artwork could not be loaded. Remove the pack and download it again."
            }
            loadingGame = false; configureTimer()
        }
    }
    func returnToLibrary() {
        leave(); loadTask?.cancel(); selectedGameID = nil; loadingGame = false
        gameBackground = nil; gardenBackground = nil; midgroundArtwork = nil; platformArtwork = nil; expandedFighterArtwork = nil; fighterArtwork = nil; gameLoadError = nil; controlsFocused = false; configureTimer()
    }
    func closeMenu() { showsMenu = false; paused = false; clearInput(); inputFocusRequest &+= 1 }
    func activate() { configureTimer() }
    func panelAppeared() { visiblePanels += 1; configureTimer() }
    func panelDisappeared() {
        visiblePanels = max(0, visiblePanels - 1)
        if visiblePanels == 0 && mode == .practice { paused = true }
        clearInput(); sound.stop(); configureTimer()
    }
    private func configureTimer() {
        timer?.invalidate(); timer = nil
        guard networked || (visiblePanels > 0 && (playing || selectedGameID == "rift-arena")) else { return }
        previousTime = ProcessInfo.processInfo.systemUptime
        let interval = playing && !paused ? ArenaSimulation.step : 0.25
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        timer.tolerance = playing ? 0.002 : 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    private func botKind(slot: Int) -> ArenaFighterKind {
        let roster = ArenaFighterKind.allCases
        let start = roster.firstIndex(of: selected) ?? 0
        return roster[(start + slot) % roster.count]
    }
    func practice() {
        leave(); simulation = ArenaSimulation(first: selected, second: selected == .nova ? .atlas : .nova, map: selectedMap)
        botSlots = [1]; mode = .practice; paused = false; refreshSlots(); activate()
    }
    func host(botCount: Int = 0) {
        leave(); round = 0; sessionID = UUID().uuidString
        let count = min(3, max(0, botCount))
        simulation = ArenaSimulation(kinds: [selected] + (0..<count).map { botKind(slot: $0 + 1) }, map: selectedMap)
        botSlots = Set(1..<simulation.fighters.count)
        mode = count > 0 ? .readyHost : .hosting
        notice = "Room arena open. Add bots or invite people, then ready up."
        refreshSlots(); activate(); advertise()
    }
    func addBot() {
        guard [.hosting, .readyHost].contains(mode), simulation.fighters.count < 4 else { return }
        let index = simulation.fighters.count
        simulation = ArenaSimulation(kinds: simulation.fighters.map(\.kind) + [botKind(slot: index)], map: selectedMap)
        botSlots.insert(index); mode = .readyHost; refreshSlots(); sendRoster(); advertise(); startIfReady()
    }
    func removeBot() {
        guard [.hosting, .readyHost].contains(mode), let index = botSlots.max() else { return }
        var kinds = simulation.fighters.map(\.kind); kinds.remove(at: index)
        simulation = ArenaSimulation(kinds: kinds, map: selectedMap)
        botSlots = Set(botSlots.filter { $0 != index }.map { $0 > index ? $0 - 1 : $0 })
        for id in members.keys where members[id]!.slot > index { members[id]!.slot -= 1 }
        mode = simulation.fighters.count > 1 ? .readyHost : .hosting
        refreshSlots(); sendRoster(); advertise()
    }
    func join(_ lobby: Lobby, spectate: Bool = false) {
        leave(); selectedMap = lobby.map; round = lobby.round; peerID = lobby.peerID; sessionID = lobby.sessionID
        mode = spectate ? .spectator : .joining; lastRemote = ProcessInfo.processInfo.systemUptime
        notice = "Connecting to \(names[lobby.peerID] ?? "host")…"; activate()
        transmit(spectate ? .spectate : .join, fighter: spectate ? nil : selected)
    }
    func rematch() {
        guard simulation.winner != nil, mode == .host || mode == .guest else { return }
        if mode == .guest { transmit(.rematch); notice = "Rematch requested"; return }
        beginRematch()
    }
    private func beginRematch() {
        guard round < 1000 else { leave(); return }
        round += 1; localReady = false; remoteReady = false; reportedRound = nil
        for id in members.keys { members[id]!.ready = false; members[id]!.input = ArenaInput() }
        simulation = ArenaSimulation(kinds: simulation.fighters.map(\.kind), map: simulation.map)
        mode = .readyHost; refreshSlots(); sendRoster(); advertise()
    }
    func readyUp() {
        guard [.hosting, .readyHost, .readyGuest].contains(mode) else { return }
        localReady.toggle()
        if isActivityHost { refreshSlots(); sendRoster(); startIfReady() }
        else { transmit(.ready, ready: localReady) }
    }
    private func startIfReady() {
        guard [.hosting, .readyHost].contains(mode), simulation.fighters.count >= 2,
              localReady, members.values.allSatisfy(\.ready) else { return }
        mode = .host; notice = ""; refreshSlots(); sendRoster(); advertise()
    }
    private func sendRoster() {
        guard isActivityHost else { return }
        let kind: ArenaPacket.Kind = mode == .host ? .state : .ready
        for id in members.keys { transmit(kind, state: simulation, target: id, ready: localReady, started: mode == .host) }
        for id in spectators.keys { transmit(kind, state: simulation, target: id, ready: localReady, started: mode == .host) }
    }
    func leave(message: String = "") {
        if isActivityHost {
            for id in members.keys { transmit(.leave, target: id) }
            for id in spectators.keys { transmit(.leave, target: id) }
            transmit(.leave, target: "")
        } else if networked { transmit(.leave) }
        latencyMilliseconds = nil; sentProbe = nil; peerProbe = nil; measuredProbe = nil
        showsMenu = false; localReady = false; remoteReady = false
        spectators = [:]; spectatorProbes = [:]; spectatorCount = 0; members = [:]; botSlots = []; playerSlots = []
        remotePlayerNames = nil; remoteParticipantIDs = nil; assignedSlot = 0; reportedRound = nil
        mode = .picker; peerID = nil; clearInput(); remoteInput = ArenaInput()
        remoteSequence = -1; sequence = 0; accumulator = 0; notice = message; paused = false
    }
    func disconnect() {
        returnToLibrary(); send = nil; lobbies = []; announcedSessions = []; reportedResultKeys = []; timer?.invalidate(); timer = nil
        closeExpanded(); scene = nil; sound.stop()
    }
    func surfaceVisibility(_ id: UUID, visible: Bool) {
        let wasVisible = visibleSurfaces.contains(id)
        if visible { visibleSurfaces.insert(id) } else { visibleSurfaces.remove(id) }
        if wasVisible && visibleSurfaces.isEmpty {
            clearInput(); sound.stop()
            if mode == .practice && !paused { paused = true; showsMenu = true }
        }
    }
    func setInput(_ input: ArenaInput) {
        guard playing, mode != .spectator, !showsMenu, !paused else { clearInput(); return }
        bufferedActions.jump = bufferedActions.jump || (input.jump && !localInput.jump)
        bufferedActions.light = bufferedActions.light || (input.light && !localInput.light)
        bufferedActions.heavy = bufferedActions.heavy || (input.heavy && !localInput.heavy)
        bufferedActions.dodge = bufferedActions.dodge || (input.dodge && !localInput.dodge)
        localInput = input
    }
    func clearInput() { localInput = ArenaInput(); bufferedActions = ArenaInput() }
    func sampledInput() -> ArenaInput {
        var input = inputWithController()
        if showsMenu { return ArenaInput() }
        input.jump = input.jump || bufferedActions.jump
        input.light = input.light || bufferedActions.light
        input.heavy = input.heavy || bufferedActions.heavy
        input.dodge = input.dodge || bufferedActions.dodge
        return input
    }
    private func inputWithController() -> ArenaInput {
        guard controlsFocused, NSApp.isActive, let pad = GCController.controllers().first?.extendedGamepad else { return localInput }
        var result = localInput
        let x = pad.leftThumbstick.xAxis.value + pad.dpad.xAxis.value
        let y = pad.leftThumbstick.yAxis.value + pad.dpad.yAxis.value
        if abs(x) > 0.2 { result.horizontal = x > 0 ? 1 : -1 }
        if abs(y) > 0.35 { result.vertical = y > 0 ? 1 : -1 }
        result.jump = result.jump || pad.buttonA.isPressed
        result.light = result.light || pad.buttonX.isPressed
        result.heavy = result.heavy || pad.buttonY.isPressed
        result.dodge = result.dodge || pad.rightShoulder.isPressed
        let menu = pad.buttonMenu.isPressed
        if menu && !controllerPausePressed { togglePause() }
        controllerPausePressed = menu
        return result
    }
    private func playImpacts() {
        guard !visibleSurfaces.isEmpty else { return }
        sound.volume = Float(gameVolume)
        if priorSoundHits.count != simulation.fighters.count { priorSoundHits = simulation.fighters.map(\.hitSerial); priorSoundStocks = simulation.fighters.map(\.stocks) }
        for i in simulation.fighters.indices {
            let f = simulation.fighters[i]
            if f.stocks < priorSoundStocks[i] { sound.play(knockout: true) }
            else if f.hitSerial > priorSoundHits[i] { sound.play(knockout: false) }
            priorSoundHits[i] = f.hitSerial; priorSoundStocks[i] = f.stocks
        }
    }
    func togglePause() {
        clearInput(); showsMenu.toggle()
        if mode == .practice { paused = showsMenu }
        if !showsMenu { inputFocusRequest &+= 1 }
    }
    func focusLost() {
        clearInput(); controlsFocused = false; controllerPausePressed = false
        if mode == .practice { paused = true; showsMenu = true }
    }
    private func advertise() {
        transmit(.lobby, fighter: selected, target: "", started: mode == .host)
    }
    private func transmit(_ kind: ArenaPacket.Kind, fighter: ArenaFighterKind? = nil,
                          input: ArenaInput? = nil, state: ArenaSimulation? = nil, target: String? = nil, ready: Bool? = nil, started: Bool? = nil) {
        sequence += 1
        let now = ProcessInfo.processInfo.systemUptime
        if networked && (sentProbe == nil || now - sentProbe! >= 1) { sentProbe = now }
        let destination = target == "" ? nil : target ?? peerID
        let rosterPacket = state != nil && isActivityHost
        let packet = ArenaPacket(kind: kind, session: sessionID, sequence: sequence,
            fighter: fighter, input: input, state: state, ready: ready, started: started,
            playerNames: rosterPacket ? playerNames.map { String($0.prefix(40)) } : nil, round: round,
            map: selectedMap, probe: sentProbe,
            echo: isActivityHost ? destination.flatMap { members[$0]?.probe ?? spectatorProbes[$0] } : peerProbe,
            slots: rosterPacket ? playerSlots : nil,
            assignedSlot: rosterPacket ? destination.flatMap { members[$0]?.slot } : nil,
            spectating: rosterPacket ? destination.map { spectators[$0] != nil } : nil,
            availableSlots: kind == .lobby ? availableSlots : nil,
            humanCount: kind == .lobby ? 1 + members.count : nil,
            botCount: kind == .lobby ? botSlots.count : nil,
            participantIDs: rosterPacket ? simulation.fighters.indices.map { slot in slot == 0 ? localParticipantID : members.first(where: { $0.value.slot == slot })?.key } : nil)
        if let data = try? JSONEncoder().encode(packet), data.count <= 8192 { send?(data, destination) }
    }
    func receive(from sender: String, data: Data) {
        guard data.count <= 8192, let packet = try? JSONDecoder().decode(ArenaPacket.self, from: data), packet.isValid else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if packet.kind == .lobby {
            let announcementKey = sender + "/" + packet.session
            let fresh = !announcedSessions.contains(announcementKey)
            lobbies.removeAll { $0.peerID == sender }
            let lobby = Lobby(peerID: sender, sessionID: packet.session, fighter: packet.fighter!, map: packet.map ?? .observatory,
                round: packet.round, started: packet.started ?? false, availableSlots: packet.availableSlots ?? 0,
                humanCount: packet.humanCount ?? 1, botCount: packet.botCount ?? 0, seen: now)
            if lobbies.count < 32 { lobbies.append(lobby); if fresh { if announcedSessions.count >= 128 { announcedSessions.removeAll() }; announcedSessions.insert(announcementKey); onLobbyDiscovered?(lobby) } }
            return
        }
        if packet.kind == .leave {
            let removed = lobbies.contains { $0.peerID == sender && $0.sessionID == packet.session }
            lobbies.removeAll { $0.peerID == sender && $0.sessionID == packet.session }
            if removed { onLobbyRemoved?(packet.session) }
        }
        guard packet.session == sessionID else { return }
        if isActivityHost { receiveAsHost(sender: sender, packet: packet, now: now); return }
        guard sender == peerID, packet.sequence > remoteSequence else { return }
        if packet.kind == .leave, packet.round >= round {
            leave(message: "The activity host left. Your room and chat are still open."); return
        }
        let advancedRound = packet.round != round
        if advancedRound {
            guard (mode == .joining && packet.round >= round) || (packet.round == round + 1 && [.ready, .state].contains(packet.kind)) else { return }
            round = packet.round; localReady = false; remoteReady = false; reportedRound = nil
        }
        remoteSequence = packet.sequence
        if let probe = packet.probe { peerProbe = probe }
        if let echo = packet.echo, echo == sentProbe, echo != measuredProbe, now >= echo, now - echo < 10 {
            let sample = Int((now - echo) * 1000)
            latencyMilliseconds = latencyMilliseconds.map { ($0 * 3 + sample) / 4 } ?? sample; measuredProbe = echo
        }
        switch packet.kind {
        case .state, .ready:
            guard [.joining, .readyGuest, .guest, .spectator].contains(mode), let state = packet.state,
                  let slots = packet.slots, let rosterNames = packet.playerNames,
                  slots.count == state.fighters.count, rosterNames.count == slots.count else { return }
            if packet.kind == .state, state.frame < simulation.frame, mode == .guest, !advancedRound { return }
            if packet.spectating == true { mode = .spectator }
            else {
                guard let slot = packet.assignedSlot, state.fighters.indices.contains(slot), !slots[slot].isBot else { return }
                assignedSlot = slot; mode = packet.started == true ? .guest : .readyGuest
            }
            remotePlayerNames = rosterNames; remoteParticipantIDs = packet.participantIDs; playerSlots = slots; botSlots = Set(slots.filter(\.isBot).map(\.index))
            selectedMap = state.map; simulation = state; remoteReady = packet.ready ?? false
            lastRemote = now; notice = mode == .spectator ? "Spectating · four fighter slots; join a live bot slot when available." : ""
            revision += 1; playImpacts(); reportResultIfNeeded()
        case .leave: leave(message: "The activity host left. Your room and chat are still open.")
        case .busy: leave(message: "This arena has no spectator space available.")
        default: break
        }
    }
    private func receiveAsHost(sender: String, packet: ArenaPacket, now: Double) {
        if packet.kind == .join {
            if members[sender] != nil {
                transmit(mode == .host ? .state : .ready, state: simulation, target: sender, ready: localReady, started: mode == .host); return
            }
            let replacement = botSlots.sorted().first { mode != .host || (simulation.winner == nil && simulation.fighters[$0].stocks > 0) }
            let canAppend = mode != .host && simulation.fighters.count < 4
            guard let slot = replacement ?? (canAppend ? simulation.fighters.count : nil) else { admitSpectator(sender, packet: packet, now: now); return }
            if slot == simulation.fighters.count {
                simulation = ArenaSimulation(kinds: simulation.fighters.map(\.kind) + [packet.fighter!], map: selectedMap)
            } else if mode != .host {
                var kinds = simulation.fighters.map(\.kind); kinds[slot] = packet.fighter!
                simulation = ArenaSimulation(kinds: kinds, map: selectedMap)
            }
            botSlots.remove(slot); spectators.removeValue(forKey: sender); spectatorProbes.removeValue(forKey: sender)
            members[sender] = Member(slot: slot, ready: mode == .host, lastSeen: now, sequence: packet.sequence, probe: packet.probe)
            spectatorCount = spectators.count
            if mode == .hosting { mode = .readyHost }
            notice = mode == .host ? "A room member took over a bot's live fighter." : "Room member joined. Ready up when everyone is here."
            refreshSlots(); sendRoster(); advertise(); startIfReady(); return
        }
        if packet.kind == .spectate { admitSpectator(sender, packet: packet, now: now); return }
        if packet.kind == .leave, spectators.removeValue(forKey: sender) != nil {
            spectatorProbes.removeValue(forKey: sender); spectatorCount = spectators.count; return
        }
        guard var member = members[sender], packet.sequence > member.sequence, packet.round == round else { return }
        member.sequence = packet.sequence; member.lastSeen = now; member.probe = packet.probe
        if let echo = packet.echo, echo == sentProbe, echo != member.measuredProbe, now >= echo, now - echo < 10 { member.latency = Int((now - echo) * 1000); member.measuredProbe = echo }
        switch packet.kind {
        case .ready where mode != .host:
            let changed = member.ready != packet.ready!
            member.ready = packet.ready!; members[sender] = member
            if changed { refreshSlots(); sendRoster(); startIfReady() }
        case .input where mode == .host: member.input = packet.input!; member.lastInput = now; members[sender] = member
        case .leave: replaceWithBot(sender)
        case .rematch where mode == .host && simulation.winner != nil: members[sender] = member; beginRematch()
        default: members[sender] = member
        }
        latencyMilliseconds = members.values.compactMap(\.latency).max()
    }
    private func admitSpectator(_ sender: String, packet: ArenaPacket, now: Double) {
        guard members[sender] == nil else { return }
        guard spectators[sender] != nil || spectators.count < 8 else { transmit(.busy, target: sender); return }
        spectators[sender] = now; spectatorProbes[sender] = packet.probe; spectatorCount = spectators.count
        transmit(mode == .host ? .state : .ready, state: simulation, target: sender, ready: localReady, started: mode == .host)
    }
    private func replaceWithBot(_ id: String) {
        guard let member = members.removeValue(forKey: id) else { return }
        botSlots.insert(member.slot)
        latencyMilliseconds = members.values.compactMap(\.latency).max()
        notice = "A disconnected player's fighter is now controlled by a bot."
        refreshSlots(); sendRoster(); advertise(); startIfReady()
    }
    func update() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = min(0.1, max(0, now - previousTime)); previousTime = now; tickCount += 1
        if now - lastAdvertise >= 1 {
            lastAdvertise = now
            let expired = lobbies.filter { now - $0.seen > 3.5 }.map(\.sessionID)
            lobbies.removeAll { now - $0.seen > 3.5 }
            for id in expired { onLobbyRemoved?(id) }
            if isActivityHost {
                for id in members.keys.filter({ now - members[$0]!.lastSeen > 5 }) { replaceWithBot(id) }
                spectators = spectators.filter { now - $0.value < 5 }; spectatorCount = spectators.count
                spectatorProbes = spectatorProbes.filter { spectators[$0.key] != nil }
                advertise(); if mode != .host { sendRoster() }
            }
            if mode == .readyGuest { transmit(.ready, ready: localReady) }
            if mode == .spectator { transmit(.spectate) }
            if mode == .joining { transmit(.join, fighter: selected) }
        }
        if [.joining, .guest, .readyGuest, .spectator].contains(mode) && now - lastRemote > 5 {
            leave(message: "Activity connection lost. Your room and chat are still open."); return
        }
        let frameInput = sampledInput()
        if mode == .guest {
            if tickCount % 2 == 0 { transmit(.input, input: frameInput); bufferedActions = ArenaInput() }
            return
        }
        guard mode == .host || (mode == .practice && !paused) else { accumulator = 0; return }
        accumulator += elapsed; var steps = 0
        while accumulator >= ArenaSimulation.step && steps < 6 {
            let inputs = simulation.fighters.indices.map { slot -> ArenaInput in
                if slot == 0 { return frameInput }
                if botSlots.contains(slot) || mode == .practice { return simulation.botInput(for: slot, difficulty: botDifficulty) }
                guard let member = members.values.first(where: { $0.slot == slot }), now - member.lastInput <= 0.25 else { return ArenaInput() }
                return member.input
            }
            simulation.tick(inputs); accumulator -= ArenaSimulation.step; steps += 1
        }
        if steps > 0 { bufferedActions = ArenaInput() }
        let finished = reportResultIfNeeded()
        if finished && mode == .host { sendRoster() }
        if tickCount % 3 == 0 { revision += 1; playImpacts(); if mode == .host { sendRoster() } }
    }
    @discardableResult
    private func reportResultIfNeeded() -> Bool {
        guard [.host, .guest, .spectator].contains(mode), let winner = simulation.winner, reportedRound != round else { return false }
        let resultKey = sessionID + "/" + String(round)
        guard !reportedResultKeys.contains(resultKey) else { return false }
        let ids: [String?]
        if mode == .host {
            ids = simulation.fighters.indices.map { slot in slot == 0 ? localParticipantID : members.first(where: { $0.value.slot == slot })?.key }
        } else {
            guard let remoteParticipantIDs, remoteParticipantIDs.count == simulation.fighters.count else { return false }
            ids = remoteParticipantIDs
        }
        reportedRound = round
        if reportedResultKeys.count >= 2048 { reportedResultKeys.removeAll() }
        reportedResultKeys.insert(resultKey)
        onMatchFinished?(ArenaMatchResult(sessionID: sessionID, round: round, participantIDs: ids, playerNames: playerNames, winner: winner, botSlots: botSlots))
        return true
    }
    func openExpanded() {
        guard window == nil else {
            window?.deminiaturize(nil); window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true); return
        }
        clearInput(); expanded = true
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Rift Arena · ALO"
        w.collectionBehavior = [.fullScreenPrimary]
        w.minSize = NSSize(width: 760, height: 520)
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: ArenaPanel(session: self, detached: true))
        let delegate = ArenaWindowDelegate { [weak self] in
            self?.window = nil; self?.expanded = false; self?.clearInput(); self?.windowDelegate = nil
        }
        windowDelegate = delegate; w.delegate = delegate; window = w
        w.center(); w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func fullscreen() { window?.toggleFullScreen(nil) }
    func closeExpanded() { window?.close() }
}

@MainActor
private final class ArenaWindowDelegate: NSObject, NSWindowDelegate {
    let closed: () -> Void
    init(closed: @escaping () -> Void) { self.closed = closed }
    func windowWillClose(_ notification: Notification) { closed() }
}

@MainActor
enum ArenaStandalone {
    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let session = ArenaSession()
        session.openExpanded()
        app.run()
        session.disconnect()
    }
}
