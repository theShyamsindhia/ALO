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
                if let scene,
                   let rect = AnnotationGeometry.aspectFitRect(
                    contentSize: CGSize(width: frame.width, height: frame.height),
                    in: CGRect(origin: .zero, size: geometry.size)) {
                    AnnotationSceneView(model: scene, contentRect: rect)
                }
            }
            .overlay(alignment: .topLeading) {
                if let scene { AnnotationToolbarView(model: scene).padding(12) }
            }
        }
    }
}
