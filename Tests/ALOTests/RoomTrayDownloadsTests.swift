import Foundation
import Testing
@testable import ALO

@Suite("Room shelf download lifecycle") @MainActor
struct RoomTrayDownloadsTests {
    @Test func duplicateRequestsAreCoalescedAndCompletionClearsActivity() throws {
        let downloads = RoomTrayDownloads()
        defer { downloads.reset() }
        var requests = 0
        #expect(downloads.begin("file") { requests += 1 })
        #expect(!downloads.begin("file") { requests += 1 })
        #expect(requests == 1)
        let attempt = try #require(downloads.attempt(for: "file"))
        downloads.finish("file", attempt: attempt)
        #expect(downloads.states.isEmpty)
    }

    @Test func unavailableCopyExplainsFailureAndRetryIgnoresOldTimeout() throws {
        let downloads = RoomTrayDownloads()
        defer { downloads.reset() }
        downloads.begin("file") {}
        let first = try #require(downloads.attempt(for: "file"))
        downloads.expire("file", attempt: first)
        #expect(downloads.activeIDs.isEmpty)
        #expect(downloads.error(for: "file")?.contains("reconnect") == true)
        #expect(downloads.begin("file") {})
        let second = try #require(downloads.attempt(for: "file"))
        #expect(second != first)
        downloads.expire("file", attempt: first)
        downloads.finish("file", attempt: first, error: "Late verification failure")
        #expect(downloads.attempt(for: "file") == second)
        #expect(downloads.error(for: "file") == nil)
    }

    @Test func cancelAndLeaveIgnoreLateCallbacks() throws {
        let downloads = RoomTrayDownloads()
        downloads.begin("file") {}
        let first = try #require(downloads.attempt(for: "file"))
        downloads.cancel("file")
        downloads.finish("file", attempt: first, error: "Late failure")
        #expect(downloads.states.isEmpty)
        downloads.begin("file") {}
        let second = try #require(downloads.attempt(for: "file"))
        downloads.reset()
        downloads.expire("file", attempt: second)
        #expect(downloads.states.isEmpty)
    }

    @Test func concurrencyIsBoundedAndRejectionCanBeRetried() {
        let downloads = RoomTrayDownloads()
        defer { downloads.reset() }
        var requests = 0
        for id in 0..<4 { #expect(downloads.begin(String(id)) { requests += 1 }) }
        #expect(!downloads.begin("fifth") { requests += 1 })
        #expect(requests == 4)
        #expect(downloads.error(for: "fifth") != nil)
        downloads.cancel("0")
        #expect(downloads.begin("fifth") { requests += 1 })
        #expect(requests == 5)
        #expect(downloads.activeIDs.count == 4)
    }

    @Test func removedRoomItemsDropActivityAndErrors() throws {
        let downloads = RoomTrayDownloads()
        defer { downloads.reset() }
        downloads.begin("removed") {}
        downloads.begin("retained") {}
        let removed = try #require(downloads.attempt(for: "removed"))
        downloads.finish("removed", attempt: removed, error: "No peer")
        downloads.retain(["retained"])
        #expect(Set(downloads.states.keys) == ["retained"])
    }

    @Test func scheduledTimeoutActuallyEndsTheRequest() async throws {
        let downloads = RoomTrayDownloads(timeout: .milliseconds(10))
        defer { downloads.reset() }
        downloads.begin("file") {}
        for _ in 0..<100 where downloads.error(for: "file") == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(downloads.error(for: "file") != nil)
        #expect(downloads.activeIDs.isEmpty)
    }
}
