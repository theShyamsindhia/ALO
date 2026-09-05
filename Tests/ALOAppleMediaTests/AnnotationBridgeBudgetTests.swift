import Foundation
import Testing
@testable import ALOAppleMedia

@Suite
struct AnnotationBridgeBudgetTests {
    @Test("An explicit annotation budget carries a legal 8 MiB snapshot in one executor hop")
    func legalSnapshotBudget() {
        var tasks: [@Sendable () -> Void] = []
        var received: [Data] = []
        var failures = 0
        let snapshot = Data(repeating: 1, count: 8 * 1_024 * 1_024)
        let bridge = BoundedMediaEventBridge<Data>(maximumBytes: 16 * 1_024 * 1_024,
            schedule: { tasks.append($0) }, receive: { received += $0 }, overflow: { failures += 1 })
        #expect(bridge.submit(snapshot, byteCount: snapshot.count))
        #expect(bridge.submit(Data([2]), byteCount: 1))
        #expect(tasks.count == 1)
        tasks.removeFirst()()
        #expect(received == [snapshot, Data([2])] && failures == 0)
    }

    @Test("Larger annotation budgets leave the default media bridge limit unchanged")
    func defaultBudgetStaysBounded() {
        var tasks: [@Sendable () -> Void] = []
        var failures = 0
        let bridge = BoundedMediaEventBridge<Data>(schedule: { tasks.append($0) },
            receive: { _ in Issue.record("An oversized batch must not be delivered") }, overflow: { failures += 1 })
        let oversized = Data(repeating: 1, count: 256 * 1_024 + 1)
        #expect(!bridge.submit(oversized, byteCount: oversized.count))
        tasks.removeFirst()()
        #expect(failures == 1)
    }
}
