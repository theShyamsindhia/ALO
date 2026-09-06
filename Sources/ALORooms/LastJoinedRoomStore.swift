import Foundation
import ALOCore

/// Stores only the room identifier. Room names and private access keys remain
/// in `RoomStore`/Keychain and are never duplicated in preferences.
public struct LastJoinedRoomStore {
    private static let roomIDKey = "lastActivelyJoinedRoomID"
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "lastActivelyJoinedRoomID") {
        self.defaults = defaults
        self.key = key
    }

    public func markJoined(_ room: RoomConfiguration) {
        defaults.set(room.id, forKey: key)
    }

    public func roomToRestore(from rooms: [RoomConfiguration]) -> RoomConfiguration? {
        guard let id = defaults.string(forKey: key) else { return nil }
        guard let room = rooms.first(where: { $0.id == id }) else {
            defaults.removeObject(forKey: key)
            return nil
        }
        return room
    }

    public func clear(ifMatching roomID: String? = nil) {
        if let roomID, defaults.string(forKey: key) != roomID { return }
        defaults.removeObject(forKey: key)
    }
}
