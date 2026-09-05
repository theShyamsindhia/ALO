import Contacts
import XCTest
@testable import ALONotchRuntime

/// Database fixtures must never initialize or query the user's Contacts store.
struct DeniedMessagesContactStore: MessagesContactStoring {
    let authorizationStatus: CNAuthorizationStatus = .denied

    func contact(matching identifier: String) throws -> CNContact? {
        XCTFail("Database fixtures must not query Contacts")
        return nil
    }
}
