import XCTest
@testable import ALONotchRuntime

final class SettingsSelectionHistoryTests: XCTestCase {
    func testRecordAppendsSelectionToHistory() async {
        var history = SettingsRootViewModel.SelectionHistory(initialSelection: .general)

        history.record(.wifi)

        XCTAssertEqual(history.currentSelection, .wifi)
        XCTAssertTrue(history.canGoBack)
        XCTAssertFalse(history.canGoForward)
    }

    func testRecordAfterGoingBackDropsForwardHistory() async {
        var history = SettingsRootViewModel.SelectionHistory(initialSelection: .general)
        history.record(.wifi)
        history.record(.battery)

        XCTAssertEqual(history.goBack(), .wifi)

        history.record(.homePage)

        XCTAssertEqual(history.currentSelection, .homePage)
        XCTAssertNil(history.goForward())
    }

    func testRecordSameSelectionDoesNotDuplicateHistory() async {
        var history = SettingsRootViewModel.SelectionHistory(initialSelection: .general)

        history.record(.general)

        XCTAssertFalse(history.canGoBack)
        XCTAssertFalse(history.canGoForward)
        XCTAssertNil(history.goBack())
    }

    func testBackAndForwardMoveAcrossRecordedSelections() async {
        var history = SettingsRootViewModel.SelectionHistory(initialSelection: .general)
        history.record(.wifi)
        history.record(.battery)

        XCTAssertEqual(history.goBack(), .wifi)
        XCTAssertEqual(history.goBack(), .general)
        XCTAssertNil(history.goBack())

        XCTAssertEqual(history.goForward(), .wifi)
        XCTAssertEqual(history.goForward(), .battery)
        XCTAssertNil(history.goForward())
    }
}
