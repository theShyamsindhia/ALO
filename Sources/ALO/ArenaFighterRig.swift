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
    private let cape = SKNode()
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
        let teamColor = color.usingColorSpace(.deviceRGB) ?? color
        let heavy = kind == .atlas
        let accent = heavy
            ? NSColor(calibratedRed: 0.62, green: 0.39, blue: 0.25, alpha: 1)
            : NSColor(calibratedRed: 0.48, green: 0.40, blue: 0.62, alpha: 1)
        let armor = heavy
            ? NSColor(calibratedRed: 0.30, green: 0.30, blue: 0.32, alpha: 1)
            : NSColor(calibratedRed: 0.24, green: 0.22, blue: 0.28, alpha: 1)
        let light = NSColor(calibratedRed: heavy ? 0.71 : 0.62, green: heavy ? 0.54 : 0.49, blue: heavy ? 0.32 : 0.31, alpha: 1)
        let shade = NSColor(calibratedRed: 0.16, green: 0.15, blue: 0.19, alpha: 1)
        let steel = NSColor(calibratedRed: 0.76, green: 0.77, blue: 0.82, alpha: 1)
        hips.position.y = 26; addChild(hips)

        rearLeg = leg(parent: hips, x: -5, z: 1, armored: heavy, color: shade, light: armor)
        rearArm = arm(parent: torso, x: heavy ? -12 : -9, z: -1, armored: heavy, color: shade, light: armor)
        hips.addChild(torso); torso.position.y = 5
        torso.zPosition = 3
        cape.position = CGPoint(x: -5, y: 22); cape.zPosition = -4; torso.addChild(cape)
        if !heavy {
            cape.addChild(polygon([(2, 4), (-8, 0), (-13, -13), (-25, -36), (-16, -32), (-20, -44), (-5, -34), (2, -23), (6, -7)], fill: accent, stroke: shade))
            cape.addChild(polygon([(-7, -1), (-12, -15), (-23, -34), (-18, -31), (-13, -25), (-8, -17)], fill: NSColor(red: 0.63, green: 0.54, blue: 0.75, alpha: 1)))
            cape.addChild(polygon([(-1, -9), (-9, -29), (-17, -40), (-7, -31), (0, -23)], fill: NSColor(red: 0.35, green: 0.29, blue: 0.45, alpha: 1)))
            cape.addChild(polygon([(-11, -17), (-13, -17), (-23, -35), (-21, -34)], fill: light))
        }
        scarf.position = CGPoint(x: -4, y: 26); scarf.zPosition = -2; torso.addChild(scarf)
        scarf.addChild(polygon([(-2, 3), (-20, 1), (-27, -6), (-9, -4), (2, -1)], fill: accent, stroke: shade))
        scarfTail.position = CGPoint(x: -19, y: -1)
        scarf.addChild(scarfTail)
        scarfTail.addChild(polygon([(0, 2), (-16, 0), (-24, -8), (-9, -5), (2, -2)], fill: accent.blended(withFraction: 0.3, of: shade) ?? accent, stroke: ink))

        let waist = polygon([(-10, 3), (10, 3), (heavy ? 14 : 12, 21), (8, 27), (-9, 27), (heavy ? -15 : -12, 20)], fill: cloth, stroke: ink)
        torso.addChild(waist)
        let breastplate = polygon([(-10, 23), (-6, 27), (9, 26), (heavy ? 13 : 10, 17), (7, 8), (-6, 10), (-11, 17)], fill: armor, stroke: ink)
        breastplate.lineWidth = 1.3; torso.addChild(breastplate)
        torso.addChild(polygon([(-9, 22), (-5, 26), (8, 25), (6, 22), (-5, 21), (-4, 13), (-7, 16)], fill: light))
        torso.addChild(polygon([(1, 21), (10, 21), (8, 12), (5, 9), (1, 11)], fill: shade))
        torso.addChild(roundRect(width: 20, height: 5, radius: 1.5, at: CGPoint(x: 0, y: 5), fill: ink))
        torso.addChild(roundRect(width: 6, height: 6, radius: 2, at: CGPoint(x: 3, y: 5), fill: light))
        torso.addChild(roundRect(width: 3, height: 3, radius: 1, at: CGPoint(x: 3, y: 5), fill: teamColor))
        if heavy {
            torso.addChild(polygon([(-9, 25), (10, 25), (6, 17), (1, 13), (-7, 18)], fill: accent, stroke: shade))
            torso.addChild(polygon([(-8, 5), (9, 5), (12, -17), (6, -13), (3, -26), (-4, -21), (-11, -23)], fill: accent, stroke: shade))
            torso.addChild(polygon([(-6, 2), (-3, 1), (-4, -20), (-9, -21)], fill: light))
            torso.addChild(polygon([(3, 0), (7, 1), (9, -16), (6, -13), (3, -23)], fill: NSColor(red: 0.42, green: 0.24, blue: 0.17, alpha: 1)))
        }
        let coat = polygon([(-8, 4), (8, 4), (heavy ? 14 : 13, -8), (6, -7), (1, -3), (-5, -9), (-13, -6)], fill: shade, stroke: ink)
        coat.zPosition = 1; torso.addChild(coat)
        torso.addChild(polygon([(-7, 1), (-4, 2), (-3, -5), (-7, -8), (-10, -6)], fill: armor))

        head.position = CGPoint(x: 1, y: 29); head.zPosition = 5
        head.xScale = heavy ? 0.88 : 0.86; head.yScale = 0.90
        torso.addChild(head)
        head.addChild(roundRect(width: 9, height: 9, radius: 2, at: CGPoint(x: 0, y: 0), fill: shade))
        if heavy {
            let helmet = polygon([(-11, 3), (-13, 15), (-8, 23), (4, 25), (13, 18), (14, 5), (7, -3), (-3, -2)], fill: armor, stroke: light)
            helmet.lineWidth = 1.7; head.addChild(helmet)
            head.addChild(polygon([(-10, 15), (-6, 22), (4, 24), (8, 20), (-2, 18), (-5, 11)], fill: NSColor(red: 0.43, green: 0.43, blue: 0.44, alpha: 1)))
            head.addChild(polygon([(-7, 12), (11, 15), (12, 10), (4, 8), (-5, 8)], fill: ink))
            head.addChild(polygon([(-1, 14), (2, 16), (5, 9), (4, -2), (1, -1), (1, 7)], fill: light))
            head.addChild(polygon([(6, 9), (11, 8), (9, 2), (6, 0)], fill: shade))
            head.addChild(polygon([(-11, 17), (-17, 15), (-15, 5), (-10, 2)], fill: armor, stroke: light))
            head.addChild(polygon([(-4, 23), (-1, 31), (4, 29), (7, 23)], fill: light, stroke: shade))
            let plume = SKNode(); plume.position = CGPoint(x: -1, y: 27); plume.zPosition = -1
            plume.addChild(polygon([(2, 2), (-5, 7), (-17, 8), (-30, 2), (-37, -7), (-26, -2), (-17, -1), (-5, -1)], fill: accent, stroke: shade))
            plume.addChild(polygon([(-5, 5), (-17, 6), (-29, 1), (-32, -3), (-20, 1), (-8, 1)], fill: NSColor(red: 0.75, green: 0.49, blue: 0.32, alpha: 1)))
            head.addChild(plume)
        } else {
            let hood = polygon([(-12, 0), (-16, 11), (-12, 22), (-4, 29), (7, 26), (16, 16), (14, 5), (8, -4), (-2, -5)], fill: accent, stroke: shade)
            hood.lineWidth = 1.3; head.addChild(hood)
            head.addChild(polygon([(-14, 11), (-11, 21), (-4, 28), (5, 25), (-4, 19), (-8, 8)], fill: NSColor(red: 0.62, green: 0.53, blue: 0.74, alpha: 1)))
            head.addChild(polygon([(-6, 16), (6, 21), (12, 15), (10, 5), (3, 0), (-6, 3), (-10, 10)], fill: shade, stroke: light))
            head.addChild(polygon([(-5, 11), (7, 15), (10, 10), (6, 4), (0, 2), (-5, 6)], fill: armor))
            head.addChild(polygon([(-2, 11), (2, 11), (3, 9), (0, 9)], fill: steel))
            head.addChild(polygon([(5, 12), (9, 14), (8, 11), (5, 10)], fill: steel))
            head.addChild(polygon([(-4, 5), (6, 6), (5, 1), (0, -1)], fill: ink))
            let hair = CGMutablePath()
            hair.move(to: CGPoint(x: -8, y: 14)); hair.addCurve(to: CGPoint(x: -19, y: -5), control1: CGPoint(x: -17, y: 3), control2: CGPoint(x: -7, y: 2))
            hair.move(to: CGPoint(x: 9, y: 17)); hair.addCurve(to: CGPoint(x: 10, y: -6), control1: CGPoint(x: 13, y: 7), control2: CGPoint(x: 4, y: 2))
            let curls = SKShapeNode(path: hair); curls.strokeColor = steel; curls.lineWidth = 2.4; curls.fillColor = .clear; head.addChild(curls)
            head.addChild(polygon([(-12, 3), (-20, 6), (-29, 2), (-31, -3), (-22, 0), (-14, -2)], fill: steel.blended(withFraction: 0.25, of: shade) ?? steel))
        }

        frontLeg = leg(parent: hips, x: 6, z: 5, armored: heavy, color: armor, light: light)
        frontArm = arm(parent: torso, x: heavy ? 13 : 10, z: 7, armored: heavy, color: armor, light: light)
        frontArm.root.name = "front-upper-arm"
        frontArm.lower.name = "front-forearm"
        frontArm.tip.name = "front-hand"
        for limb in [frontArm!, rearArm!] {
            limb.lower.addChild(roundRect(width: heavy ? 10 : 6, height: 3, radius: 0.8, at: CGPoint(x: 0, y: -10), fill: teamColor))
        }
        weapon.name = "held-weapon"
        frontArm.tip.addChild(weapon)
        if kind == .nova {
            weapon.addChild(roundRect(width: 4, height: 11, radius: 1, at: CGPoint(x: 0, y: -3), fill: ink))
            weapon.addChild(polygon([(-8, -7), (-5, -4), (-1, -5), (4, -8), (8, -6), (7, -10), (0, -9)], fill: light, stroke: shade))
            let bladePath = CGMutablePath()
            bladePath.move(to: CGPoint(x: -2, y: -8))
            bladePath.addQuadCurve(to: CGPoint(x: 9, y: -46), control: CGPoint(x: -4, y: -32))
            bladePath.addQuadCurve(to: CGPoint(x: 2, y: -8), control: CGPoint(x: 4, y: -26))
            bladePath.closeSubpath()
            let blade = SKShapeNode(path: bladePath); blade.fillColor = steel; blade.strokeColor = shade; blade.lineWidth = 0.8
            weapon.addChild(blade)
            let edge = CGMutablePath(); edge.move(to: CGPoint(x: 2, y: -9))
            edge.addQuadCurve(to: CGPoint(x: 9, y: -46), control: CGPoint(x: 3, y: -28))
            weaponEdge.path = edge; weaponEdge.fillColor = .clear; weaponEdge.strokeColor = NSColor(white: 0.96, alpha: 1); weaponEdge.lineWidth = 1.2
            weapon.addChild(weaponEdge)
        } else {
            for limb in [frontArm!, rearArm!] {
                let glove = polygon([(-9, 5), (8, 5), (15, -3), (12, -17), (-8, -18), (-14, -5)], fill: armor, stroke: light)
                glove.lineWidth = 2; limb.tip.addChild(glove)
                limb.tip.addChild(polygon([(-9, 1), (-13, -5), (-7, -15), (-3, -15), (-6, -4), (-3, 2)], fill: light))
                for (i, x) in [-4.0, 2, 8].enumerated() {
                    let knuckle = roundRect(width: 7, height: i == 1 ? 10 : 8, radius: 3, at: CGPoint(x: x, y: -6), fill: NSColor(red: 0.46, green: 0.46, blue: 0.49, alpha: 1))
                    knuckle.strokeColor = shade; knuckle.lineWidth = 1; limb.tip.addChild(knuckle)
                    limb.tip.addChild(roundRect(width: 3, height: 2, radius: 0.8, at: CGPoint(x: x - 1, y: -3), fill: steel))
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
        let width = armored ? 13.0 : 6.5
        root.addChild(roundRect(width: width, height: 15, radius: width / 2, at: CGPoint(x: 0, y: -6), fill: cloth))
        root.addChild(polygon([(-width * 0.65, 2), (width * 0.6, 3), (width * 0.8, -4), (width * 0.3, -8), (-width * 0.7, -5)], fill: color, stroke: armored ? light : ink))
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
            let profile = f.attackProfile
            let startup = Double(max(1, profile.startup))
            let activeFrames = Double(max(1, profile.activeFrames))
            let recoveryFrames = Double(max(1, profile.totalFrames - profile.startup - profile.activeFrames))
            let age = Double(f.attackAge)
            // The final two startup frames release the limb, so the first
            // damaging frame already shows an extended weapon/gauntlet.
            let releaseStart = max(1, startup - 2)
            let windup = min(1, age / releaseStart)
            let strike = min(1, max(0, (age - releaseStart) / max(1, startup - releaseStart)))
            let recovery = min(1, max(0, (age - startup - activeFrames) / recoveryFrames))
            let aim = Double(f.attackDirection) * 1.18
            let target = Double.pi / 2 + aim
            if age < releaseStart {
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
        cape.zRotation = reducedMotion ? 0 : -lean * 0.6 - speed * 0.18 + sin(Double(frame) * 0.09) * 0.04
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
