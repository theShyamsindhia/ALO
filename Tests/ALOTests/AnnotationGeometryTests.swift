import CoreGraphics
import Testing
@testable import ALOCore

struct AnnotationGeometryTests {
    private func metadata(
        rect: CGRect = CGRect(x: 100, y: 80, width: 800, height: 600),
        status: CapturedFrameMetadata.Status = .complete
    ) -> CapturedFrameMetadata {
        CapturedFrameMetadata(captureTimeNanos: 123, contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              screenRect: rect, contentScale: 0.5, scaleFactor: 2, status: status)
    }

    @Test("Aspect fit rejects letterboxing and preserves normalized content coordinates")
    func aspectFitInput() throws {
        let rect = try #require(AnnotationGeometry.aspectFitRect(
            contentSize: CGSize(width: 1600, height: 900),
            in: CGRect(x: 10, y: 20, width: 800, height: 600)
        ))
        #expect(rect == CGRect(x: 10, y: 95, width: 800, height: 450))
        #expect(AnnotationGeometry.normalizedPoint(CGPoint(x: 410, y: 50), in: rect) == nil)
        #expect(AnnotationGeometry.normalizedPoint(CGPoint(x: 410, y: 320), in: rect) == CGPoint(x: 0.5, y: 0.5))
        #expect(AnnotationGeometry.point(CGPoint(x: 1, y: 1), in: rect) == CGPoint(x: 810, y: 545))
    }

    @Test("Resized captured windows exclude padding inside the encoded video frame")
    func resizedWindowContent() throws {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let frameSize = CGSize(width: 1280, height: 720)
        let rect = try #require(AnnotationGeometry.visibleContentRect(
            frameSize: frameSize,
            contentRect: CGRect(x: 80, y: 0, width: 960, height: 720), in: bounds
        ))
        #expect(rect == CGRect(x: 50, y: 75, width: 600, height: 450))
        #expect(AnnotationGeometry.normalizedPoint(CGPoint(x: 25, y: 300), in: rect) == nil)
        #expect(AnnotationGeometry.normalizedPoint(CGPoint(x: 350, y: 300), in: rect) == CGPoint(x: 0.5, y: 0.5))
    }

    @Test("AppKit conversion follows the primary display across negative desktop origins")
    func multipleDisplayOrigins() {
        // A secondary monitor sits to the left and above the primary monitor.
        let screenRect = CGRect(x: -1600, y: -900, width: 1200, height: 800)
        #expect(AnnotationGeometry.appKitRect(from: screenRect, primaryDisplayHeight: 1080)
                == CGRect(x: -1600, y: 1180, width: 1200, height: 800))
        #expect(AnnotationGeometry.appKitPoint(CGPoint(x: 0.25, y: 0.75),
                                              metadata: metadata(rect: screenRect), primaryDisplayHeight: 1080)
                == CGPoint(x: -1300, y: 1380))
    }

    @Test("Desktop alignment updates when the captured window moves or resizes")
    func desktopResizeAlignment() {
        let center = CGPoint(x: 0.5, y: 0.5)
        #expect(AnnotationGeometry.appKitPoint(center, metadata: metadata(), primaryDisplayHeight: 1080)
                == CGPoint(x: 500, y: 700))
        let moved = metadata(rect: CGRect(x: 1920, y: 100, width: 1200, height: 800))
        #expect(AnnotationGeometry.appKitPoint(center, metadata: moved, primaryDisplayHeight: 1080)
                == CGPoint(x: 2520, y: 580))
    }

    @Test("Unavailable and minimized capture statuses never accept desktop input",
          arguments: [CapturedFrameMetadata.Status.blank, .suspended, .stopped, .unavailable])
    func unavailableFrames(status: CapturedFrameMetadata.Status) {
        let frame = metadata(status: status)
        #expect(!frame.isInteractive)
        #expect(AnnotationGeometry.appKitPoint(.zero, metadata: frame, primaryDisplayHeight: 1080) == nil)
    }

    @Test("Invalid geometry and out-of-range coordinates cannot create annotations")
    func invalidGeometry() {
        #expect(AnnotationGeometry.aspectFitRect(contentSize: .zero,
                                                in: CGRect(x: 0, y: 0, width: 100, height: 100)) == nil)
        #expect(AnnotationGeometry.point(CGPoint(x: -0.1, y: 0.5),
                                        in: CGRect(x: 0, y: 0, width: 100, height: 100)) == nil)
        #expect(!metadata(rect: .zero).isInteractive)
        var frame = metadata()
        frame.screenRect = nil
        #expect(!frame.isInteractive)
        frame = metadata()
        frame.contentScale = .nan
        #expect(!frame.isInteractive)
        frame = metadata()
        frame.desktopOverlaySupported = false
        #expect(!frame.isInteractive)
        #expect(AnnotationGeometry.appKitPoint(.zero, metadata: frame, primaryDisplayHeight: 1080) == nil)
    }
}
