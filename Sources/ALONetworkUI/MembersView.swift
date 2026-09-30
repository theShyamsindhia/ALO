import SwiftUI

/// The people in a network. Names come from the caller; the verified roster
/// only proves identity, so show the short code alongside any name.
public struct ALOMembersView: View {
    private let networkName: String
    private let members: [ALOMemberSummary]
    private let canManage: Bool
    private let isBusy: Bool
    private let errorMessage: String?
    private let onRemove: (String) -> Void
    private let onAddMember: (() -> Void)?
    private let onDone: () -> Void

    public init(networkName: String, members: [ALOMemberSummary], canManage: Bool, isBusy: Bool = false,
                errorMessage: String? = nil, onRemove: @escaping (String) -> Void,
                onAddMember: (() -> Void)? = nil, onDone: @escaping () -> Void) {
        self.networkName = networkName
        self.members = members
        self.canManage = canManage
        self.isBusy = isBusy
        self.errorMessage = errorMessage
        self.onRemove = onRemove
        self.onAddMember = onAddMember
        self.onDone = onDone
    }

    public var body: some View {
        ALOSheet(systemImage: "person.2.fill", title: "People",
                 subtitle: "\(members.count) \(members.count == 1 ? "person" : "people") in \(networkName)") {
            VStack(spacing: 0) {
                ForEach(ordered) { member in
                    row(member)
                    if member.id != ordered.last?.id {
                        Rectangle().fill(ALOBrand.hairline).frame(height: 1).padding(.leading, 60)
                    }
                }
            }
            .aloWell()
            Label("Compare verification codes in person or on a call before you trust someone new.",
                  systemImage: "checkmark.shield")
                .font(ALOFont.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let errorMessage {
                ALOInlineError(message: errorMessage)
            }
        } actions: {
            if canManage, let onAddMember {
                Button(action: onAddMember) {
                    ALOActionLabel(title: "Add someone…", systemImage: "person.badge.plus")
                }
                .buttonStyle(.aloSecondary)
                .disabled(isBusy)
            }
            Button("Done", action: onDone)
                .buttonStyle(.aloPrimary)
                .keyboardShortcut(.cancelAction)
                .disabled(isBusy)
        }
        .navigationTitle("People")
    }

    private var ordered: [ALOMemberSummary] {
        members.sorted { lhs, rhs in
            if lhs.isCurrentUser != rhs.isCurrentUser { return lhs.isCurrentUser }
            if lhs.isOwner != rhs.isOwner { return lhs.isOwner }
            return lhs.fingerprint < rhs.fingerprint
        }
    }

    private func row(_ member: ALOMemberSummary) -> some View {
        HStack(spacing: 12) {
            ALOAvatar(name: member.name, seed: member.fingerprint, isCurrentUser: member.isCurrentUser, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(member.name).font(ALOFont.label).lineLimit(1).truncationMode(.tail)
                        .help(member.name)
                    if member.isCurrentUser { ALOTag("You", tint: .coral) }
                    if member.isOwner { ALOTag("Owner", tint: .blue) }
                }
                Text(ALOIdentityCode.short(member.fingerprint))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .help(member.fingerprint)
            }
            Spacer(minLength: 8)
            if canManage, !member.isOwner, !member.isCurrentUser {
                Button("Remove", role: .destructive) { onRemove(member.id) }
                    .buttonStyle(.aloQuietDestructive)
                    .disabled(isBusy)
                    .accessibilityLabel("Remove \(member.name)")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }
}
