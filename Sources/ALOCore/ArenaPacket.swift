import Foundation

/// Versioned, ephemeral traffic. Never stored in the room CRDT or chat transcript.
public struct ArenaPlayerSlot: Codable, Equatable, Sendable {
    public var index: Int
    public var name: String
    public var isBot: Bool
    public var ready: Bool
    public init(index: Int, name: String, isBot: Bool, ready: Bool) {
        self.index = index; self.name = name; self.isBot = isBot; self.ready = ready
    }
}

public struct ArenaPacket: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case lobby, join, ready, rematch, spectate, state, input, leave, busy }
    public var version = 4
    public var participantIDs: [String?]?
    public var slots: [ArenaPlayerSlot]?
    public var assignedSlot: Int?
    public var spectating: Bool?
    public var availableSlots: Int?
    public var humanCount: Int?
    public var botCount: Int?
    public var map: ArenaMap?
    public var probe: Double?
    public var echo: Double?
    public var round: Int = 0
    public var kind: Kind
    public var session: String
    public var sequence: Int
    public var playerNames: [String]?
    public var ready: Bool?
    public var started: Bool?
    public var fighter: ArenaFighterKind?
    public var input: ArenaInput?
    public var state: ArenaSimulation?
    public init(kind: Kind, session: String, sequence: Int = 0, fighter: ArenaFighterKind? = nil,
                input: ArenaInput? = nil, state: ArenaSimulation? = nil, ready: Bool? = nil, started: Bool? = nil, playerNames: [String]? = nil, round: Int = 0, map: ArenaMap? = nil, probe: Double? = nil, echo: Double? = nil, slots: [ArenaPlayerSlot]? = nil, assignedSlot: Int? = nil, spectating: Bool? = nil, availableSlots: Int? = nil, humanCount: Int? = nil, botCount: Int? = nil, participantIDs: [String?]? = nil) {
        self.participantIDs = participantIDs
        self.slots = slots; self.assignedSlot = assignedSlot; self.spectating = spectating
        self.availableSlots = availableSlots; self.humanCount = humanCount; self.botCount = botCount
        self.map = map; self.probe = probe; self.echo = echo
        self.kind = kind; self.session = session; self.sequence = sequence
        self.round = round
        self.playerNames = playerNames
        self.ready = ready; self.started = started
        self.fighter = fighter; self.input = input; self.state = state
    }
    public var isValid: Bool {
        guard version == 4, (0...1000).contains(round), UUID(uuidString: session) != nil, (0...1_000_000).contains(sequence) else { return false }
        for stamp in [probe, echo].compactMap({ $0 }) {
            guard stamp.isFinite, stamp >= 0 else { return false }
        }
        if let names = playerNames, !(1...4).contains(names.count) || names.contains(where: { $0.count > 40 }) { return false }
        if let assignedSlot, !(0..<4).contains(assignedSlot) { return false }
        for count in [availableSlots, humanCount, botCount].compactMap({ $0 }) where !(0...4).contains(count) { return false }
        if let humanCount, let botCount, humanCount + botCount > 4 { return false }
        if let participantIDs {
            let ids = participantIDs.compactMap { $0 }
            guard (1...4).contains(participantIDs.count), ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
                  Set(ids).count == ids.count, state == nil || state?.fighters.count == participantIDs.count else { return false }
        }
        if let slots {
            guard (1...4).contains(slots.count), slots.enumerated().allSatisfy({ $0.offset == $0.element.index && $0.element.name.count <= 40 }),
                  state == nil || state?.fighters.count == slots.count,
                  assignedSlot == nil || assignedSlot! < slots.count else { return false }
        }
        switch kind {
        case .input: return input?.isValid == true && state == nil
        case .state: return state?.isValidSnapshot == true && input == nil
        case .join, .lobby: return fighter != nil && state == nil && input == nil
        case .ready: return ready != nil && (state == nil || state?.isValidSnapshot == true) && input == nil
        case .rematch, .spectate, .leave, .busy: return state == nil && input == nil
        }
    }
}
