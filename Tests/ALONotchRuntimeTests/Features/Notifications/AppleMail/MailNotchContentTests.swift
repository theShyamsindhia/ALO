import XCTest
@testable import ALONotchRuntime

final class MailNotchContentTests: XCTestCase {

    func testIDUsesRegistryID() {
        let message = makeTestMailMessage(
            rowID: 123,
            messageIDHeader: "",
            sender: "sender@example.com",
            subject: "Test",
            summary: "Preview",
            receivedDate: Date()
        )

        let content = NotificationsNotchContent(
            items: [.mail(message)],
            onOpenMail: { _ in }
        )

        XCTAssertEqual(content.id, NotchContentRegistry.Notifications.messages.id)
    }
    
    func testSizeUsesExpandedHeightWhenSummaryExists() {
        let message = makeTestMailMessage(
            rowID: 1,
            messageIDHeader: "",
            sender: "sender@example.com",
            subject: "Test",
            summary: "Preview",
            receivedDate: Date()
        )

        let content = NotificationsNotchContent(
            items: [.mail(message)],
            onOpenMail: { _ in }
        )

        let size = content.size(
            baseWidth: 200,
            baseHeight: 40
        )

        XCTAssertEqual(size.width, 360)
        XCTAssertEqual(size.height, 115)
    }

    func testSizeUsesCompactHeightWhenSummaryIsMissing() {
        let message = makeTestMailMessage(
            rowID: 2,
            messageIDHeader: "",
            sender: "sender@example.com",
            subject: "Test",
            summary: nil,
            receivedDate: Date()
        )

        let content = NotificationsNotchContent(
            items: [.mail(message)],
            onOpenMail: { _ in }
        )

        let size = content.size(
            baseWidth: 200,
            baseHeight: 40
        )

        XCTAssertEqual(size.width, 360)
        XCTAssertEqual(size.height, 100)
    }

    func testDynamicIslandSizeWhenSummaryExists() {
        let message = makeTestMailMessage(
            rowID: 3,
            messageIDHeader: "",
            sender: "sender@example.com",
            subject: "Test",
            summary: "Preview",
            receivedDate: Date()
        )

        let content = NotificationsNotchContent(
            items: [.mail(message)],
            onOpenMail: { _ in }
        )

        let size = content.dynamicIslandSize(
            baseWidth: 200,
            baseHeight: 40
        )

        XCTAssertEqual(size.width, 410)
        XCTAssertEqual(size.height, 112)
    }

    func testDynamicIslandSizeWhenSummaryIsMissing() {
        let message = makeTestMailMessage(
            rowID: 4,
            messageIDHeader: "",
            sender: "sender@example.com",
            subject: "Test",
            summary: nil,
            receivedDate: Date()
        )

        let content = NotificationsNotchContent(
            items: [.mail(message)],
            onOpenMail: { _ in }
        )

        let size = content.dynamicIslandSize(
            baseWidth: 200,
            baseHeight: 40
        )

        XCTAssertEqual(size.width, 380)
        XCTAssertEqual(size.height, 100)
    }
}
