import SwiftUI
import ALOCore

/// Both windowed and floating viewers share exactly the same aspect-fit
/// coordinate mapping. Annotation gestures never target the letterbox bars.
struct AnnotatedVideoSurface: View {
    let frame: CGImage
    let scene: AnnotationSceneModel?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                if let scene {
                    VideoAnnotationContent(scene: scene,
                        frameSize: CGSize(width: frame.width, height: frame.height),
                        bounds: CGRect(origin: .zero, size: geometry.size))
                }
            }
            .overlay(alignment: .topLeading) {
                if let scene { AnnotationToolbarView(model: scene).padding(12) }
            }
        }
    }
}

/// Metadata can suspend input while the decoder still displays its last image.
/// Observe the scene independently so that transition does not need a new frame.
@MainActor
private struct VideoAnnotationContent: View {
    @ObservedObject var scene: AnnotationSceneModel
    let frameSize: CGSize
    let bounds: CGRect

    var body: some View {
        if let rect = scene.visibleContentRect(frameSize: frameSize, in: bounds) {
            AnnotationSceneView(model: scene, contentRect: rect)
        }
    }
}
