import SwiftUI

struct MobileAnnotationVideoView: View {
    let image: CGImage
    let scene: AnnotationSceneModel?
    var body: some View {
        if let scene { AnnotatedMobileImage(image: image, scene: scene) }
        else {
            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity).background(.black)
                .accessibilityLabel("Live screen shared by the broadcaster")
        }
    }
}

private struct AnnotatedMobileImage: View {
    let image: CGImage
    @ObservedObject var scene: AnnotationSceneModel
    var body: some View {
        VStack(spacing: 12) {
            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity).background(.black)
                .overlay {
                    GeometryReader { geometry in
                        if let rect = scene.visibleContentRect(
                            frameSize: CGSize(width: image.width, height: image.height),
                            in: CGRect(origin: .zero, size: geometry.size)) {
                            AnnotationSceneView(model: scene, contentRect: rect)
                        }
                    }
                }
                .accessibilityLabel("Live shared screen with annotations")
            ScrollView(.horizontal) {
                AnnotationToolbarView(model: scene)
            }
            .scrollIndicators(.visible)
            .accessibilityLabel("Shared screen annotation tools")
        }
    }
}
