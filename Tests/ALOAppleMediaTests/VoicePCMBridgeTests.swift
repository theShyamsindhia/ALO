import Testing
@testable import ALOAppleMedia

struct VoicePCMBridgeTests {
    private enum Event: Sendable, Equatable {
        case control(Int)
        case pcm(Int)
        var isPCM: Bool { if case .pcm = self { return true }; return false }
    }

    @Test func PCMBytePressureStaysBoundedAndCloseStillInvalidatesDelivery() {
        var tasks: [@Sendable () -> Void] = [], received: [Event] = [], failures = 0
        let bridge = BoundedMediaEventBridge<Event>(maximumEvents: 8, maximumBytes: 1_920,
            droppable: { $0.isPCM }, schedule: { tasks.append($0) },
            receive: { received += $0 }, overflow: { failures += 1 })
        #expect(bridge.submit(.control(0)))
        for index in 0..<9 { #expect(bridge.submit(.pcm(index), byteCount: 960)) }
        tasks.removeFirst()()
        #expect(received == [.control(0), .pcm(7), .pcm(8)])
        #expect(failures == 0)
        #expect(bridge.submit(.pcm(9), byteCount: 960))
        bridge.close(); tasks.removeFirst()()
        #expect(received.last == .pcm(8))
        #expect(!bridge.submit(.pcm(10), byteCount: 960))
    }

    @Test func ninthMicChunkDropsOldPCMWithoutRevokingConsent() {
        var tasks: [@Sendable () -> Void] = [], received: [Int] = []
        var microphoneActive = true
        let bridge = BoundedMediaEventBridge<Int>(maximumEvents: 8, maximumBytes: 7_680,
            droppable: { _ in true }, schedule: { tasks.append($0) },
            receive: { received += $0 }, overflow: { microphoneActive = false })
        for chunk in 0..<9 { _ = bridge.submit(chunk, byteCount: 960) }
        #expect(tasks.count == 1)
        tasks.removeFirst()()
        #expect(microphoneActive)
        #expect(received == Array(1..<9))
        #expect(bridge.submit(9, byteCount: 960))
        if !tasks.isEmpty { tasks.removeFirst()() }
        #expect(received.last == 9)
    }

    @Test func multitalkerPCMPressurePreservesControlOrderAndFreshTail() throws {
        var tasks: [@Sendable () -> Void] = [], received: [Event] = [], failures = 0
        let bridge = BoundedMediaEventBridge<Event>(maximumEvents: 128, maximumBytes: 122_880,
            droppable: { $0.isPCM }, schedule: { tasks.append($0) },
            receive: { received += $0 }, overflow: { failures += 1 })
        _ = bridge.submit(.control(0)) // Two authenticated begin offers.
        _ = bridge.submit(.control(1))
        for index in 0..<160 { _ = bridge.submit(.pcm(index), byteCount: 960) }
        _ = bridge.submit(.control(2)) // End must not be evicted by newer PCM.
        for index in 160..<200 { _ = bridge.submit(.pcm(index), byteCount: 960) }
        _ = bridge.submit(.control(3))
        #expect(tasks.count == 1)
        tasks.removeFirst()()
        #expect(failures == 0)
        #expect(received.count == 128)
        #expect(received.filter { !$0.isPCM } == [.control(0), .control(1), .control(2), .control(3)])
        let pcm = received.compactMap { if case .pcm(let index) = $0 { return index }; return nil }
        #expect(pcm == Array(76..<200))
        let end = try #require(received.firstIndex(of: .control(2)))
        let lastPCM = try #require(received.firstIndex(of: .pcm(199)))
        #expect(end < lastPCM)
        #expect(bridge.submit(.control(4)))
    }

    @Test func PCMDoesNotDisplaceControlOnlyQueueButControlOverflowRemainsTerminal() {
        var tasks: [@Sendable () -> Void] = [], received: [Event] = [], failures = 0
        let bridge = BoundedMediaEventBridge<Event>(maximumEvents: 2, maximumBytes: 960,
            droppable: { $0.isPCM }, schedule: { tasks.append($0) },
            receive: { received += $0 }, overflow: { failures += 1 })
        #expect(bridge.submit(.control(0)))
        #expect(bridge.submit(.control(1)))
        #expect(bridge.submit(.pcm(0), byteCount: 960)) // Bounded loss, not transport failure.
        tasks.removeFirst()()
        #expect(received == [.control(0), .control(1)])
        #expect(failures == 0)
        #expect(bridge.submit(.control(2)))
        #expect(bridge.submit(.control(3)))
        #expect(!bridge.submit(.control(4)))
        if !tasks.isEmpty { tasks.removeFirst()() }
        #expect(failures == 1)
    }
}
