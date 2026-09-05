import AppKit
import SwiftUI
import ALOCore
import GameController

@MainActor
final class ArenaSession: ObservableObject {
    enum Mode { case picker, practice, hosting, joining, readyHost, readyGuest, host, guest, spectator }
    struct Lobby: Identifiable {
        var id: String { peerID }
        let peerID: String
        let sessionID: String
        let fighter: ArenaFighterKind
        let round: Int
        let started: Bool
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
    private(set) var fighterArtwork: NSImage?
    private var loadTask: Task<Void, Never>?
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
    private let sound = ArenaSoundPlayer()
    private var priorSoundHits = [0, 0]
    private var priorSoundStocks = [3, 3]
    private var controllerPausePressed = false
    var simulation = ArenaSimulation()
    var send: ((Data, String?) -> Void)?
    var names: [String: String] = [:]
    var localName = "You"
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
    var localIndex: Int { mode == .guest ? 1 : 0 }
    var playing: Bool { [.practice, .host, .guest, .spectator].contains(mode) }
    var networked: Bool { [.host, .guest, .hosting, .joining, .readyHost, .readyGuest, .spectator].contains(mode) }
    var playerNames: [String] {
        if mode == .spectator, let remotePlayerNames { return remotePlayerNames }
        return mode == .guest || mode == .spectator || mode == .readyGuest ? [names[peerID ?? ""] ?? "Host", localName]
            : [localName, mode == .practice ? "Training bot" : names[peerID ?? ""] ?? "Challenger"]
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
            fighterArtwork = pack.content.fighterImageData.flatMap(NSImage.init(data:))
            if pack.content.backgroundImageBase64 != nil && gameBackground == nil {
                gameLoadError = "The artwork could not be loaded. Remove the pack and download it again."
            }
            loadingGame = false; configureTimer()
        }
    }
    func returnToLibrary() {
        leave(); loadTask?.cancel(); selectedGameID = nil; loadingGame = false
        gameBackground = nil; fighterArtwork = nil; gameLoadError = nil; controlsFocused = false; configureTimer()
    }
    func closeMenu() { showsMenu = false; paused = false; clearInput() }
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
    func practice() {
        leave(); simulation = ArenaSimulation(first: selected, second: selected == .nova ? .atlas : .nova)
        mode = .practice; paused = false; activate()
    }
    func host() {
        leave(); round = 0; sessionID = UUID().uuidString; mode = .hosting
        notice = "Waiting for a room member to join…"; activate(); advertise()
    }
    func join(_ lobby: Lobby, spectate: Bool = false) {
        leave(); round = lobby.round; peerID = lobby.peerID; sessionID = lobby.sessionID
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
        round += 1; localReady = false; remoteReady = false
        simulation = ArenaSimulation(first: simulation.fighters[0].kind, second: simulation.fighters[1].kind)
        mode = .readyHost
        transmit(.ready, ready: false)
        for spectator in spectators.keys { transmit(.ready, target: spectator, ready: false) }
    }
    func readyUp() {
        localReady.toggle(); transmit(.ready, ready: localReady); startIfReady()
    }
    private func startIfReady() {
        guard mode == .readyHost, localReady, remoteReady else { return }
        mode = .host; notice = ""; transmit(.state, state: simulation)
    }
    func leave(message: String = "") {
        if networked {
            transmit(.leave)
            for spectator in spectators.keys { transmit(.leave, target: spectator) }
        }
        showsMenu = false
        localReady = false; remoteReady = false; spectators = [:]; spectatorCount = 0
        mode = .picker; peerID = nil; clearInput(); remoteInput = ArenaInput()
        remoteSequence = -1; sequence = 0; accumulator = 0; notice = message; paused = false
    }
    func disconnect() {
        returnToLibrary(); send = nil; lobbies = []; timer?.invalidate(); timer = nil
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
        bufferedActions.jump = bufferedActions.jump || (input.jump && !localInput.jump)
        bufferedActions.light = bufferedActions.light || (input.light && !localInput.light)
        bufferedActions.heavy = bufferedActions.heavy || (input.heavy && !localInput.heavy)
        bufferedActions.dodge = bufferedActions.dodge || (input.dodge && !localInput.dodge)
        localInput = input
    }
    func clearInput() { localInput = ArenaInput(); bufferedActions = ArenaInput() }
    private func sampledInput() -> ArenaInput {
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
        for i in 0..<2 {
            let f = simulation.fighters[i]
            if f.stocks < priorSoundStocks[i] { sound.play(knockout: true) }
            else if f.hitSerial > priorSoundHits[i] { sound.play(knockout: false) }
            priorSoundHits[i] = f.hitSerial; priorSoundStocks[i] = f.stocks
        }
    }
    func togglePause() {
        clearInput(); showsMenu.toggle()
        if mode == .practice { paused = showsMenu }
    }
    func focusLost() {
        clearInput()
        if mode == .practice { paused = true; showsMenu = true }
    }
    private func advertise() {
        transmit(.lobby, fighter: selected, target: "", started: mode == .host)
    }
    private func transmit(_ kind: ArenaPacket.Kind, fighter: ArenaFighterKind? = nil,
                          input: ArenaInput? = nil, state: ArenaSimulation? = nil, target: String? = nil, ready: Bool? = nil, started: Bool? = nil) {
        sequence += 1
        let packet = ArenaPacket(kind: kind, session: sessionID, sequence: sequence,
                                 fighter: fighter, input: input, state: state, ready: ready, started: started, playerNames: kind == .state ? playerNames.map { String($0.prefix(40)) } : nil, round: round)
        if let data = try? JSONEncoder().encode(packet) { send?(data, target == "" ? nil : target ?? peerID) }
    }
    func receive(from sender: String, data: Data) {
        guard data.count <= 8192, let packet = try? JSONDecoder().decode(ArenaPacket.self, from: data),
              packet.isValid else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if packet.kind == .lobby {
            lobbies.removeAll { $0.peerID == sender }
            if lobbies.count < 32 {
                lobbies.append(Lobby(peerID: sender, sessionID: packet.session, fighter: packet.fighter!, round: packet.round, started: packet.started ?? false, seen: now))
            }
            if timer == nil { activate() }; return
        }
        if packet.kind == .leave { lobbies.removeAll { $0.peerID == sender && $0.sessionID == packet.session } }
        guard packet.session == sessionID else { return }
        if packet.kind == .spectate && (mode == .host || mode == .readyHost) {
            guard spectators[sender] != nil || spectators.count < 8 else { return }
            spectators[sender] = now; spectatorCount = spectators.count
            if mode == .host { transmit(.state, state: simulation, target: sender) }
            else { transmit(.ready, target: sender, ready: localReady) }
            return
        }
        if packet.kind == .leave && spectators.removeValue(forKey: sender) != nil {
            spectatorCount = spectators.count; return
        }
        if packet.kind == .join && mode == .hosting {
            peerID = sender; remoteSequence = packet.sequence; lastRemote = now
            simulation = ArenaSimulation(first: selected, second: packet.fighter!)
            mode = .readyHost; notice = "Challenger joined. Ready up to begin."
            transmit(.ready, ready: localReady); return
        }
        if packet.kind == .join && sender != peerID && [.readyHost, .host].contains(mode) {
            transmit(.busy, target: sender); return
        }
        guard sender == peerID, packet.sequence > remoteSequence else { return }
        if packet.kind == .ready && packet.round == round + 1 && (mode == .guest || mode == .spectator) {
            round = packet.round; localReady = false; remoteReady = false
            simulation = ArenaSimulation(first: simulation.fighters[0].kind, second: simulation.fighters[1].kind)
            if mode == .guest { mode = .readyGuest }
            else { notice = "Waiting for players to ready up…" }
        }
        guard packet.round == round else { return }
        remoteSequence = packet.sequence
        switch packet.kind {
        case .state where mode == .joining || mode == .readyGuest || mode == .guest || mode == .spectator:
            guard let state = packet.state, (mode == .joining || mode == .readyGuest || mode == .spectator) || state.frame >= simulation.frame else { return }
            remotePlayerNames = packet.playerNames
            simulation = state; if mode != .spectator && mode != .guest { mode = .guest }; lastRemote = now; notice = ""; revision += 1; playImpacts()
        case .ready where mode == .joining || mode == .readyHost || mode == .readyGuest || mode == .spectator:
            if mode == .joining { mode = .readyGuest }
            remoteReady = packet.ready!; lastRemote = now; startIfReady()
        case .rematch where mode == .host && simulation.winner != nil:
            lastRemote = now; beginRematch()
        case .input where mode == .host:
            remoteInput = packet.input!; lastInput = now; lastRemote = now
        case .leave:
            leave(message: "The other player left. Start another match whenever you’re ready.")
        case .busy:
            leave(message: "That arena is no longer available.")
        default: break
        }
    }
    private func update() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = min(0.1, max(0, now - previousTime)); previousTime = now
        tickCount += 1
        if now - lastAdvertise >= 1 {
            lastAdvertise = now
            lobbies.removeAll { now - $0.seen > 3.5 }
            if mode == .hosting || mode == .host { advertise() }
            if mode == .readyHost || mode == .readyGuest {
                transmit(.ready, ready: localReady)
                if mode == .readyHost {
                    for spectator in spectators.keys { transmit(.ready, target: spectator, ready: localReady) }
                }
            }
            if mode == .spectator { transmit(.spectate) }
            spectators = spectators.filter { now - $0.value < 5 }
            spectatorCount = spectators.count
            if mode == .joining { transmit(.join, fighter: selected) }
        }
        if [.joining, .host, .guest, .readyHost, .readyGuest, .spectator].contains(mode) && now - lastRemote > 5 {
            leave(message: "Connection lost. Your room and chat are still open."); return
        }
        let frameInput = sampledInput()
        if mode == .guest {
            // Send heartbeat inputs even after results so the host doesn't time out.
            if tickCount % 2 == 0 { transmit(.input, input: frameInput); bufferedActions = ArenaInput() }
            return
        }
        guard mode == .host || (mode == .practice && !paused) else { accumulator = 0; return }
        if mode == .host && now - lastInput > 0.25 { remoteInput = ArenaInput() }
        accumulator += elapsed
        var steps = 0
        while accumulator >= ArenaSimulation.step && steps < 6 {
            simulation.tick([frameInput, mode == .practice ? simulation.botInput() : remoteInput])
            accumulator -= ArenaSimulation.step; steps += 1
        }
        if steps > 0 { bufferedActions = ArenaInput() }
        if tickCount % 3 == 0 {
            revision += 1; playImpacts()
            if mode == .host {
                transmit(.state, state: simulation)
                for spectator in spectators.keys { transmit(.state, state: simulation, target: spectator) }
            }
        }
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
