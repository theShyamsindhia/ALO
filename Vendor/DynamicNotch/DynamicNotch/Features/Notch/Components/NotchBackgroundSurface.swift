import SwiftUI
internal import AppKit

struct NotchBackgroundSurface: View {
    let topCornerRadius: CGFloat
    let bottomCornerRadius: CGFloat
    let isDynamicIsland: Bool
    let dynamicIslandCornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    
    var body: some View {
        if isDynamicIsland {
            let shape = DynamicIslandShape(cornerRadius: dynamicIslandCornerRadius)
            baseSurface(shape: shape)
                .contentShape(shape)
        } else {
            let shape = NotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius)
            baseSurface(shape: shape)
                .contentShape(shape)
        }
    }
    
    @ViewBuilder
    private func baseSurface<S: Shape>(shape: S) -> some View {
        // Keep one surface alive through compact/expanded transitions. Swapping
        // black and glass branches inserts/removes two independently animated shells.
        if reduceTransparency {
            shape.fill(Color(nsColor: .windowBackgroundColor))
        } else if #available(macOS 26.0, *) {
            // macOS owns the tint, refraction and accessibility preferences.
            shape.fill(.clear)
                .glassEffect(.regular, in: shape)
                .allowsHitTesting(false)
        } else {
            NotchBackdropMaterial()
                .clipShape(shape)
                .allowsHitTesting(false)
        }
    }
}

/// Public AppKit backdrop blending, without private filters or screen capture.
struct NotchBackdropMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        view.identifier = NSUserInterfaceItemIdentifier("ALO.Notch.Backdrop")
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
