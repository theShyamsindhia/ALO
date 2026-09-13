import SwiftUI

public enum RoomNotchLayout: CaseIterable {
    case tray, recipients, conversation, files, canvasPreview, canvas, tool

    public func size(display: CGSize) -> CGSize {
        let desired: CGSize
        switch self {
        case .tray: desired = CGSize(width: 460, height: 190)
        case .recipients: desired = CGSize(width: 460, height: 220)
        case .conversation: desired = CGSize(width: 520, height: 350)
        case .files: desired = CGSize(width: 480, height: 290)
        case .canvasPreview: desired = CGSize(width: 460, height: 220)
        case .canvas: desired = CGSize(width: 520, height: 400)
        case .tool: desired = CGSize(width: 460, height: 310)
        }
        return CGSize(width: min(desired.width, display.width - 32),
                      height: min(desired.height, display.height - 48))
    }
}

/// The original tray's item dimensions, pressed feedback and scroll-edge fade.
public struct RoomNotchTray<Content: View>: View {
    private let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 10) { content }.padding(.horizontal, 4).padding(.vertical, 3)
        }
        .scrollIndicators(.automatic)
        .mask { ScrollFadeMask(cornerRadius: 16, maskType: .horizontalFade) }
    }
}

public struct RoomNotchTile<Icon: View>: View {
    let title: String
    let action: () -> Void
    let icon: Icon
    public init(_ title: String, action: @escaping () -> Void, @ViewBuilder icon: () -> Icon) {
        self.title = title; self.action = action; self.icon = icon()
    }
    public var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                icon.font(.system(size: 25, weight: .medium)).frame(width: 40, height: 36)
                Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1).frame(width: 72)
            }
        }
        .buttonStyle(PressedButtonStyle(width: 80, height: 84, cornerRadius: 16))
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityLabel(title)
    }
}

/// ALO supplies the real room UI; the runtime owns only its presentation.
@MainActor
final class RoomInteractionModel: ObservableObject {
    @Published var title = "Room"
    @Published var subtitle = ""
    @Published var content = AnyView(EmptyView())
    var availableSize = RoomNotchLayout.tray.size(display: CGSize(width: 1440, height: 900))
    var open: () -> Void = {}

}

struct RoomInteractionContent: NotchContentProtocol, DynamicIslandCustomizable {
    static let activityID = "alo.room.interaction"
    var id: String { Self.activityID }
    let model: RoomInteractionModel
    var priority: Int { 30 }
    var isExpandable: Bool { true }
    var isRestorable: Bool { false }
    var protectsExpandedInteraction: Bool { true }
    var strokeColor: Color { .white.opacity(0.2) }

    func size(baseWidth: CGFloat, baseHeight: CGFloat) -> CGSize {
        CGSize(width: min(model.availableSize.width, max(baseWidth + 180, 360)), height: baseHeight + 66)
    }

    func expandedSize(baseWidth: CGFloat, baseHeight: CGFloat) -> CGSize { model.availableSize }
    func cornerRadius(baseRadius: CGFloat) -> (top: CGFloat, bottom: CGFloat) { (24, 34) }
    func expandedCornerRadius(baseRadius: CGFloat) -> (top: CGFloat, bottom: CGFloat) { (24, 34) }
    func dynamicIslandSize(baseWidth: CGFloat, baseHeight: CGFloat) -> CGSize { size(baseWidth: baseWidth, baseHeight: baseHeight) }
    func expandedDynamicIslandSize(baseWidth: CGFloat, baseHeight: CGFloat) -> CGSize { model.availableSize }
    func dynamicIslandCornerRadius(baseHeight: CGFloat) -> CGFloat { 28 }
    func expandedDynamicIslandCornerRadius(baseHeight: CGFloat) -> CGFloat { 28 }
    func makeView() -> AnyView { AnyView(RoomInteractionPreview(model: model)) }
    func makeExpandedView() -> AnyView { AnyView(RoomInteractionBody(model: model)) }
}

private struct RoomInteractionPreview: View {
    @ObservedObject var model: RoomInteractionModel
    @Environment(\.isDynamicIsland) private var isDynamicIsland
    var body: some View {
        VStack {
            Spacer(minLength: 0)
            Button(action: model.open) {
              HStack(spacing: 12) {
                Image(systemName: "person.2.fill").font(.title3).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(model.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").foregroundStyle(.secondary)
              }.contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("Open \(model.subtitle) in \(model.title)")
                .padding(.horizontal, isDynamicIsland ? 22 : 42).padding(.bottom, 16)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Expand to view room actions")
    }
}

private struct RoomInteractionBody: View {
    @ObservedObject var model: RoomInteractionModel
    @Environment(\.isDynamicIsland) private var isDynamicIsland
    var body: some View {
        model.content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 36).padding(.horizontal, isDynamicIsland ? 22 : 42).padding(.bottom, 20)
    }
}
