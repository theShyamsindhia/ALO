import ALOCore

/// Secure media has no authenticated remote-volume command yet. Do not present
/// a local optimistic slider as authority over another device's output.
enum ParticipantMediaControlPolicy {
    static func allows(policy: RoomTransportPolicy?, isBroadcaster: Bool, isLocal: Bool) -> Bool {
        isLocal || (policy == .legacyOnly && isBroadcaster)
    }
}
