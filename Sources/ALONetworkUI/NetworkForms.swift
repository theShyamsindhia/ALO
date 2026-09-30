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
        ALOSheet(systemImage: "person.2.fill", title: "Create a network",
                 subtitle: "A home for your group. It starts with a Main channel, and you decide who gets in.") {
            ALOFieldGroup("Network name", footnote: "People nearby see this name when they ask to join.") {
                TextField("For example, Studio", text: $name)
                    .aloField()
                    .accessibilityLabel("Network name")
                    .focused($nameFocused)
                    .onSubmit(create)
                    .disabled(isBusy)
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
                ALOActionLabel(title: "Create network", systemImage: "plus", isBusy: isBusy)
            }
            .buttonStyle(.aloPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(isBusy)
        }
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
        ALOSheet(systemImage: "envelope.open.fill", title: "Open an invitation",
                 subtitle: "Someone invited you to their network or a private channel.") {
            Button(action: onImportFile) {
                ALOActionLabel(title: "Choose invitation file…", systemImage: "doc.badge.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.aloSecondary)
            .disabled(isBusy)
            ALOPackageTextEditor(title: "Or paste the invitation", text: $invitationText, focus: $textFocused)
                .disabled(isBusy)
            Label("ALO checks who sent it and that it was made for you before anything changes.",
                  systemImage: "checkmark.shield")
                .font(ALOFont.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message = localError ?? errorMessage {
                ALOInlineError(message: message)
            }
        } actions: {
            Button("Cancel", action: onCancel)
                .buttonStyle(.aloSecondary)
                .keyboardShortcut(.cancelAction)
                .disabled(isBusy)
            Button(action: importInvitation) {
                ALOActionLabel(title: "Open invitation", systemImage: "square.and.arrow.down", isBusy: isBusy)
            }
            .buttonStyle(.aloPrimary)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(isBusy)
        }
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
