import AppKit
import ALOCore
import SpriteKit

/// A finished floating masonry island, built once with a bounded number of
/// static nodes. Its local y=0 edge matches the simulation's collision surface.
@MainActor
final class ArenaPlatformNode: SKNode {
    private struct StonePalette {
        let top: NSColor
        let face: NSColor
        let shade: NSColor
        let glint: NSColor
        let moss: NSColor
        let root: NSColor
        init(map: ArenaMap) {
            switch map {
            case .observatory:
                top = NSColor(red: 0.40, green: 0.42, blue: 0.49, alpha: 1)
                face = NSColor(red: 0.27, green: 0.29, blue: 0.36, alpha: 1)
                shade = NSColor(red: 0.14, green: 0.16, blue: 0.22, alpha: 1)
                moss = NSColor(red: 0.32, green: 0.40, blue: 0.36, alpha: 1)
            case .moonGarden:
                top = NSColor(red: 0.39, green: 0.43, blue: 0.40, alpha: 1)
                face = NSColor(red: 0.25, green: 0.30, blue: 0.29, alpha: 1)
                shade = NSColor(red: 0.12, green: 0.18, blue: 0.18, alpha: 1)
                moss = NSColor(red: 0.39, green: 0.47, blue: 0.33, alpha: 1)
            case .skybridge:
                top = NSColor(red: 0.44, green: 0.43, blue: 0.46, alpha: 1)
                face = NSColor(red: 0.31, green: 0.30, blue: 0.35, alpha: 1)
                shade = NSColor(red: 0.19, green: 0.18, blue: 0.24, alpha: 1)
                moss = NSColor(red: 0.34, green: 0.39, blue: 0.37, alpha: 1)
            }
            glint = NSColor(red: 0.75, green: 0.73, blue: 0.65, alpha: 1)
            root = NSColor(red: 0.22, green: 0.25, blue: 0.23, alpha: 1)
        }
    }

    init(platform: ArenaPlatform, map: ArenaMap, index: Int, texture: SKTexture? = nil) {
        super.init()
        name = "masonry-platform-\(index)"
        position = CGPoint(x: platform.left, y: platform.top)
        let width = platform.right - platform.left
        guard width > 0 else { return }
        let small = platform.droppable
        let depth = small ? 43.0 : 104.0
        let palette = StonePalette(map: map)
        let cliff: [(Double, Double)] = [
            (4, -8), (width - 4, -8), (width - 6, -25),
            (width * 0.94, -depth * 0.48), (width * 0.90, -depth * 0.47),
            (width * 0.83, -depth * 0.80), (width * 0.75, -depth * 0.86),
            (width * 0.70, -depth * 1.10), (width * 0.61, -depth * 1.08),
            (width * 0.54, -depth * 1.21), (width * 0.45, -depth * 1.15),
            (width * 0.39, -depth * 0.94), (width * 0.29, -depth * 1.02),
            (width * 0.24, -depth * 0.76), (width * 0.13, -depth * 0.73),
            (width * 0.09, -depth * 0.46), (10, -depth * 0.38), (4, -25)
        ]
        let cliffPath = polygonPath(cliff)
        let base = shape(cliffPath, fill: palette.face, stroke: palette.shade)
        base.lineWidth = 2; addChild(base)

        // Large fractured strata build volume before fine surface details.
        let facetCount = small ? 4 : 10
        for i in 0..<facetCount {
            let step = width * 0.82 / Double(facetCount)
            let x = width * 0.09 + Double(i) * step
            let start = -18.0 - noise(i + index * 7) * 9
            let bottom = -depth * (0.56 + noise(i * 3 + 4) * 0.35)
            let color = i.isMultiple(of: 3) ? palette.shade : tint(palette.face, by: 0.06 + noise(i + 11) * 0.10)
            let facet = polygon([(x, start), (x + step * 0.88, start - 3),
                                 (x + step * 0.71, bottom), (x + step * 0.17, bottom - 6),
                                 (x + step * 0.06, start - 18)], fill: color)
            addChild(facet)
            let edge = stroke([(x + 1, start - 2), (x + step * 0.06 + 1, start - 18), (x + step * 0.17 + 1, bottom - 4)], color: palette.top.withAlphaComponent(0.35), width: 1)
            addChild(edge)
        }

        if let texture {
            // Texture adds grain only; the authored silhouette and crisp walkable
            // edge remain authoritative. No texture pixels extend past the cliff.
            let crop = SKCropNode()
            let mask = shape(cliffPath, fill: .white)
            crop.maskNode = mask
            let surface = SKSpriteNode(texture: texture)
            surface.size = CGSize(width: width, height: depth * 1.25)
            surface.position = CGPoint(x: width / 2, y: -depth * 0.60)
            surface.color = palette.face; surface.colorBlendFactor = 0.55; surface.alpha = 0.28
            crop.addChild(surface); addChild(crop)
        }

        // The ledge is masonry, with a separate beveled cornice and recessed band.
        addChild(polygon([(1, -4), (width - 1, -4), (width - 5, -13), (5, -13)], fill: palette.top))
        addChild(polygon([(5, -13), (width - 5, -13), (width - 9, -19), (9, -19)], fill: palette.shade))
        addChild(polygon([(10, -20), (width - 10, -20), (width - 14, -27), (14, -27)], fill: tint(palette.face, by: 0.10)))
        addChild(stroke([(9, -19), (width - 9, -19)], color: palette.glint.withAlphaComponent(0.23), width: 1))
        addChild(stroke([(14, -27), (width - 14, -27)], color: palette.shade.withAlphaComponent(0.85), width: 2))

        // Individually shaded paving blocks establish the flat collision edge.
        let tiles = small ? 4 : 15
        let tileWidth = (width - 2) / Double(tiles)
        for i in 0..<tiles {
            let left = 1 + Double(i) * tileWidth
            let right = left + tileWidth - 1
            let top = tint(palette.top, by: noise(i + index * 5) * 0.12)
            addChild(polygon([(left, 0), (right, 0), (right - 1, -7), (left + 1, -7)], fill: top))
            addChild(stroke([(left + 2, -1), (right - 2, -1)], color: palette.glint.withAlphaComponent(i.isMultiple(of: 3) ? 0.60 : 0.38), width: 1))
        }
        addChild(stroke([(0, 0), (width, 0)], color: palette.glint.withAlphaComponent(0.86), width: 1.4))
        addChild(stroke([(5, -8), (width - 5, -8)], color: palette.shade.withAlphaComponent(0.72), width: 1.4))

        let joints = CGMutablePath()
        let blocks = small ? 4 : 14
        for i in 1..<blocks {
            let x = 10 + (width - 20) * Double(i) / Double(blocks)
            joints.move(to: CGPoint(x: x, y: -13))
            joints.addLine(to: CGPoint(x: x + 2, y: -19))
            joints.move(to: CGPoint(x: x + 11, y: -20))
            joints.addLine(to: CGPoint(x: x + 9, y: -27))
        }
        addChild(line(joints, color: palette.shade.withAlphaComponent(0.65), width: 1))

        // Fine cracks are grouped into a single static path rather than hundreds
        // of individual rock sprites. A second offset line catches the light.
        let cracks = CGMutablePath()
        for i in 0..<(small ? 3 : 9) {
            let x = width * (0.12 + 0.76 * noise(i * 9 + index + 3))
            let top = -29.0 - noise(i * 7) * depth * 0.25
            cracks.move(to: CGPoint(x: x, y: top))
            cracks.addLines(between: [CGPoint(x: x + 4, y: top - 8), CGPoint(x: x - 2, y: top - 15), CGPoint(x: x + 5, y: top - 23)])
            cracks.move(to: CGPoint(x: x + 4, y: top - 8))
            cracks.addLine(to: CGPoint(x: x + 12, y: top - 10))
        }
        let fissures = line(cracks, color: palette.shade.withAlphaComponent(0.9), width: 1.3)
        addChild(fissures)
        let crackLight = line(cracks, color: palette.top.withAlphaComponent(0.18), width: 0.7)
        crackLight.position.x = 1; addChild(crackLight)

        // Small carved inlays live in the front band, below the playable edge.
        let inlays = small ? 2 : 6
        for i in 0..<inlays {
            let x = width * Double(i + 1) / Double(inlays + 1)
            let engraving = CGMutablePath()
            engraving.move(to: CGPoint(x: x - 4, y: -23))
            engraving.addLines(between: [CGPoint(x: x, y: -20), CGPoint(x: x + 4, y: -23), CGPoint(x: x, y: -26), CGPoint(x: x - 4, y: -23)])
            engraving.move(to: CGPoint(x: x - 8, y: -23)); engraving.addLine(to: CGPoint(x: x - 6, y: -23))
            engraving.move(to: CGPoint(x: x + 6, y: -23)); engraving.addLine(to: CGPoint(x: x + 8, y: -23))
            addChild(line(engraving, color: palette.glint.withAlphaComponent(map == .observatory ? 0.56 : 0.32), width: 0.9))
        }

        // Moss follows ledge seams, with sparse blades for scale. Tufts never
        // conceal the continuous bright collision line.
        for i in 0..<(small ? 3 : 10) {
            let x = 8 + (width - 24) * noise(i * 7 + index * 13)
            let span = 8 + noise(i * 5 + 9) * (small ? 10 : 18)
            let y = i.isMultiple(of: 3) ? -9.0 : -27.0
            addChild(polygon([(x, y), (x + span * 0.25, y + 1), (x + span, y),
                              (x + span * 0.78, y - 3), (x + span * 0.50, y - 2), (x + span * 0.28, y - 5), (x + 2, y - 2)], fill: palette.moss.withAlphaComponent(0.75)))
            if map == .moonGarden || i.isMultiple(of: 3) {
                let blades = CGMutablePath()
                for j in 0..<3 {
                    let stem = x + Double(j) * 3
                    blades.move(to: CGPoint(x: stem, y: -1))
                    blades.addQuadCurve(to: CGPoint(x: stem - 2 + Double(j), y: 3 + Double(j % 2) * 2), control: CGPoint(x: stem - 1, y: 2))
                }
                addChild(line(blades, color: palette.moss.withAlphaComponent(0.82), width: 1))
            }
        }

        let rootCount = small ? 2 : 6
        for i in 0..<rootCount {
            let x = width * (0.2 + Double(i) * 0.6 / Double(max(1, rootCount - 1)))
            let y = -depth * (0.63 + noise(i * 3 + index) * 0.2)
            let length = (small ? 15.0 : 25.0) + noise(i + 15) * 13
            let roots = CGMutablePath()
            roots.move(to: CGPoint(x: x, y: y))
            roots.addCurve(to: CGPoint(x: x - 7, y: y - length), control1: CGPoint(x: x + 6, y: y - 8), control2: CGPoint(x: x - 9, y: y - length + 6))
            roots.move(to: CGPoint(x: x + 1, y: y - 7))
            roots.addQuadCurve(to: CGPoint(x: x + 12, y: y - length * 0.82), control: CGPoint(x: x + 11, y: y - 10))
            roots.move(to: CGPoint(x: x - 2, y: y - length * 0.65))
            roots.addLine(to: CGPoint(x: x - 12, y: y - length * 0.70))
            addChild(line(roots, color: palette.root, width: small ? 1.5 : 2))
            let rootHighlight = line(roots, color: palette.moss.withAlphaComponent(0.27), width: 0.7)
            rootHighlight.position.x = -0.7; addChild(rootHighlight)
        }
    }

    /// Call once after the node is attached to a scene/SKView. The returned
    /// sprite is already aligned in this node's parent coordinates, including
    /// roots below the platform and tufts above the collision edge. Replace
    /// this node with it; the many static paths then cost one steady draw.
    /// Platforms are authored with unit scale/no rotation before baking.
    func bake(to view: SKView) -> SKSpriteNode? {
        let bounds = calculateAccumulatedFrame()
        guard bounds.width > 0, bounds.height > 0,
              let texture = view.texture(from: self) else { return nil }
        texture.filteringMode = .linear
        let sprite = SKSpriteNode(texture: texture)
        sprite.name = name
        sprite.anchorPoint = .zero
        sprite.size = bounds.size
        sprite.position = bounds.origin
        sprite.zPosition = zPosition
        return sprite
    }

    required init?(coder: NSCoder) { fatalError("ArenaPlatformNode is constructed from a platform") }
    private func noise(_ seed: Int) -> Double { Double(abs((seed * 73 + 29) % 101)) / 100 }
    private func tint(_ color: NSColor, by amount: Double) -> NSColor {
        color.blended(withFraction: amount, of: NSColor(white: 0.9, alpha: 1)) ?? color
    }
    private func polygonPath(_ points: [(Double, Double)]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: first.0, y: first.1))
        for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.0, y: point.1)) }
        path.closeSubpath(); return path
    }
    private func polygon(_ points: [(Double, Double)], fill: NSColor) -> SKShapeNode { shape(polygonPath(points), fill: fill) }
    private func shape(_ path: CGPath, fill: NSColor, stroke: NSColor = .clear) -> SKShapeNode {
        let node = SKShapeNode(path: path)
        node.fillColor = fill; node.strokeColor = stroke; node.lineWidth = 1; node.isAntialiased = true
        return node
    }
    private func stroke(_ points: [(Double, Double)], color: NSColor, width: Double) -> SKShapeNode {
        let path = CGMutablePath()
        guard let first = points.first else { return SKShapeNode() }
        path.move(to: CGPoint(x: first.0, y: first.1))
        for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.0, y: point.1)) }
        return line(path, color: color, width: width)
    }
    private func line(_ path: CGPath, color: NSColor, width: Double) -> SKShapeNode {
        let node = SKShapeNode(path: path)
        node.strokeColor = color; node.fillColor = .clear; node.lineWidth = width; node.isAntialiased = true
        return node
    }
}
