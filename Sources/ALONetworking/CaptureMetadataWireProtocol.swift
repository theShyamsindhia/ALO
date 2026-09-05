import CoreGraphics
import Foundation
import ALOCore

/// Geometry sent only on the admitted current broadcaster's media-control
/// channel. The expected source ID comes from its accepted annotation snapshot,
/// never from this payload. Desktop coordinates and window identifiers stay local.
public struct CaptureMetadataWireMessage: Equatable, Sendable {
    public static let protocolName = "alo.capture-metadata"
    public static let version = 1
    public static let maximumWireBytes = 4_096
    public static let maximumFrameDimension = 16_384
    public static let maximumFramePixels = 67_108_864

    private struct Rect: Codable, Equatable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    private struct Envelope: Codable, Equatable, Sendable {
        let protocolName: String
        let version: Int
        let sessionID: UUID
        let captureTimeNanos: UInt64
        let frameWidth: Int
        let frameHeight: Int
        let contentRect: Rect
        let contentScale: Double
        let scaleFactor: Double
        let status: CapturedFrameMetadata.Status
    }

    private let envelope: Envelope
    public var sessionID: UUID { envelope.sessionID }
    public var captureTimeNanos: UInt64 { envelope.captureTimeNanos }
    public var frameSize: CGSize { CGSize(width: envelope.frameWidth, height: envelope.frameHeight) }
    public var normalizedContentRect: CGRect {
        CGRect(x: envelope.contentRect.x, y: envelope.contentRect.y,
               width: envelope.contentRect.width, height: envelope.contentRect.height)
    }

    /// The caller supplies the encoded surface dimensions and its content rect
    /// in pixels. Do not pass desktop points or a scaled viewer's image bounds.
    /// Unavailable/stopped statuses retain the last known valid source geometry.
    public init(sessionID: UUID, metadata: CapturedFrameMetadata, frameSize: CGSize) throws {
        guard frameSize.width.isFinite, frameSize.height.isFinite,
              (1...CGFloat(Self.maximumFrameDimension)).contains(frameSize.width),
              (1...CGFloat(Self.maximumFrameDimension)).contains(frameSize.height),
              frameSize.width.rounded(.towardZero) == frameSize.width,
              frameSize.height.rounded(.towardZero) == frameSize.height,
              metadata.contentRect.origin.x.isFinite, metadata.contentRect.origin.y.isFinite,
              metadata.contentRect.size.width.isFinite, metadata.contentRect.size.height.isFinite,
              metadata.contentRect.size.width > 0, metadata.contentRect.size.height > 0,
              metadata.contentRect.origin.x >= 0, metadata.contentRect.origin.y >= 0,
              metadata.contentRect.origin.x + metadata.contentRect.size.width <= frameSize.width,
              metadata.contentRect.origin.y + metadata.contentRect.size.height <= frameSize.height else {
            throw SecureTransportError.malformed
        }
        let x = Double(metadata.contentRect.origin.x / frameSize.width)
        let y = Double(metadata.contentRect.origin.y / frameSize.height)
        envelope = Envelope(protocolName: Self.protocolName, version: Self.version,
            sessionID: sessionID, captureTimeNanos: metadata.captureTimeNanos,
            frameWidth: Int(frameSize.width), frameHeight: Int(frameSize.height),
            contentRect: Rect(x: x, y: y,
                width: min(Double(metadata.contentRect.size.width / frameSize.width), 1 - x),
                height: min(Double(metadata.contentRect.size.height / frameSize.height), 1 - y)),
            contentScale: metadata.contentScale, scaleFactor: metadata.scaleFactor, status: metadata.status)
        try Self.validate(envelope)
    }

    public func encoded() throws -> Data {
        let data = try JSONEncoder().encode(envelope)
        guard data.count <= Self.maximumWireBytes else { throw SecureTransportError.oversized }
        return data
    }

    /// Authentication/role admission is the media channel's responsibility.
    /// This mandatory source check prevents delayed geometry from a prior share
    /// being applied to the currently displayed source. Equal timestamps remain
    /// legal so an idle/stopped status can accompany the last captured frame.
    public init(encoded data: Data, expectedSessionID: UUID, notBeforeCaptureTimeNanos: UInt64? = nil) throws {
        guard data.count <= Self.maximumWireBytes else { throw SecureTransportError.oversized }
        let decoded = try JSONDecoder().decode(Envelope.self, from: data)
        try Self.validate(decoded)
        guard decoded.sessionID == expectedSessionID else { throw SecureTransportError.wrongContext }
        if let minimum = notBeforeCaptureTimeNanos, decoded.captureTimeNanos < minimum {
            throw SecureTransportError.replay
        }
        envelope = decoded
    }

    /// Reconstruct surface-pixel geometry for the viewer presentation controller.
    /// Missing desktop coordinates are intentional and do not disable viewers.
    public var viewerMetadata: CapturedFrameMetadata {
        let rect = envelope.contentRect
        let x = rect.x * Double(envelope.frameWidth), y = rect.y * Double(envelope.frameHeight)
        return CapturedFrameMetadata(captureTimeNanos: captureTimeNanos,
            contentRect: CGRect(x: x, y: y,
                width: min(rect.width * Double(envelope.frameWidth), Double(envelope.frameWidth) - x),
                height: min(rect.height * Double(envelope.frameHeight), Double(envelope.frameHeight) - y)),
            screenRect: nil, contentScale: envelope.contentScale, scaleFactor: envelope.scaleFactor,
            status: envelope.status, desktopOverlaySupported: false)
    }

    private static func validate(_ value: Envelope) throws {
        guard value.protocolName == protocolName, value.version == version else {
            throw SecureTransportError.unsupportedProtocol
        }
        let rect = value.contentRect
        guard (1...maximumFrameDimension).contains(value.frameWidth),
              (1...maximumFrameDimension).contains(value.frameHeight),
              value.frameWidth <= maximumFramePixels / value.frameHeight,
              value.captureTimeNanos < UInt64.max,
              value.contentScale.isFinite, value.scaleFactor.isFinite,
              value.contentScale > 0, value.contentScale <= 16,
              value.scaleFactor > 0, value.scaleFactor <= 16,
              [rect.x, rect.y, rect.width, rect.height].allSatisfy(\.isFinite),
              rect.x >= 0, rect.y >= 0, rect.width > 0, rect.height > 0,
              rect.x <= 1, rect.y <= 1, rect.width <= 1, rect.height <= 1,
              rect.x + rect.width <= 1, rect.y + rect.height <= 1 else {
            throw SecureTransportError.malformed
        }
    }
}
