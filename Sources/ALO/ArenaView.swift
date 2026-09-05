import AppKit
import SpriteKit
import SwiftUI
import ALOCore

struct ArenaPanel: View {
    @ObservedObject var session: ArenaSession
    var detached = false
    @State private var showsControls = false
    @State private var configuredBots = 1
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
                GeometryReader { geometry in
                    let width = min(geometry.size.width, geometry.size.height * 1000 / 610)
                    ArenaSurface(session: session)
                        .frame(width: width, height: width * 610 / 1000)
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                HStack(spacing: 12) {
                    Text(session.mode == .spectator ? "Spectating" : "Click arena to focus")
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer(minLength: 0)
                    if session.networked && session.mode != .spectator && session.playerSlots.contains(where: { !$0.isBot && $0.index != session.localIndex }) {
                        HStack(spacing: 4) {
                            Circle().fill((session.latencyMilliseconds ?? 0) > 120 ? Color.orange : accent).frame(width: 5, height: 5)
                            Text(session.latencyMilliseconds.map { "\($0) ms" } ?? "Measuring…").monospacedDigit()
                        }.help("Game round-trip delay. Audio sync cannot reduce network latency.")
                    }
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
                    if let image = session.arenaBackground {
                        Image(nsImage: image).resizable().scaledToFill().frame(height: detached ? 185 : 100).clipped()
                    } else { Rectangle().fill(.white.opacity(0.04)).frame(height: 100) }
                    LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Rift Arena").font(.system(size: 22, weight: .semibold))
                        Text("Platform fighter · Up to 4 players").font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
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
                    Text("Choose your arena").font(.system(size: 12, weight: .semibold))
                    HStack(spacing: 8) {
                        ForEach(ArenaMap.allCases, id: \.self) { map in
                            Button { session.selectedMap = map } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    ArenaMapThumbnail(map: map, selected: session.selectedMap == map)
                                        .frame(height: 45)
                                    Text(map.title).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                                    Text(map.subtitle).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
                                }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.white.opacity(session.selectedMap == map ? 0.10 : 0.035), in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(session.selectedMap == map ? 0.3 : 0.08)))
                            }.buttonStyle(.plain).accessibilityLabel("\(map.title), \(map.subtitle)\(session.selectedMap == map ? ", selected" : "")")
                        }
                    }
                    Text("4 player slots · 8 spectators. Late joiners can take over a live bot; a full match opens in spectate mode.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    ForEach(session.lobbies) { lobby in
                        Button { session.join(lobby) } label: {
                            HStack {
                                Text("\(session.names[lobby.peerID] ?? "Room member") · \(lobby.map.title)")
                                Spacer(); Text(lobby.availableSlots > 0 ? (lobby.started ? "Take bot slot" : "Join") : "Spectate").foregroundStyle(accent)
                            }.font(.system(size: 12)).padding(12).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }
                }
                if session.mode == .picker && !session.notice.isEmpty { Text(session.notice).font(.system(size: 11)).foregroundStyle(accent) }
                DisclosureGroup("How to play") {
                    Text("Build damage and launch your opponent off the arena. Three lives each. Move A/D, jump Space, aim W/S, attack J/K, dodge L. You have two air jumps and W + K recovery. Esc opens players, controls and settings.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).padding(.top, 6)
                }.font(.system(size: 11))
            }.padding(14).frame(maxWidth: detached ? 720 : .infinity).frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                if session.mode == .picker {
                    HStack(spacing: 12) {
                        Stepper("Bots: \(configuredBots)", value: $configuredBots, in: 0...3)
                            .font(.system(size: 11)).fixedSize()
                        Spacer(minLength: 0)
                        Button { session.host(botCount: configuredBots) } label: {
                            Label("Create room match", systemImage: "person.2.fill")
                        }.buttonStyle(.borderedProminent).disabled(session.send == nil)
                            .help("Invites your room. Everyone readies up, then late joiners can replace bots.")
                    }
                    if session.send == nil { Text("Join a live room to create a match.").font(.system(size: 10)).foregroundStyle(.secondary) }
                } else if session.mode == .hosting || session.mode == .readyHost || session.mode == .readyGuest {
                    HStack(spacing: 6) {
                        ForEach(session.playerSlots, id: \.index) { slot in
                            VStack(spacing: 3) {
                                Text(slot.name).lineLimit(1)
                                Text(slot.isBot ? "Bot" : slot.ready ? "Ready" : "Not ready").foregroundStyle(.secondary)
                            }.font(.system(size: 10)).frame(maxWidth: .infinity)
                        }
                    }
                    HStack {
                        if session.isActivityHost {
                            Button("Add bot") { session.addBot() }.disabled(!session.canAddBot)
                            Button("Remove bot") { session.removeBot() }.disabled(!session.canRemoveBot)
                        }
                        Spacer(minLength: 0)
                        Button("Leave") { session.leave() }
                        Button(session.localReady ? "Unready" : "Ready up") { session.readyUp() }.buttonStyle(.borderedProminent)
                    }.font(.system(size: 11))
                } else {
                    HStack { ProgressView().controlSize(.small); Text(session.notice).font(.system(size: 12)); Spacer(); Button("Cancel") { session.leave() } }
                }
            }.padding(12).frame(maxWidth: .infinity)
                .background(Color(red: 0.16, green: 0.16, blue: 0.17))
                .overlay(alignment: .top) { Divider().opacity(0.3) }
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
    private var rigs = [ArenaFighterRig]()
    private var builtMap: ArenaMap?
    private let worldCamera = SKCameraNode()
    private var shields = [SKShapeNode]()
    private var ambient = SKNode()
    private var backdropNode: SKSpriteNode?
    private var depthLayers: [(SKNode, CGFloat)] = []
    private var shadows: [SKShapeNode] = []
    private var introTitle = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
    private var introNames = SKLabelNode(fontNamed: "AvenirNext-Medium")
    private var cinematicBars: [SKSpriteNode] = []
    private var effects = SKNode()
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
        removeAllChildren(); worldCamera.removeAllChildren(); camera = worldCamera
        worldCamera.position = CGPoint(x: 500, y: 305); worldCamera.setScale(1); worldCamera.zPosition = 100; addChild(worldCamera)
        bodies.removeAll(); rigs.removeAll(); shields.removeAll(); shadows.removeAll()
        cinematicBars.removeAll(); depthLayers.removeAll(); ambient.removeAllChildren(); effects.removeAllChildren()
        builtMap = session?.simulation.map
        priorHits = session?.simulation.fighters.map(\.hitSerial) ?? []
        priorStocks = session?.simulation.fighters.map(\.stocks) ?? []
        lastFrame = -1
        // Artwork layers are decoded once; rig nodes and platform geometry are reused per frame.
        if let image = session?.arenaBackground {
            let backdrop = SKSpriteNode(texture: SKTexture(image: image))
            backdropNode = backdrop
            backdrop.size = CGSize(width: 1280, height: 790); backdrop.position = CGPoint(x: 500, y: 305); backdrop.zPosition = -50
            addChild(backdrop)
            let veil = SKSpriteNode(color: NSColor(white: 0.05, alpha: 0.18), size: CGSize(width: 1280, height: 790))
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
        if let image = session?.midgroundArtwork {
            let layer = SKNode(); layer.zPosition = -25
            let islands = SKSpriteNode(texture: SKTexture(image: image))
            islands.size = CGSize(width: 1100, height: 670); islands.position = CGPoint(x: 500, y: 285)
            islands.alpha = 0.75; layer.addChild(islands); addChild(layer); depthLayers.append((layer, 1.25))
        }
        // Separate vector silhouettes move at different depths; the arena stays fixed.
        for layer in 0..<2 {
            let node = SKNode(); node.zPosition = layer == 0 ? -20 : 22
            for side in [0, 1] {
                let x = side == 0 ? -35.0 : 1005.0
                let vine = shape([CGPoint(x: x, y: 0), CGPoint(x: x + 25, y: Double(220 + layer * 100)),
                                  CGPoint(x: x + 55, y: 0)], color: NSColor(white: 0.06 + Double(layer) * 0.02, alpha: 0.8))
                node.addChild(vine)
                for leaf in 0..<6 {
                    let frond = SKShapeNode(ellipseOf: CGSize(width: 70, height: 15))
                    frond.fillColor = NSColor(calibratedRed: 0.13, green: 0.17, blue: 0.15, alpha: 0.65)
                    frond.strokeColor = .clear; frond.position = CGPoint(x: x + 22, y: Double(35 + leaf * 30))
                    frond.zRotation = Double(leaf % 2 == 0 ? 1 : -1) * 0.5
                    node.addChild(frond)
                }
            }
            addChild(node); depthLayers.append((node, CGFloat(layer + 1)))
        }
        let ring = SKShapeNode(ellipseOf: CGSize(width: 680, height: 145))
        ring.position = CGPoint(x: 500, y: 112); ring.strokeColor = mint.withAlphaComponent(0.12); ring.lineWidth = 2; addChild(ring)
        for (index, platform) in (session?.simulation.arenaPlatforms ?? ArenaSimulation.platforms).enumerated() {
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
        _ = label(session?.simulation.map.title ?? "Hollow Observatory", x: 500, y: 40, size: 10, color: mint.withAlphaComponent(0.4))
        for (i, fighter) in (session?.simulation.fighters ?? []).enumerated() {
            let color = NSColor(ArenaAppearance.playerColor(i))
            let shadow = SKShapeNode(ellipseOf: CGSize(width: 46, height: 9))
            shadow.fillColor = NSColor.black.withAlphaComponent(0.5); shadow.strokeColor = .clear
            shadow.zPosition = 3; addChild(shadow); shadows.append(shadow)
            let body = SKNode(); body.zPosition = 10
            let rig = ArenaFighterRig(kind: fighter.kind, color: color)
            body.addChild(rig); rigs.append(rig)
            let shield = SKShapeNode(circleOfRadius: 44); shield.position.y = 35; shield.strokeColor = color
            shield.lineWidth = 2; shield.glowWidth = 1; body.addChild(shield); shields.append(shield)
            addChild(body); bodies.append(body)
            let slot = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
            slot.text = "P\(i + 1)"; slot.fontSize = 11; slot.fontColor = color; slot.position.y = 104
            body.addChild(slot)
        }
        for y in [24.0, 586.0] {
            let bar = SKSpriteNode(color: .black.withAlphaComponent(0.7), size: CGSize(width: 1000, height: 48))
            bar.position = CGPoint(x: 0, y: y - 305); bar.zPosition = 40; worldCamera.addChild(bar); cinematicBars.append(bar)
        }
        introTitle.position = CGPoint(x: 0, y: 190); introTitle.fontSize = 24; introTitle.zPosition = 41; worldCamera.addChild(introTitle)
        introNames.position = CGPoint(x: 0, y: 157); introNames.fontSize = 14; introNames.fontColor = .white.withAlphaComponent(0.7)
        introNames.zPosition = 41; worldCamera.addChild(introNames)
        announcement.position = CGPoint(x: 0, y: 102); announcement.fontSize = 54; announcement.zPosition = 30; worldCamera.addChild(announcement)
        clockLabel.position = CGPoint(x: 0, y: 244); clockLabel.fontSize = 20; worldCamera.addChild(clockLabel)
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
        guard !sim.fighters.isEmpty else { return }
        if bodies.count != sim.fighters.count || builtMap != sim.map { buildWorld() }
        let motion = session.effectsEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let centre = sim.fighters.map(\.x).reduce(0, +) / Double(sim.fighters.count)
        if motion {
            let alive = sim.fighters.filter { $0.stocks > 0 && $0.respawn == 0 }
            let minX = alive.map(\.x).min() ?? 350, maxX = alive.map(\.x).max() ?? 650
            let targetX = min(550, max(450, (minX + maxX) / 2))
            let targetScale = sim.countdown > 0 ? 1 + Double(sim.countdown) / 180 * 0.08 : min(1.12, max(1, (maxX - minX) / 800))
            worldCamera.position.x += (targetX - worldCamera.position.x) * 0.04
            worldCamera.setScale(worldCamera.xScale + (targetScale - worldCamera.xScale) * 0.04)
        } else {
            worldCamera.position = CGPoint(x: 500, y: 305); worldCamera.setScale(1)
        }
        let offset = motion ? min(32, max(-32, (centre - 500) * 0.11)) : 0
        backdropNode?.position = CGPoint(x: 500 - offset * 0.35, y: 305 + (motion ? sin(currentTime * 0.18) * 3 : 0))
        for (node, depth) in depthLayers {
            node.position.x = -offset * depth + (motion ? sin(currentTime * 0.3) * depth * 2 : 0)
        }
        let introAlpha = sim.countdown > 0 ? min(1, Double(sim.countdown) / 30) : 0
        cinematicBars.forEach { $0.alpha = introAlpha }
        introTitle.text = sim.map.title
        introNames.text = session.playerNames.map { String($0.prefix(16)) }.joined(separator: "   ·   ")
        introTitle.alpha = introAlpha; introNames.alpha = introAlpha
        let changed = sim.frame != lastFrame
        lastFrame = sim.frame
        for i in sim.fighters.indices {
            let f = sim.fighters[i], body = bodies[i]
            let target = CGPoint(x: f.x, y: f.y)
            // Smooth remote snapshots without extrapolating authoritative game state.
            if session.mode == .guest && hypot(body.position.x - target.x, body.position.y - target.y) < 140 {
                body.position.x += (target.x - body.position.x) * 0.55
                body.position.y += (target.y - body.position.y) * 0.55
            } else { body.position = target }
            let ground = sim.arenaPlatforms.filter { f.x >= $0.left && f.x <= $0.right && $0.top <= f.y + 1 }.map(\.top).max()
            shadows[i].isHidden = ground == nil || f.respawn > 0 || f.stocks == 0
            if let ground {
                let height = max(0, f.y - ground)
                shadows[i].position = CGPoint(x: f.x, y: ground + 2)
                shadows[i].xScale = max(0.35, 1 - height / 500)
                shadows[i].alpha = max(0.12, 0.65 - height / 600)
            }
            body.xScale = f.facing * (f.kind == .atlas ? 1.16 : 1)
            body.yScale = f.kind == .atlas ? 1.08 : 1
            body.isHidden = f.respawn > 0 || f.stocks == 0
            body.alpha = f.invulnerable > 0 && sim.frame % 12 < 6 ? 0.45 : 1
            rigs[i].update(fighter: f, frame: sim.frame, reducedMotion: !motion)
            shields[i].isHidden = f.invulnerable == 0
            if changed && f.attackFrames > 0 && (f.attackAge == 2 || sim.attackActive(i) && f.attackAge % 3 == 0) {
                let box = sim.attackCenter(i)
                let arc = SKShapeNode(circleOfRadius: box.radius)
                arc.position = CGPoint(x: box.x, y: box.y); arc.strokeColor = NSColor(ArenaAppearance.playerColor(i)).withAlphaComponent(sim.attackActive(i) ? 0.8 : 0.25)
                arc.lineWidth = sim.attackActive(i) ? 5 : 1; arc.xScale = 0.7
                effects.addChild(arc); arc.run(.sequence([.group([.fadeOut(withDuration: 0.18), .scale(to: 1.25, duration: 0.18)]), .removeFromParent()]))
            }
            if f.hitSerial != priorHits[i] {
                burst(at: CGPoint(x: f.x, y: f.y + 28), color: .white, count: 12)
                priorHits[i] = f.hitSerial
            }
            if f.stocks < priorStocks[i] {
                burst(at: CGPoint(x: min(960, max(40, f.x)), y: min(480, max(50, f.y))), color: NSColor(ArenaAppearance.playerColor(i)), count: 24)
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

private struct ArenaMapThumbnail: View {
    let map: ArenaMap
    let selected: Bool
    var body: some View {
        Canvas { context, size in
            for platform in map.platforms {
                let rect = CGRect(x: platform.left / 1000 * size.width, y: (1 - platform.top / 500) * size.height,
                                  width: (platform.right - platform.left) / 1000 * size.width, height: 3)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(selected ? ArenaAppearance.accent : .gray))
            }
        }.background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 6)).accessibilityHidden(true)
    }
}
