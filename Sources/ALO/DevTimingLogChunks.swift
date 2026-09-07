import Foundation

/// Local dev evidence only. Unified logging can truncate a single dynamic value
/// near 1KB, so every line (including framing) stays below 800 UTF-8 bytes.
enum DevTimingLogChunks {
    struct Part: Equatable {
        let sampledAtNanos: UInt64
        let index: Int
        let count: Int
        let payload: String
        var line: String {
            "Dev timing sample monotonic_ns=\(sampledAtNanos) part=\(index)/\(count): \(payload)"
        }
    }

    static func make(detail: String, sampledAtNanos: UInt64) -> [Part] {
        var payloads: [String] = []
        var current = ""
        var bytes = 0
        // Reserve ample framing space, even for maximum-width integer fields.
        for scalar in detail.unicodeScalars {
            let value = String(scalar)
            let size = value.utf8.count
            if bytes + size > 640 {
                payloads.append(current); current = ""; bytes = 0
            }
            current += value
            bytes += size
        }
        payloads.append(current)
        return payloads.enumerated().map {
            Part(sampledAtNanos: sampledAtNanos, index: $0.offset + 1,
                 count: payloads.count, payload: $0.element)
        }
    }

    /// A missing, duplicated, or mixed-snapshot part invalidates the capture.
    static func reassemble(_ parts: [Part]) -> String? {
        guard let first = parts.first, first.count == parts.count,
              parts.allSatisfy({ $0.sampledAtNanos == first.sampledAtNanos && $0.count == first.count }),
              Set(parts.map(\.index)) == Set(1...parts.count) else { return nil }
        return parts.sorted { $0.index < $1.index }.map(\.payload).joined()
    }
}
