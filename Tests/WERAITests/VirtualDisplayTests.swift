import CoreGraphics
import Foundation
import Testing
@testable import WERAI

struct VirtualDisplayTests {
    @Test(
        "Real virtual display mounts and unmounts cleanly",
        .enabled(if: ProcessInfo.processInfo.environment["ALO_TEST_REAL_VIRTUAL_DISPLAY"] == "1")
    )
    func realDisplayLifecycle() throws {
        let display = try VirtualDisplayManager()
        let id = display.displayID
        #expect(id != kCGNullDirectDisplay)
        #expect(Self.onlineDisplays().contains(id))
        display.stop()
        for _ in 0..<10 where Self.onlineDisplays().contains(id) {
            Thread.sleep(forTimeInterval: 0.1)
        }
        #expect(!Self.onlineDisplays().contains(id))
    }

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return [] }
        return Array(displays.prefix(Int(count)))
    }

    @Test("Virtual display ownership tears down exactly once")
    func ownerTearsDownExactlyOnce() throws {
        let fake = FakeVirtualDisplay(id: 41)
        var factoryCalls = 0
        let owner = VirtualDisplayOwner {
            factoryCalls += 1
            return fake
        }

        #expect(try owner.create() == 41)
        #expect(owner.displayID == 41)
        owner.stop()
        owner.stop()
        #expect(factoryCalls == 1)
        #expect(fake.stopCount == 1)
        #expect(owner.displayID == nil)
    }

    @Test("Replacing a virtual display first releases the old one")
    func replacingDisplayReleasesOldOne() throws {
        let first = FakeVirtualDisplay(id: 11)
        let second = FakeVirtualDisplay(id: 12)
        var displays: [FakeVirtualDisplay] = [first, second]
        let owner = VirtualDisplayOwner { displays.removeFirst() }

        #expect(try owner.create() == 11)
        #expect(try owner.create() == 12)
        #expect(first.stopCount == 1)
        #expect(second.stopCount == 0)
        owner.stop()
        #expect(second.stopCount == 1)
    }

    @Test("Video capture selects only the requested display")
    func exactDisplaySelection() {
        #expect(ScreenVideoCapture.selectsRequestedDisplay(9, from: [2, 9, 4]) == 9)
        #expect(ScreenVideoCapture.selectsRequestedDisplay(7, from: [2, 9, 4]) == nil)
    }
}

private final class FakeVirtualDisplay: VirtualDisplayManaging {
    let displayID: CGDirectDisplayID
    private(set) var stopCount = 0

    init(id: CGDirectDisplayID) { displayID = id }
    func stop() { stopCount += 1 }
}
