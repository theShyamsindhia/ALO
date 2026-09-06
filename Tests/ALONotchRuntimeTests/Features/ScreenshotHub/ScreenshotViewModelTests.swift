//
//  ScreenshotViewModelTests.swift
//  DynamicNotchTests
//

import AppKit
import XCTest
import Combine
@testable import ALONotchRuntime

@MainActor
final class ScreenshotViewModelTests: XCTestCase {
    private var viewModel: ScreenshotViewModel!
    private var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenshotViewModelTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        viewModel = ScreenshotViewModel()
    }

    override func tearDown() async throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        viewModel = nil
        tempDirectory = nil
        try await super.tearDown()
    }

    func testInitialState() async {
        XCTAssertNil(viewModel.activeScreenshot)
        XCTAssertFalse(viewModel.isDropped)
        XCTAssertFalse(viewModel.isDeleted)
        XCTAssertFalse(viewModel.isSavedToDisk)
        XCTAssertFalse(viewModel.isCopied)
    }

    func testProcessNewScreenshotSetsActiveScreenshotAndNotifiesListener() async {
        let expectation = expectation(description: "onScreenshotReady called")
        var receivedScreenshot: ScreenshotModel?

        viewModel.onScreenshotReady = { screenshot in
            receivedScreenshot = screenshot
            expectation.fulfill()
        }

        let dummyImage = NSImage(size: NSSize(width: 100, height: 100))
        let sampleFile = tempDirectory.appendingPathComponent("test-screenshot.png")
        try? "dummy".write(to: sampleFile, atomically: true, encoding: .utf8)

        viewModel.processNewScreenshot(image: dummyImage, fileURL: sampleFile, fileName: "test-screenshot.png")

        await fulfillment(of: [expectation], timeout: 2.0)

        XCTAssertNotNil(viewModel.activeScreenshot)
        XCTAssertEqual(receivedScreenshot?.fileName, "test-screenshot.png")
        XCTAssertFalse(viewModel.isDropped)
        XCTAssertFalse(viewModel.isDeleted)
    }

    func testDismissInvokesCallback() async {
        let expectation = expectation(description: "onScreenshotDismissed called")

        viewModel.onScreenshotDismissed = {
            expectation.fulfill()
        }

        viewModel.dismiss()

        await fulfillment(of: [expectation], timeout: 1.0)
    }

    func testMarkAsDropped() async {
        XCTAssertFalse(viewModel.isDropped)
        viewModel.markAsDropped()
        XCTAssertTrue(viewModel.isDropped)
    }

    func testCopyWritesUsableImageWithoutClearingClipboardFirst() async throws {
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 32, height: 32).fill()
        image.unlockFocus()
        let source = tempDirectory.appendingPathComponent("copy-source.png")
        try Data("source".utf8).write(to: source)
        viewModel.processNewScreenshot(image: image, fileURL: source, fileName: "copy-source.png")

        let pasteboard = NSPasteboard(name: .init("ALO.Tests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(viewModel.copyImageToClipboard(pasteboard))
        XCTAssertNotNil(pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage)
        XCTAssertTrue(viewModel.isCopied)
    }

    func testFailedCopyPreservesExistingClipboardContents() async throws {
        let source = tempDirectory.appendingPathComponent("empty-source.png")
        try Data("source".utf8).write(to: source)
        viewModel.processNewScreenshot(image: NSImage(), fileURL: source, fileName: "empty-source.png")
        let pasteboard = NSPasteboard(name: .init("ALO.Tests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("keep me", forType: .string)

        XCTAssertFalse(viewModel.copyImageToClipboard(pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "keep me")
        XCTAssertFalse(viewModel.isCopied)
    }

    func testDroppedFileRemainsAvailableAfterPreviewDismisses() async throws {
        let source = tempDirectory.appendingPathComponent("drag-source.png")
        try Data("source".utf8).write(to: source)
        viewModel.processNewScreenshot(
            image: NSImage(size: NSSize(width: 20, height: 20)),
            fileURL: source,
            fileName: "drag-source.png"
        )
        viewModel.markAsDropped()
        viewModel.dismiss()

        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testClipboardBaselineDoesNotConsumeTheUsersNextScreenshot() async throws {
        let pasteboard = NSPasteboard(name: .init("ALO.Tests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        let monitor = ScreenshotMonitorService(pasteboard: pasteboard)
        let captured = expectation(description: "new clipboard screenshot captured")
        monitor.onScreenshotCaptured = { _, _, _ in captured.fulfill() }
        monitor.updateLastPasteboardChangeCount()

        let image = NSImage(size: NSSize(width: 24, height: 24))
        image.lockFocus()
        NSColor.systemPurple.setFill()
        NSRect(x: 0, y: 0, width: 24, height: 24).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(tiff, forType: .tiff))
        monitor.scanPasteboardNow()

        await fulfillment(of: [captured], timeout: 1)
    }

    func testDeleteScreenshotSetsFlagAndInvokesDismiss() async {
        let expectation = expectation(description: "onScreenshotDismissed called on delete")

        viewModel.onScreenshotDismissed = {
            expectation.fulfill()
        }

        viewModel.deleteScreenshot()

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertTrue(viewModel.isDeleted)
    }
}
