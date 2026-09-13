import SwiftUI

@MainActor
final class RoomPresenceModel: ObservableObject {
    // This view owner has only ARC cleanup, like RoomInteractionModel.
    nonisolated deinit {}

    @Published var title = "Room"
    @Published var people = 0
}

/// A quiet entry point when the room has no music. It never replaces an active
/// conversation, transfer or utility, and opens ALO's existing in-notch workspace.
struct RoomPresenceContent: NotchContentProtocol, DynamicIslandCustomizable {
    static let activityID = "alo.room.presence"
    let model: RoomPresenceModel
    let open: @MainActor () -> Void
    var id: String { Self.activityID }
    var priority: Int { -1 }
    func size(baseWidth: CGFloat, baseHeight: CGFloat) -> CGSize {
        CGSize(width: max(280, baseWidth + 100), height: baseHeight + 48)
    }
    func dynamicIslandSize(baseWidth: CGFloat, baseHeight: CGFloat) -> CGSize {
        size(baseWidth: baseWidth, baseHeight: baseHeight)
    }
    func makeView() -> AnyView { AnyView(RoomPresenceView(model: model, open: open)) }
}

private struct RoomPresenceView: View {
    @ObservedObject var model: RoomPresenceModel
    let open: @MainActor () -> Void
    var body: some View {
        VStack {
            Spacer(minLength: 0)
            Button(action: open) {
                HStack(spacing: 10) {
                    Image(systemName: "person.2.fill").foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.title).font(.callout.weight(.semibold)).lineLimit(1)
                        Text("\(model.people) \(model.people == 1 ? "person" : "people") · Open room")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down").font(.caption).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(model.title) in the notch. \(model.people) \(model.people == 1 ? "person" : "people") connected")
            .padding(.horizontal, 22).padding(.bottom, 12)
        }
    }
}
