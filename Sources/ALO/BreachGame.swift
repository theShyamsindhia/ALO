import AppKit
import SwiftUI
import SceneKit
import ALOCore
import Combine

enum BreachControl: String, CaseIterable {
    case forward = "Forward", backward = "Backward", left = "Left", right = "Right", reload = "Reload", interact = "Interact"
    var defaultKey: UInt16 { switch self { case .forward: 13; case .backward: 1; case .left: 0; case .right: 2; case .reload: 15; case .interact: 14 } }
    var defaultLabel: String { switch self { case .forward: "W"; case .backward: "S"; case .left: "A"; case .right: "D"; case .reload: "R"; case .interact: "E" } }
}

@MainActor
final class BreachController: ObservableObject {
    @Published var game = BreachMatch()
    let room: BreachRoomSession
    private var observation: AnyCancellable?
    @Published var buying = false
    @Published var started = false
    @Published var captured = false
    @Published var scoreboard = false
    @Published var sensitivity = UserDefaults.standard.object(forKey: "breach.sensitivity") as? Double ?? 0.002
    @Published var fov = UserDefaults.standard.object(forKey: "breach.fov") as? Double ?? 80
    @Published var shadows = UserDefaults.standard.object(forKey: "breach.shadows") as? Bool ?? true
    @Published var hit = false
    @Published var volume = UserDefaults.standard.object(forKey: "breach.volume") as? Double ?? 0.5
    @Published var controlKeys: [BreachControl: UInt16] = [:]
    @Published var controlLabels: [BreachControl: String] = [:]
    @Published var controlFeedback = "Click a binding, then press a key. Escape cancels."
    private let audio = BreachAudio()
    let world = BreachScene()
    var yaw = 0.0, pitch = 0.0
    var keys = Set<UInt16>()
    weak var inputView: BreachInputView?
    var trigger = false
    private var timer: Timer?
    private var lastTime = ProcessInfo.processInfo.systemUptime
    private var hitUntil = 0.0
    init(room: BreachRoomSession) {
        self.room = room
        world.setGraphics(shadows: shadows, fov: fov)
        observation = room.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        room.panelAppeared()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }

        var used = Set<UInt16>()
        for control in BreachControl.allCases {
            let saved = UserDefaults.standard.object(forKey: "breach.key.\(control.rawValue)") as? Int
            let code = saved.flatMap(UInt16.init(exactly:)) ?? control.defaultKey
            if Self.reservedKeys.contains(code) || used.contains(code) {
                resetControls(); return
            }
            controlKeys[control] = code; used.insert(code)
            controlLabels[control] = UserDefaults.standard.string(forKey: "breach.label.\(control.rawValue)") ?? control.defaultLabel
        }
    }
    private static let reservedKeys: Set<UInt16> = [11, 36, 48, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
    func key(_ control: BreachControl) -> UInt16 { controlKeys[control] ?? control.defaultKey }
    func label(_ control: BreachControl) -> String { controlLabels[control] ?? control.defaultLabel }
    func bind(_ control: BreachControl, event: NSEvent) -> Bool {
        guard !Self.reservedKeys.contains(event.keyCode),
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
            controlFeedback = "That key is reserved. Use a single letter, number, arrow or punctuation key."; return false
        }
        if let duplicate = BreachControl.allCases.first(where: { $0 != control && key($0) == event.keyCode }) {
            controlFeedback = "Already used for \(duplicate.rawValue.lowercased()). Choose another key."; return false
        }
        let arrows: [UInt16: String] = [123: "←", 124: "→", 125: "↓", 126: "↑", 49: "Space", 51: "Delete", 117: "Forward delete"]
        guard let name = arrows[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased(), !name.isEmpty,
              arrows[event.keyCode] != nil || name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) else {
            controlFeedback = "That key cannot be assigned. Choose a letter, number or arrow key."; return false
        }
        controlKeys[control] = event.keyCode; controlLabels[control] = name
        UserDefaults.standard.set(Int(event.keyCode), forKey: "breach.key.\(control.rawValue)")
        UserDefaults.standard.set(name, forKey: "breach.label.\(control.rawValue)")
        keys.removeAll(); controlFeedback = "\(control.rawValue) assigned to \(name)."
        return true
    }
    func resetControls() {
        controlKeys = Dictionary(uniqueKeysWithValues: BreachControl.allCases.map { ($0, $0.defaultKey) })
        controlLabels = Dictionary(uniqueKeysWithValues: BreachControl.allCases.map { ($0, $0.defaultLabel) })
        for control in BreachControl.allCases {
            UserDefaults.standard.removeObject(forKey: "breach.key.\(control.rawValue)")
            UserDefaults.standard.removeObject(forKey: "breach.label.\(control.rawValue)")
        }
        keys.removeAll(); controlFeedback = "Default controls restored."
    }
    var localIndex: Int { min(3,max(0,room.localIndex)) }
    var player: BreachPlayer { game.players[localIndex] }
    var online: Bool { room.mode != .practice && room.mode != .picker }
    func start() { release(); room.practice(); room.showsMenu = true }
    func host() { release(); room.host() }
    func capture() {
        guard room.started, game.phase != .matchOver, !captured else { return }
        inputView?.window?.makeFirstResponder(inputView)
        room.showsMenu = false; buying = false
        captured = true; keys.removeAll(); trigger = false
        CGAssociateMouseAndMouseCursorPosition(0); NSCursor.hide()
    }
    func release() {
        if captured { CGAssociateMouseAndMouseCursorPosition(1); NSCursor.unhide() }
        captured = false; buying = false; keys.removeAll(); trigger = false; scoreboard = false
        room.clearInput(); room.showsMenu = true
    }
    func stop() { release(); buying = false; room.leave() }
    func close() { stop(); room.panelDisappeared(); timer?.invalidate(); timer = nil; observation = nil }
    func look(dx: Double, dy: Double) {
        guard captured else { return }
        yaw -= dx*sensitivity; yaw = yaw.truncatingRemainder(dividingBy: 2 * .pi)
        pitch = min(1.35,max(-1.35,pitch-dy*sensitivity))
    }
    private func input() -> BreachInput {
        var value = BreachInput()
        value.yaw = yaw; value.pitch = pitch
        if captured && player.alive && room.mode != .spectator && !room.waitingForRound {
            value.forward = (keys.contains(key(.forward)) ? 1 : 0) - (keys.contains(key(.backward)) ? 1 : 0)
            value.strafe = (keys.contains(key(.right)) ? 1 : 0) - (keys.contains(key(.left)) ? 1 : 0)
            value.walk = keys.contains(56); value.fire = trigger
            value.interact = keys.contains(key(.interact))
        }
        return value
    }
    func reload() { var value = input(); value.reload = true; room.setInput(value) }
    func shoot() { guard captured else { return }; var value = input(); value.fire = true; room.setInput(value) }
    func toggleBuy() {
        guard game.phase == .buy && room.started && room.mode != .spectator else { return }
        if buying { buying = false; capture() } else { release(); buying = true; room.showsMenu = false }
    }
    func purchase(_ weapon: BreachWeapon? = nil, armor: Bool = false) {
        var value = BreachInput(); value.buy = weapon; value.buyArmor = armor
        room.setInput(value)
    }
    func applySettings() {
        UserDefaults.standard.set(volume, forKey: "breach.volume")
        UserDefaults.standard.set(sensitivity, forKey: "breach.sensitivity")
        UserDefaults.standard.set(fov, forKey: "breach.fov")
        UserDefaults.standard.set(shadows, forKey: "breach.shadows")
        world.setGraphics(shadows: shadows, fov: fov)
    }
    private var previousRound = 0
    private func step() {
        let now = ProcessInfo.processInfo.systemUptime
        let previous = game.players[localIndex]
        game = room.simulation; started = room.started
        if previousRound != game.round {
            previousRound = game.round; yaw = game.players[localIndex].yaw; pitch = 0
            keys.removeAll(); trigger = false
        }
        let current = player
        let fired = current.weapon == previous.weapon && current.ammo < previous.ammo
        if fired { audio.play("shot", volume: Float(volume)) }
        if current.health < previous.health { audio.play("hurt", volume: Float(volume)) }
        if current.reloadRemaining > previous.reloadRemaining + 0.2 { audio.play("reload", volume: Float(volume)) }
        if current.kills > previous.kills { hitUntil = now + 0.2; audio.play("hit", volume: Float(volume)) }
        hit = now < hitUntil
        if game.phase != .buy && buying { buying = false; room.showsMenu = true }
        if (game.phase == .matchOver || !started) && captured { release() }
        if captured { room.setInput(input()) }
        let positions = game.players.indices.map { index -> BreachPoint in
            let motion = room.presentationPosition(for: index, at: now)
            return BreachPoint(motion.x, motion.y)
        }
        world.update(match: game, localIndex: localIndex, yaw: yaw, pitch: pitch, firing: fired, positions: positions)
    }

}

@MainActor
final class BreachInputView: SCNView {
    weak var controller: BreachController?
    private var tracking: NSTrackingArea?
    override var acceptsFirstResponder: Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow,.mouseMoved,.inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if controller?.captured == true { controller?.trigger = true; controller?.shoot() } else { controller?.capture() }
    }
    override func mouseUp(with event: NSEvent) { controller?.trigger = false }
    override func mouseMoved(with event: NSEvent) { controller?.look(dx: event.deltaX, dy: event.deltaY) }
    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func keyDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.command) else { super.keyDown(with: event); return }
        if event.keyCode == 53 { controller?.release(); return }
        guard controller?.captured == true else { return }
        if event.keyCode == 48 { controller?.scoreboard = true }
        else if event.keyCode == 11 { controller?.toggleBuy() }
        else if event.keyCode == controller?.key(.reload) { controller?.reload() }
        else { controller?.keys.insert(event.keyCode) }
    }
    override func keyUp(with event: NSEvent) {
        controller?.keys.remove(event.keyCode)
        if event.keyCode == 48 { controller?.scoreboard = false }
    }
    override func flagsChanged(with event: NSEvent) {
        if event.modifierFlags.contains(.shift) { controller?.keys.insert(56) }
        else { controller?.keys.remove(56) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" {
            window?.performClose(nil); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
struct BreachSurface: NSViewRepresentable {
    let controller: BreachController
    func makeNSView(context: Context) -> BreachInputView {
        let view = BreachInputView()
        controller.inputView = view
        view.controller = controller; view.scene = controller.world.scene; view.pointOfView = controller.world.cameraNode
        view.antialiasingMode = .multisampling4X; view.preferredFramesPerSecond = 60; view.isPlaying = true
        view.backgroundColor = .black; view.autoenablesDefaultLighting = false
        return view
    }
    func updateNSView(_ view: BreachInputView, context: Context) {}
}

struct BreachGameView: View {
    @ObservedObject var controller: BreachController
    private var room: BreachRoomSession { controller.room }
    private var game: BreachMatch { controller.game }
    private var player: BreachPlayer { controller.player }
    private let gold = Color(red: 0.96, green: 0.72, blue: 0.34)
    var body: some View {
        ZStack {
            BreachSurface(controller: controller)
            if room.started {
                hud.allowsHitTesting(false)
                if controller.scoreboard { stats.allowsHitTesting(false) }
                if game.phase == .matchOver { result }
                else if controller.buying { buyPanel }
                else if !controller.captured { pause }
            } else { briefing }
        }
        .foregroundStyle(.white).tint(gold).preferredColorScheme(.dark)
        .frame(minWidth: 900, minHeight: 600)
    }
    private var hud: some View {
        VStack {
            HStack {
                Text("BREACH / FOUNDRY").tracking(3).font(.system(size: 12,weight: .bold))
                Spacer()
                Text("ATTACK \(game.attackersScore)  :  \(game.defendersScore) DEFEND").font(.headline)
                Spacer(); Text("ROUND \(game.round) · FIRST TO 5").font(.caption)
            }.padding(20).background(.black.opacity(0.55))
            VStack(spacing: 5) {
                Text("\(game.phase.rawValue.uppercased())  ·  \(Int(max(0,game.seconds)))s").font(.headline.monospacedDigit())
                Text(objective).font(.caption)
                if game.plantProgress > 0 { ProgressView(value: game.plantProgress, total: 3).frame(width: 200) }
                if game.defuseProgress > 0 { ProgressView(value: game.defuseProgress, total: 5).frame(width: 200) }
            }.padding(10).background(.black.opacity(0.5),in: RoundedRectangle(cornerRadius: 10))
            Spacer()
            Image(systemName: controller.hit ? "xmark" : "plus").font(.system(size: 18,weight: .light)).foregroundStyle(controller.hit ? gold : .white)
            Spacer()
            if !player.alive { Text("ELIMINATED · Next round respawn").font(.headline).padding(10).background(.black.opacity(0.6)) }
            if !room.notice.isEmpty { Text(room.notice).font(.caption).padding(6).background(.black.opacity(0.65)) }
            HStack(alignment: .bottom) {
                VStack(alignment: .leading) {
                    Text("\(player.team.rawValue.uppercased()) · $\(player.money)").font(.caption).foregroundStyle(gold)
                    Text("\(player.health) HP  /  \(player.armor) ARMOR").font(.title3.bold())
                }
                Spacer()
                Text("\(controller.label(.reload)) Reload · \(controller.label(.interact)) Hold to interact · B Buy · Tab Stats · Esc Menu").font(.caption2)
                Spacer()
                VStack(alignment: .trailing) {
                    Text(player.reloadRemaining > 0 ? "RELOADING…" : player.weapon.rawValue).font(.caption)
                    Text("\(player.ammo) / \(player.reserve)").font(.system(size: 28,weight: .bold,design: .monospaced))
                }
            }.padding(22).background(.black.opacity(0.65))
        }
    }
    private var objective: String {
        if room.waitingForRound { return "Seat reserved · Bot plays until the next round" }
        if room.mode == .spectator { return "Spectating · Join an open seat from the lobby for the next match" }
        if game.phase == .roundOver { return game.notice }
        if game.phase == .buy { return "Prepare at spawn · B opens the buy menu" }
        if game.phase == .planted { return player.team == .defenders ? "Bomb planted · Hold \(controller.label(.interact)) near the bomb to defuse" : "Bomb planted · Protect it until detonation" }
        if player.team == .defenders { return "Defend sites A and B. Stop the attackers." }
        return game.bombCarrier == controller.localIndex ? "You carry the bomb · Hold \(controller.label(.interact)) at A or B to plant" : "Escort the carrier · Recover the dropped bomb by walking over it"
    }
    private var briefing: some View {
        HStack {
            ScrollView {
                VStack(alignment: .leading,spacing: 18) {
                    Text("ALO / 2v2 TACTICAL FPS").font(.caption.bold()).tracking(3).foregroundStyle(gold)
                    Text("BREACH").font(.system(size: 58,weight: .black,design: .rounded)).tracking(4)
                    Text("FOUNDRY / DEMOLITION").font(.headline).tracking(2)
                    Text("Attackers plant at A or B. Defenders defuse or hold the sites. Buy your equipment between rounds. First team to five wins.").foregroundStyle(.secondary)
                    if room.mode == .picker {
                        Button("Practice with bots") { controller.start() }.buttonStyle(.borderedProminent)
                        Button("Host channel match") { controller.host() }.buttonStyle(.bordered).disabled(!room.roomConnected)
                        Text(room.roomConnected ? "Channel members can join. Bots fill open seats." : "Open Breach from an ALO channel to host or join friends.").font(.caption).foregroundStyle(.secondary)
                        ForEach(room.lobbies) { lobby in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(room.names[lobby.peerID] ?? "Channel match").font(.headline)
                                    Text(lobby.started ? "In progress · \(lobby.availableSlots) open seats" : "Lobby · \(lobby.availableSlots) open seats").font(.caption)
                                }
                                Spacer()
                                Button("Join") { room.join(lobby) }.disabled(lobby.availableSlots == 0)
                                Button("Watch") { room.join(lobby,spectate: true) }
                            }
                        }
                    } else {
                        Text(room.mode == .joining ? "CONNECTING…" : "ROOM LOBBY").font(.headline)
                        ForEach(room.slots, id: \.index) { slot in
                            HStack {
                                Circle().fill(slot.index < 2 ? gold : .cyan).frame(width: 8,height: 8)
                                Text(slot.name); Spacer()
                                Text(slot.isBot ? "Bot" : slot.ready ? "Ready" : "Not ready").foregroundStyle(.secondary)
                            }
                        }
                        if room.mode != .joining && room.mode != .spectator {
                            Button(room.localReady ? "Unready" : "Ready to start") { room.readyUp() }.buttonStyle(.borderedProminent)
                        }
                        Button("Leave match") { controller.stop() }.buttonStyle(.bordered)
                    }
                    if !room.notice.isEmpty { Text(room.notice).font(.caption).foregroundStyle(gold) }
                    Divider()
                    DisclosureGroup("Game settings") { settings.padding(.top,8) }
                    Text("WASD move · Mouse aim/fire · R reload · E interact\nB buy · Hold Tab for stats · Escape releases the mouse\nCmd W closes the window. Online matches continue when unfocused.").font(.caption).foregroundStyle(.secondary)
                }.padding(28)
            }.frame(width: 490).background(.black.opacity(0.88))
            Spacer()
        }
    }
    private var settings: some View {
        VStack(alignment: .leading,spacing: 12) {
            HStack { Text("Sensitivity"); Slider(value: $controller.sensitivity,in: 0.0005...0.006) }
            HStack { Text("Field of view"); Slider(value: $controller.fov,in: 60...105); Text("\(Int(controller.fov))°") }
            HStack { Text("Effects volume"); Slider(value: $controller.volume,in: 0...1) }
            Toggle("Dynamic shadows",isOn: $controller.shadows)
            DisclosureGroup("Controls") {
                ForEach(BreachControl.allCases,id: \.self) { control in
                    HStack {
                        Text(control.rawValue); Spacer()
                        BreachKeyRecorder(label: controller.label(control)) { controller.bind(control,event: $0) }
                            .frame(width: 110,height: 25).accessibilityLabel("Assign \(control.rawValue.lowercased()) key")
                    }
                }
                Text(controller.controlFeedback).font(.caption2).foregroundStyle(.secondary)
                Button("Reset controls") { controller.resetControls() }
            }
        }.font(.system(size: 12))
        .onChange(of: controller.sensitivity) { _,_ in controller.applySettings() }
        .onChange(of: controller.fov) { _,_ in controller.applySettings() }
        .onChange(of: controller.volume) { _,_ in controller.applySettings() }
        .onChange(of: controller.shadows) { _,_ in controller.applySettings() }
    }
    private var pause: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text(controller.online ? "MOUSE RELEASED" : "MATCH PAUSED").font(.title2.bold())
                Text(controller.online ? "The channel match continues while this menu is open." : "Resume when you are ready.").font(.caption).foregroundStyle(.secondary)
                Button("Resume & capture mouse") { controller.capture() }.buttonStyle(.borderedProminent)
                if game.phase == .buy && room.mode != .spectator { Button("Buy equipment") { controller.toggleBuy() }.buttonStyle(.bordered) }
                settings
                Button("Leave match") { controller.stop() }.buttonStyle(.bordered)
            }.padding(24)
        }.frame(width: 440,height: 490).background(.black.opacity(0.92),in: RoundedRectangle(cornerRadius: 16))
    }
    private var buyPanel: some View {
        VStack(alignment: .leading,spacing: 18) {
            HStack { Text("BUY EQUIPMENT").font(.title2.bold()); Spacer(); Text("$\(player.money)").foregroundStyle(gold) }
            Text("\(Int(max(0,game.seconds))) seconds · Purchases are checked by the match host.").font(.caption).foregroundStyle(.secondary)
            ForEach(BreachWeapon.allCases,id: \.self) { weapon in
                HStack {
                    VStack(alignment: .leading) { Text(weapon.rawValue).font(.headline); Text("\(weapon.magazine)-round magazine").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Buy · $\(BreachMatch.price(weapon))") { controller.purchase(weapon) }.disabled(player.money < BreachMatch.price(weapon))
                }
            }
            HStack { Text("Armor"); Spacer(); Button("Buy · $650") { controller.purchase(armor: true) }.disabled(player.money < 650 || player.armor >= 100) }
            Text("Purchases work at your spawn during the buy phase. A new weapon includes ammunition.").font(.caption).foregroundStyle(.secondary)
            Button("Return to game") { controller.toggleBuy() }.buttonStyle(.borderedProminent).keyboardShortcut("b", modifiers: [])
        }.padding(28).frame(width: 460).background(.black.opacity(0.94),in: RoundedRectangle(cornerRadius: 16))
    }
    private var stats: some View {
        VStack(spacing: 16) {
            Text("FOUNDRY / DEMOLITION").font(.title2.bold())
            HStack { Text("Operator").frame(maxWidth: .infinity,alignment: .leading); Text("K / D").frame(width: 60); Text("Cash").frame(width: 70); Text("HP").frame(width: 35) }.foregroundStyle(.secondary)
            ForEach(game.players) { p in
                HStack {
                    Circle().fill(p.team == .attackers ? gold : .cyan).frame(width: 8,height: 8)
                    Text(room.slots.first(where: { $0.index == p.id })?.name ?? "Player \(p.id + 1)").frame(maxWidth: .infinity,alignment: .leading)
                    Text("\(p.kills) / \(p.deaths)").frame(width: 60)
                    Text("$\(p.money)").frame(width: 70)
                    Text(p.alive ? "\(p.health)" : "—").frame(width: 35)
                }
            }
            Text("Attackers \(game.attackersScore) – \(game.defendersScore) Defenders").font(.headline)
        }.padding(28).frame(width: 560).background(.black.opacity(0.9),in: RoundedRectangle(cornerRadius: 16))
    }
    private var result: some View {
        VStack(spacing: 18) {
            Text("\(game.winner?.rawValue.uppercased() ?? "MATCH") WIN").font(.largeTitle.bold())
            Text("\(game.attackersScore) : \(game.defendersScore)").font(.system(size: 48,weight: .bold))
            Text("\(player.kills) kills · \(player.deaths) deaths").foregroundStyle(.secondary)
            if room.mode != .spectator { Button("Rematch") { room.rematch() }.buttonStyle(.borderedProminent) }
            Button("Leave match") { controller.stop() }.buttonStyle(.bordered)
        }.padding(36).background(.black.opacity(0.94),in: RoundedRectangle(cornerRadius: 18))
    }
}



@MainActor
final class BreachWindowController: NSObject, NSWindowDelegate {
    static let shared = BreachWindowController()
    private var window: NSWindow?
    private var controller: BreachController?
    func show(session: BreachRoomSession? = nil) {
        if let window {
            if let session, controller?.room !== session { window.performClose(nil) }
            else { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        }
        let game = BreachController(room: session ?? BreachRoomSession())
        let window = BreachWindow(contentRect: NSRect(x: 0,y: 0,width: 1100,height: 720),
                              styleMask: [.titled,.closable,.miniaturizable,.resizable],backing: .buffered,defer: false)
        window.title = "Breach · ALO"; window.delegate = self; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: BreachGameView(controller: game))
        window.minSize = NSSize(width: 900,height: 625); window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.fullScreenPrimary]
        self.window = window; controller = game; window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowDidResignKey(_ notification: Notification) { controller?.release() }
    func windowWillClose(_ notification: Notification) { controller?.close(); controller = nil; window = nil }
}

@MainActor
final class BreachWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" {
            performClose(nil); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
enum BreachStandalone {
    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = BreachStandaloneDelegate()
        app.delegate = delegate
        BreachWindowController.shared.show()
        withExtendedLifetime(delegate) { app.run() }
    }
}


@MainActor
private struct BreachKeyRecorder: NSViewRepresentable {
    let label: String
    let onKey: (NSEvent) -> Bool
    func makeNSView(context: Context) -> BreachKeyButton {
        let button = BreachKeyButton()
        button.bezelStyle = .rounded
        button.target = button
        button.action = #selector(BreachKeyButton.beginRecording)
        button.onKey = onKey
        button.bindingLabel = label
        button.title = label
        button.setAccessibilityRole(.button)
        return button
    }
    func updateNSView(_ button: BreachKeyButton, context: Context) {
        button.bindingLabel = label; button.onKey = onKey
        if !button.recording { button.title = label }
    }
}

@MainActor
private final class BreachKeyButton: NSButton {
    var onKey: ((NSEvent) -> Bool)?
    var bindingLabel = ""
    private(set) var recording = false
    override var acceptsFirstResponder: Bool { true }
    @objc func beginRecording() {
        window?.makeFirstResponder(self)
        recording = true; title = "Press a key…"
    }
    override func mouseDown(with event: NSEvent) { beginRecording() }
    override func keyDown(with event: NSEvent) {
        if !recording {
            if event.keyCode == 49 || event.keyCode == 36 { recording = true; title = "Press a key…" }
            else { super.keyDown(with: event) }
            return
        }
        if event.keyCode == 53 { finish(); return }
        if onKey?(event) == true { finish() }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Keep window/application commands available even while recording.
        if event.modifierFlags.contains(.command) {
            if recording { _ = onKey?(event) }
            return false
        }
        if recording { keyDown(with: event); return true }
        return super.performKeyEquivalent(with: event)
    }
    override func resignFirstResponder() -> Bool { finish(); return super.resignFirstResponder() }
    private func finish() { recording = false; title = bindingLabel }
}

@MainActor
private final class BreachStandaloneDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
