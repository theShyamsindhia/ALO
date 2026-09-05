import XCTest
@testable import ALONotchRuntime

final class NotchTransitionMetricsTests: XCTestCase {
    func testVerticalCompensationOffsetIsZeroForBaseHeight() async {
        let offset = NotchTransitionMetrics.verticalCompensationOffset(
            for: 38,
            baseHeight: 38
        )

        XCTAssertEqual(offset, 0, accuracy: 0.001)
    }

    func testVerticalCompensationOffsetUsesHalfOfExtraHeight() async {
        let offset = NotchTransitionMetrics.verticalCompensationOffset(
            for: 148,
            baseHeight: 38
        )

        XCTAssertEqual(offset, -55, accuracy: 0.001)
    }
}
