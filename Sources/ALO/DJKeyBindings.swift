import AppKit
import Combine
import SwiftUI

enum DJAction: String, CaseIterable, Identifiable {
    case pad0, pad1, pad2, pad3, pad4, pad5, pad6, pad7
    case pad8, pad9, pad10, pad11, pad12, pad13, pad14, pad15
    case deckAPlay, deckBPlay, deckACue, deckBCue, deckALoop, deckBLoop
    case stopAll, crossfadeLeft, crossfadeCenter, crossfadeRight
    case deckARecord, deckBRecord

    var id: String { rawValue }
    static func pad(_ index: Int) -> DJAction { allCases[min(15, max(0, index))] }
    var padIndex: Int? {
        guard rawValue.hasPrefix("pad") else { return nil }
        return Int(rawValue.dropFirst(3))
    }
    var title: String {
        if let index = padIndex { return "Pad \(index + 1)" }
        switch self {
        case .deckARecord: return "Deck A · Record / stop"
        case .deckBRecord: return "Deck B · Record / stop"
        case .deckAPlay: return "Deck A · Play / pause"
        case .deckBPlay: return "Deck B · Play / pause"
        case .deckACue: return "Deck A · Return to cue"
        case .deckBCue: return "Deck B · Return to cue"
        case .deckALoop: return "Deck A · Toggle loop"
        case .deckBLoop: return "Deck B · Toggle loop"
        case .stopAll: return "Stop all"
        case .crossfadeLeft: return "Crossfader · Deck A"
        case .crossfadeCenter: return "Crossfader · Center"
        case .crossfadeRight: return "Crossfader · Deck B"
        default: return rawValue
        }
    }
}

@MainActor
final class DJKeyBindings: ObservableObject {
    static let shared = DJKeyBindings()
    static let storageKey = "alo.dj.keyBindings.v1"
    static let defaults: [DJAction: String] = {
        var mapping: [DJAction: String] = [:]
        for (index, character) in "1234qwerasdfzxcv".enumerated() { mapping[.pad(index)] = String(character) }
        mapping[.deckAPlay] = "t"; mapping[.deckBPlay] = "y"
        mapping[.deckACue] = "g"; mapping[.deckBCue] = "h"
        mapping[.deckALoop] = "b"; mapping[.deckBLoop] = "n"
        mapping[.crossfadeLeft] = "j"; mapping[.crossfadeCenter] = "k"; mapping[.crossfadeRight] = "l"
        mapping[.stopAll] = "escape"
        mapping[.deckARecord] = "u"; mapping[.deckBRecord] = "i"
        return mapping
    }()
    @Published private(set) var mapping: [DJAction: String]
    private let preferences: UserDefaults

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        mapping = Self.defaults
        // Preserve earlier custom keys when the two recording actions are added.
        if let saved = preferences.dictionary(forKey: Self.storageKey) as? [String: String] {
            let recordingActions: [DJAction] = [.deckARecord, .deckBRecord]
            let legacyActions = DJAction.allCases.filter { !recordingActions.contains($0) }
            let expected = saved.count == legacyActions.count ? legacyActions : DJAction.allCases
            guard Set(saved.keys) == Set(expected.map(\.rawValue)) else { return }
            var restored: [DJAction: String] = [:]
            for action in expected {
                guard let raw = saved[action.rawValue], let key = Self.normalized(raw),
                      !restored.values.contains(key) else { return }
                restored[action] = key
            }
            for action in recordingActions where restored[action] == nil {
                let candidates = [Self.defaults[action]!] + Array("abcdefghijklmnopqrstuvwxyz0123456789,./;[]-=!@#$%^&*()").map(String.init)
                guard let free = candidates.first(where: { !restored.values.contains($0) }) else { return }
                restored[action] = free
            }
            mapping = restored
        }
    }

    static func normalized(_ raw: String) -> String? {
        if raw == "\u{1b}" || raw.lowercased() == "escape" || raw == "⎋" { return "escape" }
        let key = raw.lowercased()
        guard key.count == 1, key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(.punctuationCharacters).union(.symbols).contains($0) }) else { return nil }
        return key
    }
    func key(for action: DJAction) -> String { mapping[action] ?? Self.defaults[action]! }
    func label(for action: DJAction) -> String { key(for: action) == "escape" ? "Esc" : key(for: action).uppercased() }
    func action(for key: String) -> DJAction? {
        guard let normalized = Self.normalized(key) else { return nil }
        return mapping.first(where: { $0.value == normalized })?.key
    }
    func setKey(_ raw: String, for action: DJAction) throws {
        guard let key = Self.normalized(raw) else { throw DJKeyError.invalid }
        if let existing = mapping.first(where: { $0.value == key && $0.key != action }) {
            throw DJKeyError.conflict(existing.key.title)
        }
        mapping[action] = key
        save()
    }
    func resetDefaults() { mapping = Self.defaults; save() }
    private func save() { preferences.set(Dictionary(uniqueKeysWithValues: mapping.map { ($0.key.rawValue, $0.value) }), forKey: Self.storageKey) }
}

private enum DJKeyError: LocalizedError {
    case invalid, conflict(String)
    var errorDescription: String? {
        switch self {
        case .invalid: return "Enter one letter, number, or symbol, or type escape."
        case .conflict(let title): return "That key is assigned to \(title). Change its key first."
        }
    }
}

@MainActor
final class DJKeyMonitor {
    private var monitor: Any?
    func start(window: NSWindow, bindings: DJKeyBindings, handler: @escaping (DJAction) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window, weak bindings] event in
            guard let window, let bindings,
                  Self.accepts(event, window: window),
                  let action = bindings.action(for: event.keyCode == 53 ? "escape" : (event.charactersIgnoringModifiers ?? "")) else { return event }
            handler(action)
            return nil
        }
    }
    static func accepts(_ event: NSEvent, window: NSWindow) -> Bool {
        guard event.type == .keyDown, !event.isARepeat,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              window.isKeyWindow, event.windowNumber == window.windowNumber,
              window.attachedSheet == nil, NSApp.modalWindow == nil else { return false }
        if let text = window.firstResponder as? NSText, text.isEditable { return false }
        return true
    }
    func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

struct DJKeyEditorView: View {
    @ObservedObject var bindings: DJKeyBindings
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("DJ keyboard controls").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            Text("Edit a key, then press Return or Apply. Keys work while DJ Studio is active, except while typing or using a sheet. Each action needs its own key.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(DJAction.allCases) { action in
                        DJKeyEditorRow(action: action, key: bindings.key(for: action)) { key in
                            do { try bindings.setKey(key, for: action); error = nil }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).accessibilityLabel(error) }
            HStack {
                Button("Reset defaults") { bindings.resetDefaults(); error = nil }
                Spacer()
                Text("Escape is entered as “escape”.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(24).frame(width: 570, height: 630)
    }
}

private struct DJKeyEditorRow: View {
    let action: DJAction
    let key: String
    let apply: (String) -> Void
    @State private var draft = ""
    var body: some View {
        HStack {
            Text(action.title)
            Spacer()
            TextField("Key", text: $draft).textFieldStyle(.roundedBorder).frame(width: 80)
                .accessibilityLabel("Key for \(action.title)").onSubmit { apply(draft) }
            Button("Apply") { apply(draft) }.disabled(draft == key)
        }.onAppear { draft = key }.onChange(of: key) { _, newValue in draft = newValue }
    }
}
