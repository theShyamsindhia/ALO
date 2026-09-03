import Foundation
import WERAICore

/// Stores only the room identifier. Room names and private access keys remain
/// in `RoomStore`/Keychain and are never duplicated in preferences.
struct LastJoinedRoomStore {
    private static let roomIDKey = "lastActivelyJoinedRoomID"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func markJoined(_ room: RoomConfiguration) {
        defaults.set(room.id, forKey: Self.roomIDKey)
    }

    func roomToRestore(from rooms: [RoomConfiguration]) -> RoomConfiguration? {
        guard let id = defaults.string(forKey: Self.roomIDKey) else { return nil }
        guard let room = rooms.first(where: { $0.id == id }) else {
            defaults.removeObject(forKey: Self.roomIDKey)
            return nil
        }
        return room
    }

    func clear(ifMatching roomID: String? = nil) {
        if let roomID, defaults.string(forKey: Self.roomIDKey) != roomID { return }
        defaults.removeObject(forKey: Self.roomIDKey)
    }
}
