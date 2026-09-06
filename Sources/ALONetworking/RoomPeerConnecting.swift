import Foundation

/// The single room-scoped dialing boundary for media, video, voice and files.
/// The implementation resolves an ALREADY ADMITTED peer, proves the requested
/// role with the current room/identity, bounds pending dials, and cancels them
/// on room exit. Callers must not manufacture endpoints from advertisements.
///
/// Completion runs on the transport executor: install handlers inline before
/// hopping to a UI/native-media executor, or coalesced early payloads are lost.
public protocol RoomPeerConnecting: AnyObject {
    func openPeerChannel(to peerID: UUID, role: ReliableChannelRole,
        completion: @escaping (Result<(SecurePeerChannel, AuthenticatedPeer), Error>) -> Void)
}

extension MeshControlPlane: RoomPeerConnecting {}
