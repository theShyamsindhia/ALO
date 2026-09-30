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
    @State private var showsInvitationText = false

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
        ALOSheet(systemImage: invitationText == nil ? "person.badge.plus" : "checkmark.circle.fill",
                 title: invitationText == nil ? "Add someone" : "Invitation ready",
                 subtitle: invitationText == nil
                    ? "Add a person to \(networkName). They'll be able to join its public channels, including Main."
                    : "Send this invitation to them. It only works for the person you added.") {
            if invitationText == nil {
                Button(action: onImportPublicIdentityFile) {
                    ALOActionLabel(title: "Choose their public identity…", systemImage: "doc.badge.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.aloSecondary)
                .disabled(isBusy)
                ALOPackageTextEditor(title: "Or paste it here", text: $publicIdentityText, focus: $identityFocused)
                    .disabled(isBusy)
                Label("They can share it from their profile menu. Never ask for their recovery key.",
                      systemImage: "info.circle")
                    .font(ALOFont.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let recipient {
                HStack(spacing: 12) {
                    ALOAvatar(name: recipient.name, seed: recipient.fingerprint, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recipient.name).font(ALOFont.label)
                        Text("Added to \(networkName)").font(ALOFont.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    ALOTag("Member", tint: .blue)
                }
                .padding(12)
                .aloWell()
                ALOFingerprint(value: recipient.fingerprint, title: "Their verification code")
            }
            if let invitationText {
                Button(showsInvitationText ? "Hide invitation text" : "Show invitation text") {
                    showsInvitationText.toggle()
                }
                .buttonStyle(.aloQuiet)
                if showsInvitationText {
                    ScrollView {
                        Text(invitationText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(minHeight: 80, maxHeight: 140)
                    .aloWell(cornerRadius: ALOMetrics.fieldRadius)
                }
                Text("Private channels need separate access, given when you create or edit them.")
                    .font(ALOFont.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let message = localError ?? errorMessage {
                ALOInlineError(message: message)
            }
        } actions: {
            Button(invitationText == nil ? "Cancel" : "Done", action: onCancel)
                .buttonStyle(.aloSecondary)
                .keyboardShortcut(.cancelAction)
                .disabled(isBusy)
            if invitationText == nil {
                Button(action: createInvitation) {
                    ALOActionLabel(title: "Add and create invitation", systemImage: "person.badge.plus", isBusy: isBusy)
                }
                .buttonStyle(.aloPrimary)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isBusy)
            } else {
                Button(action: onExportInvitation) {
                    ALOActionLabel(title: "Save invitation…", systemImage: "square.and.arrow.up", isBusy: isBusy)
                }
                .buttonStyle(.aloPrimary)
                .disabled(isBusy)
            }
        }
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
