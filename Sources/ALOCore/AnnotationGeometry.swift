import CoreGraphics
import Foundation

/// The geometry of one ScreenCaptureKit frame, in its original coordinate spaces.
public struct CapturedFrameMetadata: Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case complete, idle, blank, suspended, started, stopped, unavailable

        public var isVisible: Bool { self == .complete || self == .idle || self == .started }
    }

    public var captureTimeNanos: UInt64
    /// The region occupied by content in the captured surface, excluding padding.
    public var contentRect: CGRect
    /// Global CoreGraphics desktop points, with a top-left origin.
    public var screenRect: CGRect?
    public var contentScale: Double
    public var scaleFactor: Double
    public var status: Status
    /// False when the system cannot safely exclude presenter overlays from capture.
    public var desktopOverlaySupported: Bool

    public init(
        captureTimeNanos: UInt64,
        contentRect: CGRect,
        screenRect: CGRect?,
        contentScale: Double,
        scaleFactor: Double,
        status: Status,
        desktopOverlaySupported: Bool = true
    ) {
        self.captureTimeNanos = captureTimeNanos
        self.contentRect = contentRect
        self.screenRect = screenRect
        self.contentScale = contentScale
        self.scaleFactor = scaleFactor
        self.status = status
        self.desktopOverlaySupported = desktopOverlaySupported
    }

    public var isInteractive: Bool {
        desktopOverlaySupported && status.isVisible && AnnotationGeometry.isUsable(contentRect)
            && screenRect.map(AnnotationGeometry.isUsable) == true
            && contentScale.isFinite && contentScale > 0
            && scaleFactor.isFinite && scaleFactor > 0
    }
}

/// Shared annotation coordinates are normalized to the visible captured content.
/// Viewer coordinates are top-left based; AppKit desktop conversion is explicit.
public enum AnnotationGeometry {
    public static func isUsable(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0 && !rect.isNull
    }

    public static func aspectFitRect(contentSize: CGSize, in bounds: CGRect) -> CGRect? {
        guard isUsable(CGRect(origin: .zero, size: contentSize)), isUsable(bounds) else { return nil }
        let scale = min(bounds.width / contentSize.width, bounds.height / contentSize.height)
        let size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Rejects letterbox input; never clamps a point outside the content into a stroke.
    public static func normalizedPoint(_ point: CGPoint, in contentRect: CGRect) -> CGPoint? {
        guard isUsable(contentRect), point.x.isFinite, point.y.isFinite,
              point.x >= contentRect.minX, point.x <= contentRect.maxX,
              point.y >= contentRect.minY, point.y <= contentRect.maxY else { return nil }
        return CGPoint(x: (point.x - contentRect.minX) / contentRect.width,
                       y: (point.y - contentRect.minY) / contentRect.height)
    }

    public static func point(_ normalizedPoint: CGPoint, in contentRect: CGRect) -> CGPoint? {
        guard isUsable(contentRect), normalizedPoint.x.isFinite, normalizedPoint.y.isFinite,
              (0...1).contains(normalizedPoint.x), (0...1).contains(normalizedPoint.y) else { return nil }
        return CGPoint(x: contentRect.minX + normalizedPoint.x * contentRect.width,
                       y: contentRect.minY + normalizedPoint.y * contentRect.height)
    }

    /// A captured window can occupy only part of an encoded frame after resizing.
    /// Project its surface region into the aspect-fit video rectangle before hit testing.
    public static func visibleContentRect(
        frameSize: CGSize, contentRect: CGRect, in bounds: CGRect
    ) -> CGRect? {
        guard let videoRect = aspectFitRect(contentSize: frameSize, in: bounds),
              isUsable(contentRect) else { return nil }
        let clipped = contentRect.intersection(CGRect(origin: .zero, size: frameSize))
        guard isUsable(clipped) else { return nil }
        return CGRect(
            x: videoRect.minX + clipped.minX / frameSize.width * videoRect.width,
            y: videoRect.minY + clipped.minY / frameSize.height * videoRect.height,
            width: clipped.width / frameSize.width * videoRect.width,
            height: clipped.height / frameSize.height * videoRect.height
        )
    }

    /// Flip around the primary display's top edge, never the active display or
    /// union of all displays. This also handles monitors left of or above primary.
    public static func appKitRect(from screenRect: CGRect, primaryDisplayHeight: CGFloat) -> CGRect? {
        guard isUsable(screenRect), primaryDisplayHeight.isFinite, primaryDisplayHeight > 0 else { return nil }
        return CGRect(x: screenRect.minX, y: primaryDisplayHeight - screenRect.maxY,
                      width: screenRect.width, height: screenRect.height)
    }

    public static func appKitPoint(
        _ normalizedPoint: CGPoint, metadata: CapturedFrameMetadata, primaryDisplayHeight: CGFloat
    ) -> CGPoint? {
        guard metadata.isInteractive, let screenRect = metadata.screenRect,
              let rect = appKitRect(from: screenRect, primaryDisplayHeight: primaryDisplayHeight),
              let topLeftPoint = point(normalizedPoint, in: CGRect(origin: .zero, size: rect.size)) else { return nil }
        return CGPoint(x: rect.minX + topLeftPoint.x, y: rect.maxY - topLeftPoint.y)
    }
}
