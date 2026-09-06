#if os(macOS)
import AppKit
import SceneKit
import ALOCore

/// Original, locally generated environment; its solid surfaces use the simulation's map.
@MainActor
final class BreachScene {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    private let sun = SCNNode()
    private let viewModel = SCNNode()
    private let flash = SCNNode()
    private var botNodes: [Int: SCNNode] = [:]
    private var currentWeapon: BreachWeapon?
    private var flashUntil = 0.0
    private var lastPosition = BreachPoint(0, 12)
    private var stride = 0.0
    private let concrete: SCNMaterial
    private let steel: SCNMaterial
    private let dark: SCNMaterial
    private let orange: SCNMaterial

    init() {
        concrete = Self.material(NSColor(calibratedRed: 0.49, green: 0.50, blue: 0.47, alpha: 1), roughness: 0.94, textured: true)
        steel = Self.material(NSColor(calibratedRed: 0.22, green: 0.31, blue: 0.32, alpha: 1), roughness: 0.5, metalness: 0.65, textured: true)
        dark = Self.material(NSColor(calibratedWhite: 0.10, alpha: 1), roughness: 0.42, metalness: 0.55)
        orange = Self.material(NSColor(calibratedRed: 0.94, green: 0.39, blue: 0.12, alpha: 1), roughness: 0.72)
        scene.background.contents = NSColor(calibratedRed: 0.39, green: 0.49, blue: 0.56, alpha: 1)
        scene.fogColor = NSColor(calibratedRed: 0.48, green: 0.56, blue: 0.60, alpha: 1)
        scene.fogStartDistance = 32; scene.fogEndDistance = 100
        let camera = SCNCamera()
        camera.zNear = 0.04; camera.zFar = 150; camera.fieldOfView = 82
        camera.wantsHDR = true; camera.wantsExposureAdaptation = false
        camera.exposureOffset = 0.2; camera.bloomIntensity = 0.15
        camera.screenSpaceAmbientOcclusionIntensity = 0.65
        camera.screenSpaceAmbientOcclusionRadius = 0.5
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 1.65, 12)
        scene.rootNode.addChildNode(cameraNode)
        cameraNode.addChildNode(viewModel)
        sun.light = SCNLight(); sun.light?.type = .directional
        sun.light?.color = NSColor(calibratedRed: 1, green: 0.89, blue: 0.74, alpha: 1)
        sun.light?.intensity = 1600; sun.light?.castsShadow = true
        sun.light?.shadowMode = .deferred; sun.light?.shadowSampleCount = 8
        sun.light?.shadowMapSize = CGSize(width: 2048, height: 2048)
        sun.light?.shadowColor = NSColor(white: 0.03, alpha: 0.65)
        sun.light?.orthographicScale = 42; sun.light?.maximumShadowDistance = 65
        sun.eulerAngles = SCNVector3(-0.85, -0.55, 0)
        scene.rootNode.addChildNode(sun)
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient
        ambient.light?.color = NSColor(calibratedRed: 0.66, green: 0.76, blue: 0.87, alpha: 1)
        ambient.light?.intensity = 470; scene.rootNode.addChildNode(ambient)
        if let url = Bundle.module.url(forResource: "concrete", withExtension: "png", subdirectory: "Breach"), let texture = NSImage(contentsOf: url) {
            concrete.diffuse.contents = texture
            concrete.diffuse.wrapS = .repeat; concrete.diffuse.wrapT = .repeat
        }
        buildYard()
    }

    func setGraphics(shadows: Bool, fov: Double) {
        sun.light?.castsShadow = shadows
        cameraNode.camera?.fieldOfView = CGFloat(min(110, max(60, fov)))
        cameraNode.camera?.screenSpaceAmbientOcclusionIntensity = shadows ? 0.65 : 0
    }

    func update(game: BreachSimulation, yaw: Double, pitch: Double, firing: Bool) {
        let time = ProcessInfo.processInfo.systemUptime
        let traveled = game.player.distance(to: lastPosition)
        stride += min(traveled, 0.3) * 10
        lastPosition = game.player
        cameraNode.position = SCNVector3(game.player.x, 1.65, game.player.z)
        cameraNode.eulerAngles = SCNVector3(pitch, yaw, 0)
        if currentWeapon != game.weapon { buildWeapon(game.weapon); currentWeapon = game.weapon }
        if firing { flashUntil = time + 0.06 }
        flash.isHidden = time > flashUntil
        let recoil = max(0, flashUntil - time) * 0.65
        let bob = traveled > 0.001 ? sin(stride) * 0.012 : 0
        viewModel.position = SCNVector3(0.25, -0.24 + bob - (game.reloadRemaining > 0 ? 0.18 : 0), -0.45 + recoil)
        viewModel.eulerAngles.x = CGFloat(game.reloadRemaining > 0 ? -0.35 : recoil)
        for bot in game.bots {
            let node: SCNNode
            if let existing = botNodes[bot.id] { node = existing }
            else { node = makeGuard(); botNodes[bot.id] = node; scene.rootNode.addChildNode(node) }
            node.isHidden = bot.health <= 0
            node.position = SCNVector3(bot.position.x, 0, bot.position.z)
            node.eulerAngles.y = CGFloat(atan2(game.player.x - bot.position.x, game.player.z - bot.position.z))
        }
        let activeIDs = Set(game.bots.map(\.id))
        for (id, node) in botNodes where !activeIDs.contains(id) { node.isHidden = true }
    }

    private func buildYard() {
        let ground = Self.material(NSColor(calibratedRed: 0.26, green: 0.28, blue: 0.28, alpha: 1), roughness: 0.98, textured: true)
        ground.diffuse.contentsTransform = SCNMatrix4MakeScale(18, 18, 1)
        box(40, 0.18, 40, at: SCNVector3(0, -0.10, 0), material: ground)
        for (index, wall) in BreachSimulation.walls.enumerated() {
            let isCrate = wall.height < 2
            let body = box(wall.width, wall.height, wall.depth,
                           at: SCNVector3(wall.x, wall.height / 2, wall.z), material: isCrate ? steel : concrete)
            if isCrate {
                // Edge reinforcement remains inside the collision footprint.
                for side in [-1.0, 1.0] {
                    box(wall.width, 0.10, wall.depth, at: SCNVector3(0, side * (wall.height / 2 - 0.06), 0), material: dark, parent: body)
                    box(0.09, wall.height, wall.depth, at: SCNVector3(side * (wall.width / 2 - 0.05), 0, 0), material: dark, parent: body)
                }
                for rib in -2...2 {
                    box(0.045, wall.height * 0.80, 0.025, at: SCNVector3(Double(rib) * wall.width / 6, 0, wall.depth / 2 + 0.005), material: dark, parent: body)
                }
                sign("CARGO / 0\(index)", width: min(wall.width * 0.65, 1.4), at: SCNVector3(wall.x, wall.height * 0.65, wall.z + wall.depth / 2 + 0.018))
            } else {
                box(wall.width, 0.12, wall.depth, at: SCNVector3(0, wall.height / 2 - 0.06, 0), material: steel, parent: body)
                box(wall.width, 0.28, wall.depth + 0.012, at: SCNVector3(0, -wall.height / 2 + 0.14, 0), material: dark, parent: body)
            }
        }
        // Flush ground paint gives routes and targets clear visual identity.
        let paint = Self.material(NSColor(calibratedRed: 0.75, green: 0.64, blue: 0.30, alpha: 1), roughness: 1)
        for x in [-13.5, 13.5] {
            for z in Swift.stride(from: -13.0, through: 13.0, by: 2.4) {
                box(0.07, 0.006, 1.4, at: SCNVector3(x, 0.006, z), material: paint)
            }
        }
        for z in [-12.0, 12.0] {
            box(5, 0.008, 0.08, at: SCNVector3(0, 0.008, z), material: orange)
            for x in Swift.stride(from: -2.4, through: 2.4, by: 0.6) {
                let mark = box(0.2, 0.009, 0.7, at: SCNVector3(x, 0.009, z), material: paint)
                mark.eulerAngles.y = -.pi / 4
            }
        }
        sign("SECTOR 07   /   FREIGHT YARD", width: 7, at: SCNVector3(0, 2.5, -15.47))
        sign("A   /   LOADING", width: 3, at: SCNVector3(10, 2.2, -4.47))
        sign("B   /   SERVICE", width: 3, at: SCNVector3(-10, 2.2, 5.53))
        // All skyline structures are beyond playable bounds.
        for x in [-21.0, 22.0] {
            box(5, 7, 26, at: SCNVector3(x, 3.5, -2), material: steel)
            for z in Swift.stride(from: -13.0, through: 9.0, by: 3.0) {
                box(5.1, 0.12, 0.12, at: SCNVector3(x, 5.6, z), material: dark)
            }
        }
        for x in [-13.0, 13.0] {
            box(0.45, 10, 0.45, at: SCNVector3(x, 5, -19), material: orange)
        }
        box(27, 0.5, 0.55, at: SCNVector3(0, 9.7, -19), material: orange)
        for x in Swift.stride(from: -12.0, through: 12.0, by: 3.0) {
            let brace = box(3.3, 0.12, 0.12, at: SCNVector3(x, 9.0, -19), material: steel)
            brace.eulerAngles.z = 0.4
        }
        for x in [-11.0, 0.0, 11.0] {
            cylinder(1.2, 5, at: SCNVector3(x, 2.5, -24), material: concrete)
            cylinder(0.22, 8, at: SCNVector3(x, 6, -24), material: dark)
        }
    }

    private func makeGuard() -> SCNNode {
        let root = SCNNode()
        let cloth = Self.material(NSColor(calibratedRed: 0.30, green: 0.28, blue: 0.23, alpha: 1), roughness: 0.95)
        let armor = Self.material(NSColor(calibratedRed: 0.23, green: 0.13, blue: 0.10, alpha: 1), roughness: 0.67)
        box(0.48, 0.57, 0.28, at: SCNVector3(0, 1.13, 0), material: cloth, parent: root)
        box(0.44, 0.42, 0.12, at: SCNVector3(0, 1.17, 0.16), material: armor, parent: root)
        box(0.22, 0.055, 0.02, at: SCNVector3(0, 1.31, 0.23), material: orange, parent: root)
        for x in [-0.13, 0.13] {
            box(0.18, 0.64, 0.19, at: SCNVector3(x, 0.51, 0), material: cloth, parent: root)
            box(0.20, 0.18, 0.31, at: SCNVector3(x, 0.12, 0.045), material: dark, parent: root)
            box(0.14, 0.16, 0.09, at: SCNVector3(x, 0.59, 0.13), material: armor, parent: root)
        }
        let helmet = SCNSphere(radius: 0.205); helmet.segmentCount = 14; helmet.firstMaterial = armor
        let head = SCNNode(geometry: helmet); head.position = SCNVector3(0, 1.64, 0); head.scale.y = 1.12; root.addChildNode(head)
        box(0.29, 0.10, 0.06, at: SCNVector3(0, 1.65, 0.185), material: dark, parent: root)
        for x in [-0.31, 0.31] {
            let arm = box(0.16, 0.39, 0.17, at: SCNVector3(x, 1.18, 0.15), material: cloth, parent: root)
            arm.eulerAngles.x = -0.8
        }
        box(0.13, 0.13, 0.70, at: SCNVector3(0.18, 1.27, 0.42), material: dark, parent: root)
        return root
    }

    private func buildWeapon(_ weapon: BreachWeapon) {
        viewModel.childNodes.forEach { $0.removeFromParentNode() }
        let length: Double = weapon == .rifle ? 0.54 : weapon == .smg ? 0.37 : 0.22
        box(0.10, 0.12, length, at: SCNVector3(0, 0, 0), material: dark, parent: viewModel)
        box(0.08, 0.025, length * 0.70, at: SCNVector3(0, 0.075, -0.01), material: steel, parent: viewModel)
        let grip = box(0.075, 0.20, 0.09, at: SCNVector3(0, -0.12, length * 0.27), material: dark, parent: viewModel)
        grip.eulerAngles.x = -0.2
        if weapon != .pistol {
            let magazine = box(0.065, 0.19, 0.11, at: SCNVector3(0, -0.14, -0.07), material: steel, parent: viewModel)
            magazine.eulerAngles.x = 0.15
            box(0.09, 0.09, 0.19, at: SCNVector3(0, -0.02, length / 2 + 0.07), material: steel, parent: viewModel)
        }
        let barrel = cylinder(0.022, 0.18, at: SCNVector3(0, 0.025, -length / 2 - 0.07), material: steel, parent: viewModel)
        barrel.eulerAngles.x = .pi / 2
        box(0.02, 0.055, 0.025, at: SCNVector3(0, 0.09, -length * 0.40), material: dark, parent: viewModel)
        for x in [-0.035, 0.035] { box(0.015, 0.045, 0.025, at: SCNVector3(x, 0.10, length * 0.28), material: dark, parent: viewModel) }
        box(0.005, 0.025, 0.07, at: SCNVector3(0.053, 0.005, 0), material: orange, parent: viewModel)
        let glove = Self.material(NSColor(calibratedRed: 0.33, green: 0.29, blue: 0.23, alpha: 1), roughness: 0.95)
        box(0.11, 0.11, 0.15, at: SCNVector3(0.045, -0.14, 0.12), material: glove, parent: viewModel)
        if weapon != .pistol { box(0.12, 0.10, 0.14, at: SCNVector3(-0.03, -0.09, -0.18), material: glove, parent: viewModel) }
        let flashGeometry = SCNSphere(radius: 0.046); flashGeometry.segmentCount = 8
        let emission = Self.material(.orange, roughness: 1); emission.emission.contents = NSColor.orange; emission.lightingModel = .constant
        flashGeometry.firstMaterial = emission; flash.geometry = flashGeometry
        flash.position = SCNVector3(0, 0.025, -length / 2 - 0.18); flash.scale = SCNVector3(0.6, 0.6, 2.0)
        flash.castsShadow = false; flash.isHidden = true; viewModel.addChildNode(flash)
        viewModel.enumerateChildNodes { node, _ in node.castsShadow = false }
    }

    @discardableResult private func box(_ w: Double, _ h: Double, _ d: Double, at p: SCNVector3, material: SCNMaterial, parent: SCNNode? = nil) -> SCNNode {
        let shape = SCNBox(width: w, height: h, length: d, chamferRadius: min(0.018, min(w, min(h, d)) / 8))
        if material === concrete, let surface = material.copy() as? SCNMaterial {
            surface.diffuse.contentsTransform = SCNMatrix4MakeScale(CGFloat(max(w, d) / 4), CGFloat(h / 4), 1)
            shape.firstMaterial = surface
        } else { shape.firstMaterial = material }
        let node = SCNNode(geometry: shape); node.position = p; (parent ?? scene.rootNode).addChildNode(node); return node
    }
    @discardableResult private func cylinder(_ radius: Double, _ height: Double, at p: SCNVector3, material: SCNMaterial, parent: SCNNode? = nil) -> SCNNode {
        let geometry = SCNCylinder(radius: radius, height: height); geometry.radialSegmentCount = 16; geometry.firstMaterial = material
        let node = SCNNode(geometry: geometry); node.position = p; (parent ?? scene.rootNode).addChildNode(node); return node
    }
    private func sign(_ title: String, width: Double, at p: SCNVector3) {
        let image = NSImage(size: NSSize(width: 1024, height: 160))
        image.lockFocus()
        NSColor(calibratedWhite: 0.10, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 1024, height: 160).fill()
        NSColor.orange.setFill(); NSRect(x: 0, y: 0, width: 12, height: 160).fill()
        (title as NSString).draw(at: NSPoint(x: 40, y: 53), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 48, weight: .bold), .foregroundColor: NSColor.white])
        image.unlockFocus()
        let plane = SCNPlane(width: width, height: width * 160 / 1024)
        let material = Self.material(.white, roughness: 0.85); material.diffuse.contents = image; plane.firstMaterial = material
        let node = SCNNode(geometry: plane); node.position = p; scene.rootNode.addChildNode(node)
    }
    private static func material(_ color: NSColor, roughness: Double, metalness: Double = 0, textured: Bool = false) -> SCNMaterial {
        let material = SCNMaterial(); material.lightingModel = .physicallyBased
        material.diffuse.contents = color; material.roughness.contents = roughness; material.metalness.contents = metalness
        if textured {
            let image = NSImage(size: NSSize(width: 256, height: 256)); image.lockFocus()
            color.setFill(); NSRect(x: 0, y: 0, width: 256, height: 256).fill()
            // Deterministic grain and panel seams, generated once and reused by all geometry.
            var seed: UInt64 = 7491
            for _ in 0..<3500 {
                seed = seed &* 6364136223846793005 &+ 1; let x = CGFloat((seed >> 24) % 256)
                seed = seed &* 6364136223846793005 &+ 1; let y = CGFloat((seed >> 24) % 256)
                NSColor(white: seed % 2 == 0 ? 1 : 0, alpha: 0.075).setFill()
                NSRect(x: x, y: y, width: 1.5, height: 1.5).fill()
            }
            NSColor(white: 0, alpha: 0.12).setFill(); NSRect(x: 0, y: 0, width: 256, height: 2).fill(); NSRect(x: 0, y: 0, width: 2, height: 256).fill()
            image.unlockFocus(); material.diffuse.contents = image
            material.diffuse.wrapS = .repeat; material.diffuse.wrapT = .repeat
        }
        return material
    }
}
#endif
