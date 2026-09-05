import AppKit
import SpriteKit
import SwiftUI
import ALOCore

struct ArenaPanel: View {
    @ObservedObject var session: ArenaSession
    var detached = false
    @State private var showsControls = false
    private let accent = ArenaAppearance.accent
    var body: some View {
        VStack(spacing: 0) {
            if session.selectedGameID != nil || detached { toolbar }
            if session.expanded && !detached {
                VStack(spacing: 10) {
                    Image(systemName: "macwindow").font(.system(size: 24)).foregroundStyle(accent)
                    Text("Playing in another window").font(.system(size: 12, weight: .medium))
                    Button("Show game") { session.openExpanded() }.buttonStyle(.borderedProminent)
                    Button("Return to room") { session.closeExpanded() }.buttonStyle(.bordered)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.selectedGameID == nil {
                GameLibraryView(store: session.library, onPlay: session.openGame)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.loadingGame {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Preparing your game…").font(.system(size: 12))
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = session.gameLoadError {
                VStack(spacing: 10) {
                    Text(error).font(.system(size: 12)).multilineTextAlignment(.center)
                    Button("Back to library") { session.returnToLibrary() }
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.selectedGameID == "fourfold" {
                FourfoldPanel(session: session.fourfold, onBack: session.returnToLibrary, showsHeader: false)
            } else if session.playing {
                game
            } else { details }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white.opacity(0.92))
        .background(Color(red: 0.15, green: 0.15, blue: 0.16).opacity(0.94))
        .tint(accent)
        .onAppear { session.panelAppeared() }
        .onDisappear { session.panelDisappeared() }
    }
    private var toolbar: some View {
        HStack(spacing: 10) {
            if session.selectedGameID != nil {
                Button { session.returnToLibrary() } label: { Label("Library", systemImage: "chevron.left") }
                    .help("Leave this activity and return to Games")
            }
            Spacer(minLength: 0)
            Text(session.selectedGameID == "fourfold" ? "Fourfold" : session.selectedGameID == nil ? "Games" : "Rift Arena")
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
            if session.playing {
                Button { session.togglePause() } label: { Label("Menu", systemImage: "slider.horizontal.3") }
                    .help("Players, controls and settings · Esc")
            }
            Button { detached ? session.fullscreen() : session.openExpanded() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }.help(detached ? "Toggle fullscreen" : "Expand game")
            if detached { Button { session.closeExpanded() } label: { Image(systemName: "rectangle.inset.filled") }.help("Return game to room") }
        }.buttonStyle(.plain).font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 14).frame(height: 38)
            .background(.white.opacity(0.025))
    }
    private var game: some View {
        ZStack {
            VStack(spacing: 0) {
                ArenaPlayerRoster(session: session, compact: true).padding(.horizontal, 10).padding(.vertical, 6)
                ArenaSurface(session: session).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                HStack(spacing: 12) {
                    Text(session.mode == .spectator ? "Spectating" : "Click arena to focus")
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer(minLength: 0)
                    Button("Controls") { showsControls = true; session.togglePause() }
                    Text("Esc · Menu").foregroundStyle(.white.opacity(0.5))
                }.font(.system(size: 10, weight: .medium)).buttonStyle(.plain).padding(.horizontal, 14).frame(height: 28)
            }
            if session.showsMenu || session.paused {
                ArenaMenuOverlay(session: session, detached: detached, effectsEnabled: $session.effectsEnabled,
                    initialSection: showsControls ? "Controls" : "Overview",
                    onResume: { session.closeMenu(); showsControls = false },
                    onLeave: { session.returnToLibrary(); showsControls = false })
            } else if session.mode == .spectator && !session.notice.isEmpty {
                VStack(spacing: 8) { ProgressView(); Text(session.notice).font(.system(size: 12)) }
                    .padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            } else if let winner = session.simulation.winner {
                VStack(spacing: 12) {
                    Image(systemName: "crown.fill").foregroundStyle(accent).font(.system(size: 24))
                    Text(winner == -1 ? "Draw" : "\(session.playerNames[winner]) wins")
                        .font(.system(size: 22, weight: .semibold))
                    HStack(spacing: 10) {
                        Button("Library") { session.returnToLibrary() }.buttonStyle(.bordered)
                        if session.mode != .spectator {
                            Button(session.mode == .practice ? "Play again" : "Rematch") {
                                session.mode == .practice ? session.practice() : session.rematch()
                            }.buttonStyle(.borderedProminent)
                        }
                    }
                }.padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
        }
    }
    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ZStack(alignment: .bottomLeading) {
                    if let image = session.gameBackground {
                        Image(nsImage: image).resizable().scaledToFill().frame(height: detached ? 185 : 100).clipped()
                    } else { Rectangle().fill(.white.opacity(0.04)).frame(height: 100) }
                    LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Rift Arena").font(.system(size: 22, weight: .semibold))
                        Text("Platform fighter · Solo or room duel").font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
                    }.padding(14)
                }.frame(height: detached ? 185 : 100).clipShape(RoundedRectangle(cornerRadius: 14))
                Text("Choose your fighter").font(.system(size: 12, weight: .semibold))
                HStack(spacing: 10) {
                    ForEach(ArenaFighterKind.allCases, id: \.self) { fighter in
                        Button { session.selected = fighter } label: {
                            HStack(spacing: 10) {
                                Image(systemName: fighter == .nova ? "bolt" : "shield").font(.system(size: 20))
                                    .foregroundStyle(accent)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(fighter.title).font(.system(size: 13, weight: .semibold))
                                    Text(fighter.subtitle).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                                }
                                Spacer(minLength: 0)
                                if session.selected == fighter { Image(systemName: "checkmark.circle.fill").foregroundStyle(accent) }
                            }.padding(12).frame(maxWidth: .infinity)
                                .background(.white.opacity(session.selected == fighter ? 0.09 : 0.03), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(session.selected == fighter ? 0.25 : 0.08)))
                        }.buttonStyle(.plain).disabled(session.mode != .picker)
                    }
                }
                if session.mode == .picker {
                    HStack(spacing: 10) {
                        Button { session.practice() } label: { Label("Play solo", systemImage: "play.fill").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent)
                        Button { session.host() } label: { Label("Invite room", systemImage: "person.2").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered).disabled(session.send == nil)
                            .help("Open two player slots. Both players must ready up before the match begins.")
                    }.controlSize(.large)
                    ForEach(session.lobbies) { lobby in
                        Button { session.join(lobby, spectate: lobby.started) } label: {
                            HStack {
                                Text("\(session.names[lobby.peerID] ?? "Room member")’s match")
                                Spacer(); Text(lobby.started ? "Spectate" : "Join").foregroundStyle(accent)
                            }.font(.system(size: 12)).padding(12).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }
                } else if session.mode == .readyHost || session.mode == .readyGuest {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("You · " + (session.localReady ? "Ready" : "Not ready"), systemImage: session.localReady ? "checkmark.circle.fill" : "circle")
                            Label("Rival · " + (session.remoteReady ? "Ready" : "Not ready"), systemImage: session.remoteReady ? "checkmark.circle.fill" : "circle")
                        }.font(.system(size: 11))
                        Spacer()
                        Button(session.localReady ? "Unready" : "Ready up") { session.readyUp() }.buttonStyle(.borderedProminent)
                    }
                } else {
                    HStack { ProgressView().controlSize(.small); Text(session.notice).font(.system(size: 12)); Spacer(); Button("Cancel") { session.leave() } }
                }
                if session.mode == .picker && !session.notice.isEmpty { Text(session.notice).font(.system(size: 11)).foregroundStyle(accent) }
                DisclosureGroup("How to play") {
                    Text("Build damage and launch your opponent off the arena. Three lives each. Move A/D, jump Space, aim W/S, attack J/K, dodge L. You have two air jumps and W + K recovery. Esc opens players, controls and settings.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).padding(.top, 6)
                }.font(.system(size: 11))
            }.padding(14).frame(maxWidth: detached ? 720 : .infinity).frame(maxWidth: .infinity)
        }
    }
}

private struct ArenaSurface: NSViewRepresentable {
    let session: ArenaSession
    func makeNSView(context: Context) -> ArenaSKView {
        let view = ArenaSKView()
        view.session = session
        view.preferredFramesPerSecond = 60
        view.ignoresSiblingOrder = true
        view.allowsTransparency = true
        let scene = ArenaScene(session: session)
        scene.scaleMode = .aspectFit
        view.presentScene(scene)
        return view
    }
    func updateNSView(_ nsView: ArenaSKView, context: Context) {
        nsView.refreshVisibility()
    }
    static func dismantleNSView(_ nsView: ArenaSKView, coordinator: ()) {
        nsView.session?.clearInput(); nsView.presentScene(nil)
    }
}

final class ArenaSKView: SKView {
    weak var session: ArenaSession?
    private var keys = Set<UInt16>()
    private let surfaceID = UUID()
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(self); session?.controlsFocused = true }
    override func resignFirstResponder() -> Bool {
        keys.removeAll(); session?.clearInput(); session?.controlsFocused = false
        return super.resignFirstResponder()
    }
    override func keyDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.command) else { super.keyDown(with: event); return }
        if event.keyCode == 35 || event.keyCode == 53 {
            if !event.isARepeat { session?.togglePause() }
            return
        }
        guard [0, 2, 13, 1, 49, 38, 40, 37, 123, 124, 125, 126].contains(event.keyCode) else {
            super.keyDown(with: event); return
        }
        keys.insert(event.keyCode); publish()
    }
    override func keyUp(with event: NSEvent) { keys.remove(event.keyCode); publish() }
    private func publish() {
        var input = ArenaInput()
        input.horizontal = (keys.contains(2) || keys.contains(124) ? 1 : 0) - (keys.contains(0) || keys.contains(123) ? 1 : 0)
        input.vertical = (keys.contains(13) || keys.contains(126) ? 1 : 0) - (keys.contains(1) || keys.contains(125) ? 1 : 0)
        input.jump = keys.contains(49); input.light = keys.contains(38)
        input.heavy = keys.contains(40); input.dodge = keys.contains(37)
        session?.setInput(input)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged), name: NSWindow.didChangeOcclusionStateNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(lostFocus), name: NSWindow.didResignKeyNotification, object: window)
        }
        visibilityChanged()
    }
    func refreshVisibility() { visibilityChanged() }
    @objc private func visibilityChanged() {
        let visible = window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor
        isPaused = !visible || session?.paused == true
        preferredFramesPerSecond = isPaused ? 1 : 60
        let id = surfaceID
        DispatchQueue.main.async { [weak session] in session?.surfaceVisibility(id, visible: visible) }
    }
    override func viewDidHide() { super.viewDidHide(); visibilityChanged() }
    override func viewDidUnhide() { super.viewDidUnhide(); visibilityChanged() }
    @objc private func lostFocus() { keys.removeAll(); session?.controlsFocused = false; session?.focusLost() }
    deinit { NotificationCenter.default.removeObserver(self) }
}

final class ArenaScene: SKScene {
    private weak var session: ArenaSession?
    private var bodies = [SKNode]()
    private var blades = [SKShapeNode]()
    private var shields = [SKShapeNode]()
    private var labels = [SKLabelNode]()
    private var damageLabels = [SKLabelNode]()
    private var ambient = SKNode()
    private var effects = SKNode()
    private var usesIllustratedFighters = false
    private var announcement = SKLabelNode(fontNamed: "AvenirNext-Heavy")
    private var clockLabel = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
    private var priorHits = [0, 0]
    private var priorStocks = [3, 3]
    private var lastFrame = -1
    private let mint = NSColor(calibratedRed: 0.55, green: 0.59, blue: 0.75, alpha: 1)
    private let coral = NSColor(calibratedRed: 0.75, green: 0.59, blue: 0.51, alpha: 1)
    init(session: ArenaSession) {
        self.session = session
        super.init(size: CGSize(width: 1000, height: 610))
        backgroundColor = .clear
        buildWorld()
    }
    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func shape(_ points: [CGPoint], color: NSColor, line: NSColor = .clear) -> SKShapeNode {
        let path = CGMutablePath(); path.addLines(between: points); path.closeSubpath()
        let node = SKShapeNode(path: path); node.fillColor = color; node.strokeColor = line
        return node
    }
    private func label(_ text: String, x: Double, y: Double, size: Double, color: NSColor = .white) -> SKLabelNode {
        let node = SKLabelNode(fontNamed: "AvenirNext-Bold")
        node.text = text; node.fontSize = size; node.fontColor = color; node.position = CGPoint(x: x, y: y)
        addChild(node); return node
    }
    private func buildWorld() {
        // Static vector geometry: no downloads, per-frame textures or physics bodies.
        if let image = session?.gameBackground {
            let backdrop = SKSpriteNode(texture: SKTexture(image: image))
            backdrop.size = self.size; backdrop.position = CGPoint(x: 500, y: 305); backdrop.zPosition = -50
            addChild(backdrop)
            let veil = SKSpriteNode(color: NSColor(white: 0.05, alpha: 0.18), size: self.size)
            veil.position = backdrop.position; veil.zPosition = -49; addChild(veil)
        } else {
        let moon = SKShapeNode(circleOfRadius: 86)
        moon.position = CGPoint(x: 720, y: 438)
        moon.fillColor = NSColor(calibratedRed: 0.14, green: 0.19, blue: 0.31, alpha: 1)
        moon.strokeColor = mint.withAlphaComponent(0.18); moon.lineWidth = 2; addChild(moon)
        for i in 0..<65 {
            let star = SKShapeNode(circleOfRadius: i % 5 == 0 ? 1.7 : 0.8)
            star.position = CGPoint(x: (i * 157 + 37) % 1000, y: (i * 71 + 210) % 570)
            star.fillColor = .white.withAlphaComponent(CGFloat(0.12 + Double(i % 4) * 0.09)); star.strokeColor = .clear; addChild(star)
        }
        for layer in 0..<3 {
            var points = [CGPoint(x: -80, y: 0)]
            for i in 0...12 { points.append(CGPoint(x: i * 95 - 60, y: 120 + layer * 35 + (i * 71 + layer * 37) % 130)) }
            points.append(CGPoint(x: 1100, y: 0))
            let color = NSColor(calibratedRed: 0.045 + Double(layer) * 0.013, green: 0.07 + Double(layer) * 0.012, blue: 0.14 + Double(layer) * 0.018, alpha: 1)
            addChild(shape(points, color: color))
        }
        }
        let ring = SKShapeNode(ellipseOf: CGSize(width: 680, height: 145))
        ring.position = CGPoint(x: 500, y: 112); ring.strokeColor = mint.withAlphaComponent(0.12); ring.lineWidth = 2; addChild(ring)
        for (index, platform) in ArenaSimulation.platforms.enumerated() {
            let l = platform.left, r = platform.right, y = platform.top
            addChild(shape([CGPoint(x: l, y: y), CGPoint(x: r, y: y), CGPoint(x: r - 24, y: y - 40),
                            CGPoint(x: (l + r) / 2 + 25, y: y - (index == 0 ? 112 : 65)), CGPoint(x: l + 15, y: y - 40)],
                           color: NSColor(calibratedRed: 0.20, green: 0.20, blue: 0.21, alpha: 1), line: NSColor(white: 0.65, alpha: 0.3)))
            let top = SKShapeNode(rectOf: CGSize(width: r - l, height: 9), cornerRadius: 4)
            top.position = CGPoint(x: (l + r) / 2, y: y - 4); top.fillColor = NSColor(calibratedRed: 0.58, green: 0.55, blue: 0.48, alpha: 1)
            top.strokeColor = NSColor(calibratedRed: 0.78, green: 0.74, blue: 0.65, alpha: 1); top.glowWidth = 0; addChild(top)
            if index == 0 {
                for j in 0..<7 {
                    let rune = SKShapeNode(rectOf: CGSize(width: 20, height: 3)); rune.fillColor = NSColor(calibratedRed: 0.72, green: 0.64, blue: 0.45, alpha: 0.5)
                    rune.strokeColor = .clear; rune.position = CGPoint(x: 280 + j * 74, y: 124); addChild(rune)
                }
            }
        }
        _ = label("Hollow Observatory", x: 500, y: 40, size: 10, color: mint.withAlphaComponent(0.4))
        for i in 0..<2 {
            let color = i == 0 ? mint : coral
            let body = SKNode(); body.zPosition = 10
            let coat = shape([CGPoint(x: -20, y: 11), CGPoint(x: -14, y: 42), CGPoint(x: 12, y: 45), CGPoint(x: 23, y: 9), CGPoint(x: 0, y: 17)], color: color.withAlphaComponent(0.85), line: color)
            body.addChild(coat)
            for x in [-10, 10] {
                let leg = SKShapeNode(rectOf: CGSize(width: 10, height: 18), cornerRadius: 3)
                leg.position = CGPoint(x: x, y: 6); leg.fillColor = NSColor(white: 0.16, alpha: 1); leg.strokeColor = color; body.addChild(leg)
            }
            let head = SKShapeNode(rectOf: CGSize(width: 29, height: 26), cornerRadius: 10)
            head.position = CGPoint(x: 0, y: 47); head.fillColor = NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.22, alpha: 1)
            head.strokeColor = color; head.lineWidth = 2; body.addChild(head)
            let visor = SKShapeNode(rectOf: CGSize(width: 23, height: 5), cornerRadius: 2)
            visor.position = CGPoint(x: 4, y: 49); visor.fillColor = .white; visor.strokeColor = color; visor.glowWidth = 2; body.addChild(visor)
            let blade = SKShapeNode(); blade.fillColor = color; blade.strokeColor = .white; blade.lineWidth = 1
            body.addChild(blade); blades.append(blade)
            if let artwork = session?.fighterArtwork {
                usesIllustratedFighters = true
                body.children.forEach { $0.isHidden = true }
                let kind = session?.simulation.fighters[i].kind ?? (i == 0 ? .nova : .atlas)
                let sheet = SKTexture(image: artwork)
                let rect = kind == .nova ? CGRect(x: 0, y: 0.06, width: 0.55, height: 0.89) : CGRect(x: 0.55, y: 0.06, width: 0.45, height: 0.89)
                let figure = SKSpriteNode(texture: SKTexture(rect: rect, in: sheet))
                figure.size = CGSize(width: kind == .nova ? 88 : 65, height: 88)
                figure.anchorPoint = CGPoint(x: 0.5, y: 0); figure.position = CGPoint(x: 0, y: -4)
                figure.name = "illustration"; body.addChild(figure)
                let marker = SKShapeNode(ellipseOf: CGSize(width: 40, height: 8))
                marker.position.y = 1; marker.strokeColor = color; marker.fillColor = color.withAlphaComponent(0.18)
                marker.lineWidth = 2; body.addChild(marker)
            }
            let shield = SKShapeNode(circleOfRadius: 42); shield.position.y = 29; shield.strokeColor = color
            shield.lineWidth = 2; shield.glowWidth = 2; body.addChild(shield); shields.append(shield)
            addChild(body); bodies.append(body)
            let x = i == 0 ? 155.0 : 845.0
            let plate = SKShapeNode(rectOf: CGSize(width: 220, height: 74), cornerRadius: 14)
            plate.position = CGPoint(x: x, y: 550); plate.fillColor = NSColor(white: 0.03, alpha: 0.75)
            plate.strokeColor = color.withAlphaComponent(0.35); plate.isHidden = true; addChild(plate)
            labels.append(label("", x: x, y: 563, size: 13, color: color))
            damageLabels.append(label("", x: x, y: 531, size: 23))
            labels[i].isHidden = true; damageLabels[i].isHidden = true
            let slot = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
            slot.text = "P\(i + 1)"; slot.fontSize = 11; slot.fontColor = color; slot.position.y = usesIllustratedFighters ? 88 : 72
            body.addChild(slot)
        }
        announcement.position = CGPoint(x: 500, y: 407); announcement.fontSize = 54; announcement.zPosition = 30; addChild(announcement)
        clockLabel.position = CGPoint(x: 500, y: 549); clockLabel.fontSize = 20; addChild(clockLabel)
        ambient.zPosition = -10; addChild(ambient)
        for index in 0..<16 {
            let mote = SKShapeNode(circleOfRadius: index % 3 == 0 ? 1.6 : 0.8)
            mote.fillColor = NSColor(calibratedRed: 0.83, green: 0.77, blue: 0.61, alpha: 0.6)
            mote.strokeColor = .clear; mote.position = CGPoint(x: (index * 173 + 80) % 1000, y: (index * 91 + 55) % 500)
            ambient.addChild(mote)
            mote.run(.repeatForever(.sequence([
                .group([.moveBy(x: 20, y: 35, duration: 4), .fadeAlpha(to: 0.1, duration: 4)]),
                .group([.moveBy(x: -20, y: -35, duration: 4), .fadeAlpha(to: 0.7, duration: 4)])
            ])))
        }
        effects.zPosition = 20; addChild(effects)
    }
    override func update(_ currentTime: TimeInterval) {
        guard let session else { return }
        ambient.isHidden = !session.effectsEnabled || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ambient.isPaused = ambient.isHidden
        let sim = session.simulation
        guard sim.fighters.count == 2 else { return }
        let changed = sim.frame != lastFrame
        lastFrame = sim.frame
        for i in 0..<2 {
            let f = sim.fighters[i], body = bodies[i]
            let target = CGPoint(x: f.x, y: f.y)
            // Smooth remote snapshots without extrapolating authoritative game state.
            if session.mode == .guest && hypot(body.position.x - target.x, body.position.y - target.y) < 140 {
                body.position.x += (target.x - body.position.x) * 0.55
                body.position.y += (target.y - body.position.y) * 0.55
            } else { body.position = target }
            body.xScale = f.facing * (f.kind == .atlas ? 1.16 : 1)
            body.yScale = f.kind == .atlas ? 1.08 : 1
            body.isHidden = f.respawn > 0 || f.stocks == 0
            body.alpha = f.invulnerable > 0 && sim.frame % 12 < 6 ? 0.45 : 1
            body.zRotation = f.stun > 0 ? -f.facing * 0.18 : f.attackFrames > 0 ? -f.facing * sin(Double(f.attackAge) * 0.18) * 0.16 : sin(Double(sim.frame) * 0.2) * min(0.06, abs(f.vx) / 5000)
            if let figure = body.childNode(withName: "illustration") {
                figure.position.y = -4 + (f.grounded && abs(f.vx) > 40 ? abs(sin(Double(sim.frame) * 0.4)) * 3 : 0)
            }
            shields[i].isHidden = f.invulnerable == 0
            if !usesIllustratedFighters && blades[i].path == nil {
            let path = CGMutablePath()
            if f.kind == .nova {
                path.addLines(between: [CGPoint(x: 16, y: 26), CGPoint(x: 61, y: 39), CGPoint(x: 53, y: 27), CGPoint(x: 18, y: 21)])
                path.closeSubpath()
            } else { path.addRoundedRect(in: CGRect(x: 16, y: 15, width: 27, height: 25), cornerWidth: 7, cornerHeight: 7) }
            blades[i].path = path
            }
            blades[i].zRotation = f.attackFrames > 0 ? Double(f.attackDirection) * 0.9 + sin(Double(f.attackAge) * 0.25) * 0.7 : 0
            if changed {
            let name = String(session.playerNames[i].prefix(18))
            labels[i].text = "\(name) · \(f.kind.title.uppercased())"
            damageLabels[i].text = "\(Int(f.damage))%   " + String(repeating: "●", count: max(0, f.stocks))
            damageLabels[i].fontColor = f.damage > 100 ? coral : .white
            }
            if changed && f.attackFrames > 0 && (f.attackAge == 2 || sim.attackActive(i) && f.attackAge % 3 == 0) {
                let box = sim.attackCenter(i)
                let arc = SKShapeNode(circleOfRadius: box.radius)
                arc.position = CGPoint(x: box.x, y: box.y); arc.strokeColor = (i == 0 ? mint : coral).withAlphaComponent(sim.attackActive(i) ? 0.8 : 0.25)
                arc.lineWidth = sim.attackActive(i) ? 5 : 1; arc.xScale = 0.7
                effects.addChild(arc); arc.run(.sequence([.group([.fadeOut(withDuration: 0.18), .scale(to: 1.25, duration: 0.18)]), .removeFromParent()]))
            }
            if f.hitSerial != priorHits[i] {
                burst(at: CGPoint(x: f.x, y: f.y + 28), color: .white, count: 12)
                priorHits[i] = f.hitSerial
            }
            if f.stocks < priorStocks[i] {
                burst(at: CGPoint(x: min(960, max(40, f.x)), y: min(480, max(50, f.y))), color: i == 0 ? mint : coral, count: 24)
            }
            priorStocks[i] = f.stocks
        }
        let seconds = max(0, sim.remainingFrames / 60)
        clockLabel.text = String(format: "%d:%02d", seconds / 60, seconds % 60)
        announcement.text = sim.countdown > 0 ? "\((sim.countdown + 59) / 60)" : sim.frame < 215 ? "BRAWL" : ""
    }
    private func burst(at position: CGPoint, color: NSColor, count: Int) {
        guard session?.effectsEnabled == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        for i in 0..<count {
            let spark = SKShapeNode(rectOf: CGSize(width: 7, height: 3), cornerRadius: 1)
            spark.fillColor = color; spark.strokeColor = .clear; spark.position = position
            let angle = Double(i) / Double(count) * Double.pi * 2
            spark.zRotation = angle; effects.addChild(spark)
            spark.run(.sequence([.group([.moveBy(x: cos(angle) * 70, y: sin(angle) * 70, duration: 0.3), .fadeOut(withDuration: 0.3)]), .removeFromParent()]))
        }
    }
}
