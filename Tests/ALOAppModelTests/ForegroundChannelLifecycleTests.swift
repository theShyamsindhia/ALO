import Testing
@testable import ALOAppModel

@Suite("Foreground channel lifecycle")
@MainActor
struct ForegroundChannelLifecycleTests {
    @Test func repeatedForegroundActivationPreservesManualJoin() async throws {
        let lifecycle = ForegroundChannelLifecycle()
        await lifecycle.activate { _ in }.value
        let intent = try #require(lifecycle.beginJoin())
        var automaticReconnects = 0
        // Permission sheets and Control Center pass through inactive without suspend.
        await lifecycle.activate { _ in automaticReconnects += 1 }.value
        #expect(lifecycle.accepts(intent))
        #expect(automaticReconnects == 0)
    }

    @Test func explicitAccountRefreshRunsWithoutInvalidatingJoin() async throws {
        let lifecycle = ForegroundChannelLifecycle()
        await lifecycle.activate { _ in }.value
        let intent = try #require(lifecycle.beginJoin())
        var refreshes = 0
        await lifecycle.activate(refreshIfForeground: true) { activation in
            #expect(lifecycle.accepts(activation))
            refreshes += 1
        }.value
        #expect(refreshes == 1)
        #expect(lifecycle.accepts(intent))
        lifecycle.suspend()
        #expect(!lifecycle.accepts(intent))
    }

    @Test func repeatedActivationDoesNotCancelAccountSetup() async throws {
        let lifecycle = ForegroundChannelLifecycle()
        var resume: CheckedContinuation<Void, Never>?
        var completions = 0
        let task = lifecycle.activate { activation in
            await withCheckedContinuation { resume = $0 }
            if !Task.isCancelled, lifecycle.accepts(activation) { completions += 1 }
        }
        while resume == nil { await Task.yield() }
        await lifecycle.activate { _ in Issue.record("Duplicate activation ran setup") }.value
        try #require(resume).resume()
        await task.value
        #expect(completions == 1)
    }

    @Test func suspendBeforeQueuedActivationDoesNotStartWork() async {
        let lifecycle = ForegroundChannelLifecycle()
        var starts = 0
        let task = lifecycle.activate { _ in starts += 1 }
        lifecycle.suspend()
        await task.value
        #expect(starts == 0)
        #expect(!lifecycle.isForeground)
    }

    @Test func suspensionInvalidatesAnActivationWaitingForAccountResume() async throws {
        let lifecycle = ForegroundChannelLifecycle()
        var resume: CheckedContinuation<Void, Never>?
        var staleReconnects = 0
        let pending = lifecycle.activate { activation in
            await withCheckedContinuation { resume = $0 }
            if !Task.isCancelled, lifecycle.accepts(activation) { staleReconnects += 1 }
        }
        while resume == nil { await Task.yield() }
        lifecycle.suspend()
        var newReconnects = 0
        await lifecycle.activate { _ in newReconnects += 1 }.value
        try #require(resume).resume()
        await pending.value
        #expect(staleReconnects == 0)
        #expect(newReconnects == 1)
    }

    @Test func manualJoinIsCapturedBeforeQueuedWorkAndCannotSurviveSuspend() async throws {
        let lifecycle = ForegroundChannelLifecycle()
        await lifecycle.activate { _ in }.value
        let intent = try #require(lifecycle.beginJoin())
        lifecycle.suspend()
        #expect(!lifecycle.accepts(intent))
        #expect(lifecycle.beginJoin() == nil)
        await lifecycle.activate { _ in }.value
        #expect(!lifecycle.accepts(intent))
        let next = try #require(lifecycle.beginJoin())
        #expect(lifecycle.accepts(next))
    }

    @Test func leaveBeforeQueuedActivationDoesNotRestoreSavedChannel() async {
        let lifecycle = ForegroundChannelLifecycle()
        var reconnects = 0
        let task = lifecycle.activate { _ in reconnects += 1 }
        lifecycle.invalidatePendingWork()
        await task.value
        #expect(reconnects == 0)
    }

    @Test func newerExplicitSelectionSupersedesEarlierSelection() async throws {
        let lifecycle = ForegroundChannelLifecycle()
        await lifecycle.activate { _ in }.value
        let first = try #require(lifecycle.beginJoin())
        let second = try #require(lifecycle.beginJoin())
        #expect(!lifecycle.accepts(first))
        #expect(lifecycle.accepts(second))
    }

    @Test func manualSelectionSupersedesQueuedAutomaticReconnect() async throws {
        let lifecycle = ForegroundChannelLifecycle()
        var automaticReconnects = 0
        let task = lifecycle.activate { _ in automaticReconnects += 1 }
        let manual = try #require(lifecycle.beginJoin())
        await task.value
        #expect(automaticReconnects == 0)
        #expect(lifecycle.accepts(manual))
    }
}
