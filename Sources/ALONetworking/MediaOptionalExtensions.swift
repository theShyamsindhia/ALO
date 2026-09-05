import Foundation

/// A final raw ingress bound still applies after an optional extension has been
/// quarantined. Classification never parses beyond the secure channel's cap.
struct RawMediaTrafficBudget {
    private var started: UInt64?
    private var count = 0
    private var bytes = 0
    mutating func accept(_ size: Int, now: UInt64) -> Bool {
        guard size >= 0, size <= SecurePeerChannel.maximumPayloadBytes else { return false }
        if started == nil || now < started! || now - started! >= 1_000_000_000 {
            started = now; count = 0; bytes = 0
        }
        guard count < 4_096, size <= 20 * 1_024 * 1_024 - bytes else { return false }
        count += 1; bytes += size; return true
    }
}

enum MediaOptionalExtension {
    case annotation, metadata
    private struct Header: Decodable { let protocolName: String }
    static func classify(_ data: Data) -> Self? {
        guard data.count <= SecurePeerChannel.maximumPayloadBytes,
              let header = try? JSONDecoder().decode(Header.self, from: data) else { return nil }
        switch header.protocolName {
        case AnnotationWireMessage.capability: return .annotation
        case CaptureMetadataWireMessage.protocolName: return .metadata
        default: return nil
        }
    }
}
