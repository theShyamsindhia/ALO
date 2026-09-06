import Foundation
import CryptoKit
import ALONetworking

/// File IO and hashing run off both the UI and room control executors.
final class DirectFileTransfer: @unchecked Sendable {
    let id = UUID()
    let peerID: UUID
    private let transmit: (Data, @escaping (Result<Void, Error>) -> Void) -> Void
    private let cancelChannel: () -> Void
    private let queue = DispatchQueue(label: "alo.file-transfer", qos: .utility)
    private let pendingLock = NSLock()
    private var pendingPayloads = 0
    private let source: URL?
    private let onOffer: (DirectFileTransfer, String, Int64) -> Void
    private let onProgress: (UUID, Double) -> Void
    private let onEnd: (UUID, Result<URL?, Error>) -> Void
    private enum Phase { case offer, decision, sending, pacing, receiving, finishing, ended }
    private var phase = Phase.offer
    private var name = ""
    private var size: Int64 = 0
    private var offset: Int64 = 0
    private var reader: FileHandle?
    private var sink: DirectFileSink?
    private var destination: URL?
    private var hash = SHA256()
    private var timeout: DispatchWorkItem?
    private var lastProgress = -1.0

    // Install handlers inline on the authenticated channel executor so an
    // offer coalesced with the handshake cannot be lost during a UI hop.
    convenience init(channel: SecurePeerChannel, peerID: UUID, source: URL?,
         onOffer: @escaping (DirectFileTransfer, String, Int64) -> Void,
         onProgress: @escaping (UUID, Double) -> Void,
         onEnd: @escaping (UUID, Result<URL?, Error>) -> Void) {
        self.init(peerID: peerID, source: source,
            transmit: { channel.send(payload: $0, completion: $1) }, cancelChannel: { channel.cancel() },
            onOffer: onOffer, onProgress: onProgress, onEnd: onEnd)
        channel.onPayload = { [weak self] data in
            self?.receivePayload(data)
        }
        channel.onState = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.cancel()
            default: break
            }
        }
    }
    init(peerID: UUID, source: URL?,
         transmit: @escaping (Data, @escaping (Result<Void, Error>) -> Void) -> Void,
         cancelChannel: @escaping () -> Void,
         onOffer: @escaping (DirectFileTransfer, String, Int64) -> Void,
         onProgress: @escaping (UUID, Double) -> Void,
         onEnd: @escaping (UUID, Result<URL?, Error>) -> Void) {
        self.peerID = peerID; self.source = source
        self.transmit = transmit; self.cancelChannel = cancelChannel
        self.onOffer = onOffer; self.onProgress = onProgress; self.onEnd = onEnd
    }
    func receivePayload(_ data: Data) {
        let admitted = pendingLock.withLock {
            guard data.count <= 100 * 1024, pendingPayloads < 4 else { return false }
            pendingPayloads += 1; return true
        }
        guard admitted else { cancel(); return }
        queue.async {
            defer { self.pendingLock.withLock { self.pendingPayloads -= 1 } }
            self.receive(data)
        }
    }
    func start() {
        queue.async {
            guard self.phase != .ended else { return }
            self.armTimeout()
            guard let source = self.source else { return }
            do {
                self.name = try DirectFileWire.safeName(source.lastPathComponent)
                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let count = values.fileSize, count <= DirectFileWire.maximumFileBytes else { throw DirectFileError.tooLarge }
                self.size = Int64(count)
                self.reader = try FileHandle(forReadingFrom: source)
                self.phase = .decision
                self.armTimeout()
                self.send(.offer(name: self.name, size: self.size))
            } catch { self.end(.failure(error)) }
        }
    }
    func accept() {
        queue.async {
            guard self.source == nil, self.phase == .decision else { return }
            do {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ALO-Incoming-\(self.id)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                self.destination = directory.appendingPathComponent(self.name)
                self.sink = try DirectFileSink(url: self.destination!, size: self.size)
                self.phase = .receiving
                self.armTimeout()
                self.send(.accept)
            } catch { self.end(.failure(error)) }
        }
    }
    func decline() {
        queue.async {
            guard self.phase == .decision else { return }
            self.send(.decline) { self.end(.failure(DirectFileError.declined)) }
        }
    }
    func cancel() { queue.async { self.end(.failure(DirectFileError.interrupted)) } }
    private func receive(_ data: Data) {
        guard phase != .ended else { return }
        do {
            let message = try DirectFileWire.decode(data)
            armTimeout()
            switch message {
            case .offer(let name, let count) where source == nil && phase == .offer:
                self.name = try DirectFileWire.safeName(name)
                guard count >= 0, count <= DirectFileWire.maximumFileBytes else { throw DirectFileError.tooLarge }
                size = count; phase = .decision; armTimeout()
                DispatchQueue.main.async { self.onOffer(self, name, count) }
            case .accept where source != nil && phase == .decision:
                phase = .sending; try nextChunk()
            case .decline where source != nil && phase == .decision:
                end(.failure(DirectFileError.declined))
            case .chunk(let position, let bytes) where phase == .receiving:
                guard let sink else { throw DirectFileError.invalidFile }
                try sink.append(offset: position, bytes: bytes)
                offset = sink.offset; progress()
                send(.acknowledge(offset: offset))
            case .acknowledge(let position) where phase == .sending:
                guard position == offset else { throw DirectFileError.invalidFile }
                progress()
                // Keep bulk file traffic paced beneath interactive room audio.
                // One acknowledged 64KB chunk per 8ms caps payload at 8MB/s.
                phase = .pacing
                queue.asyncAfter(deadline: .now() + .milliseconds(8)) {
                    guard self.phase == .pacing, self.reader != nil else { return }
                    self.phase = .sending
                    do { try self.nextChunk() } catch { self.end(.failure(error)) }
                }
            case .finish(let digest) where phase == .receiving:
                guard let sink else { throw DirectFileError.invalidFile }
                try sink.finish(digest: digest)
                self.sink = nil; phase = .finishing
                send(.complete) { self.end(.success(self.destination)) }
            case .complete where phase == .finishing && source != nil:
                end(.success(nil))
            default: throw DirectFileError.invalidFile
            }
        } catch { end(.failure(error)) }
    }
    private func nextChunk() throws {
        guard let reader else { throw DirectFileError.invalidFile }
        if offset == size {
            // Refuse a file that grew while it was being sent.
            guard (try reader.read(upToCount: 1) ?? Data()).isEmpty else { throw DirectFileError.invalidFile }
            phase = .finishing; send(.finish(digest: Data(hash.finalize()))); return
        }
        let bytes = try reader.read(upToCount: Int(min(Int64(DirectFileWire.chunkBytes), size - offset))) ?? Data()
        guard !bytes.isEmpty else { throw DirectFileError.invalidFile }
        let position = offset
        offset += Int64(bytes.count); hash.update(data: bytes)
        send(.chunk(offset: position, bytes: bytes))
    }
    private func send(_ message: DirectFileWire, completed: (() -> Void)? = nil) {
        do {
            transmit(try message.encoded()) { [weak self] result in
                self?.queue.async { [weak self] in
                    guard let self, self.phase != .ended else { return }
                    if case .failure(let error) = result { self.end(.failure(error)) }
                    else { completed?() }
                }
            }
        } catch { end(.failure(error)) }
    }
    private func progress() {
        let fraction = size == 0 ? 1 : Double(offset) / Double(size)
        guard fraction == 1 || fraction - lastProgress >= 0.005 else { return }
        lastProgress = fraction
        DispatchQueue.main.async { self.onProgress(self.id, fraction) }
    }
    private func armTimeout() {
        timeout?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.end(.failure(DirectFileError.interrupted)) }
        timeout = task
        queue.asyncAfter(deadline: .now() + (phase == .decision ? 120 : 30), execute: task)
    }
    private func end(_ result: Result<URL?, Error>) {
        guard phase != .ended else { return }
        phase = .ended; timeout?.cancel(); timeout = nil
        try? reader?.close(); reader = nil; sink = nil
        if case .failure = result, let destination {
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
        }
        cancelChannel()
        DispatchQueue.main.async { self.onEnd(self.id, result) }
    }
}
