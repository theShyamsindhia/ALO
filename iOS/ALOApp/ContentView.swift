import SwiftUI
import ALONetworking
import ALOCore

struct ContentView: View {
    @ObservedObject var model: MobileRoomModel
    @State private var joining: NearbyPeerHint?
    @State private var showLeaveConfirmation = false

    var body: some View {
        NavigationStack {
            Group {
                if model.room != nil { roomContent } else { nearbyContent }
            }
            .navigationTitle(model.room?.name ?? "Nearby")
            .safeAreaInset(edge: .bottom) {
                if model.isTemporarySimulatorSession {
                    Label("Simulator test · identity and room data disappear on quit", systemImage: "hammer")
                        .font(.caption).padding().frame(maxWidth: .infinity)
                        .background(.regularMaterial)
                        .accessibilityIdentifier("temporarySimulatorSession")
                }
            }
            .toolbar {
                if model.room != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Leave", role: .destructive) { showLeaveConfirmation = true }
                            .frame(minHeight: 44)
                    }
                }
            }
            .confirmationDialog("Leave this room?", isPresented: $showLeaveConfirmation,
                                titleVisibility: .visible) {
                Button("Leave and forget automatic rejoin", role: .destructive) { model.leave() }
            } message: {
                Text(model.isTemporarySimulatorSession
                     ? "The invite secret is removed from this test session. Temporary history and device keys are discarded when you quit."
                     : "The invite secret is removed from this device. Your local room history and remembered device keys stay saved.")
            }
            .sheet(item: $joining) { hint in
                JoinRoomView(model: model, hint: hint)
            }
        }
    }

    private var nearbyContent: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("A room, together.").font(.title2.weight(.semibold))
                    Text("Join people on your local network. Your phone can participate in the room without becoming the broadcaster.")
                        .foregroundStyle(.secondary)
                }.padding(.vertical, 8)
                Button(action: model.scan) {
                    Label(model.discoveryState == .browsing ? "Refresh nearby rooms" : "Find nearby rooms",
                          systemImage: "antenna.radiowaves.left.and.right")
                        .frame(minHeight: 44)
                }
            } footer: {
                Text("Finding rooms asks for Local Network access. No microphone access is requested.")
            }
            if model.discoveryState == .permissionRequired {
                Section {
                    Label("Local Network access is off", systemImage: "network.slash")
                    Text("Enable ALO in Settings → Privacy & Security → Local Network, then return and refresh.")
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }.frame(minHeight: 44)
                }
            }
            Section("Rooms") {
                ForEach(model.nearbyRooms) { room in
                    Button { joining = room; model.errorMessage = nil } label: {
                        HStack(spacing: 12) {
                            Image(systemName: room.isPrivate ? "lock" : "person.2")
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(room.displayName).foregroundStyle(.primary)
                                Text(room.isPrivate ? "Private · invite secret required" : "Public · nearby room")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").foregroundStyle(.secondary).accessibilityHidden(true)
                        }.frame(minHeight: 44)
                    }.accessibilityHint("Review privacy and join this room")
                }
                if model.nearbyRooms.isEmpty {
                    if model.discoveryState == .browsing {
                        HStack { ProgressView(); Text("Looking for nearby rooms…") }
                    } else {
                        Text(model.discoveryState == .waiting ? "Network unavailable. The scan will retry briefly." : "No rooms in this scan. Find rooms to refresh the list.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            errorSection
        }.listStyle(.insetGrouped)
    }

    private var roomContent: some View {
        List {
            Section {
                Label(model.status, systemImage: model.connected ? "lock.shield" : "network")
                    .accessibilityIdentifier("roomConnectionStatus")
                if !model.connected {
                    Button("Retry connection", action: model.retry).frame(minHeight: 44)
                }
            }
            errorSection
            Section("In the room") {
                if model.participants.isEmpty { Text("Waiting for authenticated participants…").foregroundStyle(.secondary) }
                ForEach(model.participants) { participant in
                    Label(participant.name + (participant.id == model.localID ? " (you)" : ""),
                          systemImage: participant.id == model.localID ? "iphone" : "person.crop.circle")
                }
            }
            Section {
                NavigationLink { ChatView(model: model) } label: {
                    Label("Room chat", systemImage: "bubble.left.and.bubble.right").frame(minHeight: 44)
                }
                NavigationLink { QueueView(model: model) } label: {
                    Label("Shared queue", systemImage: "music.note.list").frame(minHeight: 44)
                }
            }
            Section("Media") {
                if let title = model.replica.nowPlaying.title {
                    Text(title).font(.headline)
                    if let artist = model.replica.nowPlaying.artist { Text(artist).foregroundStyle(.secondary) }
                }
                Label(model.audioConnected ? "Encrypted audio connected" : "Waiting for audio",
                      systemImage: model.audioConnected ? "speaker.wave.2" : "speaker.slash")
                Text(model.mediaAvailability).font(.subheadline).foregroundStyle(.secondary)
            }
            if model.replica.videoEnabled || model.videoImage != nil {
                Section("Shared screen") {
                    if let image = model.videoImage {
                        MobileAnnotationVideoView(image: image, scene: model.annotationScene)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                    }
                    Text(model.videoStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
            MobileVoiceControls(controller: model.voice,
                participants: model.participants.filter { $0.id != model.localID })
            Section {
                AudioLevelControl(title: "Media", muted: $model.levels.mediaMuted, volume: $model.levels.mediaVolume)
                AudioLevelControl(title: "Voice", muted: $model.levels.voiceMuted, volume: $model.levels.voiceVolume)
            } header: { Text("On this device") } footer: {
                Text("These preferences affect only your device. Incoming voice does not lower media volume. Talk and Open Line request microphone access only after your action.")
            }
        }.listStyle(.insetGrouped)
    }

    @ViewBuilder private var errorSection: some View {
        if let error = model.errorMessage {
            Section {
                Label(error, systemImage: "exclamationmark.triangle")
                Button("Dismiss message") { model.errorMessage = nil }.frame(minHeight: 44)
            }
        }
    }
}

private struct AudioLevelControl: View {
    let title: String
    @Binding var muted: Bool
    @Binding var volume: Float
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Mute \(title.lowercased())", isOn: $muted)
            Slider(value: $volume, in: 0...1) { Text("\(title) volume") }
                .accessibilityValue("\(Int(volume * 100)) percent")
                .disabled(muted)
        }.padding(.vertical, 4)
    }
}

private struct JoinRoomView: View {
    @ObservedObject var model: MobileRoomModel
    let hint: NearbyPeerHint
    @State private var secret = ""
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?
    private enum Field { case name, secret }
    var body: some View {
        NavigationStack {
            Form {
                Section("Your name in the room") {
                    TextField("Display name", text: $model.displayName)
                        .textContentType(.nickname).focused($focusedField, equals: .name)
                        .accessibilityLabel("Display name")
                }
                if hint.isPrivate {
                    Section {
                        SecureField("Invite secret", text: $secret)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($focusedField, equals: .secret)
                    } header: {
                        Text("Private room invite")
                    } footer: {
                        Text(model.isTemporarySimulatorSession
                             ? "Paste the full base64 secret. This simulator test keeps it only in memory until quit."
                             : "Paste the full base64 secret shared by a room member. It is stored in Keychain only after admission succeeds.")
                    }
                }
                Section("Before you join") {
                    Label("Encrypted connection", systemImage: "lock.shield")
                    Text("Nearby room and device names are unverified. Joining establishes an encrypted connection and remembers admitted device keys; it does not verify the person behind a device.")
                    Text("Other room members can see your display name and messages. Once connected, this device advertises the room nearby. A public room is open to nearby people; a private room requires its invite secret.")
                    Text(model.isTemporarySimulatorSession
                         ? "Use isolated test peers and a throwaway room. Other members can retain this device’s key, participant record, and messages, even after you quit. ALO reconnects only within this running test session; quitting forgets its local room and identity. Your microphone never starts automatically."
                         : "After a successful join, ALO reconnects to this room when you return to the app. It never starts your microphone automatically.")
                }
                if let error = model.errorMessage {
                    Section { Label(error, systemImage: "exclamationmark.triangle") }
                }
                Section {
                    Button("Join room") {
                        if model.join(hint, secret: secret) { secret = ""; dismiss() }
                        else { focusedField = model.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .name : .secret }
                    }.frame(minHeight: 44).accessibilityIdentifier("joinRoomButton")
                }
            }
            .navigationTitle(hint.displayName).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { secret = ""; dismiss() } } }
        }
    }
}

private struct ChatView: View {
    @ObservedObject var model: MobileRoomModel
    @State private var message = ""
    @State private var validation: String?
    @State private var replyingTo: RoomChatMessage?
    @State private var editing: RoomChatMessage?
    var body: some View {
        List {
            Section {
                if model.chatMessages.isEmpty { Text("No messages yet.").foregroundStyle(.secondary) }
                ForEach(model.chatMessages) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(item.sender).font(.subheadline.weight(.semibold))
                            if item.pinned { Image(systemName: "pin.fill").accessibilityLabel("Pinned") }
                            if item.edited && !item.deleted { Text("Edited").font(.caption).foregroundStyle(.secondary) }
                        }
                        if let reply = item.replyTo,
                           let parent = model.chatMessages.first(where: { $0.id == reply }) {
                            Text("Reply to \(parent.sender): \(parent.text)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Text(item.text).foregroundStyle(item.deleted ? .secondary : .primary).textSelection(.enabled)
                        if !item.deleted {
                            HStack {
                                ForEach(item.reactions.keys.sorted(), id: \.self) { emoji in
                                    if let users = item.reactions[emoji], !users.isEmpty {
                                        Text("\(emoji) \(users.count)").font(.caption)
                                    }
                                }
                            }
                        }
                    }.padding(.vertical, 4).accessibilityElement(children: .combine)
                        .contextMenu {
                            if !item.deleted {
                                Button("Reply") { replyingTo = item; editing = nil }
                                if item.senderID == model.localID {
                                    Button("Edit") { editing = item; replyingTo = nil; message = item.text }
                                    Button("Delete", role: .destructive) {
                                        _ = model.sendChatOperation(.init(kind: .delete, target: item.id))
                                    }
                                }
                                Menu("React") {
                                    ForEach(RoomChatOperation.emoji, id: \.self) { emoji in
                                        Button(emoji) {
                                            _ = model.sendChatOperation(.init(kind: .reaction, target: item.id, text: emoji,
                                                enabled: !(item.reactions[emoji]?.contains(model.localID) ?? false)))
                                        }
                                    }
                                }
                                Button(item.pinned ? "Unpin" : "Pin") {
                                    _ = model.sendChatOperation(.init(kind: .pin, target: item.id, enabled: !item.pinned))
                                }
                            }
                        }
                }
            } footer: {
                Text("Showing up to 500 messages with shared edits, replies and reactions.")
            }
            Section("Message the room") {
                if editing != nil {
                    HStack { Text("Editing your message"); Spacer(); Button("Cancel") { self.editing = nil; message = "" } }
                } else if let replyingTo {
                    HStack { Text("Replying to \(replyingTo.sender)"); Spacer(); Button("Cancel") { self.replyingTo = nil } }
                }
                TextField("Message", text: $message, axis: .vertical).lineLimit(1...6)
                if let validation { Text(validation).foregroundStyle(.secondary) }
                Button("Send message") {
                    let operation = RoomChatOperation(kind: editing == nil ? .message : .edit,
                        target: editing?.id ?? replyingTo?.id,
                        text: message.trimmingCharacters(in: .whitespacesAndNewlines))
                    if model.sendChatOperation(operation) { message = ""; validation = nil; editing = nil; replyingTo = nil }
                    else { validation = "Use a nonempty message of at most 700 characters (4 KB including formatting)." }
                }.disabled(!model.connected).frame(minHeight: 44)
                if !model.connected { Text("Reconnect to send messages.").foregroundStyle(.secondary) }
            }
        }.navigationTitle("Room chat").navigationBarTitleDisplayMode(.inline)
    }
}

private struct MobileVoiceControls: View {
    @ObservedObject var controller: MobileVoiceController
    let participants: [RoomParticipant]
    var body: some View {
        Section {
            Label(controller.status, systemImage: controller.transmitting ? "mic.fill" : "mic.slash")
            if controller.requesting || controller.transmitting {
                Button(controller.requesting ? "Cancel microphone request" : "Stop talking", role: .destructive) {
                    if controller.openLine == .idle { controller.endTransmission() } else { controller.endOpenLine() }
                }.frame(minHeight: 44)
            }
            switch controller.openLine {
            case .invited(let invitation):
                Text("\(invitation.callerName) is calling. You can hear them before picking up.")
                Button("Pick up · turn microphone on") { Task { await controller.respond(accept: true) } }
                    .disabled(controller.requesting).frame(minHeight: 44)
                Button("Decline", role: .cancel) { Task { await controller.respond(accept: false) } }.frame(minHeight: 44)
            case .inviting:
                Text("Calling · your microphone is on for this peer")
                Button("End Open Line", role: .destructive) { controller.endOpenLine() }.frame(minHeight: 44)
            case .connected:
                Text("Open Line connected · both directions use encrypted voice")
                Button("End Open Line", role: .destructive) { controller.endOpenLine() }.frame(minHeight: 44)
            case .idle:
                ForEach(participants) { participant in
                    if let id = UUID(uuidString: participant.id) {
                        VStack(alignment: .leading) {
                            Toggle(participant.name, isOn: Binding(
                                get: { controller.selectedRecipients.contains(id) },
                                set: { selected in
                                    if selected { controller.selectedRecipients.insert(id) }
                                    else { controller.selectedRecipients.remove(id) }
                                }))
                                .disabled(controller.requesting || controller.transmitting)
                            Button("Open Line with \(participant.name)") { Task { await controller.invite(id) } }
                                .disabled(!controller.ready || controller.requesting || controller.transmitting)
                                .frame(minHeight: 44)
                        }
                    }
                }
                Button("Talk to selected people") { Task { await controller.beginTalk() } }
                    .disabled(!controller.ready || controller.requesting || controller.transmitting || controller.selectedRecipients.isEmpty)
                    .frame(minHeight: 44)
            }
        } header: {
            Text("Talk and Open Line")
        } footer: {
            Text("Choose up to eight people. Invite turns your microphone on for that person; Pick up starts voice back. Rejoining, interruptions and route changes turn it off. New room members are never added to an active microphone session.")
        }
    }
}

private struct QueueView: View {
    @ObservedObject var model: MobileRoomModel
    var body: some View {
        List {
            Section {
                if model.replica.queue.isEmpty { Text("The shared queue is empty.").foregroundStyle(.secondary) }
                ForEach(model.replica.queue) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.headline)
                        if let subtitle = item.subtitle { Text(subtitle).foregroundStyle(.secondary) }
                        Text("Added by \(item.addedBy)").font(.caption).foregroundStyle(.secondary)
                    }.accessibilityElement(children: .combine)
                }
            } footer: { Text("The shared queue is read-only on iPhone and iPad. Playback is controlled by the broadcaster.") }
        }.navigationTitle("Shared queue").navigationBarTitleDisplayMode(.inline)
    }
}
