import SwiftUI

public struct RoomMentionSnapshot: Equatable, Sendable {
    public let sender: String
    public let message: String
    public let roomTitle: String

    public init(sender: String, message: String, roomTitle: String) {
        self.sender = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        self.message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        self.roomTitle = roomTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct RoomMentionNotchContent: NotchContentProtocol, DynamicIslandCustomizable {
    static let activityID = "alo.room.mention"

    let snapshot: RoomMentionSnapshot
    let onOpen: @MainActor () -> Void

    var id: String { Self.activityID }
    var isRestorable: Bool { false }
    var windowLink: (@MainActor () -> Void)? { onOpen }

    func size(baseWidth: CGFloat, baseHeight: CGFloat) -> CGSize {
        .init(width: baseWidth + 180, height: baseHeight + 64)
    }

    func dynamicIslandSize(baseWidth: CGFloat, baseHeight: CGFloat) -> CGSize {
        .init(width: baseWidth + 210, height: baseHeight + 60)
    }

    func cornerRadius(baseRadius: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        (top: 24, bottom: 38)
    }

    func dynamicIslandCornerRadius(baseHeight: CGFloat) -> CGFloat {
        baseHeight * 0.2
    }

    @MainActor
    func makeView() -> AnyView {
        AnyView(RoomMentionNotchView(snapshot: snapshot))
    }
}

private struct RoomMentionNotchView: View {
    let snapshot: RoomMentionSnapshot
    @Environment(\.isDynamicIsland) private var isDynamicIsland

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.22))
                    Image(systemName: "at")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(snapshot.sender.isEmpty ? "Room message" : snapshot.sender)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if !snapshot.roomTitle.isEmpty {
                            Text(snapshot.roomTitle)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.42))
                                .lineLimit(1)
                        }
                    }
                    Text(snapshot.message.isEmpty ? "Mentioned you" : snapshot.message)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.36))
            }
            .padding(.leading, isDynamicIsland ? 18 : 40)
            .padding(.trailing, isDynamicIsland ? 18 : 36)
            .padding(.bottom, isDynamicIsland ? 10 : 12)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Mention from \(snapshot.sender): \(snapshot.message)")
    }
}
