import Foundation
import Testing
import ALONetworking
@testable import ALO

@Suite("Direct file end-to-end flow", .serialized)
struct DirectFileTransferTests {
    @Test func cancellationRemovesPartialFileAndNeverPresentsIt() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 4, count: 400000).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let pair = TransferPair(source: source, accept: true, interrupt: true)
        defer { pair.cancel() }; pair.start()
        for _ in 0..<500 {
            if pair.lock.withLock({ pair.results.count == 2 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(pair.lock.withLock { pair.results.count } == 2)
        #expect(pair.lock.withLock { pair.results.allSatisfy { if case .failure = $0 { return true }; return false } })
        let partial = FileManager.default.temporaryDirectory.appendingPathComponent("ALO-Incoming-\(pair.receiver.id)")
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }
    @Test func transfersMultipleChunksAndOnlyPresentsVerifiedFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("test.bin")
        let bytes = Data(repeating: 93, count: 200_123)
        try bytes.write(to: source)
        let pair = TransferPair(source: source, accept: true)
        defer { pair.cancel() }
        pair.start()
        for _ in 0..<500 {
            if pair.lock.withLock({ pair.results.count == 2 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let results = pair.lock.withLock { pair.results }
        #expect(results.count == 2)
        let received = try #require(results.compactMap { try? $0.get() }.first)
        defer { try? FileManager.default.removeItem(at: received.deletingLastPathComponent()) }
        #expect(try Data(contentsOf: received) == bytes)
        #expect(pair.lock.withLock { pair.chunks } == 4)
    }
    @Test func rejectionSendsNoFileBytes() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1,2,3]).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let pair = TransferPair(source: source, accept: false)
        defer { pair.cancel() }; pair.start()
        for _ in 0..<500 {
            if pair.lock.withLock({ pair.results.count == 2 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(pair.lock.withLock { pair.results.count } == 2)
        #expect(pair.lock.withLock { pair.chunks } == 0)
        #expect(pair.lock.withLock { pair.results.allSatisfy { if case .failure = $0 { return true }; return false } })
    }
}

private final class TransferPair: @unchecked Sendable {
    let lock = NSLock()
    var results: [Result<URL?, Error>] = []
    var chunks = 0
    var sender: DirectFileTransfer!
    var receiver: DirectFileTransfer!
    init(source: URL, accept: Bool, interrupt: Bool = false) {
        receiver = DirectFileTransfer(peerID: UUID(), source: nil, transmit: { [weak self] data, completion in
            self?.sender.receivePayload(data); completion(.success(()))
        }, cancelChannel: {}, onOffer: { transfer, _, _ in
            if accept { transfer.accept() } else { transfer.decline() }
        }, onProgress: { _, _ in }, onEnd: { [weak self] _, result in self?.record(result) })
        sender = DirectFileTransfer(peerID: UUID(), source: source, transmit: { [weak self] data, completion in
            if let decoded = try? DirectFileWire.decode(data), case .chunk = decoded {
                self?.lock.withLock { self?.chunks += 1 }
                if interrupt {
                    self?.receiver.receivePayload(data)
                    self?.cancel(); completion(.failure(DirectFileError.interrupted)); return
                }
            }
            self?.receiver.receivePayload(data); completion(.success(()))
        }, cancelChannel: {}, onOffer: { _, _, _ in }, onProgress: { _, _ in }, onEnd: { [weak self] _, result in self?.record(result) })
    }
    private func record(_ result: Result<URL?, Error>) { lock.withLock { results.append(result) } }
    func start() { receiver.start(); sender.start() }
    func cancel() { sender.cancel(); receiver.cancel() }
}
