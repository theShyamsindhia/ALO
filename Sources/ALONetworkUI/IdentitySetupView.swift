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
    private let fingerprint: String?
    private let recoveryText: String?
    private let recoveryExported: Bool
    private let isBusy: Bool
    private let errorMessage: String?
    private let onCreateIdentity: () -> Void
    private let onRestoreIdentity: () -> Void
    private let onImportRecoveryFile: () -> Void
    private let onRevealRecovery: () -> Void
    private let onExportRecovery: () -> Void
    private let onContinue: () -> Void
    @State private var mode = IdentityMode.create
    @State private var localError: String?
    @State private var acknowledgesRecoveryRisk = false
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
        fingerprint: String? = nil,
        recoveryText: String? = nil,
        recoveryExported: Bool = false,
        isBusy: Bool = false,
        errorMessage: String? = nil,
        onCreateIdentity: @escaping () -> Void,
        onRestoreIdentity: @escaping () -> Void,
        onImportRecoveryFile: @escaping () -> Void,
        onRevealRecovery: @escaping () -> Void,
        onExportRecovery: @escaping () -> Void,
        onContinue: @escaping () -> Void
    ) {
        self.stage = stage
        _displayName = displayName
        _recoveryImportText = recoveryImportText
        self.fingerprint = fingerprint
        self.recoveryText = recoveryText
        self.recoveryExported = recoveryExported
        self.isBusy = isBusy
        self.errorMessage = errorMessage
        self.onCreateIdentity = onCreateIdentity
        self.onRestoreIdentity = onRestoreIdentity
        self.onImportRecoveryFile = onImportRecoveryFile
        self.onRevealRecovery = onRevealRecovery
        self.onExportRecovery = onExportRecovery
        self.onContinue = onContinue
    }

    public var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(stage == .identity ? "Your identity. Your networks." : "Save your recovery kit")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(stage == .identity
                         ? "Set up your ALO identity to create or join networks. Your identity stays with you when you move between devices."
                         : "This kit restores the same identity on another device. Keep a copy somewhere only you can access.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(.vertical, 4)
            }

            if stage == .identity {
                identitySection
            } else {
                recoverySection
            }

            if let message = localError ?? errorMessage {
                Section { ALOInlineError(message: message) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(stage == .identity ? "Welcome to ALO" : "Recovery kit")
        .onAppear { if stage == .identity { nameFocused = true } }
        .onChange(of: stage) { _, _ in localError = nil }
        .onChange(of: mode) { _, newMode in
            localError = nil
            nameFocused = newMode == .create
            recoveryFocused = newMode == .restore
        }
    }

    private var identitySection: some View {
        Group {
            Section("Identity setup") {
                Picker("Setup method", selection: $mode) {
                    ForEach(IdentityMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.segmented)
                .disabled(isBusy)

                VStack(alignment: .leading, spacing: 6) {
                        Text("Display name").font(.subheadline.weight(.medium))
                        TextField("How people will see you", text: $displayName)
                            .textContentType(.nickname)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Display name")
                            .focused($nameFocused)
                            .onSubmit { if mode == .create { createIdentity() } else { restoreIdentity() } }
                            .disabled(isBusy)
                    }
                if mode == .create {
                    Button(action: createIdentity) {
                        ALOActionLabel(title: "Create identity", systemImage: "person.crop.circle.badge.plus", isBusy: isBusy)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy)
                    .accessibilityIdentifier("ALO.Identity.Create")
                } else {
                    Text("Import the recovery kit you previously saved, or paste its complete contents below.")
                        .foregroundStyle(.secondary)
                    Button(action: onImportRecoveryFile) {
                        ALOActionLabel(title: "Import recovery file…", systemImage: "doc.badge.arrow.up")
                    }.disabled(isBusy)
                    ALOPackageTextEditor(title: "Recovery kit contents", text: $recoveryImportText, focus: $recoveryFocused)
                        .disabled(isBusy)
                    Button(action: restoreIdentity) {
                        ALOActionLabel(title: "Restore identity", systemImage: "person.crop.circle.badge.checkmark", isBusy: isBusy)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(isBusy)
                    .accessibilityIdentifier("ALO.Identity.Restore")
                }
            }
            Section {
                Text("No account or server is needed. Network access comes from invitations issued to your identity.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var recoverySection: some View {
        Group {
            Section("Your identity") {
                Text(displayName).font(.headline).textSelection(.enabled)
                if let fingerprint { ALOFingerprint(value: fingerprint) }
            }
            Section("Keep this private") {
                Label {
                    Text("Your recovery kit is unencrypted. Anyone with it can become you and access your networks.")
                        .bold()
                } icon: {
                    Image(systemName: "exclamationmark.shield").accessibilityHidden(true)
                }
                .fixedSize(horizontal: false, vertical: true)

                Text("Never send your recovery kit as an invitation. Share your public identity when someone wants to add you to a network.")
                    .foregroundStyle(.secondary)

                if let recoveryText {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recovery kit contents").font(.subheadline.weight(.medium))
                        ScrollView {
                            Text(recoveryText)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 80, maxHeight: 160)
                        .accessibilityLabel("Private recovery kit contents")
                    }
                } else {
                    Button(action: onRevealRecovery) {
                        ALOActionLabel(title: "Reveal recovery kit", systemImage: "eye")
                    }.disabled(isBusy)
                }

                Button(action: onExportRecovery) {
                    ALOActionLabel(title: recoveryExported ? "Export recovery kit again…" : "Export recovery kit…",
                                   systemImage: "square.and.arrow.up", isBusy: isBusy)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
                .accessibilityIdentifier("ALO.Identity.ExportRecovery")

                if recoveryExported {
                    Label("Recovery kit exported", systemImage: "checkmark.circle")
                }
                Toggle("I saved my recovery kit somewhere private", isOn: $acknowledgesRecoveryRisk)
                    .disabled(isBusy)
            }
            Section {
                Button(action: continueSetup) {
                    ALOActionLabel(title: "Continue to networks", systemImage: "arrow.right", isBusy: isBusy)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("ALO.Identity.Continue")
            } footer: {
                Text("If saving fails, retry with this same identity and recovery kit.")
            }
        }
    }

    private func createIdentity() {
        guard !isBusy else { return }
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            localError = "Enter a display name to create your identity."
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
            localError = "Paste your recovery kit or import a recovery file."
            recoveryFocused = true
            return
        }
        localError = nil
        onRestoreIdentity()
    }

    private func continueSetup() {
        guard !isBusy else { return }
        guard acknowledgesRecoveryRisk, recoveryExported else {
            localError = "Save your recovery kit, then confirm that you kept it somewhere private."
            return
        }
        localError = nil
        onContinue()
    }
}
