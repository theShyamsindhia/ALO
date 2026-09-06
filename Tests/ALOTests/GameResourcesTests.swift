import XCTest
@testable import ALO

final class GameResourcesTests: XCTestCase {
    func testRelocatedAppResourcesAndCLIResources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for location in ["Moved App.app/Contents/Resources", "cli"] {
            let directory = root.appendingPathComponent(location)
            let texture = directory.appendingPathComponent("ALO_ALO.bundle/Breach/concrete.png")
            try FileManager.default.createDirectory(at: texture.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: texture)
            XCTAssertEqual(GameResources.concreteURL(searchDirectories: [directory]), texture)
        }
        // Missing resources should produce an optional miss, never a fatalError.
        XCTAssertNil(GameResources.concreteURL(searchDirectories: [root.appendingPathComponent("missing")]))
    }
}
