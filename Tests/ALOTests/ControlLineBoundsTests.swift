import Foundation
import Testing
import ALOCore

@Suite struct ControlLineBoundsTests {
    @Test func refusesUnterminatedOversizedInput() {
        let decoder = ControlLineDecoder(maximumLineBytes: 64)
        #expect(decoder.append(Data(repeating: 65, count: 64)).isEmpty)
        #expect(!decoder.isOverflowed)
        #expect(decoder.append(Data([65])).isEmpty)
        #expect(decoder.isOverflowed)
        #expect(decoder.bufferedByteCount == 0)
        #expect(decoder.append(Data("{\"type\":\"ping\"}\n".utf8)).isEmpty)
    }

    @Test func boundsEachLineNotEntireNetworkRead() throws {
        let decoder = ControlLineDecoder(maximumLineBytes: 64)
        let line = try ControlMessage(type: "ping").encodedLine()
        let batch = (0..<100).reduce(into: Data()) { bytes, _ in bytes.append(line) }
        #expect(decoder.append(batch).count == 100)
        #expect(!decoder.isOverflowed)
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test func detectsOversizedTailAfterValidMessage() throws {
        let decoder = ControlLineDecoder(maximumLineBytes: 32)
        var batch = try ControlMessage(type: "ping").encodedLine()
        batch.append(Data(repeating: 65, count: 33))
        #expect(decoder.append(batch).count == 1)
        #expect(decoder.isOverflowed)
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test func slicedDataAndFragmentedDelimiter() throws {
        let decoder = ControlLineDecoder(maximumLineBytes: 32)
        var data = Data(repeating: 0, count: 5)
        data.append(try ControlMessage(type: "ping").encodedLine())
        #expect(decoder.append(data.dropFirst(5).dropLast()).isEmpty)
        #expect(decoder.append(Data([10])).map(\.type) == ["ping"])
    }
}
