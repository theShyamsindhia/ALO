import Foundation

/// Shared backpressure for library traffic. Each game/session/direction owns its latest frame.
public struct GameSendQueue: Sendable {
    private struct Entry: Sendable { let stream: String; let kind: String; let data: Data }
    private var lifecycle: [Entry] = []
    private var frames: [Entry] = []
    public init() {}
    public var count: Int { lifecycle.count + frames.count }
    public mutating func enqueue(kind: String, data: Data, stream: String = "default") {
        guard data.count <= 16_384, stream.utf8.count <= 160 else { return }
        if kind == "state" || kind == "input" {
            // Replace in-place so a noisy stream cannot starve another stream.
            if let i = frames.firstIndex(where: { $0.stream == stream && $0.kind == kind }) { frames[i] = Entry(stream: stream, kind: kind, data: data) }
            else { if frames.count == 16 { frames.removeFirst() }; frames.append(Entry(stream: stream, kind: kind, data: data)) }
            return
        }
        if kind == "leave" { lifecycle.removeAll { $0.stream == stream }; frames.removeAll { $0.stream == stream } }
        if kind != "action" { lifecycle.removeAll { $0.stream == stream && $0.kind == kind } }
        if lifecycle.count == 32 { lifecycle.removeFirst() }
        lifecycle.append(Entry(stream: stream, kind: kind, data: data))
    }
    public mutating func popFirst() -> Data? {
        if !lifecycle.isEmpty { return lifecycle.removeFirst().data }
        if !frames.isEmpty { return frames.removeFirst().data }
        return nil
    }
}

/// Source compatibility for older callers. There is only one queue implementation.
public typealias ArenaSendQueue = GameSendQueue
