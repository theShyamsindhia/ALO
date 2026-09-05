import Foundation
import ALONetworking

/// Inline channel attachment cannot await the playback executor. This tiny gate
/// rejects late connection callbacks before they replace another live binding.
final class MediaAttachmentGate: @unchecked Sendable {
    private let lock = NSLock()
    private var token: TransportToken?
    func set(_ token: TransportToken?) { lock.withLock { self.token = token } }
    func accepts(_ token: TransportToken) -> Bool { lock.withLock { self.token == token } }
}
