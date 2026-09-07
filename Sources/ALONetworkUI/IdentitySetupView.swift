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
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        stage == .identity
                            ? (mode == .create ? "What should we call you?" : "Welcome back")
                            : "Save your recovery key"
                    )
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    Text(
                        stage == .identity
                            ? "Choose the name people will see in ALO."
                            : "Your key brings you back if you lose or change your device."
                    )
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }.padding(.vertical, 4)
                if stage == .identity {
                    identitySection
                } else {
                    recoverySection
                }

                if let message = localError ?? errorMessage {
                    ALOInlineError(message: message)
                }
            }
            .frame(maxWidth: 420, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .center)
        }
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
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your name").font(.subheadline.weight(.medium))
                TextField("Name", text: $displayName)
                    .textContentType(.nickname)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .accessibilityLabel("Your name")
                    .accessibilityHint(localError ?? "The name people will see")
                    .focused($nameFocused)
                    .onSubmit { if mode == .create { createIdentity() } else { restoreIdentity() } }
                    .disabled(isBusy)
            }
            if mode == .create {
                Button(action: createIdentity) {
                    ALOActionLabel(title: "Continue", isBusy: isBusy)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isBusy)
                .accessibilityIdentifier("ALO.Identity.Create")
            } else {
                Text("Choose your saved recovery key, or paste its contents.")
                    .foregroundStyle(.secondary)
                Button(action: onImportRecoveryFile) {
                    ALOActionLabel(title: "Choose recovery key…", systemImage: "doc.badge.arrow.up")
                }.disabled(isBusy)
                ALOPackageTextEditor(
                    title: "Recovery key contents", text: $recoveryImportText, focus: $recoveryFocused
                )
                .disabled(isBusy)
                Button(action: restoreIdentity) {
                    ALOActionLabel(
                        title: "Restore identity", systemImage: "person.crop.circle.badge.checkmark",
                        isBusy: isBusy)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isBusy)
                .accessibilityIdentifier("ALO.Identity.Restore")
            }
            Button(
                mode == .create ? "Restore an existing identity" : "Create a new identity"
            ) {
                mode = mode == .create ? .restore : .create
            }
            .buttonStyle(.borderless)
            .frame(minHeight: ALONetworkMetrics.actionHeight)
            .disabled(isBusy)
        }
    }

    private var recoverySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text(
                    "This key is unencrypted. Anyone with it can become you and access your networks. Save it somewhere private."
                )
            } icon: {
                Image(systemName: "exclamationmark.shield").accessibilityHidden(true)
            }
            .fixedSize(horizontal: false, vertical: true)

            if !recoveryExported {
                Button(action: onExportRecovery) {
                    ALOActionLabel(
                        title: "Save recovery key…", systemImage: "square.and.arrow.down", isBusy: isBusy)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("ALO.Identity.ExportRecovery")
            } else {
                Label("Recovery key saved", systemImage: "checkmark.circle")
                Button(action: continueSetup) {
                    ALOActionLabel(title: "I saved it privately — Continue", isBusy: isBusy)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("ALO.Identity.Continue")
                Button("Save another copy…", action: onExportRecovery)
                    .frame(minHeight: ALONetworkMetrics.actionHeight)
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
