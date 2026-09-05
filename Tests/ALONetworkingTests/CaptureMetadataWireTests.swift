import CoreGraphics
import Foundation
import Testing
import ALOCore
@testable import ALONetworking

@Suite
struct CaptureMetadataWireTests {
    private func metadata(status: CapturedFrameMetadata.Status = .complete) -> CapturedFrameMetadata {
        CapturedFrameMetadata(captureTimeNanos: 123_456,
            contentRect: CGRect(x: 80, y: 60, width: 640, height: 480),
            screenRect: CGRect(x: -1234, y: 9876, width: 640, height: 480),
            contentScale: 0.5, scaleFactor: 2, status: status)
    }

    private func rewrite(_ data: Data, _ change: (inout [String: Any]) -> Void) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        change(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test("Wire geometry follows the encoded surface and omits the presenter's desktop")
    func geometryAndPrivacy() throws {
        let session = UUID()
        let source = metadata()
        let message = try CaptureMetadataWireMessage(sessionID: session, metadata: source,
            frameSize: CGSize(width: 800, height: 600))
        let data = try message.encoded()
        #expect(data.count <= CaptureMetadataWireMessage.maximumWireBytes)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("screenRect") && !json.contains("desktopOverlaySupported"))
        #expect(!json.contains("-1234") && !json.contains("9876"))
        let decoded = try CaptureMetadataWireMessage(encoded: data, expectedSessionID: session)
        #expect(decoded == message)
        #expect(decoded.normalizedContentRect == CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
        #expect(decoded.viewerMetadata.contentRect == source.contentRect)
        #expect(decoded.viewerMetadata.contentScale == 0.5 && decoded.viewerMetadata.scaleFactor == 2)
        #expect(decoded.viewerMetadata.screenRect == nil && !decoded.viewerMetadata.desktopOverlaySupported)
    }

    @Test("Metadata cannot cross sharing sessions or move capture time backward")
    func sourceAndTimestampAdmission() throws {
        let session = UUID()
        let message = try CaptureMetadataWireMessage(sessionID: session, metadata: metadata(), frameSize: CGSize(width: 800, height: 600))
        let data = try message.encoded()
        #expect(throws: SecureTransportError.wrongContext) {
            try CaptureMetadataWireMessage(encoded: data, expectedSessionID: UUID())
        }
        #expect(throws: SecureTransportError.replay) {
            try CaptureMetadataWireMessage(encoded: data, expectedSessionID: session, notBeforeCaptureTimeNanos: 123_457)
        }
        #expect(try CaptureMetadataWireMessage(encoded: data, expectedSessionID: session,
            notBeforeCaptureTimeNanos: 123_456).captureTimeNanos == 123_456)
    }

    @Test("Normalization keeps edge-aligned source content inside the decoded surface")
    func edgeAlignedGeometry() throws {
        for width in [641, 1365, 1921, 3839] {
            let session = UUID()
            let size = CGSize(width: width, height: 1079)
            var source = metadata()
            source.contentRect = CGRect(x: 7, y: 3, width: width - 7, height: 1076)
            let wire = try CaptureMetadataWireMessage(sessionID: session, metadata: source, frameSize: size)
            let decoded = try CaptureMetadataWireMessage(encoded: wire.encoded(), expectedSessionID: session)
            #expect(CGRect(origin: .zero, size: size).contains(decoded.viewerMetadata.contentRect))
            #expect(abs(decoded.viewerMetadata.contentRect.maxX - CGFloat(width)) < 0.000_001)
            #expect(abs(decoded.viewerMetadata.contentRect.maxY - 1079) < 0.000_001)
        }
    }

    @Test("Unavailable source status survives transport without granting desktop access")
    func frameStatusTransitions() throws {
        for status: CapturedFrameMetadata.Status in [.complete, .idle, .blank, .suspended, .started, .stopped, .unavailable] {
            let session = UUID()
            let message = try CaptureMetadataWireMessage(sessionID: session, metadata: metadata(status: status),
                frameSize: CGSize(width: 800, height: 600))
            let decoded = try CaptureMetadataWireMessage(encoded: message.encoded(), expectedSessionID: session)
            #expect(decoded.viewerMetadata.status == status)
            #expect(!decoded.viewerMetadata.isInteractive, "Desktop interactivity must never be inferred from remote geometry")
        }
    }

    @Test("Invalid local geometry cannot produce a wire payload")
    func invalidLocalGeometry() {
        for value in [Double.nan, .infinity, -.infinity, -1, 0, 17] {
            var invalid = metadata()
            invalid.scaleFactor = value
            #expect(throws: (any Error).self) {
                try CaptureMetadataWireMessage(sessionID: UUID(), metadata: invalid, frameSize: CGSize(width: 800, height: 600))
            }
        }
        for rect in [CGRect(x: -1, y: 0, width: 20, height: 20), CGRect(x: 799, y: 0, width: 2, height: 1),
                     CGRect(x: 0, y: 0, width: 0, height: 1), CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)] {
            var invalid = metadata()
            invalid.contentRect = rect
            #expect(throws: (any Error).self) {
                try CaptureMetadataWireMessage(sessionID: UUID(), metadata: invalid, frameSize: CGSize(width: 800, height: 600))
            }
        }
        for size in [CGSize(width: 800.5, height: 600), CGSize(width: CGFloat.infinity, height: 600),
                     CGSize(width: 16_385, height: 600), CGSize(width: 16_384, height: 16_384)] {
            #expect(throws: (any Error).self) {
                try CaptureMetadataWireMessage(sessionID: UUID(), metadata: metadata(), frameSize: size)
            }
        }
    }

    @Test("Untrusted wire fields are bounded and validated before presentation")
    func invalidWireGeometry() throws {
        let session = UUID()
        let data = try CaptureMetadataWireMessage(sessionID: session, metadata: metadata(),
            frameSize: CGSize(width: 800, height: 600)).encoded()
        let changes: [(inout [String: Any]) -> Void] = [
            { $0["frameWidth"] = 0 }, { $0["frameHeight"] = -1 }, { $0["frameWidth"] = 16_385 },
            { $0["frameWidth"] = 16_384; $0["frameHeight"] = 16_384 },
            { $0["frameWidth"] = 800.5 }, { $0["contentScale"] = 0 }, { $0["scaleFactor"] = 17 },
            { $0["contentRect"] = ["x": 0.8, "y": 0.1, "width": 0.8, "height": 0.8] },
            { $0["contentRect"] = ["x": -0.1, "y": 0.1, "width": 0.8, "height": 0.8] },
            { $0["contentRect"] = ["x": "NaN", "y": 0.1, "width": 0.8, "height": 0.8] },
            { $0["status"] = "unknown" }, { $0.removeValue(forKey: "sessionID") },
            { $0["protocolName"] = "other" }, { $0["version"] = 2 }
        ]
        for change in changes {
            let invalid = try rewrite(data, change)
            #expect(throws: (any Error).self) {
                try CaptureMetadataWireMessage(encoded: invalid, expectedSessionID: session)
            }
        }
        #expect(throws: SecureTransportError.oversized) {
            try CaptureMetadataWireMessage(encoded: data + Data(repeating: 32, count: 4_096), expectedSessionID: session)
        }
    }
}
