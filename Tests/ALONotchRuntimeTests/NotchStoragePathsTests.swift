import XCTest
@testable import ALONotchRuntime

final class NotchStoragePathsTests: XCTestCase {
    func testGeneratedStorageIsOwnedByHostNotUpstreamApp() {
        for path in [NotchStoragePaths.fileTray, NotchStoragePaths.screenshots, NotchStoragePaths.airDrop] {
            XCTAssertTrue(path.pathComponents.contains(NotchStoragePaths.hostIdentifier))
            XCTAssertTrue(path.pathComponents.contains("Notch"))
            XCTAssertFalse(path.pathComponents.contains("DynamicNotch"))
            XCTAssertFalse(path.pathComponents.contains("com.Jackson.DynamicNotch"))
        }
        XCTAssertEqual(NotchStoragePaths.fileTray.lastPathComponent, "FileTray")
        XCTAssertEqual(NotchStoragePaths.screenshots.lastPathComponent, "RawScreenshots")
        XCTAssertEqual(NotchStoragePaths.airDrop.lastPathComponent, "AirDrop")
    }
}
