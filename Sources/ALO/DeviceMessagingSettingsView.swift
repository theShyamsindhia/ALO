import AppKit
import SwiftUI
import ALOAppModel
import ALONetworking

/// Only explicit local user actions approve executable/task/device authority.
/// Names discovered on the network never appear as authenticated consent rows.
struct DeviceMessagingSettingsView: View {
    @ObservedObject var controller: MacDeviceMessagingController
    @ObservedObject private var account: NetworkAccountModel
    @State private var selectedRegistration: UUID?
    @State private var confirmation = ""
    @State private var retirement: MacDeviceMessagingController.StoredGrant?
    @State private var messageRetirement: MacDeviceMessagingController.Message?
    private var verifiedSelection: Bool {
        controller.view.registrations.contains { $0.id == selectedRegistration && $0.state == .verified }
    }
    init(controller: MacDeviceMessagingController) {
        self.controller = controller; self.account = controller.account
    }
    private var command: String? { Bundle.main.executableURL.map { DeviceMessagingLocalEndpoint.shellArgument($0.path) + " codex" } }
    var body: some View {
        Form {
            Section("Opt-in device messaging") {
                Text("Allow approved devices to queue attributed text to a task you explicitly register and verify. Queued does not mean delivered.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Approve local Codex executable…") {
                    let picker = NSOpenPanel(); picker.canChooseDirectories = false
                    picker.allowsMultipleSelection = false; picker.prompt = "Approve executable"
                    if picker.runModal() == .OK, let url = picker.url { controller.approveExecutable(url) }
                }
                if let executable = controller.view.executable { Text(executable).font(.caption).textSelection(.enabled) }
                Toggle("Enable owner-local messaging", isOn: Binding(get: { controller.view.enabled }, set: controller.setEnabled))
                    .disabled(controller.view.executable == nil || controller.view.stopping || !controller.account.identityReady)
                if controller.view.stopping { Text("Revoking authority and stopping…").foregroundStyle(.secondary) }
                if let error = controller.view.error { Text(error).textSelection(.enabled) }
                if let notice = controller.view.notice { Text(notice).font(.caption).textSelection(.enabled) }
            }
            Section("Networks") {
                Text("Explicitly enable each saved network. This advertises your device and the network identifier to nearby devices, including for networks you do not own. It does not join an audio channel or grant task access.").font(.caption)
                ForEach(account.networks, id: \.id) { network in
                    Button("Enable messaging in \(network.name)") { controller.enableNetwork(network.id) }
                        .disabled(!controller.view.enabled)
                }
            }
            Section("Registered local tasks") {
                if let command {
                    Text("From the owning task: \(command) register --task UUID --title 'TITLE'")
                        .font(.caption).textSelection(.enabled)
                    Button("Copy registration command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command + " register --task UUID --title 'TITLE'", forType: .string)
                    }
                }
                Text("Use this app's exact executable path: Dev and release have separate owner-local endpoints. Registration alone grants nothing.").font(.caption)
                Picker("Explicit local task selection", selection: $selectedRegistration) {
                    Text("Choose a registered task").tag(UUID?.none)
                    ForEach(controller.view.registrations, id: \.id) { entry in
                        Text("\(entry.title) · \(entry.state == .verified ? "verified" : "not verified")").tag(Optional(entry.id))
                    }
                }
                ForEach(controller.view.registrations, id: \.id) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title).font(.headline)
                        Text("Registration: \(entry.id.uuidString)").font(.caption).textSelection(.enabled)
                        Text("Task: \(entry.taskID.uuidString)").font(.caption).textSelection(.enabled)
                        if let status = controller.view.capabilityStatuses[entry.id] { Text(status).font(.caption) }
                        HStack {
                            Button("Queue fixed capability test") { controller.test(entry.id) }
                                .disabled(entry.state == .revoked || !controller.view.enabled)
                            Button("Revoke and forget registration") { controller.forget(entry.id) }
                        }
                    }
                }
                TextField("Code read in the actual selected task", text: $confirmation)
                Button("Confirm code from task") {
                    guard let selectedRegistration else { return }
                    controller.confirm(selectedRegistration, response: confirmation); confirmation = ""
                }.disabled(selectedRegistration == nil || confirmation.isEmpty)
                Text("The generated code is intentionally not shown here. A successful queue exit is not task receipt confirmation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Nearby candidates — not yet authenticated") {
                ForEach(controller.view.candidates) { candidate in
                    Button("Authenticate candidate \(candidate.id.uuidString.prefix(8))") { controller.connect(candidate) }
                }
            }
            Section("Authenticated incoming devices") {
                ForEach(controller.view.incoming) { peer in
                    VStack(alignment: .leading) {
                        Text(peer.root).font(.caption).textSelection(.enabled)
                        Text("Full TLS key: \(peer.spki)").font(.caption2).textSelection(.enabled)
                        Button("Approve selected verified local task for this device") {
                            guard let selectedRegistration else { return }
                            controller.approve(peer.id, registration: selectedRegistration)
                        }.disabled(!verifiedSelection)
                    }
                }
            }
            Section("Authenticated outbound destinations") {
                ForEach(controller.view.remotes) { peer in
                    VStack(alignment: .leading) {
                        Text(peer.root).font(.caption).textSelection(.enabled)
                        Text("Full TLS key: \(peer.spki)").font(.caption2).textSelection(.enabled)
                        ForEach(peer.grants, id: \.self) { grant in
                            Button("Use receiver-approved grant \(grant.uuidString.prefix(8)) for selected local task") {
                                guard let selectedRegistration else { return }
                                controller.bind(peer.id, grant: grant, registration: selectedRegistration)
                            }.disabled(!verifiedSelection)
                        }
                    }
                }
            }
            Section("Stored receiver grants") {
                Text("Revoked grants remain as duplicate/uncertain evidence across restart. Retiring one permanently discards its stored receipt history; it never authorizes replay.").font(.caption)
                ForEach(controller.view.storedGrants) { grant in
                    VStack(alignment: .leading) {
                        Text("\(grant.id.uuidString) · \(grant.records) stored receipts").textSelection(.enabled)
                        Text("Local task: \(grant.task.uuidString)").textSelection(.enabled)
                        Button("Retire revoked grant and discard receipts…", role: .destructive) { retirement = grant }
                            .disabled(!grant.revoked)
                    }.font(.caption)
                }
            }
            Section("Local message snapshots") {
                ForEach(controller.view.destinations) { destination in
                    VStack(alignment: .leading) {
                        Text("Destination: \(destination.id.uuidString)").textSelection(.enabled)
                        Text("Registration: \(destination.registration.uuidString)").textSelection(.enabled)
                        Text(destination.root).textSelection(.enabled)
                        if let command {
                            Text("printf %s 'MESSAGE' | \(command) send --registration \(destination.registration.uuidString) --destination \(destination.id.uuidString) --message NEW-UUID")
                                .font(.caption).textSelection(.enabled)
                        }
                    }.font(.caption)
                }
                ForEach(controller.view.messages) { message in
                    HStack {
                        Text("\(message.message.uuidString): \(message.status)").font(.caption).textSelection(.enabled)
                        Button("Clear local status…") { messageRetirement = message }
                    }
                }
                Text("Up to 32 local statuses are retained. Clearing one frees local capacity only; the receiver's stored receipts and duplicate protection remain.").font(.caption)
                Text("Re-testing a task or a network authority change retires its routes. Earlier statuses become historical and cannot be queried here; the receiver remains authoritative.").font(.caption)
                if let command {
                    Text("\(command) receipt --registration UUID --message UUID")
                        .font(.caption).textSelection(.enabled)
                }
                Text("Explicit status query only. No text is resent automatically.").font(.caption)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Permanently discard this revoked grant's receipt history?", isPresented: Binding(
            get: { retirement != nil }, set: { if !$0 { retirement = nil } })) {
                Button("Discard stored receipts", role: .destructive) {
                    if let retirement { controller.retireGrant(retirement.id, network: retirement.network) }
                    retirement = nil
                }
                Button("Cancel", role: .cancel) { retirement = nil }
            }
        .accessibilityIdentifier("ALO.Settings.DeviceMessaging")
        .confirmationDialog("Clear this local status? No message will be resent and the receiver's stored receipts will remain.", isPresented: Binding(
            get: { messageRetirement != nil }, set: { if !$0 { messageRetirement = nil } })) {
                Button("Clear local status") {
                    if let messageRetirement { controller.retireMessage(messageRetirement) }
                    messageRetirement = nil
                }
                Button("Cancel", role: .cancel) { messageRetirement = nil }
            }
    }
}
