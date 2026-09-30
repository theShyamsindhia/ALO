import SwiftUI

public enum ALOIdentitySetupStage: Hashable, Sendable {
    case identity
    case recovery
}

/// All identity creation, restoration and export happen in the supplied actions.
/// Keep the same prepared identity when an export or persistence action fails.
public struct ALOIdentitySetupView: View {
    public let stage: ALOIdentitySetupStage
    @Binding private var displayName: String
    @Binding private var recoveryImportText: String
    private let recoveryExported: Bool
    private let isBusy: Bool
    private let errorMessage: String?
    private let onCreateIdentity: () -> Void
    private let onRestoreIdentity: () -> Void
    private let onImportRecoveryFile: () -> Void
    private let onExportRecovery: () -> Void
    private let onContinue: () -> Void
    @State private var mode = IdentityMode.create
    @State private var localError: String?
    @FocusState private var nameFocused: Bool
    @FocusState private var recoveryFocused: Bool

    private enum IdentityMode: String, CaseIterable, Identifiable {
        case create = "Create identity"
        case restore = "Restore identity"
        var id: Self { self }
    }

    public init(
        stage: ALOIdentitySetupStage,
        displayName: Binding<String>,
        recoveryImportText: Binding<String>,
        recoveryExported: Bool = false,
        isBusy: Bool = false,
        errorMessage: String? = nil,
        onCreateIdentity: @escaping () -> Void,
        onRestoreIdentity: @escaping () -> Void,
        onImportRecoveryFile: @escaping () -> Void,
        onExportRecovery: @escaping () -> Void,
        onContinue: @escaping () -> Void
    ) {
        self.stage = stage
        _displayName = displayName
        _recoveryImportText = recoveryImportText
        self.recoveryExported = recoveryExported
        self.isBusy = isBusy
        self.errorMessage = errorMessage
        self.onCreateIdentity = onCreateIdentity
        self.onRestoreIdentity = onRestoreIdentity
        self.onImportRecoveryFile = onImportRecoveryFile
        self.onExportRecovery = onExportRecovery
        self.onContinue = onContinue
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    ALOBrandMark(size: 52)
                    Text(
                        stage == .identity
                            ? (mode == .create ? "What should we call you?" : "Welcome back")
                            : "Save your recovery key"
                    )
                    .font(ALOFont.title)
                    .accessibilityAddTraits(.isHeader)
                    Text(
                        stage == .identity
                            ? (mode == .create
                                ? "This is the name people see when you listen together."
                                : "Restore your identity from the recovery key you saved.")
                            : "It brings you back if you lose or replace this device."
                    )
                    .font(ALOFont.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if stage == .identity {
                    identitySection
                } else {
                    recoverySection
                }

                if let message = localError ?? errorMessage {
                    ALOInlineError(message: message)
                }
            }
            .frame(maxWidth: 400, alignment: .leading)
            .padding(26)
            .aloCard(cornerRadius: 26)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(ALOBackdrop())
        .navigationTitle(stage == .identity ? "Welcome to ALO" : "Recovery key")
        .onAppear { if stage == .identity { nameFocused = true } }
        .onChange(of: stage) { _, _ in localError = nil }
        .onChange(of: mode) { _, newMode in
            localError = nil
            nameFocused = newMode == .create
            recoveryFocused = newMode == .restore
        }
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            ALOFieldGroup("Your name") {
                TextField("For example, Raj", text: $displayName)
                    .textContentType(.nickname)
                    .aloField()
                    .accessibilityLabel("Your name")
                    .accessibilityHint(localError ?? "The name people will see")
                    .focused($nameFocused)
                    .onSubmit { if mode == .create { createIdentity() } else { restoreIdentity() } }
                    .disabled(isBusy)
            }
            if mode == .create {
                Button(action: createIdentity) {
                    ALOActionLabel(title: "Continue", isBusy: isBusy).frame(maxWidth: .infinity)
                }
                .buttonStyle(.aloPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(isBusy)
                .accessibilityIdentifier("ALO.Identity.Create")
            } else {
                Button(action: onImportRecoveryFile) {
                    ALOActionLabel(title: "Choose recovery key…", systemImage: "doc.badge.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.aloSecondary)
                .disabled(isBusy)
                ALOPackageTextEditor(
                    title: "Or paste its contents", text: $recoveryImportText, focus: $recoveryFocused
                )
                .disabled(isBusy)
                Button(action: restoreIdentity) {
                    ALOActionLabel(
                        title: "Restore identity", systemImage: "person.crop.circle.badge.checkmark",
                        isBusy: isBusy)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.aloPrimary)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isBusy)
                .accessibilityIdentifier("ALO.Identity.Restore")
            }
            Button(
                mode == .create ? "I already have a recovery key" : "Start fresh instead"
            ) {
                mode = mode == .create ? .restore : .create
            }
            .buttonStyle(.aloQuiet)
            .frame(maxWidth: .infinity)
            .disabled(isBusy)
        }
    }

    private var recoverySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ALOIconBadge("key.fill", tint: .coral, size: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Keep it private").font(ALOFont.label)
                    Text("Anyone with this key can sign in as you. Store it somewhere only you can reach, like a password manager.")
                        .font(ALOFont.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .aloWell()

            if !recoveryExported {
                Button(action: onExportRecovery) {
                    ALOActionLabel(
                        title: "Save recovery key…", systemImage: "square.and.arrow.down", isBusy: isBusy)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.aloPrimary)
                .disabled(isBusy)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("ALO.Identity.ExportRecovery")
            } else {
                Label("Recovery key saved", systemImage: "checkmark.circle.fill")
                    .font(ALOFont.label)
                    .foregroundStyle(ALOBrand.blueText)
                Button(action: continueSetup) {
                    ALOActionLabel(title: "Continue", isBusy: isBusy).frame(maxWidth: .infinity)
                }
                .buttonStyle(.aloPrimary)
                .disabled(isBusy)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("ALO.Identity.Continue")
                Button("Save another copy…", action: onExportRecovery)
                    .buttonStyle(.aloQuiet)
                    .frame(maxWidth: .infinity)
                    .disabled(isBusy)
            }
        }
    }

    private func createIdentity() {
        guard !isBusy else { return }
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            localError = "Enter your name to continue."
            nameFocused = true
            return
        }
        localError = nil
        onCreateIdentity()
    }

    private func restoreIdentity() {
        guard !isBusy else { return }
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            localError = "Enter a display name for your restored identity."
            nameFocused = true
            return
        }
        guard !recoveryImportText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            localError = "Paste your recovery key or choose a recovery file."
            recoveryFocused = true
            return
        }
        localError = nil
        onRestoreIdentity()
    }

    private func continueSetup() {
        guard !isBusy else { return }
        guard recoveryExported else {
            localError = "Save your recovery key somewhere private to continue."
            return
        }
        localError = nil
        onContinue()
    }
}
