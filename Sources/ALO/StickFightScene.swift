import AppKit
import SpriteKit
import SwiftUI
import ALOCore

struct StickFightSurface: NSViewRepresentable {
    let session: StickFightSession
    let inputBlocked: Bool
    var soundEnabled = true
    func makeNSView(context: Context) -> StickFightSKView {
        let view = StickFightSKView()
        view.session = session; view.preferredFramesPerSecond = 60; view.ignoresSiblingOrder = true
        let scene = StickFightScene(session: session); scene.soundEnabled = soundEnabled; scene.scaleMode = .aspectFit; view.presentScene(scene)
        view.setAccessibilityLabel("Stick Fight arena. Click to focus. A and D move, Space jumps, J punches, K shoots, L blocks. Escape opens menu.")
        return view
    }
    func updateNSView(_ view: StickFightSKView, context: Context) { view.setBlocked(inputBlocked); (view.scene as? StickFightScene)?.soundEnabled = soundEnabled }
    static func dismantleNSView(_ view: StickFightSKView, coordinator: ()) { view.resetInput(); view.presentScene(nil) }
}

final class StickFightSKView: SKView {
    weak var session: StickFightSession?
    private var keys: Set<UInt16> = []
    private var blocked = false
    private var leftMouse = false
    private var rightMouse = false
    private var mouseAim: Double?
    private var mouseTracking: NSTrackingArea?
    private var requestedFocus = false
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard !blocked, session?.mode != .spectator else { return }
        window?.makeFirstResponder(self); leftMouse = true; updateAim(event); sendInput()
    }
    override func mouseUp(with event: NSEvent) { leftMouse = false; sendInput() }
    override func rightMouseDown(with event: NSEvent) { guard !blocked else { return }; window?.makeFirstResponder(self); rightMouse = true; updateAim(event); sendInput() }
    override func rightMouseUp(with event: NSEvent) { rightMouse = false; sendInput() }
    override func mouseMoved(with event: NSEvent) { guard window?.firstResponder === self else { return }; updateAim(event); sendInput() }
    override func mouseDragged(with event: NSEvent) { updateAim(event); sendInput() }
    override func rightMouseDragged(with event: NSEvent) { updateAim(event); sendInput() }
    private func updateAim(_ event: NSEvent) {
        guard let scene, let session, session.simulation.fighters.indices.contains(session.localIndex) else { return }
        let point = scene.convertPoint(fromView: convert(event.locationInWindow, from: nil))
        let fighter = session.simulation.fighters[session.localIndex]
        mouseAim = atan2(point.y - fighter.y - 30, point.x - fighter.x)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let mouseTracking { removeTrackingArea(mouseTracking) }
        let tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking); mouseTracking = tracking
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
        if event.keyCode == 53 { if !event.isARepeat { resetInput(); session?.togglePause() }; return }
        if event.keyCode == 48 { resetInput(); super.keyDown(with: event); return }
        guard !blocked else { return }
        keys.insert(event.keyCode); sendInput()
    }
    override func keyUp(with event: NSEvent) { keys.remove(event.keyCode); sendInput() }
    override func resignFirstResponder() -> Bool { resetInput(); return super.resignFirstResponder() }
    func resetInput() { keys.removeAll(); leftMouse = false; rightMouse = false; mouseAim = nil; session?.clearInput() }
    private func sendInput() {
        guard !blocked else { resetInput(); return }
        var input = StickFightInput()
        input.horizontal = (keys.contains(2) || keys.contains(124) ? 1 : 0) - (keys.contains(0) || keys.contains(123) ? 1 : 0)
        input.aimY = (keys.contains(13) || keys.contains(126) ? 1 : 0) - (keys.contains(1) || keys.contains(125) ? 1 : 0)
        input.jump = keys.contains(49) || keys.contains(13) || keys.contains(126); input.punch = keys.contains(38) || leftMouse; input.shoot = keys.contains(40) || leftMouse; input.block = keys.contains(37) || rightMouse
        input.aimAngle = mouseAim; input.throwWeapon = keys.contains(3)
        session?.setInput(input)
    }
    func setBlocked(_ value: Bool) {
        let restore = blocked && !value
        blocked = value
        if value { resetInput() }
        if !requestedFocus || restore { requestedFocus = true; requestFocus() }
        isPaused = window.map { !$0.occlusionState.contains(.visible) } ?? false
    }
    private func requestFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.isKeyWindow, NSApp.isActive,
                  !self.blocked, self.session?.mode != .spectator, !self.isHiddenOrHasHiddenAncestor else { return }
            window.makeFirstResponder(self)
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); NotificationCenter.default.removeObserver(self)
        guard let window else { resetInput(); return }
        NotificationCenter.default.addObserver(self, selector: #selector(lostFocus), name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged), name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(lostFocus), name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged), name: NSWindow.didChangeOcclusionStateNotification, object: window)
        visibilityChanged(); requestFocus()
    }
    @objc private func lostFocus() {
        resetInput()
        if session?.mode == .practice, session?.showsMenu == false { session?.togglePause() }
    }
    @objc private func visibilityChanged() { isPaused = window.map { !$0.occlusionState.contains(.visible) } ?? false; if isPaused { lostFocus() } }
    override func viewDidHide() { super.viewDidHide(); lostFocus(); isPaused = true }
    override func viewDidUnhide() { super.viewDidUnhide(); visibilityChanged() }
    deinit { NotificationCenter.default.removeObserver(self) }
}

final class StickFightScene: SKScene {
    private weak var session: StickFightSession?
    private var builtMap: StickFightMap?
    private let terrain = SKNode(), actors = SKNode(), effects = SKNode(), objects = SKNode()
    private var rigs: [StickFightRig] = []
    private var hits: [Int] = [], alive: [Bool] = []
    private var shadows: [SKSpriteNode] = []
    private let sceneCamera = SKCameraNode()
    private var shake = 0.0
    private var shots: [Int: SKNode] = [:], drops: [Int: SKNode] = [:]
    private let movingHazardLayer = SKNode()
    private var hazardNodes: [(SKShapeNode, SKShapeNode, SKShapeNode)] = []
    private let announcement = SKLabelNode(fontNamed: "AvenirNext-Heavy")
    private let subtitle = SKLabelNode(fontNamed: "AvenirNext-Medium")
    private let roundLabel = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
    var soundEnabled = true { didSet { if !soundEnabled { sound.stop() } } }
    private let sound = ArenaSoundPlayer()
    private var ragdolls: [StickFightRagdoll] = []
    private var lastRenderTime: TimeInterval?
    private var lastSoundTime: TimeInterval = 0
    private var lastRound = -1
    private var snapshotFrame = -1
    private var snapshotTime: TimeInterval = 0
    private let focusHint = SKLabelNode(fontNamed: "AvenirNext-Medium")
    private let stone = NSColor(calibratedRed: 0.025, green: 0.045, blue: 0.105, alpha: 1)
    private var trim: NSColor { builtMap == .frostfall ? NSColor(calibratedRed: 0.75, green: 0.91, blue: 0.89, alpha: 1) : builtMap == .foundry ? NSColor(calibratedRed: 0.85, green: 0.46, blue: 0.13, alpha: 1) : NSColor(calibratedRed: 0.69, green: 0.035, blue: 0.19, alpha: 1) }
    init(session: StickFightSession) {
        self.session = session
        super.init(size: CGSize(width: 1000, height: 600))
        backgroundColor = NSColor(calibratedRed: 0.27, green: 0.28, blue: 0.25, alpha: 1)
        sceneCamera.position = CGPoint(x: 500, y: 300); camera = sceneCamera; addChild(sceneCamera)
        terrain.zPosition = -5; addChild(terrain)
        movingHazardLayer.zPosition = 6; addChild(movingHazardLayer)
        actors.zPosition = 10; addChild(actors); objects.zPosition = 8; addChild(objects); effects.zPosition = 20; addChild(effects)
        announcement.position = CGPoint(x: 500, y: 375); announcement.fontSize = 48; announcement.zPosition = 40; addChild(announcement)
        subtitle.position = CGPoint(x: 500, y: 348); subtitle.fontSize = 12; subtitle.fontColor = .white.withAlphaComponent(0.7); subtitle.zPosition = 40; addChild(subtitle)
        roundLabel.position = CGPoint(x: 500, y: 574); roundLabel.fontSize = 11; roundLabel.fontColor = .white.withAlphaComponent(0.6); roundLabel.zPosition = 40; addChild(roundLabel)
        focusHint.position = CGPoint(x: 500, y: 552); focusHint.fontSize = 11; focusHint.fontColor = .white.withAlphaComponent(0.65); focusHint.zPosition = 40; addChild(focusHint)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMove(to view: SKView) {
        super.didMove(to: view)
        if let session { build(session.simulation.map) }
        update(ProcessInfo.processInfo.systemUptime)
    }
    private func polygon(_ points: [CGPoint], fill: NSColor) -> SKShapeNode {
        let p = CGMutablePath(); p.addLines(between: points); p.closeSubpath()
        let n = SKShapeNode(path: p); n.fillColor = fill; n.strokeColor = .clear; return n
    }
    private static func softTexture(color: NSColor) -> SKTexture {
        let color = color.usingColorSpace(.deviceRGB) ?? color
        let context = CGContext(data:nil,width:128,height:128,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray
        let gradient = CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:colors,locations:[0,1])!
        context.drawRadialGradient(gradient,startCenter:CGPoint(x:64,y:64),startRadius:0,endCenter:CGPoint(x:64,y:64),endRadius:64,options:[])
        return SKTexture(cgImage:context.makeImage()!)
    }
    private static func backdropTexture(cold: Bool, hot: Bool) -> SKTexture {
        let context = CGContext(data:nil,width:1000,height:600,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        let top = cold ? NSColor(calibratedRed:0.035,green:0.14,blue:0.21,alpha:1) : NSColor(calibratedRed:0.07,green:0.12,blue:0.16,alpha:1)
        let bottom = cold ? NSColor(calibratedRed:0.42,green:0.58,blue:0.61,alpha:1) : NSColor(calibratedRed:hot ? 0.46 : 0.43,green:hot ? 0.30 : 0.42,blue:0.28,alpha:1)
        let gradient = CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:[bottom.cgColor,top.cgColor] as CFArray,locations:[0,1])!
        context.drawLinearGradient(gradient,start:.zero,end:CGPoint(x:0,y:600),options:[])
        let light = NSColor(calibratedRed:cold ? 0.65 : 1,green:cold ? 0.84 : 0.89,blue:cold ? 0.92 : 0.62,alpha:0.24)
        let halo = CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:[light.cgColor,light.withAlphaComponent(0).cgColor] as CFArray,locations:[0,1])!
        context.drawRadialGradient(halo,startCenter:CGPoint(x:645,y:445),startRadius:0,endCenter:CGPoint(x:645,y:445),endRadius:300,options:[])
        context.setFillColor(light.withAlphaComponent(0.18).cgColor); context.fillEllipse(in:CGRect(x:602,y:417,width:90,height:90))
        return SKTexture(cgImage:context.makeImage()!)
    }
    private func build(_ map: StickFightMap) {
        builtMap = map; terrain.removeAllChildren(); effects.removeAllChildren()
        let cold = map == .frostfall, hot = map == .foundry
        let sky = Self.backdropTexture(cold: cold, hot: hot)
        let skyNode = SKSpriteNode(texture: sky); skyNode.size = size; skyNode.position = CGPoint(x:500,y:300); skyNode.zPosition = -20; terrain.addChild(skyNode)
        // Long irregular, curved silhouettes create depth without repeating tiles.
        for layer in 0..<5 {
            let path = CGMutablePath(); path.move(to: CGPoint(x:-60,y:-20))
            var last = CGPoint(x:-60,y:Double(470 - layer * 69))
            path.addLine(to:last)
            for i in 1...10 {
                let x = Double(i) * 124 - 60
                let y = Double(460 - layer * 68) + sin(Double(i) * 1.73 + Double(layer) * 2.7) * 87 + cos(Double(i) * 0.81 + Double(layer)) * 41
                let next = CGPoint(x:x,y:y)
                path.addCurve(to:next,control1:CGPoint(x:last.x + 24,y:last.y - 2),control2:CGPoint(x:next.x - 39,y:next.y + 15))
                last = next
            }
            path.addLine(to:CGPoint(x:1120,y:-20)); path.closeSubpath()
            let mountain = SKShapeNode(path:path)
            let t = Double(layer)
            mountain.fillColor = cold ? NSColor(calibratedRed:0.21 - t * 0.025,green:0.35 - t * 0.032,blue:0.41 - t * 0.031,alpha:1) : NSColor(calibratedRed:0.39 - t * 0.042,green:0.39 - t * 0.044,blue:0.32 - t * 0.031,alpha:1)
            mountain.strokeColor = .clear; mountain.zPosition = -15 + CGFloat(layer); terrain.addChild(mountain)
        }
        let glow = SKSpriteNode(texture:Self.softTexture(color:NSColor(calibratedRed:cold ? 0.63 : 1,green:cold ? 0.83 : 0.78,blue:cold ? 0.91 : 0.43,alpha:0.16)))
        glow.size = CGSize(width:850,height:360); glow.position = CGPoint(x:600,y:360); glow.zPosition = -9; terrain.addChild(glow)
        for i in 0..<25 {
            let mote = SKShapeNode(circleOfRadius:i % 4 == 0 ? 1.2 : 0.6); mote.fillColor = NSColor(calibratedRed:1,green:0.82,blue:0.55,alpha:0.14 + Double(i % 3) * 0.05); mote.strokeColor = .clear
            mote.position = CGPoint(x:(i * 137 + 38) % 1000,y:(i * 97 + 65) % 520); mote.zPosition = -8; terrain.addChild(mote)
        }
        if hot { addFoundryBackdrop() }
        for (index, p) in map.platforms.enumerated() {
            let block = SKShapeNode(rect: CGRect(x: p.left, y: p.bottom, width: p.right - p.left, height: p.top - p.bottom)); block.fillColor = stone; block.strokeColor = .clear; terrain.addChild(block)
            let height = p.top - p.bottom
            terrain.addChild(polygon([CGPoint(x:p.left,y:p.top - 7),CGPoint(x:p.right,y:p.top - 7),CGPoint(x:p.right - 8,y:p.top - min(19,height)),CGPoint(x:p.left + 7,y:p.top - min(19,height))],fill:NSColor(calibratedRed:0.11,green:0.14,blue:0.18,alpha:1)))
            terrain.addChild(polygon([CGPoint(x:p.left,y:p.top - 8),CGPoint(x:p.left + 8,y:p.top - 17),CGPoint(x:p.left + 8,y:p.bottom),CGPoint(x:p.left,y:p.bottom)],fill:NSColor(calibratedRed:0.10,green:0.13,blue:0.18,alpha:1)))
            let underside = SKSpriteNode(texture:Self.softTexture(color:NSColor.black.withAlphaComponent(0.55)))
            underside.size = CGSize(width:p.right - p.left + 30,height:40); underside.position = CGPoint(x:(p.left+p.right)/2,y:p.bottom - 6); underside.zPosition = -0.1; terrain.addChild(underside)
            for chip in 0..<Int((p.right - p.left) / 9) {
                let x = p.left + Double(chip) * 9 + sin(Double(chip) * 4) * 3
                let y = p.top - 15 - Double((chip * 17 + index * 11) % max(1,Int(height - 19)))
                let seam = SKShapeNode(rect:CGRect(x:x,y:y,width:Double(2 + chip % 7),height:1))
                seam.fillColor = NSColor(white:0.55,alpha:0.07); seam.strokeColor = .clear; terrain.addChild(seam)
            }
            for tuft in 0..<(hot ? 0 : Int((p.right - p.left) / 18)) {
                let x = p.left + 8 + Double(tuft) * 18
                let h = Double(3 + (tuft * 13 + index * 7) % 8)
                terrain.addChild(polygon([CGPoint(x:x-5,y:p.top-1),CGPoint(x:x-4,y:p.top+h),CGPoint(x:x,y:p.top+2),CGPoint(x:x+3,y:p.top+h*0.7),CGPoint(x:x+6,y:p.top)],fill:trim))
            }
            var rim = [CGPoint(x: p.left, y: p.top - 5)]
            for x in stride(from: p.left, through: p.right, by: 8.0) { rim.append(CGPoint(x: x, y: p.top + sin(x * 0.09) * 2.3)) }
            rim.append(CGPoint(x: p.right, y: p.top - 8)); terrain.addChild(polygon(rim, fill: trim))
            let rows = max(1, min(6, Int((p.top - p.bottom) / 36)))
            for brick in 0..<(rows * 3) {
                let x = p.left + 15 + Double((brick * 47 + index * 23) % max(1, Int(p.right - p.left - 38)))
                let y = p.top - 22 - Double(brick / 3) * 34
                if y > p.bottom + 10 {
                    let brickNode = SKShapeNode(rectOf: CGSize(width: 20 + brick % 3 * 5, height: 9), cornerRadius: 2)
                    brickNode.position = CGPoint(x: x, y: y); brickNode.fillColor = NSColor(white: 0.40, alpha: 0.35); brickNode.strokeColor = NSColor.white.withAlphaComponent(0.045); brickNode.lineWidth = 0.7; terrain.addChild(brickNode)
                }
            }
        }
        for hazard in map.spikes {
            let width = hazard.right - hazard.left, height = hazard.top - hazard.bottom
            if width >= height {
                for x in stride(from: hazard.left, to: hazard.right, by: 25.0) {
                    terrain.addChild(polygon([CGPoint(x: x, y: hazard.bottom), CGPoint(x: min(x + 13, hazard.right), y: hazard.top), CGPoint(x: min(x + 25, hazard.right), y: hazard.bottom)], fill: stone))
                }
            } else {
                terrain.addChild(polygon([CGPoint(x: hazard.left, y: hazard.bottom), CGPoint(x: hazard.right, y: (hazard.top + hazard.bottom) / 2), CGPoint(x: hazard.left, y: hazard.top)], fill: stone))
            }
        }
        if !hot, let p = map.platforms.first {
            let x = p.left + (p.right - p.left) * 0.30
            let trunk = polygon([CGPoint(x: x - 8, y: p.top), CGPoint(x: x - 5, y: p.top + 108), CGPoint(x: x + 3, y: p.top + 115), CGPoint(x: x + 9, y: p.top)], fill: NSColor(calibratedRed: 0.20, green: 0.12, blue: 0.15, alpha: 1)); terrain.addChild(trunk)
            for branch in 0..<5 {
                let origin = CGPoint(x:x,y:p.top + 34 + Double(branch)*16)
                let end = CGPoint(x:x + (branch % 2 == 0 ? -1.0 : 1.0) * Double(17 + branch*3),y:origin.y+24)
                let path = CGMutablePath(); path.move(to:origin); path.addQuadCurve(to:end,control:CGPoint(x:end.x,y:origin.y+4))
                let twig = SKShapeNode(path:path); twig.strokeColor = NSColor(calibratedRed:0.21,green:0.14,blue:0.17,alpha:1); twig.lineWidth = CGFloat(4 - branch/2); twig.lineCap = .round; terrain.addChild(twig)
            }
            for i in 0..<24 {
                let cx = x + sin(Double(i)*2.39996) * Double(8 + i % 6 * 7)
                let cy = p.top + 112 + cos(Double(i)*2.39996) * Double(12 + i % 5 * 8)
                let path = CGMutablePath()
                for j in 0..<11 {
                    let angle = Double(j) / 11 * Double.pi*2
                    let radius = Double(15+i%4*3) * (0.88 + sin(Double(j*7+i))*0.12)
                    let pt = CGPoint(x:cx+cos(angle)*radius,y:cy+sin(angle)*radius)
                    if j == 0 { path.move(to:pt) } else { path.addLine(to:pt) }
                }
                path.closeSubpath()
                let leaf = SKShapeNode(path:path); leaf.fillColor = trim.blended(withFraction:CGFloat(i % 3)*0.07,of:i % 2 == 0 ? .black : .white)!; leaf.strokeColor = .clear; terrain.addChild(leaf)
            }
            for i in 0..<12 {
                let leaf = SKShapeNode(ellipseOf:CGSize(width:4,height:1.6)); leaf.fillColor = trim.withAlphaComponent(0.7); leaf.strokeColor = .clear
                leaf.position = CGPoint(x:x+sin(Double(i)*5)*55,y:p.top+20+Double(i)*7); leaf.zRotation = Double(i)*0.8; terrain.addChild(leaf)
            }

        }
    }
    private func addFoundryBackdrop() {
        let steel = NSColor(calibratedRed: 0.09, green: 0.115, blue: 0.12, alpha: 0.7)
        let distant = SKNode(); distant.zPosition = -7; terrain.addChild(distant)
        for i in 0..<6 {
            let x = Double(i) * 195 - 45
            let top = Double(195 + (i * 47) % 130)
            let tower = SKShapeNode(rect: CGRect(x: x, y: 0, width: 100, height: top))
            tower.fillColor = steel; tower.strokeColor = .clear; distant.addChild(tower)
            let chimney = SKShapeNode(rect: CGRect(x: x + 25, y: top, width: 19, height: 85))
            chimney.fillColor = steel; chimney.strokeColor = .clear; distant.addChild(chimney)
            for row in 0..<4 {
                for col in 0..<3 {
                    let window = SKShapeNode(rect: CGRect(x: x + 13 + Double(col)*27, y: top - 24 - Double(row)*32, width: 12, height: 18))
                    window.fillColor = NSColor(calibratedRed: 0.86, green: 0.43, blue: 0.14, alpha: 0.13 + Double((row+col+i)%3)*0.055)
                    window.strokeColor = .clear; distant.addChild(window)
                }
            }
        }
        let frame = SKNode(); frame.zPosition = -3; terrain.addChild(frame)
        for x in [22.0, 958.0] {
            let column = SKShapeNode(rect: CGRect(x: x, y: 90, width: 20, height: 510))
            column.fillColor = steel; column.strokeColor = .clear; frame.addChild(column)
            for y in stride(from: 140.0, through: 590.0, by: 66.0) {
                let bolt = SKShapeNode(circleOfRadius: 2.5); bolt.position = CGPoint(x: x+10,y:y)
                bolt.fillColor = NSColor(white: 0.45, alpha: 0.5); bolt.strokeColor = .clear; frame.addChild(bolt)
            }
        }
        let beam = SKShapeNode(rect: CGRect(x: 0, y: 585, width: 1000, height: 15)); beam.fillColor = steel; beam.strokeColor = .clear; frame.addChild(beam)
        for x in stride(from: 35.0, through: 950.0, by: 92.0) {
            let p = CGMutablePath(); p.move(to: CGPoint(x:x,y:585)); p.addLine(to: CGPoint(x:x+40,y:558)); p.addLine(to: CGPoint(x:x+80,y:585))
            let brace = SKShapeNode(path: p); brace.strokeColor = steel; brace.lineWidth = 6; frame.addChild(brace)
        }
        let furnace = SKShapeNode(rect: CGRect(x: 310, y: 120, width: 84, height: 86), cornerRadius: 6)
        furnace.fillColor = NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.12, alpha: 1); furnace.strokeColor = NSColor(white:0.3,alpha:0.45); frame.addChild(furnace)
        let glow = SKSpriteNode(texture: Self.softTexture(color: NSColor(calibratedRed: 1, green: 0.36, blue: 0.04, alpha: 0.45)))
        glow.position = CGPoint(x:352,y:153); glow.size = CGSize(width:155,height:100); frame.addChild(glow)
        for bar in 0..<6 {
            let grate = SKShapeNode(rect: CGRect(x: 324 + Double(bar)*10, y: 133, width: 5, height: 33))
            grate.fillColor = NSColor(calibratedRed:0.055,green:0.07,blue:0.075,alpha:1); grate.strokeColor = .clear; frame.addChild(grate)
        }
    }

    override func update(_ currentTime: TimeInterval) {
        guard let session else { return }
        let sim = session.simulation
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            shake *= 0.79; sceneCamera.position = CGPoint(x: 500 + sin(currentTime * 113) * shake, y: 300 + cos(currentTime * 97) * shake * 0.6)
        } else { sceneCamera.position = CGPoint(x:500,y:300) }
        focusHint.text = session.mode == .spectator || session.showsMenu || view?.window?.firstResponder === view ? "" : "CLICK THE ARENA TO PLAY"
        if builtMap != sim.map { build(sim.map) }
        if rigs.count != sim.fighters.count {
            actors.removeAllChildren(); shadows.removeAll()
            rigs = sim.fighters.indices.map { index in
                let shadow = SKSpriteNode(texture: Self.softTexture(color: NSColor.black.withAlphaComponent(0.6)))
                shadow.size = CGSize(width: 45, height: 11); shadow.zPosition = -1; actors.addChild(shadow); shadows.append(shadow)
                let rig = StickFightRig(color: StickFightPalette.native(index)); actors.addChild(rig); return rig
            }
            hits = sim.fighters.map(\.hitSerial); alive = sim.fighters.map(\.alive)
        }
        if lastRound != sim.round { lastRound = sim.round; effects.removeAllChildren(); ragdolls.removeAll() }
        let elapsed = session.mode == .practice && session.showsMenu ? 0 : min(0.05, max(0, currentTime - (lastRenderTime ?? currentTime)))
        lastRenderTime = currentTime
        for doll in ragdolls { doll.advance(elapsed, platforms: sim.map.platforms) }
        ragdolls.removeAll { if $0.finished { $0.removeFromParent(); return true }; return false }
        if sim.frame != snapshotFrame { snapshotFrame = sim.frame; snapshotTime = currentTime }
        let remoteAge = min(GameRealtimePolicy.snapshotInterval, max(0, currentTime - snapshotTime))
        let leader = sim.fighters.map(\.wins).max() ?? 0
        for i in sim.fighters.indices {
            let f = sim.fighters[i]
            let remote = session.mode == .spectator || (session.mode == .guest && i != session.localIndex)
            let moving = sim.countdown == 0 && sim.roundOverFrames == 0 && sim.winner == nil
            let age = remote && moving ? remoteAge : 0
            let displayed = session.presentationPosition(for: i, at: currentTime)
            rigs[i].position = CGPoint(x: displayed.x, y: displayed.y)
            let ground = sim.map.platforms.filter { f.x >= $0.left && f.x <= $0.right && $0.top <= f.y + 2 }.map(\.top).max()
            shadows[i].isHidden = !f.alive || ground == nil
            if let ground {
                let elevation = max(0, f.y - ground)
                shadows[i].position = CGPoint(x: f.x, y: ground + 1)
                shadows[i].alpha = max(0.08, 0.72 - elevation / 260); shadows[i].xScale = max(0.3, 1 - elevation / 420)
            }
            rigs[i].render(f, time: Double(sim.frame) * StickFightSimulation.step + age, crown: leader > 0 && f.wins == leader)
            if f.hitSerial != hits[i] { burst(CGPoint(x: f.x, y: f.y + 24), color: .white, count: 10, velocity: CGVector(dx: f.vx, dy: f.vy)); hits[i] = f.hitSerial; playImpact(false, time: currentTime) }
            if alive[i] && !f.alive {
                burst(CGPoint(x: min(980, max(20, f.x)), y: max(20, f.y + 20)), color: StickFightPalette.native(i), count: 20, velocity: CGVector(dx: f.vx, dy: f.vy))
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    let doll = StickFightRagdoll(fighter: f, color: StickFightPalette.native(i)); effects.addChild(doll); ragdolls.append(doll)
                }
                playImpact(true, time: currentTime)
            }
            alive[i] = f.alive
        }
        if hazardNodes.count != sim.movingHazards.count {
            movingHazardLayer.removeAllChildren(); hazardNodes.removeAll()
            for _ in sim.movingHazards {
                let chain = SKShapeNode(), disk = SKShapeNode(), hub = SKShapeNode(circleOfRadius: 5)
                chain.strokeColor = stone; chain.lineWidth = 6; disk.fillColor = stone; disk.strokeColor = .clear
                hub.fillColor = trim; hub.strokeColor = .clear
                movingHazardLayer.addChild(chain); movingHazardLayer.addChild(disk); movingHazardLayer.addChild(hub)
                hazardNodes.append((chain, disk, hub))
            }
        }
        for (index, hazard) in sim.movingHazards.enumerated() {
            let (chain, disk, hub) = hazardNodes[index]
            let chainPath = CGMutablePath()
            chainPath.move(to: CGPoint(x: hazard.pivotX, y: hazard.pivotY)); chainPath.addLine(to: CGPoint(x: hazard.x, y: hazard.y))
            chain.path = chainPath
            let teeth = CGMutablePath()
            for i in 0..<32 {
                let angle = Double(i) * Double.pi / 16, radius = hazard.radius * (i % 2 == 0 ? 1 : 0.8)
                let point = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
                if i == 0 { teeth.move(to: point) } else { teeth.addLine(to: point) }
            }
            teeth.closeSubpath(); disk.path = teeth; disk.position = CGPoint(x: hazard.x, y: hazard.y)
            disk.zRotation = atan2(hazard.x - hazard.pivotX, hazard.pivotY - hazard.y)
            hub.position = disk.position
        }
        let liveShots = Set(sim.projectiles.map(\.id))
        for id in Array(shots.keys) where !liveShots.contains(id) { shots.removeValue(forKey: id)?.removeFromParent() }
        for p in sim.projectiles {
            let node: SKNode
            if let existing = shots[p.id] { node = existing } else {
                let s = SKNode()
                let core = SKShapeNode(rectOf: CGSize(width: p.thrown ? 22 : 11, height: p.thrown ? 6 : 2.5), cornerRadius: 1)
                core.fillColor = p.thrown ? NSColor(white:0.40,alpha:1) : .white; core.strokeColor = StickFightPalette.native(p.owner); core.lineWidth = 0.5; s.addChild(core)
                if p.thrown {
                    let grip = SKShapeNode(rect:CGRect(x:-4,y:-9,width:5,height:7),cornerRadius:1); grip.fillColor = NSColor(white:0.23,alpha:1); grip.strokeColor = .clear; s.addChild(grip)
                } else {
                    let trail = SKShapeNode(); let path = CGMutablePath(); path.addLines(between:[CGPoint(x:2,y:1),CGPoint(x:-27,y:0),CGPoint(x:2,y:-1)]); path.closeSubpath()
                    trail.path = path; trail.fillColor = StickFightPalette.native(p.owner).withAlphaComponent(0.35); trail.strokeColor = .clear; s.addChild(trail)
                }
                objects.addChild(s); shots[p.id] = s; node = s
            }
            node.position = CGPoint(x: p.x, y: p.y); node.zRotation = p.thrown ? Double(sim.frame) * 0.27 : atan2(p.vy, p.vx)
        }
        let liveDrops = Set(sim.pickups.map(\.id))
        for id in Array(drops.keys) where !liveDrops.contains(id) { drops.removeValue(forKey: id)?.removeFromParent() }
        for p in sim.pickups {
            let node: SKNode
            if let existing = drops[p.id] { node = existing } else {
                let s = SKNode()
                let halo = SKSpriteNode(texture:Self.softTexture(color:NSColor.yellow.withAlphaComponent(0.2))); halo.size = CGSize(width:65,height:55); s.addChild(halo)
                let length = p.weapon == .pistol ? 23.0 : 32.0
                let gun = SKShapeNode(rect:CGRect(x:-length/2,y:-2,width:length,height:7),cornerRadius:1); gun.fillColor = NSColor(calibratedRed:0.35,green:0.40,blue:0.44,alpha:1); gun.strokeColor = NSColor(calibratedRed:0.91,green:0.77,blue:0.44,alpha:1); gun.lineWidth = 0.8; s.addChild(gun)
                let barrel = SKShapeNode(rect:CGRect(x:length/2 - 1,y:0,width:7,height:3),cornerRadius:0.5); barrel.fillColor = NSColor(white:0.15,alpha:1); barrel.strokeColor = .clear; s.addChild(barrel)
                let grip = SKShapeNode(rectOf:CGSize(width:5,height:9),cornerRadius:1); grip.fillColor = NSColor(calibratedRed:0.43,green:0.30,blue:0.18,alpha:1); grip.strokeColor = .clear; grip.position = CGPoint(x:-5,y:-5); s.addChild(grip)
                let title = SKLabelNode(fontNamed:"AvenirNext-DemiBold"); title.text = p.weapon.title.uppercased(); title.fontSize = 6.5; title.fontColor = NSColor(calibratedRed:0.95,green:0.81,blue:0.51,alpha:0.9); title.position.y = 16; s.addChild(title)
                objects.addChild(s); drops[p.id] = s; node = s
            }
            node.position = CGPoint(x: p.x, y: p.y)
        }
        roundLabel.text = "ROUND \(sim.round)   /   FIRST TO 5   ·   \(sim.map.title.uppercased())"
        if sim.countdown > 0 {
            announcement.text = "\((sim.countdown + 59) / 60)"; announcement.fontColor = .white
            subtitle.text = "GET READY"
        } else if sim.roundOverFrames > 0 {
            let winner = sim.roundWinner ?? -1
            announcement.fontColor = winner >= 0 ? StickFightPalette.native(winner) : .white
            announcement.text = winner >= 0 ? "ROUND WON" : "DRAW"
            subtitle.text = winner >= 0 ? (session.slots.first(where: { $0.index == winner })?.name ?? "Player \(winner + 1)") : "Nobody survived. Go again."
        } else { announcement.text = ""; subtitle.text = "" }
        if sim.winner != nil { announcement.text = ""; subtitle.text = "" }
    }
    override func willMove(from view: SKView) { super.willMove(from: view); sound.stop() }
    private func playImpact(_ knockout: Bool, time: TimeInterval) {
        guard soundEnabled, view?.window?.isKeyWindow == true, session?.showsMenu == false, time - lastSoundTime > 0.055 else { return }
        lastSoundTime = time; sound.volume = 0.16; sound.play(knockout: knockout)
    }
    private func burst(_ point: CGPoint, color: NSColor, count: Int, velocity: CGVector = .zero) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        shake = min(3, shake + Double(count) * 0.10)
        for i in 0..<count {
            let n = SKShapeNode(circleOfRadius: CGFloat(i % 3 + 1)); n.fillColor = color; n.strokeColor = .clear; n.position = point; effects.addChild(n)
            let angle = Double(i) * 2.39996
            n.run(.sequence([.group([.moveBy(x: cos(angle) * Double(25 + i * 3) + min(40, max(-40, velocity.dx * 0.06)), y: sin(angle) * Double(25 + i * 3) + min(35, max(-35, velocity.dy * 0.06)), duration: 0.28), .fadeOut(withDuration: 0.28)]), .removeFromParent()]))
        }
    }
}

private final class StickFightRig: SKNode {
    private let rear = SKShapeNode(), limbs = SKShapeNode(), highlight = SKShapeNode(), head = SKShapeNode(circleOfRadius: 6.8)
    private let gun = SKNode(), shield = SKShapeNode(circleOfRadius: 28), crown = SKShapeNode(), muzzle = SKShapeNode()
    private let tint: NSColor
    private var weapon: StickFightWeapon?
    private var phase = 0.0, previousTime: Double?, previousGrounded = false, landing = 0.0
    private var lastCooldown = 0
    init(color: NSColor) {
        tint = color; super.init()
        for node in [rear, limbs, highlight] { node.lineCap = .round; node.lineJoin = .round; addChild(node) }
        rear.strokeColor = color.blended(withFraction: 0.20, of: .black)!; rear.lineWidth = 4.4
        limbs.strokeColor = color; limbs.lineWidth = 4.6
        highlight.strokeColor = .white.withAlphaComponent(0.12); highlight.lineWidth = 1
        head.fillColor = color; head.strokeColor = color.blended(withFraction: 0.2, of: .white)!; head.lineWidth = 0.5; addChild(head)
        addChild(gun)
        shield.strokeColor = color.withAlphaComponent(0.6); shield.fillColor = color.withAlphaComponent(0.055); shield.lineWidth = 1.5; shield.glowWidth = 1; shield.position.y = 25; addChild(shield)
        let p = CGMutablePath(); p.addLines(between: [CGPoint(x:-8,y:0),CGPoint(x:-10,y:10),CGPoint(x:-3,y:6),CGPoint(x:0,y:13),CGPoint(x:4,y:6),CGPoint(x:10,y:10),CGPoint(x:8,y:0)]); p.closeSubpath()
        crown.path = p; crown.fillColor = StickFightPalette.native(0); crown.strokeColor = NSColor.white.withAlphaComponent(0.3); crown.lineWidth = 0.5; addChild(crown)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func buildGun(_ type: StickFightWeapon) {
        gun.removeAllChildren()
        let metal = NSColor(calibratedRed: 0.19, green: 0.23, blue: 0.27, alpha: 1)
        func part(_ rect: CGRect, _ color: NSColor, _ radius: CGFloat = 1) {
            let n = SKShapeNode(rect: rect, cornerRadius: radius); n.fillColor = color; n.strokeColor = NSColor.black.withAlphaComponent(0.5); n.lineWidth = 0.6; gun.addChild(n)
        }
        let length = type == .pistol ? 21.0 : type == .scatter ? 31.0 : 27.0
        part(CGRect(x: -4, y: -2, width: length, height: 7), metal)
        part(CGRect(x: length - 6, y: 0, width: 9, height: type == .scatter ? 5 : 3), NSColor(white: 0.13, alpha: 1))
        part(CGRect(x: -1, y: -9, width: 5, height: 8), NSColor(calibratedRed: 0.28, green: 0.21, blue: 0.17, alpha: 1))
        part(CGRect(x: -3, y: 4, width: length - 5, height: 1.2), NSColor(white: 0.67, alpha: 1), 0)
        if type != .pistol {
            part(CGRect(x: -11, y: -3, width: 9, height: 7), NSColor(calibratedRed: 0.35, green: 0.25, blue: 0.16, alpha: 1))
            part(CGRect(x: 10, y: -4, width: 11, height: 4), type == .blaster ? .cyan.withAlphaComponent(0.7) : NSColor(calibratedRed: 0.38, green: 0.27, blue: 0.14, alpha: 1))
        }
        let flash = CGMutablePath(); flash.addLines(between: [CGPoint(x:0,y:0),CGPoint(x:9,y:6),CGPoint(x:7,y:2),CGPoint(x:20,y:0),CGPoint(x:8,y:-2),CGPoint(x:11,y:-6)]); flash.closeSubpath()
        muzzle.path = flash; muzzle.fillColor = NSColor(calibratedRed: 1, green: 0.88, blue: 0.47, alpha: 1); muzzle.strokeColor = .white; muzzle.lineWidth = 1; muzzle.position = CGPoint(x: length + 3, y: 1.5); gun.addChild(muzzle)
    }
    private func knee(_ hip: CGPoint, _ foot: CGPoint, bend: Double) -> CGPoint {
        let dx = foot.x - hip.x, dy = foot.y - hip.y, distance = max(0.01, hypot(dx, dy))
        let offset = sqrt(max(0, 12.8 * 12.8 - min(25.5, distance) * min(25.5, distance) / 4))
        return CGPoint(x: (hip.x + foot.x) / 2 - dy / distance * offset * bend, y: (hip.y + foot.y) / 2 + dx / distance * offset * bend)
    }
    func render(_ f: StickFightFighter, time: TimeInterval, crown hasCrown: Bool) {
        isHidden = !f.alive; guard f.alive else { return }
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let dt = min(0.04, max(0, time - (previousTime ?? time))); previousTime = time
        let speed = min(1, abs(f.vx) / 330), moving = abs(f.vx) > 15 && f.grounded
        if moving { phase += dt * (9 + speed * 12) }
        if f.grounded && !previousGrounded { landing = 1 }; previousGrounded = f.grounded; landing = max(0, landing - dt * 7)
        let cycle = reduced ? 0.0 : phase
        let stride = moving ? sin(cycle) * (7 + speed * 7) : 0
        let bounce = moving && !reduced ? abs(cos(cycle)) * 2 : 0
        let crouch = reduced ? 0 : landing * 4
        let punch = f.punchFrames > 0 ? sin(Double(f.punchFrames) / 18 * Double.pi) : 0
        let lean = min(6.5, max(-6.5, f.vx * 0.018)) + f.facing * punch * 2
        let hip = CGPoint(x: lean * 0.25, y: 20 + bounce - crouch)
        let shoulder = CGPoint(x: lean, y: 34 + bounce - crouch)
        let headPoint = CGPoint(x: lean + f.facing * 1.5, y: 44 + bounce - crouch)
        let leftFoot = CGPoint(x: -6 - stride, y: f.grounded ? max(0, sin(cycle) * 6) * (moving ? 1 : 0) : (f.vy > 0 ? 11 : 2))
        let rightFoot = CGPoint(x: 6 + stride, y: f.grounded ? max(0, -sin(cycle) * 6) * (moving ? 1 : 0) : (f.vy > 0 ? 3 : 8))
        let rearPath = CGMutablePath(), frontPath = CGMutablePath()
        rearPath.addLines(between: [hip, knee(hip, leftFoot, bend: f.facing), leftFoot])
        frontPath.addLines(between: [hip, knee(hip, rightFoot, bend: f.facing), rightFoot])
        frontPath.addLines(between: [hip, shoulder, CGPoint(x:headPoint.x,y:headPoint.y - 5)])
        let aim = f.aimAngle
        let direction = CGVector(dx: cos(aim), dy: sin(aim))
        let recoil = f.weapon.map { Double(f.shootCooldown) / Double($0.cooldown) } ?? 0
        let hand: CGPoint
        if f.blocking { hand = CGPoint(x: shoulder.x + f.facing * 12, y: shoulder.y + 9) }
        else if f.weapon != nil { hand = CGPoint(x: shoulder.x + direction.dx * (18 - recoil * 2), y: shoulder.y + direction.dy * 18) }
        else { hand = CGPoint(x: shoulder.x + f.facing * (14 + punch * 17), y: shoulder.y - 5 + punch * 5) }
        frontPath.addLines(between: [shoulder, CGPoint(x:(shoulder.x + hand.x)/2,y:(shoulder.y + hand.y)/2 - (f.blocking ? 2 : 4)), hand])
        let backHand = f.weapon != nil ? CGPoint(x: hand.x + direction.dx * 7, y: hand.y - 2) : CGPoint(x: shoulder.x - f.facing * (8 + stride * 0.35), y: shoulder.y - 13)
        rearPath.addLines(between: [shoulder, CGPoint(x: shoulder.x - f.facing * 5, y: shoulder.y - 8), backHand])
        rear.path = rearPath; limbs.path = frontPath; head.position = headPoint
        limbs.strokeColor = f.stun > 0 ? .white : tint; head.fillColor = limbs.strokeColor
        let gleam = CGMutablePath(); gleam.move(to: CGPoint(x:hip.x - 1,y:hip.y)); gleam.addLine(to: CGPoint(x:shoulder.x - 1,y:shoulder.y)); highlight.path = gleam
        shield.isHidden = !f.blocking; shield.alpha = max(0.15, min(1, f.shield / 100))
        gun.isHidden = f.weapon == nil
        if let type = f.weapon {
            if weapon != type { weapon = type; buildGun(type) }
            gun.position = hand; gun.zRotation = aim; gun.yScale = cos(aim) < 0 ? -1 : 1
            muzzle.isHidden = reduced || f.shootCooldown < type.cooldown - 3
        }
        lastCooldown = f.shootCooldown
        crown.isHidden = !hasCrown; crown.position = CGPoint(x: headPoint.x, y: headPoint.y + 10)
    }
}

/// Cosmetic articulated body. Fixed 120 Hz Verlet integration and repeated
/// distance projections keep limbs coherent independently of display cadence.
/// These points never participate in authoritative combat or player collision.
private final class StickFightRagdoll: SKNode {
    private var points: [CGPoint]
    private var previous: [CGPoint]
    private var links: [(Int, Int, CGFloat)] = []
    private let body = SKShapeNode()
    private let head = SKShapeNode(circleOfRadius: 6.7)
    private var accumulator = 0.0
    private var age = 0.0
    var finished: Bool { age >= 1.15 }
    init(fighter f: StickFightFighter, color: NSColor) {
        let offsets = [CGPoint(x: 0, y: 43), CGPoint(x: 0, y: 32), CGPoint(x: 0, y: 18),
                       CGPoint(x: -10, y: 26), CGPoint(x: -19, y: 28), CGPoint(x: 10, y: 26),
                       CGPoint(x: 21, y: 31), CGPoint(x: -7, y: 10), CGPoint(x: -13, y: 1),
                       CGPoint(x: 7, y: 10), CGPoint(x: 13, y: 1)]
        points = offsets.map { CGPoint(x: f.x + $0.x, y: f.y + $0.y) }
        // Transfer momentum from the struck fighter. A small angular velocity
        // lets the body rotate rather than translating as a rigid silhouette.
        let vx = min(900, max(-900, f.vx)), vy = min(750, max(-750, f.vy))
        previous = offsets.enumerated().map { index, offset in
            let angular = f.facing * 3
            return CGPoint(x: f.x + offset.x - (vx - (offset.y - 22) * angular) / 120,
                           y: f.y + offset.y - (vy + offset.x * angular) / 120)
        }
        super.init()
        let pairs = [(0,1),(1,2),(1,3),(3,4),(1,5),(5,6),(2,7),(7,8),(2,9),(9,10)]
        links = pairs.map { a, b in (a, b, hypot(points[a].x - points[b].x, points[a].y - points[b].y)) }
        body.strokeColor = color; body.lineWidth = 4.2; body.lineCap = .round; body.lineJoin = .round; addChild(body)
        head.fillColor = color; head.strokeColor = .clear; addChild(head)
        render()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func advance(_ elapsed: Double, platforms: [StickFightPlatform]) {
        accumulator += elapsed
        let step = 1.0 / 120
        while accumulator >= step {
            accumulator -= step; age += step
            let before = points
            for i in points.indices {
                let point = points[i]
                let dx = (point.x - previous[i].x) * 0.996
                let dy = (point.y - previous[i].y) * 0.996
                previous[i] = point
                points[i] = CGPoint(x: point.x + dx, y: point.y + dy - 1450 * step * step)
            }
            for _ in 0..<5 {
                for (a, b, length) in links {
                    let dx = points[b].x - points[a].x, dy = points[b].y - points[a].y
                    let distance = max(0.0001, hypot(dx, dy))
                    let correction = (distance - length) / distance * 0.5
                    points[a].x += dx * correction; points[a].y += dy * correction
                    points[b].x -= dx * correction; points[b].y -= dy * correction
                }
                for i in points.indices {
                    let radius = i == 0 ? 6.7 : 2.1
                    for platform in platforms where points[i].x >= platform.left - radius && points[i].x <= platform.right + radius {
                        let top = platform.top + radius
                        if points[i].y < top && before[i].y >= top - 0.5 && points[i].y >= platform.bottom {
                            let impact = points[i].y - previous[i].y
                            points[i].y = top
                            previous[i].y = top + impact * 0.22
                            previous[i].x += (points[i].x - previous[i].x) * 0.20
                        }
                    }
                }
            }
        }
        alpha = CGFloat(max(0, min(1, (1.15 - age) / 0.3)))
        render()
    }
    private func render() {
        let path = CGMutablePath()
        for (a, b, _) in links { path.move(to: points[a]); path.addLine(to: points[b]) }
        body.path = path; head.position = points[0]
    }
}
