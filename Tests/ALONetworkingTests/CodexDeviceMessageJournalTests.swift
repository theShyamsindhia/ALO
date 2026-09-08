import Foundation
import Testing
@testable import ALONetworking

struct CodexDeviceMessageJournalTests {
    @Test func journalHasExclusiveWriterAndSurvivesReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal: CodexDeviceMessageJournal? = try .init(directoryURL: directory)
        #expect(throws: (any Error).self) { try CodexDeviceMessageJournal(directoryURL: directory) }
        try journal?.save(CodexDeviceMessagingPolicy().checkpoint)
        #expect(try journal?.load() != nil)
        journal = nil
        let reopened = try CodexDeviceMessageJournal(directoryURL: directory)
        let loaded = try reopened.load()
        let saved = try #require(loaded)
        #expect(try !CodexDeviceMessagingPolicy(restoring: saved).isEnabled)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("receipts.json").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
