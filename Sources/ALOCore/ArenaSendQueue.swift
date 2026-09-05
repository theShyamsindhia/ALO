import Foundation

/// Backpressure for activity traffic. Lifecycle messages take priority over obsolete frames.
public struct ArenaSendQueue: Sendable {
    private var lifecycle: [(kind: String, data: Data)] = []
    private var latestFrame: Data?
    public init() {}
    public var count: Int { lifecycle.count + (latestFrame == nil ? 0 : 1) }
    public mutating func enqueue(kind: String, data: Data) {
        guard data.count <= 16_384 else { return }
        if kind == "state" || kind == "input" { latestFrame = data; return }
        if kind == "leave" { lifecycle.removeAll(); latestFrame = nil }
        lifecycle.removeAll { $0.kind == kind }
        if lifecycle.count == 8 { lifecycle.removeFirst() }
        lifecycle.append((kind, data))
    }
    public mutating func popFirst() -> Data? {
        if !lifecycle.isEmpty { return lifecycle.removeFirst().data }
        defer { latestFrame = nil }
        return latestFrame
    }
}
