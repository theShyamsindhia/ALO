import Foundation

/// Versioned, ephemeral traffic. Never stored in the room CRDT or chat transcript.
public struct ArenaPacket: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case lobby, join, ready, rematch, spectate, state, input, leave, busy }
    public var version = 1
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
                input: ArenaInput? = nil, state: ArenaSimulation? = nil, ready: Bool? = nil, started: Bool? = nil, playerNames: [String]? = nil, round: Int = 0) {
        self.kind = kind; self.session = session; self.sequence = sequence
        self.round = round
        self.playerNames = playerNames
        self.ready = ready; self.started = started
        self.fighter = fighter; self.input = input; self.state = state
    }
    public var isValid: Bool {
        guard version == 1, (0...1000).contains(round), UUID(uuidString: session) != nil, (0...1_000_000).contains(sequence) else { return false }
        if let names = playerNames, names.count != 2 || names.contains(where: { $0.count > 40 }) { return false }
        switch kind {
        case .input: return input?.isValid == true && state == nil
        case .state: return state?.isValidSnapshot == true && input == nil
        case .join, .lobby: return fighter != nil && state == nil && input == nil
        case .ready: return ready != nil && state == nil && input == nil
        case .rematch, .spectate, .leave, .busy: return state == nil && input == nil
        }
    }
}
