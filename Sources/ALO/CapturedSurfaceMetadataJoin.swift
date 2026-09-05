import CoreGraphics
import Foundation
import ALOCore

/// Joins ScreenCaptureKit's metadata callback to the immediately following pixel
/// surface without assuming contentRect fills the encoded frame. One slot only;
/// create a new joiner for every selected source to exclude predecessor geometry.
final class CapturedSurfaceMetadataJoin: @unchecked Sendable {
    struct Joined: Equatable { let metadata: CapturedFrameMetadata; let size: CGSize }
    private let lock = NSLock()
    private var latest: CapturedFrameMetadata?
    private var size: CGSize?
    func metadata(_ value: CapturedFrameMetadata) -> Joined? {
        lock.withLock {
            guard latest.map({ value.captureTimeNanos >= $0.captureTimeNanos }) ?? true else { return nil }
            latest = value
            // Complete/started frames will supply their own real surface size.
            guard value.status != .complete, value.status != .started, let size else { return nil }
            return Joined(metadata: value, size: size)
        }
    }
    func surface(size: CGSize, captureTimeNanos: UInt64) -> Joined? {
        lock.withLock {
            guard let latest, latest.captureTimeNanos == captureTimeNanos,
                  size.width.isFinite, size.height.isFinite,
                  size.width > 0, size.height > 0 else { return nil }
            self.size = size
            return Joined(metadata: latest, size: size)
        }
    }
}
