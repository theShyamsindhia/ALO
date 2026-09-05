import AppKit
import Carbon
import SwiftUI
import ALOCore

struct GlobalShortcutAction: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case talkToEveryone
        case talkToDevice
        case shareScreen
        case broadcastAudio
        case stopAudioBroadcast
        case stopScreenShare
        case syncMyDevice
        case syncAllDevices
        case toggleAnnotations
    }

    let kind: Kind
    let participantID: String?

    init(_ kind: Kind, participantID: String? = nil) {
        self.kind = kind
        self.participantID = participantID
    }

    var id: String { participantID.map { "\(kind.rawValue):\($0)" } ?? kind.rawValue }

    static let talkToEveryone = Self(.talkToEveryone)

    static func talkToDevice(_ participantID: String) -> Self {
        Self(.talkToDevice, participantID: participantID)
    }

    static let fixedActions: [Self] = [
        .talkToEveryone,
        Self(.shareScreen),
        Self(.broadcastAudio),
        Self(.stopAudioBroadcast),
        Self(.stopScreenShare),
        Self(.syncMyDevice),
        Self(.syncAllDevices),
        Self(.toggleAnnotations),
    ]
}

struct GlobalShortcutKey: Codable, Hashable, Sendable {
    struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        let rawValue: UInt32

        static let command = Self(rawValue: 1 << 0)
        static let option = Self(rawValue: 1 << 1)
        static let control = Self(rawValue: 1 << 2)
        static let shift = Self(rawValue: 1 << 3)
    }

    let keyCode: UInt32
    let modifiers: Modifiers
    let keyLabel: String

    init(keyCode: UInt32, modifiers: Modifiers, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    static let talkToEveryoneDefault = Self(
        keyCode: UInt32(kVK_Space),
        modifiers: [.control, .shift],
        keyLabel: "Space"
    )

    var displayName: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + keyLabel
    }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    static func from(event: NSEvent) -> Self? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        guard !modifiers.isEmpty else { return nil }
        let label = keyLabel(for: event)
        guard !label.isEmpty else { return nil }
        return Self(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyLabel: label)
    }

    private static func keyLabel(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        case kVK_PageUp: return "Page Up"
        case kVK_PageDown: return "Page Down"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
             kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
             kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20:
            let functionKeyCodes: [Int: String] = [
                kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
                kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
                kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
                kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16",
                kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
            ]
            return functionKeyCodes[Int(event.keyCode)] ?? ""
        default:
            return event.charactersIgnoringModifiers?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased() ?? ""
        }
    }
}

struct GlobalShortcutBinding: Codable, Equatable, Sendable {
    let action: GlobalShortcutAction
    let key: GlobalShortcutKey
}

struct GlobalShortcutAvailability: Equatable, Sendable {
    let available: Bool
    let reason: String?

    static let ready = Self(available: true, reason: nil)

    static func unavailable(_ reason: String) -> Self {
        Self(available: false, reason: reason)
    }
}

enum ShortcutAssignmentError: Error, Equatable {
    case conflict(GlobalShortcutAction)
    case registrationConflict(String)
}

extension ShortcutAssignmentError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .conflict:
            return "That shortcut is already assigned to another ALO action."
        case .registrationConflict(let message):
            return message
        }
    }
}

struct GlobalShortcutAssignments: Codable, Equatable, Sendable {
    private(set) var bindings: [GlobalShortcutBinding]

    init(bindings: [GlobalShortcutBinding] = []) {
        self.bindings = bindings
    }

    static var defaults: Self {
        Self(bindings: [
            GlobalShortcutBinding(action: .talkToEveryone, key: .talkToEveryoneDefault)
        ])
    }

    func key(for action: GlobalShortcutAction) -> GlobalShortcutKey? {
        bindings.first(where: { $0.action == action })?.key
    }

    func action(for key: GlobalShortcutKey) -> GlobalShortcutAction? {
        bindings.first(where: { $0.key == key })?.action
    }

    mutating func assign(_ key: GlobalShortcutKey, to action: GlobalShortcutAction) throws {
        if let conflict = bindings.first(where: { $0.key == key && $0.action != action })?.action {
            throw ShortcutAssignmentError.conflict(conflict)
        }
        bindings.removeAll(where: { $0.action == action })
        bindings.append(GlobalShortcutBinding(action: action, key: key))
    }

    mutating func clear(_ action: GlobalShortcutAction) {
        bindings.removeAll(where: { $0.action == action })
    }

    mutating func reset() {
        self = .defaults
    }
}

struct GlobalShortcutPressState: Equatable, Sendable {
    private(set) var pressedIDs = Set<UInt32>()

    mutating func shouldDispatch(id: UInt32, pressed: Bool) -> Bool {
        if pressed { return pressedIDs.insert(id).inserted }
        return pressedIDs.remove(id) != nil
    }

    mutating func removeAll() {
        pressedIDs.removeAll()
    }
}

@MainActor
final class GlobalShortcutManager: ObservableObject {
    typealias ActionHandler = (GlobalShortcutAction, Bool) -> Void

    @Published private(set) var assignments: GlobalShortcutAssignments
    @Published private(set) var registrationErrors = [GlobalShortcutAction: String]()

    private struct Registration {
        let action: GlobalShortcutAction
        let reference: EventHotKeyRef
    }

    nonisolated private static let signature: OSType = 0x414C4F48 // "ALOH"
    nonisolated private static let defaultsKey = "globalShortcutAssignments.v1"
    private let defaults: UserDefaults
    private let actionHandler: ActionHandler
    private var eventHandler: EventHandlerRef?
    private var listenerInstallError: String?
    private var registrations = [UInt32: Registration]()
    private var pressState = GlobalShortcutPressState()
    private var nextID: UInt32 = 1

    init(defaults: UserDefaults = .standard, actionHandler: @escaping ActionHandler) {
        self.defaults = defaults
        self.actionHandler = actionHandler
        if let data = defaults.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode(GlobalShortcutAssignments.self, from: data) {
            assignments = stored
        } else {
            assignments = .defaults
        }
        installEventHandler()
        registerAll()
    }

    deinit {
        for (id, registration) in registrations {
            if pressState.pressedIDs.contains(id) { actionHandler(registration.action, false) }
            UnregisterEventHotKey(registration.reference)
        }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    func key(for action: GlobalShortcutAction) -> GlobalShortcutKey? {
        assignments.key(for: action)
    }

    func assign(_ key: GlobalShortcutKey, to action: GlobalShortcutAction) throws {
        var updated = assignments
        try updated.assign(key, to: action)
        let previous = assignments
        unregisterAll()
        assignments = updated
        registerAll()
        if let message = registrationErrors[action] {
            unregisterAll()
            assignments = previous
            registerAll()
            throw ShortcutAssignmentError.registrationConflict(message)
        }
        persist()
    }

    func clear(_ action: GlobalShortcutAction) {
        var updated = assignments
        updated.clear(action)
        assignments = updated
        persistAndReregister()
    }

    func reset() {
        assignments = .defaults
        persistAndReregister()
    }

    private func persistAndReregister() {
        persist()
        unregisterAll()
        registerAll()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(assignments) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    private func installEventHandler() {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            guard hotKeyID.signature == GlobalShortcutManager.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let kind = GetEventKind(event)
            let id = hotKeyID.id
            let pressed = kind == UInt32(kEventHotKeyPressed)
            let manager = Unmanaged<GlobalShortcutManager>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in
                manager.handleEvent(id: id, pressed: pressed)
            }
            return noErr
        }
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        if status != noErr {
            listenerInstallError = "ALO could not install its global shortcut listener (\(status))."
        }
    }

    private func registerAll() {
        registrationErrors.removeAll()
        if let listenerInstallError {
            for binding in assignments.bindings {
                registrationErrors[binding.action] = listenerInstallError
            }
            return
        }
        for binding in assignments.bindings {
            var reference: EventHotKeyRef?
            let id = nextID
            nextID &+= 1
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
            let status = RegisterEventHotKey(
                binding.key.keyCode,
                binding.key.carbonModifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &reference
            )
            if status == noErr, let reference {
                registrations[id] = Registration(action: binding.action, reference: reference)
            } else {
                registrationErrors[binding.action] = status == OSStatus(eventHotKeyExistsErr)
                    ? "That shortcut is already used by macOS or another app."
                    : "The shortcut could not be registered (\(status))."
            }
        }
    }

    private func unregisterAll() {
        for (id, registration) in registrations {
            if pressState.pressedIDs.contains(id) { actionHandler(registration.action, false) }
            UnregisterEventHotKey(registration.reference)
        }
        registrations.removeAll()
        pressState.removeAll()
    }

    private func handleEvent(id: UInt32, pressed: Bool) {
        guard let registration = registrations[id] else { return }
        guard pressState.shouldDispatch(id: id, pressed: pressed) else { return }
        actionHandler(registration.action, pressed)
    }
}

@MainActor
final class ShortcutMapperWindowController: NSWindowController {
    init(manager: GlobalShortcutManager, model: ALOViewModel) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Shortcut Mapper"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 480)
        window.contentView = NSHostingView(rootView: ShortcutMapperView(manager: manager, model: model))
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct ShortcutMapperView: View {
    @ObservedObject var manager: GlobalShortcutManager
    @ObservedObject var model: ALOViewModel
    @State private var recordingAction: GlobalShortcutAction?
    @State private var assignmentError: String?

    private var remoteParticipants: [RoomParticipant] {
        model.participants.filter { $0.id != model.currentParticipantID }
    }

    private var unavailableDeviceActions: [GlobalShortcutAction] {
        let currentIDs = Set(remoteParticipants.map(\.id))
        return manager.assignments.bindings
            .map(\.action)
            .filter { $0.kind == .talkToDevice && !currentIDs.contains($0.participantID ?? "") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Shortcut Mapper").font(.largeTitle.bold())
                Text("Shortcuts work while ALO is in the background and do not need Accessibility or Input Monitoring access.")
                    .foregroundStyle(.secondary)
                Text("Talk shortcuts transmit only while the keys are held down.")
                    .foregroundStyle(.secondary)
            }
            .padding(24)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    sectionTitle("Talk")
                    shortcutRow(.talkToEveryone)
                    ForEach(remoteParticipants) { participant in
                        shortcutRow(.talkToDevice(participant.id), participantName: participant.name)
                    }
                    ForEach(unavailableDeviceActions) { action in
                        shortcutRow(action, participantName: "Unavailable device")
                    }

                    sectionTitle("Media and sync")
                    ForEach(GlobalShortcutAction.fixedActions.filter { $0 != .talkToEveryone }) { action in
                        shortcutRow(action)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }

            Divider()
            HStack {
                Text("Default: ⌃⇧Space talks to everyone")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset to Default") { manager.reset() }
            }
            .padding(18)
        }
        .frame(minWidth: 600, minHeight: 480)
        .sheet(item: $recordingAction) { action in
            ShortcutCaptureSheet(
                actionTitle: title(for: action),
                onCapture: { key in
                    do {
                        try manager.assign(key, to: action)
                        assignmentError = nil
                        recordingAction = nil
                    } catch ShortcutAssignmentError.conflict(let conflict) {
                        assignmentError = "\(key.displayName) is already assigned to \(title(for: conflict))."
                        recordingAction = nil
                    } catch {
                        assignmentError = error.localizedDescription
                        recordingAction = nil
                    }
                },
                onCancel: { recordingAction = nil }
            )
        }
        .alert("Shortcut not changed", isPresented: Binding(
            get: { assignmentError != nil },
            set: { if !$0 { assignmentError = nil } }
        )) {
            Button("OK", role: .cancel) { assignmentError = nil }
        } message: {
            Text(assignmentError ?? "")
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .padding(.top, 18)
            .padding(.bottom, 7)
    }

    private func shortcutRow(_ action: GlobalShortcutAction, participantName: String? = nil) -> some View {
        let availability = model.globalShortcutAvailability(action)
        return HStack(spacing: 14) {
            Image(systemName: icon(for: action))
                .frame(width: 24)
                .foregroundStyle(availability.available ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(for: action, participantName: participantName)).fontWeight(.medium)
                if let registrationError = manager.registrationErrors[action] {
                    Text(registrationError).font(.caption).foregroundStyle(.red)
                } else if let reason = availability.reason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let key = manager.key(for: action) {
                Button(key.displayName) { recordingAction = action }
                    .buttonStyle(.bordered)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                Button {
                    manager.clear(action)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear shortcut")
            } else {
                Button("Record") { recordingAction = action }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func title(for action: GlobalShortcutAction, participantName: String? = nil) -> String {
        switch action.kind {
        case .talkToEveryone: return "Talk to everyone"
        case .talkToDevice:
            let resolvedName = participantName
                ?? model.participants.first(where: { $0.id == action.participantID })?.name
                ?? "Unavailable device"
            return "Talk to \(resolvedName)"
        case .shareScreen: return "Share screen"
        case .broadcastAudio: return "Broadcast audio"
        case .stopAudioBroadcast: return "Stop audio broadcast"
        case .stopScreenShare: return "Stop screen share"
        case .syncMyDevice: return "Sync my device"
        case .syncAllDevices: return "Sync all devices"
        case .toggleAnnotations: return "Toggle screen annotations"
        }
    }

    private func icon(for action: GlobalShortcutAction) -> String {
        switch action.kind {
        case .talkToEveryone, .talkToDevice: return "waveform.badge.mic"
        case .shareScreen: return "rectangle.on.rectangle"
        case .broadcastAudio: return "dot.radiowaves.left.and.right"
        case .stopAudioBroadcast: return "stop.circle"
        case .stopScreenShare: return "rectangle.slash"
        case .syncMyDevice: return "arrow.triangle.2.circlepath"
        case .syncAllDevices: return "arrow.triangle.2.circlepath.circle"
        case .toggleAnnotations: return "pencil.tip.crop.circle"
        }
    }
}

private struct ShortcutCaptureSheet: View {
    let actionTitle: String
    let onCapture: (GlobalShortcutKey) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "keyboard")
                .font(.system(size: 34))
                .foregroundStyle(Color.accentColor)
            Text("Record shortcut").font(.title2.bold())
            Text(actionTitle).foregroundStyle(.secondary)
            ShortcutCaptureView(onCapture: onCapture, onCancel: onCancel)
                .frame(width: 300, height: 64)
            Text("Hold at least one modifier (⌃, ⌥, ⇧, or ⌘) and press another key. Use the clear button in the mapper to remove a shortcut, or press Escape to cancel.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
        }
        .padding(28)
        .frame(width: 450)
    }
}

private struct ShortcutCaptureView: NSViewRepresentable {
    let onCapture: (GlobalShortcutKey) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> ShortcutCaptureNSView {
        ShortcutCaptureNSView(onCapture: onCapture, onCancel: onCancel)
    }

    func updateNSView(_ nsView: ShortcutCaptureNSView, context: Context) {
        nsView.onCapture = onCapture
        nsView.onCancel = onCancel
    }
}

private final class ShortcutCaptureNSView: NSView {
    var onCapture: (GlobalShortcutKey) -> Void
    var onCancel: () -> Void
    private let label = NSTextField(labelWithString: "Press shortcut now…")

    init(onCapture: @escaping (GlobalShortcutKey) -> Void, onCancel: @escaping () -> Void) {
        self.onCapture = onCapture
        self.onCancel = onCancel
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        label.alignment = .center
        label.font = .monospacedSystemFont(ofSize: 17, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onCancel()
            return
        }
        guard event.keyCode != UInt16(kVK_Delete), event.keyCode != UInt16(kVK_ForwardDelete) else {
            NSSound.beep()
            return
        }
        guard let key = GlobalShortcutKey.from(event: event) else {
            label.stringValue = "Add a modifier key"
            NSSound.beep()
            return
        }
        label.stringValue = key.displayName
        onCapture(key)
    }
}
