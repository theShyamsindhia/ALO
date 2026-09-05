import AppKit
import ALOCore
import SpriteKit

/// Original, articulated combat silhouettes. All geometry is built once;
/// update only changes joint transforms. The caller owns world position/facing.
@MainActor
final class ArenaFighterRig: SKNode {
    private struct Limb {
        let root: SKNode
        let lower: SKNode
        let tip: SKNode
    }
    private var gaitPhase = 0.0
    private var previousFrame = -1
    private let kind: ArenaFighterKind
    private let groundShadow = SKShapeNode(ellipseOf: CGSize(width: 34, height: 6))
    private let hips = SKNode()
    private let torso = SKNode()
    private let head = SKNode()
    private let scarf = SKNode()
    private let scarfTail = SKNode()
    private let weapon = SKNode()
    private let weaponEdge = SKShapeNode()
    private let hitFlash = SKShapeNode()
    private var frontArm: Limb!
    private var rearArm: Limb!
    private var frontLeg: Limb!
    private var rearLeg: Limb!
    private let ink = NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.15, alpha: 1)
    private let cloth = NSColor(calibratedRed: 0.20, green: 0.21, blue: 0.27, alpha: 1)

    init(kind: ArenaFighterKind, color: NSColor) {
        self.kind = kind
        super.init()
        name = "articulated-\(kind.rawValue)"
        groundShadow.fillColor = NSColor(white: 0, alpha: 0.22)
        groundShadow.strokeColor = .clear; groundShadow.zPosition = -4
        groundShadow.position.y = -1; addChild(groundShadow)
        let accent = color.usingColorSpace(.deviceRGB) ?? color
        let armor = accent.blended(withFraction: 0.24, of: NSColor(white: 0.47, alpha: 1)) ?? accent
        let light = armor.blended(withFraction: 0.35, of: NSColor(white: 0.95, alpha: 1)) ?? armor
        let shade = armor.blended(withFraction: 0.45, of: ink) ?? armor
        let steel = NSColor(calibratedRed: 0.75, green: 0.77, blue: 0.80, alpha: 1)
        let heavy = kind == .atlas
        hips.position.y = 26; addChild(hips)

        rearLeg = leg(parent: hips, x: -5, z: 1, armored: heavy, color: shade, light: armor)
        rearArm = arm(parent: torso, x: -9, z: -1, armored: heavy, color: shade, light: armor)
        hips.addChild(torso); torso.position.y = 5
        torso.zPosition = 3
        scarf.position = CGPoint(x: -4, y: 26); scarf.zPosition = -2; torso.addChild(scarf)
        scarf.addChild(polygon([(-2, 3), (-20, 1), (-27, -6), (-9, -4), (2, -1)], fill: accent, stroke: shade))
        scarfTail.position = CGPoint(x: -19, y: -1)
        scarf.addChild(scarfTail)
        scarfTail.addChild(polygon([(0, 2), (-16, 0), (-24, -8), (-9, -5), (2, -2)], fill: shade, stroke: ink))

        let waist = polygon([(-10, 3), (10, 3), (heavy ? 14 : 12, 21), (8, 27), (-9, 27), (heavy ? -15 : -12, 20)], fill: cloth, stroke: ink)
        torso.addChild(waist)
        let breastplate = polygon([(-10, 23), (-6, 27), (9, 26), (heavy ? 13 : 10, 17), (7, 8), (-6, 10), (-11, 17)], fill: armor, stroke: ink)
        breastplate.lineWidth = 1.3; torso.addChild(breastplate)
        torso.addChild(polygon([(-9, 22), (-5, 26), (8, 25), (6, 22), (-5, 21), (-4, 13), (-7, 16)], fill: light))
        torso.addChild(polygon([(1, 21), (10, 21), (8, 12), (5, 9), (1, 11)], fill: shade))
        torso.addChild(roundRect(width: 20, height: 5, radius: 1.5, at: CGPoint(x: 0, y: 5), fill: ink))
        torso.addChild(roundRect(width: 5, height: 5, radius: 1, at: CGPoint(x: 3, y: 5), fill: steel))
        let coat = polygon([(-8, 4), (8, 4), (heavy ? 14 : 13, -8), (6, -7), (1, -3), (-5, -9), (-13, -6)], fill: shade, stroke: ink)
        coat.zPosition = 1; torso.addChild(coat)
        torso.addChild(polygon([(-7, 1), (-4, 2), (-3, -5), (-7, -8), (-10, -6)], fill: armor))

        head.position = CGPoint(x: 1, y: 29); head.zPosition = 5; torso.addChild(head)
        head.addChild(roundRect(width: 9, height: 9, radius: 2, at: CGPoint(x: 0, y: 0), fill: shade))
        let helmet = polygon([(-10, 3), (-11, 13), (-7, 20), (4, 22), (12, 17), (13, 8), (8, 2), (-2, 1)], fill: armor, stroke: ink)
        helmet.lineWidth = 1.3; head.addChild(helmet)
        head.addChild(polygon([(-10, 12), (-7, 19), (4, 21), (9, 18), (-3, 17), (-5, 11)], fill: light))
        head.addChild(polygon([(-5, 10), (12, 13), (12, 8), (4, 6), (-5, 7)], fill: ink))
        head.addChild(polygon([(1, 10), (11, 11.5), (10, 9), (2, 8.5)], fill: NSColor(calibratedRed: 0.91, green: 0.88, blue: 0.77, alpha: 1)))
        head.addChild(polygon([(-7, 7), (-3, 4), (6, 3), (7, 1), (-2, -1), (-8, 3)], fill: shade))
        if heavy {
            head.addChild(polygon([(-9, 17), (-14, 20), (-13, 9), (-9, 5)], fill: shade, stroke: ink))
            head.addChild(polygon([(-4, 20), (-2, 27), (3, 25), (6, 21)], fill: light, stroke: ink))
        } else {
            head.addChild(polygon([(-8, 19), (-15, 22), (-19, 17), (-13, 15), (-10, 10)], fill: shade, stroke: ink))
            head.addChild(polygon([(-7, 21), (-11, 28), (-2, 27), (6, 22)], fill: accent, stroke: ink))
        }

        frontLeg = leg(parent: hips, x: 6, z: 5, armored: heavy, color: armor, light: light)
        frontArm = arm(parent: torso, x: 10, z: 7, armored: heavy, color: armor, light: light)
        frontArm.root.name = "front-upper-arm"
        frontArm.lower.name = "front-forearm"
        frontArm.tip.name = "front-hand"
        weapon.name = "held-weapon"
        frontArm.tip.addChild(weapon)
        if kind == .nova {
            weapon.addChild(roundRect(width: 4, height: 11, radius: 1, at: CGPoint(x: 0, y: -3), fill: ink))
            weapon.addChild(roundRect(width: 15, height: 3, radius: 1, at: CGPoint(x: 0, y: -7), fill: shade))
            weapon.addChild(polygon([(-3, -8), (3, -8), (3, -34), (0, -42), (-3, -34)], fill: steel, stroke: ink))
            weapon.addChild(polygon([(0, -9), (2, -9), (2, -33), (0, -40)], fill: NSColor(white: 0.95, alpha: 1)))
            weaponEdge.path = polygonPath([(3, -10), (4, -10), (4, -34), (0, -42), (3, -33)])
            weaponEdge.fillColor = accent; weaponEdge.strokeColor = .clear
            weapon.addChild(weaponEdge)
        } else {
            for limb in [frontArm!, rearArm!] {
                let glove = polygon([(-7, 2), (6, 3), (10, -4), (8, -13), (-7, -13), (-10, -5)], fill: limb.root === frontArm.root ? armor : shade, stroke: ink)
                glove.lineWidth = 1.4; limb.tip.addChild(glove)
                limb.tip.addChild(roundRect(width: 15, height: 5, radius: 1.5, at: CGPoint(x: 0, y: -7), fill: light))
                for x in [-5.0, 0, 5] {
                    limb.tip.addChild(roundRect(width: 2, height: 5, radius: 0.5, at: CGPoint(x: x, y: -7), fill: shade))
                }
            }
        }
        hitFlash.path = polygonPath([(-11, 4), (-12, 22), (0, 28), (12, 22), (10, 6), (0, 1)])
        hitFlash.fillColor = .white; hitFlash.strokeColor = .clear; hitFlash.zPosition = 10; hitFlash.alpha = 0
        torso.addChild(hitFlash)
    }

    required init?(coder: NSCoder) { fatalError("ArenaFighterRig is constructed from a fighter kind") }

    private func arm(parent: SKNode, x: Double, z: Double, armored: Bool, color: NSColor, light: NSColor) -> Limb {
        let root = SKNode(); root.position = CGPoint(x: x, y: 23); root.zPosition = z; parent.addChild(root)
        let width = armored ? 9.0 : 7.0
        root.addChild(roundRect(width: width, height: 15, radius: width / 2, at: CGPoint(x: 0, y: -6), fill: cloth))
        root.addChild(polygon([(-width * 0.65, 2), (width * 0.6, 3), (width * 0.8, -4), (width * 0.3, -8), (-width * 0.7, -5)], fill: color, stroke: ink))
        root.addChild(polygon([(-width * 0.55, 2), (width * 0.5, 2), (width * 0.6, -1), (-width * 0.5, -2)], fill: light))
        let lower = SKNode(); lower.position.y = -13; root.addChild(lower)
        lower.addChild(roundRect(width: width * 0.85, height: 14, radius: 3, at: CGPoint(x: 0, y: -5), fill: color))
        lower.addChild(roundRect(width: 2, height: 9, radius: 0.6, at: CGPoint(x: 2, y: -4), fill: light))
        lower.addChild(roundRect(width: width + 1, height: 4, radius: 1, at: CGPoint(x: 0, y: -10), fill: ink))
        let tip = SKNode(); tip.position.y = -13; lower.addChild(tip)
        tip.addChild(roundRect(width: 7, height: 7, radius: 2.5, at: .zero, fill: color))
        return Limb(root: root, lower: lower, tip: tip)
    }
    private func leg(parent: SKNode, x: Double, z: Double, armored: Bool, color: NSColor, light: NSColor) -> Limb {
        let root = SKNode(); root.position = CGPoint(x: x, y: 1); root.zPosition = z; parent.addChild(root)
        root.addChild(roundRect(width: armored ? 10 : 8, height: 15, radius: 3.5, at: CGPoint(x: 0, y: -5), fill: cloth))
        root.addChild(polygon([(-4, -1), (4, -1), (5, -8), (2, -12), (-4, -10)], fill: color, stroke: ink))
        let lower = SKNode(); lower.position.y = -12; root.addChild(lower)
        lower.addChild(roundRect(width: 8, height: 6, radius: 2, at: CGPoint(x: 0, y: 0), fill: light))
        lower.addChild(polygon([(-4, -1), (4, -1), (3, -12), (-4, -12)], fill: color, stroke: ink))
        lower.addChild(roundRect(width: 2, height: 8, radius: 0.5, at: CGPoint(x: 1, y: -6), fill: light))
        let foot = SKNode(); foot.position.y = -12; lower.addChild(foot)
        foot.addChild(polygon([(-5, 2), (3, 2), (5, -1), (11, -2), (11, -5), (-5, -5)], fill: ink))
        foot.addChild(polygon([(-4, 1), (3, 1), (5, -2), (9, -2), (9, -3), (-4, -3)], fill: color))
        return Limb(root: root, lower: lower, tip: foot)
    }

    func update(fighter f: ArenaFighter, frame: Int, reducedMotion: Bool) {
        isHidden = f.respawn > 0 || f.stocks == 0
        guard !isHidden else { return }
        groundShadow.isHidden = !f.grounded
        let speed = min(1, abs(f.vx) / 300)
        let elapsedFrames = previousFrame < 0 || frame < previousFrame ? 1 : min(6, frame - previousFrame)
        previousFrame = frame
        gaitPhase += Double(elapsedFrames) * (0.13 + speed * 0.13)
        let gait = sin(gaitPhase)
        let breathing = reducedMotion ? 0 : sin(Double(frame) * 0.065)
        var frontShoulder = 0.27 + gait * speed * 0.65
        var backShoulder = -0.20 - gait * speed * 0.72
        var frontElbow = 0.3 + max(0, -gait) * speed * 0.5
        var backElbow = -0.15 - max(0, gait) * speed * 0.35
        var frontHip = gait * speed * 0.78
        var backHip = -gait * speed * 0.78
        var frontKnee = -max(0, -gait) * speed * 1.15
        var backKnee = -max(0, gait) * speed * 1.15
        var lean = -min(0.17, speed * 0.13) * (f.vx * f.facing >= 0 ? 1 : -1)
        var crouch = 0.0
        var wrist = 0.48
        var torsoOffset = reducedMotion ? 0 : abs(gait) * speed * 1.8 + breathing * 0.35

        if !f.grounded {
            frontHip = 0.52; backHip = -0.6
            frontKnee = -1.18; backKnee = -0.7
            frontShoulder = f.vy > 0 ? 0.95 : 0.55
            backShoulder = -0.95; frontElbow = 0.4; backElbow = -0.45
            torsoOffset = 1; lean = -0.09
        }
        if f.attackFrames > 0 {
            let startup = f.attackHeavy ? 13.0 : 5.0
            let age = Double(f.attackAge)
            let windup = min(1, age / startup)
            let strike = min(1, max(0, (age - startup) / 4))
            let recovery = min(1, max(0, (age - startup - 4) / (f.attackHeavy ? 22 : 12)))
            let aim = Double(f.attackDirection) * 1.18
            let target = Double.pi / 2 + aim
            if age < startup {
                frontShoulder = -0.65 - windup * (f.attackHeavy ? 0.85 : 0.35) + aim * 0.4
                frontElbow = 1.25 + windup * 0.65
                backShoulder = 0.65; backElbow = 0.85
                lean = 0.13 * windup; crouch = 2.5 * windup
                wrist = -0.8
            } else {
                let release = smooth(strike)
                let settle = smooth(recovery)
                let loaded = -0.65 - (f.attackHeavy ? 0.85 : 0.35) + aim * 0.4
                let extended = kind == .nova ? max(0.65, target - 0.35) : target
                frontShoulder = mix(mix(loaded, extended, release), 0.27, settle)
                frontElbow = mix(mix(1.9, kind == .nova ? -0.15 : 0.05, release), 0.3, settle)
                backShoulder = mix(-0.65, -0.2, settle)
                backElbow = mix(0.3, -0.15, settle)
                lean = mix(-0.2, -0.03, settle)
                wrist = mix(kind == .nova ? -0.15 : 0, 0.48, settle)
                crouch = 1.5 * (1 - settle)
            }
            if f.grounded {
                frontHip = 0.32; backHip = -0.36; frontKnee = -0.45; backKnee = -0.2
            }
        }
        if f.dodgeFrames > 0 {
            frontShoulder = 1.1; backShoulder = -0.8; frontElbow = 1.35; backElbow = -0.6
            frontHip = 0.78; backHip = -0.4; frontKnee = -1.5; backKnee = -1.05
            crouch = 10; lean = -0.32; wrist = 0
        }
        if f.stun > 0 {
            frontShoulder = -0.75; backShoulder = -1.45; frontElbow = -0.35; backElbow = 0.45
            frontHip = 0.4; backHip = -0.7; frontKnee = -0.5; backKnee = -0.8
            lean = 0.27; crouch = 2; wrist = -0.3
        }
        hips.position.y = 28 - crouch
        torso.position.y = 5 + torsoOffset
        torso.zRotation = lean
        head.zRotation = -lean * 0.4
        head.position.y = 29 + (reducedMotion ? 0 : breathing * 0.25)
        frontArm.root.zRotation = frontShoulder; frontArm.lower.zRotation = frontElbow
        rearArm.root.zRotation = backShoulder; rearArm.lower.zRotation = backElbow
        frontLeg.root.zRotation = frontHip; frontLeg.lower.zRotation = frontKnee
        rearLeg.root.zRotation = backHip; rearLeg.lower.zRotation = backKnee
        frontLeg.tip.zRotation = -(frontHip + frontKnee) * 0.72
        rearLeg.tip.zRotation = -(backHip + backKnee) * 0.72
        weapon.zRotation = wrist
        scarf.zRotation = reducedMotion ? 0.08 : -lean * 0.7 + sin(Double(frame) * 0.13) * (0.06 + speed * 0.15)
        scarfTail.zRotation = reducedMotion ? 0 : sin(Double(frame) * 0.17 - 0.8) * (0.13 + speed * 0.21)
        scarf.xScale = 1 + speed * 0.12
        weaponEdge.alpha = f.attackFrames > 0 ? 0.95 : 0.25
        hitFlash.alpha = f.stun > 0 && !reducedMotion && frame % 6 < 2 ? 0.35 : 0
    }

    private func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    private func smooth(_ value: Double) -> Double { value * value * (3 - 2 * value) }
    private func polygonPath(_ points: [(Double, Double)]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: first.0, y: first.1))
        for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.0, y: point.1)) }
        path.closeSubpath(); return path
    }
    private func polygon(_ points: [(Double, Double)], fill: NSColor, stroke: NSColor = .clear) -> SKShapeNode {
        let node = SKShapeNode(path: polygonPath(points)); node.fillColor = fill; node.strokeColor = stroke
        node.lineWidth = 0.8; node.isAntialiased = true; return node
    }
    private func roundRect(width: Double, height: Double, radius: Double, at point: CGPoint, fill: NSColor) -> SKShapeNode {
        let node = SKShapeNode(rectOf: CGSize(width: width, height: height), cornerRadius: radius)
        node.position = point; node.fillColor = fill; node.strokeColor = .clear; return node
    }
}
