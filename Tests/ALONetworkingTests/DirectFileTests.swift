import Foundation
import CryptoKit
import Testing
@testable import ALONetworking

@Suite("Direct file integrity and limits")
struct DirectFileTests {
    @Test func reconstructsSeveralChunksAndChecksDigest() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("received.bin")
        let bytes = Data((0..<(DirectFileWire.chunkBytes * 3 + 17)).map { UInt8($0 % 251) })
        let sink = try DirectFileSink(url: url, size: Int64(bytes.count))
        for start in stride(from: 0, to: bytes.count, by: DirectFileWire.chunkBytes) {
            let chunk = bytes.subdata(in: start..<min(bytes.count, start + DirectFileWire.chunkBytes))
            let decoded = try DirectFileWire.decode(DirectFileWire.chunk(offset: Int64(start), bytes: chunk).encoded())
            guard case .chunk(let offset, let payload) = decoded else { Issue.record("Wrong wire type"); return }
            try sink.append(offset: offset, bytes: payload)
        }
        try sink.finish(digest: Data(SHA256.hash(data: bytes)))
        #expect(try Data(contentsOf: url) == bytes)
    }
    @Test func rejectsTraversalAndControls() throws {
        for name in ["../a", "x/y", "x\\y", "..", "", "x\u{0}y", "a\nb", String(repeating: "x", count: 241)] {
            #expect(throws: DirectFileError.self) { try DirectFileWire.safeName(name) }
        }
        #expect(try DirectFileWire.safeName("my holiday 🏝️.png") == "my holiday 🏝️.png")
    }
    @Test func rejectsOutOfOrderOverflowTruncationAndCorruption() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = try DirectFileSink(url: directory.appendingPathComponent("file"), size: 3)
        #expect(throws: DirectFileError.self) { try sink.append(offset: 1, bytes: Data([1])) }
        #expect(throws: DirectFileError.self) { try sink.append(offset: 0, bytes: Data([1,2,3,4])) }
        #expect(throws: DirectFileError.self) { try sink.finish(digest: Data(SHA256.hash(data: Data()))) }
        try sink.append(offset: 0, bytes: Data([1,2,3]))
        #expect(throws: DirectFileError.self) { try sink.append(offset: 0, bytes: Data([1])) }
        #expect(throws: DirectFileError.self) { try sink.finish(digest: Data(repeating: 0, count: 32)) }
    }
    @Test func boundsFramesAndFileSizes() throws {
        #expect(throws: DirectFileError.self) { try DirectFileWire.decode(Data(repeating: 0, count: 102401)) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: DirectFileError.self) { try DirectFileSink(url: url, size: -1) }
        #expect(throws: DirectFileError.self) { try DirectFileSink(url: url, size: DirectFileWire.maximumFileBytes + 1) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
