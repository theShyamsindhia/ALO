import Foundation
import ALOCore

enum ArenaKeyAction: String, CaseIterable, Identifiable {
    case moveLeft, moveRight, aimUp, aimDown, jump, light, heavy, dodge, menu

    var id: String { rawValue }
    var title: String {
        switch self {
        case .moveLeft: "Move left"
        case .moveRight: "Move right"
        case .aimUp: "Aim up / recovery"
        case .aimDown: "Aim down / drop"
        case .jump: "Jump / air jump"
        case .light: "Light attack"
        case .heavy: "Signature / heavy"
        case .dodge: "Dodge"
        case .menu: "Game menu"
        }
    }
}

/// One physical key owns one action. Rebinding an occupied key swaps the two
/// actions, so a user can never accidentally make movement or attacks unreachable.
struct ArenaKeyBindings: Equatable {
    private static let defaultCodes: [ArenaKeyAction: UInt16] = [
        .moveLeft: 0, .moveRight: 2, .aimUp: 13, .aimDown: 1,
        .jump: 49, .light: 38, .heavy: 40, .dodge: 37, .menu: 35
    ]
    static let defaults = ArenaKeyBindings(codes: defaultCodes)

    private(set) var codes: [ArenaKeyAction: UInt16]
    var handledKeys: Set<UInt16> { Set(codes.values) }

    init(codes: [ArenaKeyAction: UInt16]) {
        self.codes = Self.defaultCodes
        for action in ArenaKeyAction.allCases {
            guard let code = codes[action], code != 53 else { continue }
            assign(code, to: action)
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> ArenaKeyBindings {
        guard let stored = defaults.dictionary(forKey: "arenaKeyBindings") as? [String: Int] else { return .defaults }
        var codes: [ArenaKeyAction: UInt16] = [:]
        for (raw, value) in stored where value >= 0 && value <= Int(UInt16.max) {
            if let action = ArenaKeyAction(rawValue: raw) { codes[action] = UInt16(value) }
        }
        return ArenaKeyBindings(codes: codes)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(Dictionary(uniqueKeysWithValues: codes.map { ($0.key.rawValue, Int($0.value)) }), forKey: "arenaKeyBindings")
    }

    subscript(_ action: ArenaKeyAction) -> UInt16 { codes[action] ?? Self.defaultCodes[action]! }

    mutating func assign(_ keyCode: UInt16, to action: ArenaKeyAction) {
        guard keyCode != 53 else { return } // Escape remains an emergency menu key.
        let old = self[action]
        if let occupied = ArenaKeyAction.allCases.first(where: { $0 != action && self[$0] == keyCode }) {
            codes[occupied] = old
        }
        codes[action] = keyCode
    }

    func action(for keyCode: UInt16) -> ArenaKeyAction? {
        ArenaKeyAction.allCases.first { self[$0] == keyCode }
    }

    static func displayName(for keyCode: UInt16) -> String {
        let names: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
            34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M", 36: "Return",
            48: "Tab", 49: "Space", 51: "Delete", 53: "Esc", 115: "Home", 116: "Page Up",
            117: "Forward Delete", 119: "End", 121: "Page Down", 123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        if let name = names[keyCode] { return name }
        let digits: [UInt16: String] = [18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0"]
        return digits[keyCode] ?? "Key \(keyCode)"
    }
}

/// Physical-key controls are scoped to the focused arena. Room-chat typing is
/// unaffected because the SpriteKit surface never installs a global monitor.
struct ArenaKeyboardInput {
    var bindings: ArenaKeyBindings
    private var keys = Set<UInt16>()

    init(bindings: ArenaKeyBindings = .defaults) { self.bindings = bindings }
    mutating func press(_ code: UInt16) { if bindings.handledKeys.contains(code) { keys.insert(code) } }
    mutating func release(_ code: UInt16) { keys.remove(code) }
    mutating func reset() { keys.removeAll() }

    var input: ArenaInput {
        var input = ArenaInput()
        input.horizontal = (keys.contains(bindings[.moveRight]) ? 1 : 0) - (keys.contains(bindings[.moveLeft]) ? 1 : 0)
        input.vertical = (keys.contains(bindings[.aimUp]) ? 1 : 0) - (keys.contains(bindings[.aimDown]) ? 1 : 0)
        input.jump = keys.contains(bindings[.jump])
        input.light = keys.contains(bindings[.light])
        input.heavy = keys.contains(bindings[.heavy])
        input.dodge = keys.contains(bindings[.dodge])
        return input
    }
}
