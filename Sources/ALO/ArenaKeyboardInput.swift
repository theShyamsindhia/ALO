import Foundation
import ALOCore

/// Physical-key controls support the existing right-hand layout and a compact
/// left-hand action layout. No global event monitor captures room-chat typing.
struct ArenaKeyboardInput {
    static let handledKeys: Set<UInt16> = [0, 2, 13, 1, 49, 38, 40, 37, 6, 7, 8, 123, 124, 125, 126]
    private var keys = Set<UInt16>()
    mutating func press(_ code: UInt16) { if Self.handledKeys.contains(code) { keys.insert(code) } }
    mutating func release(_ code: UInt16) { keys.remove(code) }
    mutating func reset() { keys.removeAll() }
    var input: ArenaInput {
        var input = ArenaInput()
        input.horizontal = (keys.contains(2) || keys.contains(124) ? 1 : 0) - (keys.contains(0) || keys.contains(123) ? 1 : 0)
        input.vertical = (keys.contains(13) || keys.contains(126) ? 1 : 0) - (keys.contains(1) || keys.contains(125) ? 1 : 0)
        input.jump = keys.contains(49)
        input.light = keys.contains(38) || keys.contains(6)
        input.heavy = keys.contains(40) || keys.contains(7)
        input.dodge = keys.contains(37) || keys.contains(8)
        return input
    }
}
