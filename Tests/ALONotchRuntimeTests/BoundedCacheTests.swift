import XCTest
@testable import ALONotchRuntime

@MainActor
final class BoundedCacheTests: XCTestCase {
    func testRecentLyricsSurviveWhileOldestEntryIsEvicted() {
        var cache = BoundedCache<String, String>(capacity: 2)
        cache["first"] = "first lyrics"
        cache["second"] = "second lyrics"
        XCTAssertEqual(cache["first"], "first lyrics")
        cache["third"] = "third lyrics"
        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(cache["second"])
        XCTAssertEqual(cache["first"], "first lyrics")
        XCTAssertEqual(cache["third"], "third lyrics")
    }

    func testReplacementAndRemovalDoNotConsumeExtraCapacity() {
        var cache = BoundedCache<String, String>(capacity: 2)
        cache["track"] = "old"
        cache["track"] = "updated"
        cache["other"] = "other"
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache["track"], "updated")
        cache["track"] = nil
        XCTAssertEqual(cache.count, 1)
        XCTAssertNil(cache["track"])
        XCTAssertEqual(cache["other"], "other")
    }
}
