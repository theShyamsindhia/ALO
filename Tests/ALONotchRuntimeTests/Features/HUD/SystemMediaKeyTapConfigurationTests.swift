import AppKit
import XCTest
@testable import ALONotchRuntime

final class SystemMediaKeyTapConfigurationTests: XCTestCase {
    private let configuration = SystemMediaKeyTapConfiguration(
        interceptVolume: true,
        interceptBrightness: true
    )

    func testInterceptsBrightnessKeyWithoutModifiers() async {
        XCTAssertTrue(configuration.intercepts(keyCode: MediaKeyCode.brightnessDown, modifiers: []))
        XCTAssertTrue(configuration.intercepts(keyCode: MediaKeyCode.brightnessUp, modifiers: []))
    }

    func testInterceptsBrightnessKeyWithFineAdjustmentModifiers() async {
        XCTAssertTrue(
            configuration.intercepts(keyCode: MediaKeyCode.brightnessUp, modifiers: [.option, .shift])
        )
    }

    func testInterceptsVolumeKeyWithShift() async {
        XCTAssertTrue(configuration.intercepts(keyCode: MediaKeyCode.volumeUp, modifiers: [.shift]))
    }

    func testIgnoresKeyboardStateModifiers() async {
        XCTAssertTrue(
            configuration.intercepts(keyCode: MediaKeyCode.brightnessUp, modifiers: [.function, .capsLock, .numericPad])
        )
    }

    func testSkipsBrightnessKeyHeldWithCommand() async {
        XCTAssertFalse(configuration.intercepts(keyCode: MediaKeyCode.brightnessDown, modifiers: [.command]))
        XCTAssertFalse(
            configuration.intercepts(keyCode: MediaKeyCode.brightnessDown, modifiers: [.command, .shift])
        )
    }

    func testSkipsBrightnessKeyHeldWithControl() async {
        XCTAssertFalse(configuration.intercepts(keyCode: MediaKeyCode.brightnessUp, modifiers: [.control]))
    }

    func testSkipsMediaKeyHeldWithOptionAlone() async {
        XCTAssertFalse(configuration.intercepts(keyCode: MediaKeyCode.brightnessUp, modifiers: [.option]))
        XCTAssertFalse(configuration.intercepts(keyCode: MediaKeyCode.volumeUp, modifiers: [.option]))
    }

    func testSkipsDisabledMediaKeys() async {
        let brightnessOnly = SystemMediaKeyTapConfiguration(interceptVolume: false, interceptBrightness: true)

        XCTAssertFalse(brightnessOnly.intercepts(keyCode: MediaKeyCode.volumeDown, modifiers: []))
        XCTAssertFalse(brightnessOnly.intercepts(keyCode: MediaKeyCode.mute, modifiers: []))
        XCTAssertTrue(brightnessOnly.intercepts(keyCode: MediaKeyCode.brightnessDown, modifiers: []))
    }

    func testSkipsUnknownKeyCode() async {
        XCTAssertFalse(configuration.intercepts(keyCode: 16, modifiers: []))
    }
}
