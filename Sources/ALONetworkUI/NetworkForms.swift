import SwiftUI

public struct ALOCreateNetworkView: View {
    @Binding private var name: String
    private let isBusy: Bool
    private let errorMessage: String?
    private let onCreate: () -> Void
    private let onCancel: () -> Void
    @State private var localError: String?
    @FocusState private var nameFocused: Bool

    public init(name: Binding<String>, isBusy: Bool = false, errorMessage: String? = nil,
                onCreate: @escaping () -> Void, onCancel: @escaping () -> Void) {
        _name = name
        self.isBusy = isBusy
        self.errorMessage = errorMessage
        self.onCreate = onCreate
        self.onCancel = onCancel
    }

    public var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Network name").font(.subheadline.weight(.medium))
                    TextField("For example, Studio", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Network name")
                        .focused($nameFocused)
                        .onSubmit(create)
                        .disabled(isBusy)
                }
            } header: {
                Text("Create network").accessibilityAddTraits(.isHeader)
            } footer: {
                Text("Your network includes #Main automatically. Add people using their public identities; invitations work without a server.")
            }
            if let message = localError ?? errorMessage {
                Section { ALOInlineError(message: message) }
            }
            Section {
                Button(action: create) {
                    ALOActionLabel(title: "Create network", systemImage: "plus", isBusy: isBusy)
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
        .navigationTitle("Create network")
        .onAppear { nameFocused = true }
    }

    private func create() {
        guard !isBusy else { return }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            localError = "Enter a name for your network."
            nameFocused = true
            return
        }
        localError = nil
        onCreate()
    }
}

public struct ALOImportInvitationView: View {
    @Binding private var invitationText: String
    private let isBusy: Bool
    private let errorMessage: String?
    private let onImport: () -> Void
    private let onImportFile: () -> Void
    private let onCancel: () -> Void
    @State private var localError: String?
    @FocusState private var textFocused: Bool

    public init(invitationText: Binding<String>, isBusy: Bool = false, errorMessage: String? = nil,
                onImport: @escaping () -> Void, onImportFile: @escaping () -> Void,
                onCancel: @escaping () -> Void) {
        _invitationText = invitationText
        self.isBusy = isBusy
        self.errorMessage = errorMessage
        self.onImport = onImport
        self.onImportFile = onImportFile
        self.onCancel = onCancel
    }

    public var body: some View {
        Form {
            Section {
                Text("An invitation adds this identity to a network or gives it access to a private channel.")
                    .foregroundStyle(.secondary)
                Button(action: onImportFile) {
                    ALOActionLabel(title: "Choose invitation file…", systemImage: "doc.badge.arrow.up")
                }.disabled(isBusy)
                ALOPackageTextEditor(title: "Invitation contents", text: $invitationText, focus: $textFocused)
                    .disabled(isBusy)
            } header: {
                Text("Import invitation").accessibilityAddTraits(.isHeader)
            } footer: {
                Text("Use an invitation issued to your public identity. ALO checks its signature and access before adding it.")
            }
            if let message = localError ?? errorMessage {
                Section { ALOInlineError(message: message) }
            }
            Section {
                Button(action: importInvitation) {
                    ALOActionLabel(title: "Import invitation", systemImage: "square.and.arrow.down", isBusy: isBusy)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isBusy)
                Button(action: onCancel) {
                    ALOActionLabel(title: "Cancel")
                }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isBusy)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Import invitation")
        .onAppear { textFocused = true }
    }

    private func importInvitation() {
        guard !isBusy else { return }
        guard !invitationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            localError = "Paste an invitation or choose an invitation file."
            textFocused = true
            return
        }
        localError = nil
        onImport()
    }
}
