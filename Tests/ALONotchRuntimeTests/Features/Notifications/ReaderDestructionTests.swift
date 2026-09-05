import Foundation
import XCTest
@testable import ALONotchRuntime

@MainActor
final class ReaderDestructionTests: XCTestCase {
    func testMailReaderReleasesDependenciesFromSynchronousBackgroundCallback() async {
        let payload = BackgroundReleasePayload(MailDatabaseReader(
            contactResolver: MessagesContactResolver(contactStore: DeniedMessagesContactStore())
        ))
        weak var retained = payload.object
        let released = expectation(description: "Mail reader released outside a Swift task")
        DispatchQueue.global(qos: .utility).async {
            payload.object = nil
            released.fulfill()
        }
        await fulfillment(of: [released], timeout: 2)
        XCTAssertNil(retained)
    }

    func testMessagesReaderReleasesDependenciesFromSynchronousBackgroundCallback() async {
        let payload = BackgroundReleasePayload(MessagesDatabaseReader(
            contactResolver: MessagesContactResolver(contactStore: DeniedMessagesContactStore())
        ))
        weak var retained = payload.object
        let released = expectation(description: "Messages reader released outside a Swift task")
        DispatchQueue.global(qos: .utility).async {
            payload.object = nil
            released.fulfill()
        }
        await fulfillment(of: [released], timeout: 2)
        XCTAssertNil(retained)
    }

    func testLazySystemContactStoreCanBeReleasedWithoutReadingContacts() async {
        let payload = BackgroundReleasePayload(SystemMessagesContactStore())
        weak var retained = payload.object
        let released = expectation(description: "Unused Contacts adapter released")
        DispatchQueue.global(qos: .utility).async {
            payload.object = nil
            released.fulfill()
        }
        await fulfillment(of: [released], timeout: 2)
        XCTAssertNil(retained)
    }
}

/// The test hands the only strong reference to one dispatch callback, then waits
/// for completion before inspecting its weak reference. No actor methods run on
/// that callback: only ARC destruction exercises the macOS backdeployment path.
nonisolated private final class BackgroundReleasePayload: @unchecked Sendable {
    var object: AnyObject?
    init(_ object: AnyObject) { self.object = object }
}
