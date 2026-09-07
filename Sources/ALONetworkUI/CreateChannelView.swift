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
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Channel name").font(.subheadline.weight(.medium))
                    TextField("For example, Music", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Channel name")
                        .focused($nameFocused)
                        .onSubmit(create)
                        .disabled(isBusy)
                }
                Text("In \(networkName)").font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("Create channel").accessibilityAddTraits(.isHeader)
            }

            Section("Access") {
                Toggle(isOn: $isPrivate) {
                    Label("Private channel", systemImage: "lock")
                }.disabled(isBusy)
                Text(isPrivate
                     ? "Only network members you select can see and join this channel. You always have access."
                     : "Every member of \(networkName) can see and join this channel. People outside the network cannot discover it.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isPrivate {
                Section("Members with access") {
                    ForEach(members) { member in
                        Toggle(isOn: memberSelection(member)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(member.name + (member.isCurrentUser ? " (you)" : ""))
                                Text(member.fingerprint)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 4)
                        }
                        .frame(minHeight: ALONetworkMetrics.actionHeight)
                        .disabled(isBusy || member.isCurrentUser)
                        .accessibilityHint(member.isCurrentUser ? "The channel creator always has access" : "Allow this network member to see and join the private channel")
                    }
                    if members.allSatisfy(\.isCurrentUser) {
                        Text("You are the only member available. Add people to the network to give them private channel access.")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let message = localError ?? errorMessage {
                Section { ALOInlineError(message: message) }
            }
            Section {
                Button(action: create) {
                    ALOActionLabel(title: "Create channel", systemImage: isPrivate ? "lock" : "number", isBusy: isBusy)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isBusy)
                Button(action: onCancel) {
                    ALOActionLabel(title: "Cancel")
                }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isBusy)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Create channel")
        .onAppear { nameFocused = true }
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
