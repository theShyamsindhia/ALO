import SwiftUI

public struct ALOCreateChannelView: View {
    private let networkName: String
    @Binding private var name: String
    @Binding private var isPrivate: Bool
    @Binding private var selectedMemberIDs: Set<String>
    private let members: [ALOMemberSummary]
    private let isBusy: Bool
    private let errorMessage: String?
    private let onCreate: () -> Void
    private let onCancel: () -> Void
    @State private var localError: String?
    @FocusState private var nameFocused: Bool

    /// `members` must come from the verified network roster. The coordinator adds
    /// the creator's identity to a private channel regardless of this selection.
    public init(
        networkName: String,
        name: Binding<String>,
        isPrivate: Binding<Bool>,
        selectedMemberIDs: Binding<Set<String>>,
        members: [ALOMemberSummary],
        isBusy: Bool = false,
        errorMessage: String? = nil,
        onCreate: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.networkName = networkName
        _name = name
        _isPrivate = isPrivate
        _selectedMemberIDs = selectedMemberIDs
        self.members = members
        self.isBusy = isBusy
        self.errorMessage = errorMessage
        self.onCreate = onCreate
        self.onCancel = onCancel
    }

    public var body: some View {
        ALOSheet(systemImage: isPrivate ? "lock.fill" : "number", title: "Create a channel",
                 subtitle: "In \(networkName)") {
            ALOFieldGroup("Channel name") {
                TextField("For example, Music", text: $name)
                    .aloField()
                    .accessibilityLabel("Channel name")
                    .focused($nameFocused)
                    .onSubmit(create)
                    .disabled(isBusy)
            }

            VStack(alignment: .leading, spacing: 8) {
                ALOSectionLabel("Who can join")
                HStack(spacing: 10) {
                    accessOption(title: "Everyone", detail: "All members of \(networkName)",
                                 systemImage: "person.2.fill", selected: !isPrivate) { isPrivate = false }
                    accessOption(title: "Private", detail: "Only people you pick",
                                 systemImage: "lock.fill", selected: isPrivate) { isPrivate = true }
                }
                .disabled(isBusy)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Private channel")
                .accessibilityValue(isPrivate ? "On" : "Off")
            }

            if isPrivate {
                VStack(alignment: .leading, spacing: 8) {
                    ALOSectionLabel("Members with access")
                    VStack(spacing: 0) {
                        ForEach(members) { member in
                            memberRow(member)
                            if member.id != members.last?.id {
                                Rectangle().fill(ALOBrand.hairline).frame(height: 1).padding(.leading, 56)
                            }
                        }
                    }
                    .aloWell()
                    if members.allSatisfy(\.isCurrentUser) {
                        Text("You're the only member so far. Add people to the network first, then give them access here.")
                            .font(ALOFont.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let message = localError ?? errorMessage {
                ALOInlineError(message: message)
            }
        } actions: {
            Button("Cancel", action: onCancel)
                .buttonStyle(.aloSecondary)
                .keyboardShortcut(.cancelAction)
                .disabled(isBusy)
            Button(action: create) {
                ALOActionLabel(title: "Create channel", systemImage: isPrivate ? "lock" : "number", isBusy: isBusy)
            }
            .buttonStyle(.aloPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(isBusy)
        }
        .navigationTitle("Create channel")
        .onAppear { nameFocused = true }
    }

    private func accessOption(title: String, detail: String, systemImage: String, selected: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                ALOIconBadge(systemImage, tint: selected ? .blue : .neutral, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(ALOFont.label).foregroundStyle(.primary)
                    Text(detail).font(ALOFont.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? ALOBrand.blueText : Color.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? ALOBrand.blueSoft : ALOBrand.neutralSoft,
                        in: RoundedRectangle(cornerRadius: ALOMetrics.rowRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ALOMetrics.rowRadius, style: .continuous)
                .strokeBorder(selected ? ALOBrand.blue.opacity(0.45) : ALOBrand.hairline, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func memberRow(_ member: ALOMemberSummary) -> some View {
        Toggle(isOn: memberSelection(member)) {
            HStack(spacing: 12) {
                ALOAvatar(name: member.name, seed: member.fingerprint, isCurrentUser: member.isCurrentUser)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(member.name).font(ALOFont.label).lineLimit(1)
                        if member.isCurrentUser { ALOTag("You", tint: .coral) }
                    }
                    Text(ALOIdentityCode.short(member.fingerprint))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        #if os(macOS)
        .toggleStyle(.checkbox)
        #endif
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(minHeight: ALONetworkMetrics.actionHeight)
        .disabled(isBusy || member.isCurrentUser)
        .accessibilityHint(member.isCurrentUser ? "The channel creator always has access" : "Allow this network member to see and join the private channel")
    }

    private func memberSelection(_ member: ALOMemberSummary) -> Binding<Bool> {
        Binding {
            member.isCurrentUser || selectedMemberIDs.contains(member.id)
        } set: { selected in
            guard !member.isCurrentUser else { return }
            if selected { selectedMemberIDs.insert(member.id) }
            else { selectedMemberIDs.remove(member.id) }
        }
    }

    private func create() {
        guard !isBusy else { return }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            localError = "Enter a name for your channel."
            nameFocused = true
            return
        }
        localError = nil
        onCreate()
    }
}
