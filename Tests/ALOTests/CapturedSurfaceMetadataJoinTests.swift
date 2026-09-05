import CoreGraphics
import Testing
import ALOCore
@testable import ALO

struct CapturedSurfaceMetadataJoinTests {
    private func metadata(_ time: UInt64, status: CapturedFrameMetadata.Status = .complete) -> CapturedFrameMetadata {
        .init(captureTimeNanos: time, contentRect: CGRect(x: 10, y: 10, width: 100, height: 50),
              screenRect: nil, contentScale: 1, scaleFactor: 2, status: status, desktopOverlaySupported: false)
    }
    @Test func realSurfaceSizeIsJoinedOnlyToMatchingCapture() {
        let join = CapturedSurfaceMetadataJoin()
        #expect(join.metadata(metadata(10)) == nil)
        #expect(join.surface(size: CGSize(width: 200, height: 100), captureTimeNanos: 9) == nil)
        #expect(join.surface(size: CGSize(width: 200, height: 100), captureTimeNanos: 10)?.size == CGSize(width: 200, height: 100))
        #expect(join.metadata(metadata(11, status: .idle))?.size == CGSize(width: 200, height: 100))
        #expect(join.metadata(metadata(9, status: .idle)) == nil)
        let replacement = CapturedSurfaceMetadataJoin()
        #expect(replacement.metadata(metadata(12, status: .idle)) == nil)
    }
}
