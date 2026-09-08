import Foundation
import Testing
@testable import ALONetworking

struct NetworkDeviceMessageFrameTests {
    @Test func fragmentedFramesAndOversizeFailClosed() throws {
        let payload = Data("text".utf8)
        let frame = try NetworkDeviceMessageFraming.encode(payload)
        var parser = NetworkDeviceMessageFraming()
        #expect(try parser.append(frame.prefix(2)).isEmpty)
        #expect(try parser.append(frame.dropFirst(2)) == [payload])
        #expect(throws: (any Error).self) {
            try NetworkDeviceMessageFraming.encode(Data(repeating: 0, count: 24 * 1024 + 1))
        }
        var malicious = NetworkDeviceMessageFraming()
        #expect(throws: (any Error).self) { try malicious.append(Data([255,255,255,255])) }
        #expect(throws: (any Error).self) { try malicious.append(frame) }
    }
    @Test func coalescedFramesPreserveOrderAndEmptyRejected() throws {
        var parser = NetworkDeviceMessageFraming()
        let frames = try NetworkDeviceMessageFraming.encode(Data([1])) + NetworkDeviceMessageFraming.encode(Data([2]))
        #expect(try parser.append(frames) == [Data([1]), Data([2])])
        #expect(throws: (any Error).self) { try parser.append(Data([0,0,0,0])) }
    }
}
