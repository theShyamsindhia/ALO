import Foundation

public struct BreachSlot: Codable, Equatable, Sendable {
    public var index: Int
    public var name: String
    public var isBot: Bool
    public var ready: Bool
    public init(index: Int, name: String, isBot: Bool, ready: Bool) {
        self.index = index; self.name = name; self.isBot = isBot; self.ready = ready
    }
}

public struct BreachPacket: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case lobby, join, spectate, ready, input, action, state, leave, busy, rematch }
    public var game = "breach-v1"
    public var kind: Kind
    public var session: String
    public var sequence: Int
    public var state: BreachMatch?
    public var input: BreachInput?
    public var slots: [BreachSlot]?
    public var assignedSlot: Int?
    public var spectating: Bool?
    public var waitingForRound: Bool?
    public var ready: Bool?
    public var started: Bool?
    public var availableSlots: Int?
    public var acknowledgedInput: Int?
    public init(kind: Kind, session: String, sequence: Int) { self.kind = kind; self.session = session; self.sequence = sequence }
    public var isValid: Bool {
        guard game == "breach-v1", UUID(uuidString: session) != nil, sequence >= 0,
              assignedSlot.map({ (0..<4).contains($0) }) ?? true,
              availableSlots.map({ (0...4).contains($0) }) ?? true,
              acknowledgedInput.map({ $0 >= -1 }) ?? true,
              input?.isValid ?? true, state?.isValidSnapshot ?? true else { return false }
        if let slots {
            guard slots.count == 4, slots.enumerated().allSatisfy({ $0.offset == $0.element.index && $0.element.name.utf8.count <= 160 }) else { return false }
            if let state, state.players.count != slots.count { return false }
        }
        switch kind {
        case .state:
            guard let state, let slots, started != nil, let spectating, input == nil else { return false }
            if spectating { return assignedSlot == nil }
            guard let assignedSlot else { return false }
            return state.players.indices.contains(assignedSlot) && !slots[assignedSlot].isBot
        case .input, .action: return input != nil && state == nil && slots == nil
        case .ready: return ready != nil && state == nil && input == nil
        case .lobby: return availableSlots != nil && started != nil && slots != nil && state == nil
        default: return state == nil && input == nil && slots == nil
        }
    }
}
