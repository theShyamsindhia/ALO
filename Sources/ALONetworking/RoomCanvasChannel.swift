import Foundation
import CryptoKit

/// Serial, bounded output. A large image occupies one job, not 128 eagerly
/// encoded frames. Small updates follow it in order; nothing is silently lost.
struct RoomCanvasOutbox {
    static let maximumJobs = 256
    static let maximumBytes = RoomCanvasChunk.maximumPayloadBytes + 512 * 1_024
    private enum Job {
        case message(Data)
        case payload(Data, UUID, Data, Int, Bool)
        var cost: Int {
            switch self { case .message(let bytes): return bytes.count
            case .payload(let bytes, _, _, _, _): return bytes.count }
        }
    }
    private var jobs: [Job] = []
    private(set) var bufferedBytes = 0
    var isEmpty: Bool { jobs.isEmpty }

    mutating func enqueue(_ message: RoomCanvasMessage, roomID: UUID, canvasID: UUID) throws {
        let data = try message.encoded(roomID: roomID, canvasID: canvasID)
        try insert(.message(data))
    }

    mutating func enqueuePayload(_ data: Data, isImage: Bool) throws {
        guard !data.isEmpty, data.count <= RoomCanvasChunk.maximumPayloadBytes else {
            throw SecureTransportError.oversized
        }
        try checkCapacity(data.count)
        try insert(.payload(data, UUID(), Data(SHA256.hash(data: data)), 0, isImage))
    }

    mutating func next(roomID: UUID, canvasID: UUID) throws -> Data? {
        guard let job = jobs.first else { return nil }
        switch job {
        case .message(let data):
            jobs.removeFirst(); bufferedBytes -= job.cost
            return data
        case .payload(let data, let id, let digest, let offset, let isImage):
            let end = min(offset + RoomCanvasChunk.chunkBytes, data.count)
            let chunk = RoomCanvasChunk(transferID: id, offset: offset, totalBytes: data.count,
                sha256: digest, bytes: data.subdata(in: offset..<end))
            let message: RoomCanvasMessage = isImage ? .imageChunk(chunk) : .checkpointChunk(chunk)
            let encoded = try message.encoded(roomID: roomID, canvasID: canvasID)
            if end == data.count { jobs.removeFirst(); bufferedBytes -= job.cost }
            else { jobs[0] = .payload(data, id, digest, end, isImage) }
            return encoded
        }
    }

    mutating func reset() { jobs.removeAll(); bufferedBytes = 0 }

    private func checkCapacity(_ count: Int) throws {
        guard jobs.count < Self.maximumJobs, count <= Self.maximumBytes - bufferedBytes else {
            throw SecurePeerChannelError.queueFull
        }
    }

    private mutating func insert(_ job: Job) throws {
        try checkCapacity(job.cost)
        jobs.append(job); bufferedBytes += job.cost
    }
}

/// Attach inline in the admission callback, before returning to the channel's
/// receive loop. Callbacks run on a separate canvas executor. The owner must install
/// callbacks in `completion`, retain the adapter, and cancel it on room exit.
/// This adapter neither authorizes canvas editing nor auto-joins a canvas.
public final class RoomCanvasChannel: @unchecked Sendable {
    public let peerID: UUID
    public let connectionID: UUID
    public var onMessage: ((RoomCanvasMessage) -> Void)?
    public var onClose: ((Error) -> Void)?
    private let roomID: UUID
    private let canvasID: UUID
    private let channel: SecurePeerChannel
    private let credentials: AuthenticatedChannelCredentials
    private let queue: DispatchQueue
    private var outbox = RoomCanvasOutbox()
    private var sending = false
    private var closed = false
    private var finishing = false
    private var drainingOwner: RoomCanvasChannel?
    private var sendDeadline: DispatchWorkItem?
    private let inputLock = NSLock()
    private var pendingInputBytes = 0
    private var pendingInputs = 0

    public static func attach(_ channel: SecurePeerChannel, roomID: UUID, canvasID: UUID,
                              localID: UUID, peerID: UUID, executor: DispatchQueue? = nil,
                              completion: @escaping (Result<RoomCanvasChannel, Error>) -> Void) {
        channel.withAuthenticatedCredentials { result in
            do {
                let credentials = try result.get()
                try validate(credentials, roomID: roomID, localID: localID, peerID: peerID)
                completion(.success(Self(channel: channel, credentials: credentials, canvasID: canvasID, executor: executor)))
            } catch { channel.cancel(); completion(.failure(error)) }
        }
    }

    static func validate(_ credentials: AuthenticatedChannelCredentials, roomID: UUID,
                         localID: UUID, peerID: UUID) throws {
        guard credentials.isActive, credentials.channelRole == .roomCanvas,
              credentials.roomID == roomID, credentials.localPeerID == localID,
              credentials.remotePeerID == peerID, localID != peerID else {
            throw SecureTransportError.wrongContext
        }
        guard credentials.negotiated.initiatorCapabilities.contains(.roomCanvas),
              credentials.negotiated.responderCapabilities.contains(.roomCanvas) else {
            throw SecureTransportError.unsupportedProtocol
        }
    }

    private init(channel: SecurePeerChannel, credentials: AuthenticatedChannelCredentials, canvasID: UUID, executor: DispatchQueue?) {
        self.channel = channel; self.credentials = credentials; self.canvasID = canvasID
        roomID = credentials.roomID; peerID = credentials.remotePeerID; connectionID = credentials.connectionID
        queue = executor ?? DispatchQueue(label: "alo.canvas.\(credentials.connectionID)", qos: .userInitiated)
        channel.onAuthenticated = nil
        channel.onPayload = { [weak self] in self?.receive($0) }
        channel.onState = { [weak self] state in
            guard let self else { return }
            self.queue.async {
                switch state {
                case .failed(let error): self.close(error)
                case .cancelled: self.close(SecurePeerChannelError.cancelled)
                default: break
                }
            }
        }
    }

    deinit { sendDeadline?.cancel(); channel.cancel() }

    private func receive(_ bytes: Data) {
        // Bound the cross-executor mailbox as well as the output. Hashing and
        // checkpoint decoding never run on the shared room/audio-control queue.
        inputLock.lock()
        guard pendingInputs < 16, bytes.count <= 1_024 * 1_024 - pendingInputBytes else {
            inputLock.unlock()
            queue.async { self.close(SecurePeerChannelError.queueFull) }
            channel.cancel()
            return
        }
        pendingInputs += 1; pendingInputBytes += bytes.count
        inputLock.unlock()
        queue.async {
            defer {
                self.inputLock.lock()
                self.pendingInputs -= 1; self.pendingInputBytes -= bytes.count
                self.inputLock.unlock()
            }
            guard !self.closed else { return }
            do {
                guard self.credentials.isActive else { throw SecurePeerChannelError.notAuthenticated }
                self.onMessage?(try RoomCanvasMessage(encoded: bytes, roomID: self.roomID, canvasID: self.canvasID))
            } catch { self.close(error) }
        }
    }

    public func send(_ message: RoomCanvasMessage) {
        enqueue { try $0.enqueue(message, roomID: self.roomID, canvasID: self.canvasID) }
    }

    public func sendCheckpoint(_ snapshot: RoomCanvasSnapshot) {
        enqueue { outbox in
            guard snapshot.isValid, snapshot.roomID == self.roomID, snapshot.canvasID == self.canvasID,
                  snapshot.ownerID == self.credentials.localPeerID else { throw SecureTransportError.wrongContext }
            try outbox.enqueuePayload(JSONEncoder().encode(snapshot), isImage: false)
        }
    }

    public func sendImage(_ bytes: Data, descriptor: RoomCanvasImage) {
        enqueue { outbox in
            guard descriptor.isValid, bytes.count == descriptor.byteCount,
                  Data(SHA256.hash(data: bytes)) == descriptor.sha256 else { throw SecureTransportError.malformed }
            try outbox.enqueuePayload(bytes, isImage: true)
        }
    }

    public func cancel() { queue.async { self.close(SecurePeerChannelError.cancelled) } }

    /// Unlike cancellation, an explicit owner end reaches the other peer after
    /// all preceding state. Its normal stalled-send deadline still applies.
    public func finish() {
        queue.async {
            guard !self.closed, !self.finishing else { return }
            do {
                try self.outbox.enqueue(.ended, roomID: self.roomID, canvasID: self.canvasID)
                self.finishing = true
                self.drainingOwner = self
                self.pump()
            } catch { self.close(error) }
        }
    }

    private func enqueue(_ operation: @escaping (inout RoomCanvasOutbox) throws -> Void) {
        queue.async {
            guard !self.closed, !self.finishing else { return }
            do {
                guard self.credentials.isActive else { throw SecurePeerChannelError.notAuthenticated }
                try operation(&self.outbox)
                self.pump()
            } catch { self.close(error) }
        }
    }

    private func pump() {
        guard !closed, !sending else { return }
        do {
            guard let bytes = try outbox.next(roomID: roomID, canvasID: canvasID) else {
                if finishing {
                    // A TCP send completion is not peer delivery. Let the
                    // viewer consume `ended` and close its side; cancelling
                    // immediately can revoke its credentials ahead of decode.
                    let deadline = DispatchWorkItem { [weak self] in self?.close(SecurePeerChannelError.cancelled) }
                    sendDeadline = deadline
                    queue.asyncAfter(deadline: .now() + 10, execute: deadline)
                }
                return
            }
            sending = true
            // A stopped reader must release our buffer even if TCP never calls
            // its send completion. Recovery is a new connection + checkpoint.
            let deadline = DispatchWorkItem { [weak self] in self?.close(SecurePeerChannelError.timedOut) }
            sendDeadline = deadline
            queue.asyncAfter(deadline: .now() + 10, execute: deadline)
            channel.send(payload: bytes) { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    guard !self.closed else { return }
                    self.sendDeadline?.cancel(); self.sendDeadline = nil; self.sending = false
                    switch result {
                    case .success: self.pump()
                    case .failure(let error): self.close(error)
                    }
                }
            }
        } catch { close(error) }
    }

    private func close(_ error: Error) {
        guard !closed else { return }
        closed = true; sendDeadline?.cancel(); sendDeadline = nil
        outbox.reset(); sending = false
        channel.cancel()
        let callback = onClose; onClose = nil; onMessage = nil
        callback?(error)
        drainingOwner = nil
    }
}
