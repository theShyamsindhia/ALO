import AppKit
import SwiftUI
import SceneKit
import ALOCore

enum BreachControl: String, CaseIterable {
    case forward = "Forward", backward = "Backward", left = "Left", right = "Right", reload = "Reload"
    var defaultKey: UInt16 { switch self { case .forward: 13; case .backward: 1; case .left: 0; case .right: 2; case .reload: 15 } }
    var defaultLabel: String { switch self { case .forward: "W"; case .backward: "S"; case .left: "A"; case .right: "D"; case .reload: "R" } }
}

@MainActor
final class BreachController: ObservableObject {
    @Published var game = BreachSimulation()
    @Published var started = false
    @Published var captured = false
    @Published var scoreboard = false
    @Published var sensitivity = UserDefaults.standard.object(forKey: "breach.sensitivity") as? Double ?? 0.002
    @Published var fov = UserDefaults.standard.object(forKey: "breach.fov") as? Double ?? 80
    @Published var shadows = UserDefaults.standard.object(forKey: "breach.shadows") as? Bool ?? true
    @Published var difficulty = 0.7
    @Published var loadout: BreachWeapon = .rifle
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
    init() {
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
    private static let reservedKeys: Set<UInt16> = [36, 48, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
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
    func start() {
        release(); game = BreachSimulation(); game.equip(loadout); started = true
        yaw = 0; pitch = 0; lastTime = ProcessInfo.processInfo.systemUptime
        world.setGraphics(shadows: shadows, fov: fov)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    func capture() {
        guard started, !game.roundOver, !captured else { return }
        inputView?.window?.makeFirstResponder(inputView)
        captured = true; keys.removeAll(); trigger = false
        CGAssociateMouseAndMouseCursorPosition(0); NSCursor.hide()
        lastTime = ProcessInfo.processInfo.systemUptime
    }
    func release() {
        if captured { CGAssociateMouseAndMouseCursorPosition(1); NSCursor.unhide() }
        captured = false; keys.removeAll(); trigger = false; scoreboard = false
    }
    func stop() { release(); timer?.invalidate(); timer = nil; started = false }
    func look(dx: Double, dy: Double) {
        guard captured else { return }
        yaw -= dx*sensitivity; pitch = min(1.35,max(-1.35,pitch-dy*sensitivity))
    }
    func nextRound() { game.nextRound(); yaw = 0; pitch = 0; world.update(game: game, yaw: yaw, pitch: pitch, firing: false) }
    func reload() {
        let before = game.reloadRemaining
        game.reload()
        if before == 0 && game.reloadRemaining > 0 { audio.play("reload", volume: Float(volume)) }
    }
    func applySettings() {
        UserDefaults.standard.set(volume, forKey: "breach.volume")
        UserDefaults.standard.set(sensitivity, forKey: "breach.sensitivity")
        UserDefaults.standard.set(fov, forKey: "breach.fov")
        UserDefaults.standard.set(shadows, forKey: "breach.shadows")
        world.setGraphics(shadows: shadows, fov: fov)
    }
    @discardableResult func shoot() -> Bool {
        guard captured else { return false }
        let fired = game.fire(yaw: yaw, pitch: pitch)
        if fired {
            audio.play("shot", volume: Float(volume))
            if game.lastHit { hitUntil = ProcessInfo.processInfo.systemUptime + 0.12; audio.play("hit", volume: Float(volume)) }
            world.update(game: game, yaw: yaw, pitch: pitch, firing: true)
        }
        return fired
    }
    private func step() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(0.05, now-lastTime); lastTime = now
        var fired = false
        if captured {
            var forward = (keys.contains(key(.forward)) ? 1.0 : 0) - (keys.contains(key(.backward)) ? 1.0 : 0)
            var strafe = (keys.contains(key(.right)) ? 1.0 : 0) - (keys.contains(key(.left)) ? 1.0 : 0)
            let length = max(1,hypot(forward,strafe)); forward /= length; strafe /= length
            let speed = keys.contains(56) ? 2.0 : 4.2
            game.move(dx: (-sin(yaw)*forward+cos(yaw)*strafe)*speed*dt,
                      dz: (-cos(yaw)*forward-sin(yaw)*strafe)*speed*dt)
            let healthBefore = game.health
            game.tick(dt, difficulty: difficulty)
            if game.health < healthBefore { audio.play("hurt", volume: Float(volume)) }
            if trigger {
                fired = shoot()
            }
            if game.roundOver { release() }
        }
        hit = now < hitUntil
        world.update(game: game, yaw: yaw, pitch: pitch, firing: fired)
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
    private let gold = Color(red: 0.96, green: 0.72, blue: 0.34)
    var body: some View {
        ZStack {
            BreachSurface(controller: controller)
            if controller.started {
                hud.allowsHitTesting(false)
                if controller.scoreboard { stats.allowsHitTesting(false) }
                if controller.game.roundOver { result }
                else if !controller.captured { pause }
            } else { startScreen }
        }
        .foregroundStyle(.white).tint(gold).preferredColorScheme(.dark)
        .frame(minWidth: 900, minHeight: 600)
        .onDisappear { controller.stop() }
    }
    private var hud: some View {
        VStack {
            HStack {
                Text("BREACH  /  FOUNDRY").tracking(3).font(.system(size: 12,weight: .bold))
                Spacer()
                Text("ROUND \(controller.game.round)  •  FIRST TO 5")
                Spacer()
                Text("\(controller.game.wins)  :  \(controller.game.losses)").font(.title2.bold())
            }.padding(22).background(.black.opacity(0.35))
            Text(String(format: "%01d:%02d", Int(controller.game.seconds)/60, Int(controller.game.seconds)%60))
                .font(.title3.monospacedDigit()).padding(8).background(.black.opacity(0.4), in: Capsule())
            Spacer()
            Image(systemName: controller.hit ? "xmark" : "plus")
                .font(.system(size: 18,weight: .light)).foregroundStyle(controller.hit ? gold : .white.opacity(0.85))
            Spacer()
            HStack(alignment: .bottom) {
                VStack(alignment: .leading) {
                    Text("HEALTH").font(.caption)
                    Text("\(controller.game.health)").font(.system(size: 38,weight: .bold,design: .rounded))
                }
                Spacer()
                Text("\(controller.label(.forward))/\(controller.label(.left))/\(controller.label(.backward))/\(controller.label(.right)) Move   ⇧ Walk   \(controller.label(.reload)) Reload   Tab Stats   Esc Menu").font(.caption)
                Spacer()
                VStack(alignment: .trailing) {
                    Text(controller.game.reloadRemaining > 0 ? "RELOADING…" : controller.game.weapon.rawValue)
                    Text("\(controller.game.ammo) / \(controller.game.reserve)").font(.system(size: 30,weight: .bold,design: .monospaced))
                }
            }.padding(24).background(LinearGradient(colors: [.clear,.black.opacity(0.8)],startPoint: .top,endPoint: .bottom))
        }
    }
    private var startScreen: some View {
        GeometryReader { geometry in
        HStack {
            ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("ALO ORIGINAL  /  TACTICAL FPS").font(.caption.bold()).tracking(3).foregroundStyle(gold)
                Text("BREACH").font(.system(size: 68,weight: .black,design: .rounded)).tracking(5)
                Text("FOUNDRY").font(.title2.bold()).tracking(6)
                Text("Clear the courtyard. Control the angles.\nDefeat three guards to win the round. First to five wins.")
                    .foregroundStyle(.white.opacity(0.65)).lineSpacing(5)
                Label("Local bot match · Dedicated game window",systemImage: "desktopcomputer").font(.caption)
                settings
                Button { controller.start() } label: {
                    Label("Deploy to Foundry",systemImage: "play.fill").font(.headline).padding(10).frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent)
                Text("Click the arena to capture your mouse. Escape releases it.\nCmd W closes the window; switching apps pauses the match.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28)
            }.frame(width: 460, height: geometry.size.height).background(.black.opacity(0.85))
            Spacer()
        }
        }
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Loadout",selection: $controller.loadout) {
                ForEach(BreachWeapon.allCases,id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).disabled(controller.started)
            Picker("Bots",selection: $controller.difficulty) {
                Text("Recruit").tag(0.7); Text("Regular").tag(1.0); Text("Veteran").tag(1.4)
            }
            HStack { Text("Sensitivity"); Slider(value: $controller.sensitivity,in: 0.0005...0.006) }
            HStack { Text("Field of view"); Slider(value: $controller.fov,in: 60...105); Text("\(Int(controller.fov))°").monospacedDigit() }
            HStack { Text("Effects volume"); Slider(value: $controller.volume, in: 0...1) }
            Toggle("Dynamic shadows",isOn: $controller.shadows)
            DisclosureGroup("Controls") {
                VStack(spacing: 7) {
                    ForEach(BreachControl.allCases, id: \.self) { control in
                        HStack {
                            Text(control.rawValue)
                            Spacer()
                            BreachKeyRecorder(label: controller.label(control)) { event in
                                controller.bind(control, event: event)
                            }.frame(width: 110, height: 25)
                                .accessibilityLabel("Assign \(control.rawValue.lowercased()) key")
                        }
                    }
                    Text(controller.controlFeedback).font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    Text("Mouse: aim · Left click: fire · Shift: walk · Tab: stats · Esc: pause")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Reset controls") { controller.resetControls() }.buttonStyle(.bordered)
                }.padding(.top, 8)
            }
        }.font(.system(size: 12))
            .onChange(of: controller.sensitivity) { _,_ in controller.applySettings() }
            .onChange(of: controller.fov) { _,_ in controller.applySettings() }
            .onChange(of: controller.volume) { _,_ in controller.applySettings() }
            .onChange(of: controller.shadows) { _,_ in controller.applySettings() }
    }
    private var pause: some View {
        GeometryReader { geometry in
        ScrollView {
        VStack(spacing: 18) {
            Text("READY WHEN YOU ARE").font(.title2.bold())
            Text("Match paused · Mouse released").foregroundStyle(.secondary)
            settings
            Button("Resume & capture mouse") { controller.capture() }.buttonStyle(.borderedProminent)
            Button("Return to briefing") { controller.stop() }.buttonStyle(.bordered)
        }.padding(28)
        }.frame(width: 420, height: min(geometry.size.height - 40, 560))
            .background(.black.opacity(0.9),in: RoundedRectangle(cornerRadius: 16))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private var stats: some View {
        VStack(spacing: 18) {
            Text("FOUNDRY  /  ELIMINATION").font(.title2.bold())
            HStack { Text("Operator"); Spacer(); Text("Kills"); Text("Health").frame(width: 65) }.foregroundStyle(.secondary)
            HStack { Text("You"); Spacer(); Text("\(controller.game.kills)"); Text("\(controller.game.health)").frame(width: 65) }
            Divider()
            ForEach(controller.game.bots) { bot in
                HStack { Text("Guard \(bot.id+1)"); Spacer(); Text(bot.health > 0 ? "Active" : "Eliminated"); Text("\(max(0,bot.health))").frame(width: 65) }
            }
            Text("Rounds  \(controller.game.wins) – \(controller.game.losses)").font(.headline)
        }.padding(28).frame(width: 500).background(.black.opacity(0.88),in: RoundedRectangle(cornerRadius: 16))
    }
    private var result: some View {
        VStack(spacing: 18) {
            Text(controller.game.matchOver ? "MATCH COMPLETE" : controller.game.health > 0 && controller.game.seconds > 0 ? "AREA SECURED" : "ROUND LOST")
                .font(.largeTitle.bold())
            Text("\(controller.game.wins) : \(controller.game.losses)").font(.system(size: 48,weight: .bold))
            Text("\(controller.game.kills) eliminations").foregroundStyle(.secondary)
            if controller.game.matchOver {
                Button("Play again") { controller.start() }.buttonStyle(.borderedProminent)
            } else {
                Button("Next round") { controller.nextRound() }.buttonStyle(.borderedProminent)
            }
            Button("Return to briefing") { controller.stop() }.buttonStyle(.bordered)
        }.padding(36).background(.black.opacity(0.9),in: RoundedRectangle(cornerRadius: 18))
    }
}

@MainActor
final class BreachWindowController: NSObject, NSWindowDelegate {
    static let shared = BreachWindowController()
    private var window: NSWindow?
    private var controller: BreachController?
    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let game = BreachController()
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
    func windowWillClose(_ notification: Notification) { controller?.stop(); controller = nil; window = nil }
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
