import SwiftUI

public struct ALOAddMemberView: View {
    private let networkName: String
    @Binding private var publicIdentityText: String
    private let recipient: ALOMemberSummary?
    private let invitationText: String?
    private let isBusy: Bool
    private let errorMessage: String?
    private let onCreateInvitation: () -> Void
    private let onImportPublicIdentityFile: () -> Void
    private let onExportInvitation: () -> Void
    private let onCancel: () -> Void
    @State private var localError: String?
    @FocusState private var identityFocused: Bool

    public init(
        networkName: String,
        publicIdentityText: Binding<String>,
        recipient: ALOMemberSummary? = nil,
        invitationText: String? = nil,
        isBusy: Bool = false,
        errorMessage: String? = nil,
        onCreateInvitation: @escaping () -> Void,
        onImportPublicIdentityFile: @escaping () -> Void,
        onExportInvitation: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.networkName = networkName
        _publicIdentityText = publicIdentityText
        self.recipient = recipient
        self.invitationText = invitationText
        self.isBusy = isBusy
        self.errorMessage = errorMessage
        self.onCreateInvitation = onCreateInvitation
        self.onImportPublicIdentityFile = onImportPublicIdentityFile
        self.onExportInvitation = onExportInvitation
        self.onCancel = onCancel
    }

    public var body: some View {
        Form {
            Section {
                Text("Add a person to \(networkName) using their public identity. They can then discover and join its public channels, including #Main.")
                    .foregroundStyle(.secondary)
                if invitationText == nil {
                    Button(action: onImportPublicIdentityFile) {
                        ALOActionLabel(title: "Import public identity file…", systemImage: "doc.badge.arrow.up")
                    }.disabled(isBusy)
                    ALOPackageTextEditor(title: "Public identity contents", text: $publicIdentityText, focus: $identityFocused)
                        .disabled(isBusy)
                    Text("Ask them to share their public identity from Networks. Never ask for their private recovery kit.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let recipient {
                    Label(recipient.name, systemImage: "person.crop.circle").fontWeight(.medium)
                    ALOFingerprint(value: recipient.fingerprint)
                }
            } header: {
                Text("Add network member").accessibilityAddTraits(.isHeader)
            }

            if let invitationText {
                Section("Invitation ready") {
                    Label("Membership added", systemImage: "checkmark.circle")
                    Text("Send this invitation to the person whose public identity you imported. It works only with their identity.")
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(invitationText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(minHeight: 80, maxHeight: 160)
                    Button(action: onExportInvitation) {
                        ALOActionLabel(title: "Export invitation…", systemImage: "square.and.arrow.up", isBusy: isBusy)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy)
                }
            }

            if let message = localError ?? errorMessage {
                Section { ALOInlineError(message: message) }
            }

            Section {
                if invitationText == nil {
                    Button(action: createInvitation) {
                        ALOActionLabel(title: "Add member and create invitation", systemImage: "person.badge.plus", isBusy: isBusy)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(isBusy)
                }
                Button(action: onCancel) {
                    ALOActionLabel(title: invitationText == nil ? "Cancel" : "Done")
                }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isBusy)
            } footer: {
                Text("Private channels require separate, explicit access.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Add network member")
        .onAppear { if invitationText == nil { identityFocused = true } }
    }

    private func createInvitation() {
        guard !isBusy else { return }
        guard !publicIdentityText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            localError = "Import or paste the person's public identity first."
            identityFocused = true
            return
        }
        localError = nil
        onCreateInvitation()
    }
}
