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
                if let scene { AnnotationControlsView(model: scene).padding(12) }
            }
        }
    }
}

/// Inspect permissions without mounting the full tool palette over every video.
/// Closing tools stops input, but never removes other participants' annotations.
@MainActor
struct AnnotationControlsView: View {
    @ObservedObject var model: AnnotationSceneModel
    var onExpansionChanged: ((Bool) -> Void)? = nil
    @State private var expanded = false

    var body: some View {
        Group {
            if expanded || model.annotationEnabled {
                AnnotationToolbarView(model: model, onClose: { expanded = false })
            } else {
                Button { expanded = true } label: {
                    Label("Annotate", systemImage: model.inputAvailable ? "pencil.tip" : "lock")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .help(model.inputAvailable ? "Show annotation tools" : model.disabledReason)
                .accessibilityLabel("Show annotation tools")
            }
        }
        .onChange(of: model.annotationEnabled) { _, enabled in
            if !enabled { expanded = false }
        }
        .onChange(of: model.snapshot?.sessionID) { _, _ in expanded = false }
        .onChange(of: expanded || model.annotationEnabled, initial: true) { _, visible in
            onExpansionChanged?(visible)
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
