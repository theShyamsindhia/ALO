import AppKit
import CryptoKit
import Testing
import ALONetworking
@testable import ALO

@Suite("Room file consent and presentation", .serialized) @MainActor
struct DirectFilePresentationTests {
    @Test func receivedCopyCanBeSavedThenDiscardedWithoutTouchingExport() async throws {
        let model = DirectFileSharingController()
        let peer = UUID()
        model.names = { [peer.uuidString: "Raj"] }; model.presentInNotch = { true }
        defer { model.stop() }
        let id = try await receiveSmallFile(model, peer: peer)
        let source = try #require(model.progress.first?.receivedURL)
        let bytes = try Data(contentsOf: source)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("Saved.txt")
        #expect(await model.export(id, to: output))
        #expect(model.progress.first?.hasSavedCopy == true)
        model.dismiss(id)
        #expect(model.progress.count == 1, "Dismiss must not silently discard received data")
        #expect(await model.export(id, to: source) == false)
        await model.discard(id)
        #expect(model.progress.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: output) == bytes)
        model.finished(id, result: .success(source))
        #expect(model.progress.isEmpty, "Late completion must not recreate a discarded copy")
    }

    @Test func leavingDuringSaveWaitsToRemoveItsSource() async throws {
        let io = PausedInboxIO()
        let model = DirectFileSharingController(inboxIO: io)
        let peer = UUID()
        model.names = { [peer.uuidString: "Raj"] }; model.presentInNotch = { true }
        let id = try await receiveSmallFile(model, peer: peer)
        let source = try #require(model.progress.first?.receivedURL)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: output); model.stop() }
        let save = Task { await model.export(id, to: output) }
        for _ in 0..<100 {
            if await io.exportStarted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await io.exportStarted)
        #expect(model.busyFileIDs.contains(id))
        await model.discard(id)
        #expect(model.progress.count == 1, "Discard must not race an export")
        model.stop()
        #expect(FileManager.default.fileExists(atPath: source.path))
        await io.resumeExport()
        #expect(await save.value)
        try await waitFor { !FileManager.default.fileExists(atPath: source.path) }
        #expect(try Data(contentsOf: output) == Data("abc".utf8))
        #expect(model.progress.isEmpty)
        #expect(model.busyFileIDs.isEmpty)
    }

    @Test func discardFailureKeepsTheCopyAndAllowsRetry() async throws {
        let io = PausedInboxIO()
        await io.setRemovalFailure(true)
        let model = DirectFileSharingController(inboxIO: io)
        let peer = UUID()
        model.names = { [peer.uuidString: "Raj"] }; model.presentInNotch = { true }
        defer { model.stop() }
        let id = try await receiveSmallFile(model, peer: peer)
        let source = try #require(model.progress.first?.receivedURL)
        await model.discard(id)
        #expect(model.progress.first?.state == .received)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(model.message?.contains("Couldn’t discard") == true)
        #expect(model.busyFileIDs.isEmpty)
        await io.setRemovalFailure(false)
        await model.discard(id)
        #expect(model.progress.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test func failedExportKeepsReceivedCopyAndDoesNotClaimItWasSaved() async throws {
        let model = DirectFileSharingController()
        let peer = UUID()
        model.names = { [peer.uuidString: "Raj"] }; model.presentInNotch = { true }
        defer { model.stop() }
        let id = try await receiveSmallFile(model, peer: peer)
        let source = try #require(model.progress.first?.receivedURL)
        let missingFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(await model.export(id, to: missingFolder.appendingPathComponent("File.txt")) == false)
        #expect(model.progress.first?.hasSavedCopy == false)
        #expect(model.progress.first?.receivedURL == source)
        #expect(try Data(contentsOf: source) == Data("abc".utf8))
        #expect(model.busyFileIDs.isEmpty)
    }

    @Test func discardWaitsForAnOutgoingTransferBorrowingTheInboxFile() async throws {
        let model = DirectFileSharingController()
        let peer = UUID()
        model.names = { [peer.uuidString: "Raj"] }; model.presentInNotch = { true }
        model.openChannel = { _, _ in }
        defer { model.stop() }
        let id = try await receiveSmallFile(model, peer: peer)
        let source = try #require(model.progress.first?.receivedURL)
        model.send(source, to: peer)
        let outgoing = try #require(model.progress.last?.id)
        #expect(!model.canDiscard(id))
        await model.discard(id)
        #expect(FileManager.default.fileExists(atPath: source.path))
        model.cancel(outgoing)
        #expect(model.canDiscard(id))
        await model.discard(id)
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test func cancellationWinsOverAlreadyQueuedSuccessfulCompletion() async throws {
        let model = DirectFileSharingController()
        let peer = UUID()
        model.names = { [peer.uuidString: "Raj"] }; model.presentInNotch = { true }
        defer { model.stop() }
        let receiver = makeReceiver(model: model, peer: peer, wire: PresentationWire())
        model.registerIncoming(receiver)
        model.offer(receiver, name: "File.txt", size: 3)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("File.txt")
        try Data("abc".utf8).write(to: source)
        // Simulate a verified transport completion already queued to the UI
        // when Cancel wins the main-executor ordering.
        model.cancel(receiver.id)
        model.finished(receiver.id, result: .success(source))
        #expect(model.progress.first?.state == .cancelled)
        #expect(model.progress.first?.receivedURL == nil)
        try await waitFor { !FileManager.default.fileExists(atPath: source.path) }
        model.dismiss(receiver.id)
        model.finished(receiver.id, result: .failure(DirectFileError.interrupted))
        #expect(model.progress.isEmpty)
    }

    @Test func inboxCountIsBoundedAndDiscardMakesRoomWithoutRejoining() async throws {
        let model = DirectFileSharingController()
        let peer = UUID()
        model.names = { [peer.uuidString: "Raj"] }; model.presentInNotch = { true }
        defer { model.stop() }
        for _ in 0..<32 { _ = try await receiveSmallFile(model, peer: peer) }
        let wire = PresentationWire()
        let extra = makeReceiver(model: model, peer: peer, wire: wire)
        model.registerIncoming(extra)
        extra.receivePayload(try DirectFileWire.offer(name: "Extra.txt", size: 3).encoded())
        try await waitFor { wire.messages.count == 1 }
        if case .decline = wire.messages.first {} else { Issue.record("Expected a full-inbox decline") }
        #expect(model.progress.count == 32)
        #expect(model.message?.contains("discard") == true)
        await model.discard(try #require(model.progress.first?.id))
        _ = try await receiveSmallFile(model, peer: peer)
        #expect(model.progress.count == 32)
    }

    @Test func terminalHistoryIsBoundedWithoutRemovingActiveTransfers() async throws {
        let model = DirectFileSharingController()
        let peer = UUID()
        model.names = { [peer.uuidString: "Raj"] }; model.presentInNotch = { true }
        model.progress = (0..<110).map { index in
            .init(id: UUID(), title: "", fraction: 1, state: .delivered, fileName: "\(index).txt")
        }
        model.openChannel = { _, completion in completion(.failure(DirectFileError.interrupted)) }
        defer { model.stop() }
        model.send(URL(fileURLWithPath: "/tmp/unused-history-test.txt"), to: peer)
        try await waitFor { model.progress.last?.state.isFinished == true }
        #expect(model.progress.count == 100)
        let id = try #require(model.progress.last?.id)
        model.dismiss(id)
        #expect(model.progress.count == 99)
    }

    @Test func mediaOffersRequireConsentAndDeclineDoesNotDeliverAnything() async throws {
        let model = DirectFileSharingController()
        let wire = PresentationWire()
        let peer = UUID()
        model.names = { [peer.uuidString: "Raj"] }
        var presentations = 0
        model.presentInNotch = { presentations += 1; return true }
        let transfer = makeReceiver(model: model, peer: peer, wire: wire)
        defer { model.stop() }
        model.registerIncoming(transfer)
        transfer.receivePayload(try DirectFileWire.offer(name: "photo.png", size: 3).encoded())
        try await waitFor { model.progress.count == 1 }
        #expect(model.progress[0].state == .offered)
        #expect(wire.messages.isEmpty, "Even media must not be automatically accepted")
        #expect(presentations == 1)
        model.decline(transfer.id)
        try await waitFor { model.progress.first?.transfer == nil }
        #expect(model.progress.first?.state == .declined)
        #expect(model.progress.first?.receivedURL == nil)
        #expect(wire.messages.count == 1)
        if case .decline = wire.messages.first {} else { Issue.record("Expected a decline") }
    }

    @Test func acceptIsExplicitAndCannotBeSentTwice() async throws {
        let model = DirectFileSharingController()
        let wire = PresentationWire()
        let peer = UUID()
        model.names = { [peer.uuidString: "Raj"] }
        model.presentInNotch = { true }
        let transfer = makeReceiver(model: model, peer: peer, wire: wire)
        defer { model.stop() }
        model.registerIncoming(transfer)
        transfer.receivePayload(try DirectFileWire.offer(name: "notes.txt", size: 3).encoded())
        try await waitFor { model.progress.count == 1 }
        model.accept(transfer.id)
        model.accept(transfer.id)
        try await waitFor { wire.messages.count == 1 }
        #expect(model.progress.first?.state == .transferring)
        if case .accept = wire.messages.first {} else { Issue.record("Expected an acceptance") }
        model.cancel(transfer.id)
        try await waitFor { model.progress.first?.transfer == nil }
        #expect(model.progress.first?.state == .cancelled)
    }

    @Test func cancelledConnectionIgnoresLateFailureAndCanBeRetried() async throws {
        let model = DirectFileSharingController()
        let peer = UUID()
        model.names = { [peer.uuidString: "Raj"] }
        model.presentInNotch = { true }
        var completions: [(Result<(SecurePeerChannel, AuthenticatedPeer), Error>) -> Void] = []
        model.openChannel = { _, completion in completions.append(completion) }
        defer { model.stop() }
        model.send(URL(fileURLWithPath: "/tmp/notch-test-file.txt"), to: peer)
        let first = model.progress[0].id
        model.cancel(first)
        #expect(model.progress[0].state == .cancelled)
        model.retry(first)
        #expect(completions.count == 2)
        #expect(model.progress.count == 1)
        #expect(model.progress[0].id != first)
        #expect(model.progress[0].state == .connecting)
        completions[0](.failure(DirectFileError.interrupted))
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.progress.count == 1)
        #expect(model.progress[0].state == .connecting)
    }

    @Test func stoppingClearsOffersAndPendingUI() {
        let model = DirectFileSharingController()
        let peer = UUID()
        model.names = { [peer.uuidString: "Raj"] }
        model.presentInNotch = { true }
        model.openChannel = { _, _ in }
        model.send(URL(fileURLWithPath: "/tmp/notch-test-file.txt"), to: peer)
        #expect(model.progress.count == 1)
        model.stop()
        #expect(model.progress.isEmpty)
        #expect(model.presentInNotch == nil)
        #expect(model.openChannel == nil)
    }

    private func makeReceiver(model: DirectFileSharingController, peer: UUID, wire: PresentationWire) -> DirectFileTransfer {
        DirectFileTransfer(peerID: peer, source: nil, transmit: { data, completion in
            wire.record(data); completion(.success(()))
        }, cancelChannel: {}, onOffer: { transfer, name, size in
            MainActor.assumeIsolated { model.offer(transfer, name: name, size: size) }
        }, onProgress: { _, _ in }, onEnd: { id, result in
            MainActor.assumeIsolated { model.finished(id, result: result) }
        })
    }

    private func receiveSmallFile(_ model: DirectFileSharingController, peer: UUID) async throws -> UUID {
        let wire = PresentationWire()
        let receiver = makeReceiver(model: model, peer: peer, wire: wire)
        model.registerIncoming(receiver)
        receiver.receivePayload(try DirectFileWire.offer(name: "Notes.txt", size: 3).encoded())
        try await waitFor { model.progress.contains(where: { $0.id == receiver.id && $0.state == .offered }) }
        model.accept(receiver.id)
        try await waitFor { !wire.messages.isEmpty }
        let bytes = Data("abc".utf8)
        receiver.receivePayload(try DirectFileWire.chunk(offset: 0, bytes: bytes).encoded())
        receiver.receivePayload(try DirectFileWire.finish(digest: Data(SHA256.hash(data: bytes))).encoded())
        try await waitFor { model.progress.contains(where: { $0.id == receiver.id && $0.state == .received }) }
        return receiver.id
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}

private actor PausedInboxIO: DirectFileInboxIO {
    private var continuation: CheckedContinuation<Void, Never>?
    private var removalFails = false
    private(set) var exportStarted = false
    func export(_ source: URL, to destination: URL) async throws {
        exportStarted = true
        await withCheckedContinuation { continuation = $0 }
        try Data(contentsOf: source).write(to: destination, options: .atomic)
    }
    func resumeExport() { continuation?.resume(); continuation = nil }
    func setRemovalFailure(_ failure: Bool) { removalFails = failure }
    func remove(_ directory: URL) throws {
        if removalFails { throw CocoaError(.fileWriteNoPermission) }
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
}

private final class PresentationWire: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [DirectFileWire] = []
    var messages: [DirectFileWire] { lock.withLock { recorded } }
    func record(_ data: Data) {
        if let message = try? DirectFileWire.decode(data) { lock.withLock { recorded.append(message) } }
    }
}
