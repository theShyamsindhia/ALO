import Foundation
import Testing
@testable import ALONetworking

@Suite("Connection lifecycle and cutover")
struct ConnectionSupervisorTests {
    @Test func discoveryWithoutAnyResultHasABoundedRetry() {
        var supervisor = ConnectionSupervisor()
        _ = supervisor.start(now: 0)
        let lifecycle = supervisor.lifecycle
        #expect(supervisor.advance(lifecycle: lifecycle, now: 14).isEmpty)
        #expect(supervisor.advance(lifecycle: lifecycle, now: 15) == [.retryScheduled(lifecycle: lifecycle, at: 15.5)])
        #expect(supervisor.resolved(lifecycle: lifecycle, now: 15.1).isEmpty)
        _ = supervisor.advance(lifecycle: lifecycle, now: 15.5)
        #expect(supervisor.resolutionFailed(lifecycle: lifecycle, now: 16) == [.retryScheduled(lifecycle: lifecycle, at: 17)])
    }
    private func connecting(_ supervisor: inout ConnectionSupervisor, now: TimeInterval = 0) throws -> TransportToken {
        _ = supervisor.start(now: now)
        _ = supervisor.resolved(lifecycle: supervisor.lifecycle, now: now)
        return try #require(supervisor.pendingToken)
    }
    private func activate(_ supervisor: inout ConnectionSupervisor, now: TimeInterval = 0) throws -> TransportToken {
        let token = try connecting(&supervisor, now: now)
        _ = supervisor.ready(token, now: now)
        _ = supervisor.authenticated(token, now: now)
        _ = supervisor.synchronized(token, madeProgress: true, now: now)
        return token
    }

    @Test func establishmentAndAuthenticationHaveSeparateDeadlines() throws {
        var supervisor = ConnectionSupervisor()
        let token = try connecting(&supervisor)
        #expect(supervisor.advance(lifecycle: token.lifecycle, now: 14).isEmpty)
        _ = supervisor.ready(token, now: 14)
        #expect(supervisor.phase == .authenticating)
        #expect(supervisor.advance(lifecycle: token.lifecycle, now: 18.99).isEmpty)
        let actions = supervisor.advance(lifecycle: token.lifecycle, now: 19)
        #expect(actions.contains(.cancel(token)))
        #expect(supervisor.phase == .reconnecting)
        #expect(supervisor.retryAt == 19.5)
    }

    @Test func lateReadyCannotReviveExpiredAttempt() throws {
        var supervisor = ConnectionSupervisor()
        let token = try connecting(&supervisor)
        #expect(supervisor.ready(token, now: 15).contains(.cancel(token)))
        #expect(supervisor.authenticated(token, now: 15.1).isEmpty)
        #expect(supervisor.synchronized(token, madeProgress: true, now: 15.2).isEmpty)
        #expect(supervisor.activeToken == nil)
    }

    @Test func candidateFailurePreservesOldLinkAndCommitRequiresAgreement() throws {
        var supervisor = ConnectionSupervisor(policy: .init(candidateCooldown: 0))
        let old = try activate(&supervisor)
        _ = supervisor.prepareCandidate(now: 1)
        let failing = try #require(supervisor.candidateToken)
        #expect(supervisor.fail(failing, now: 2) == [.cancel(failing)])
        #expect(supervisor.activeToken == old)
        #expect(supervisor.phase == .active)
        #expect(supervisor.retryAt == nil)
        _ = supervisor.prepareCandidate(now: 3)
        let replacement = try #require(supervisor.candidateToken)
        _ = supervisor.ready(replacement, now: 3)
        _ = supervisor.authenticated(replacement, now: 3)
        #expect(supervisor.synchronized(replacement, madeProgress: false, now: 3).isEmpty)
        #expect(supervisor.commitCutover(replacement, captureFrame: 100, now: 3).isEmpty)
        #expect(supervisor.synchronized(replacement, madeProgress: true, now: 3) == [.candidateReady(replacement)])
        #expect(supervisor.commitCutover(replacement, captureFrame: 100, now: 3).isEmpty)
        #expect(supervisor.activeToken == old)
        _ = supervisor.agreeCutover(replacement, captureFrame: 100, now: 4)
        #expect(supervisor.commitCutover(replacement, captureFrame: 101, now: 4).isEmpty)
        #expect(supervisor.commitCutover(replacement, captureFrame: 100, now: 4) == [
            .becameActive(replacement, replacing: old), .cancel(old)
        ])
        #expect(supervisor.activeToken == replacement)
        #expect(supervisor.fail(old, now: 5).isEmpty)
    }

    @Test func candidateTimeoutAndCooldownPreventChurn() throws {
        var supervisor = ConnectionSupervisor()
        let old = try activate(&supervisor)
        #expect(supervisor.prepareCandidate(now: 29).isEmpty)
        #expect(!supervisor.prepareCandidate(now: 30).isEmpty)
        let candidate = try #require(supervisor.candidateToken)
        #expect(supervisor.prepareCandidate(now: 31).isEmpty)
        #expect(supervisor.advance(lifecycle: supervisor.lifecycle, now: 45) == [.cancel(candidate)])
        #expect(supervisor.activeToken == old)
        #expect(supervisor.prepareCandidate(now: 46).isEmpty)
    }

    @Test func stopSuspendPermissionInvalidateAllCallbacksAndRetries() throws {
        for mode in 0..<3 {
            var supervisor = ConnectionSupervisor()
            let token = try connecting(&supervisor)
            _ = supervisor.fail(token, now: 1)
            let staleLifecycle = supervisor.lifecycle
            switch mode {
            case 0: _ = supervisor.stop()
            case 1: _ = supervisor.suspend()
            default: _ = supervisor.permissionRequired()
            }
            #expect(supervisor.retryAt == nil)
            #expect(supervisor.advance(lifecycle: staleLifecycle, now: 100).isEmpty)
            #expect(supervisor.ready(token, now: 100).isEmpty)
            #expect(supervisor.resolved(lifecycle: staleLifecycle, now: 100).isEmpty)
            _ = supervisor.start(now: 101)
            _ = supervisor.resolved(lifecycle: supervisor.lifecycle, now: 101)
            let replacement = try #require(supervisor.pendingToken)
            #expect(replacement.lifecycle != token.lifecycle)
            #expect(replacement.generation != token.generation)
            #expect(supervisor.authenticated(token, now: 102).isEmpty)
        }
    }

    @Test func hardLossCancelsPendingCandidateAndResolvesAgain() throws {
        var supervisor = ConnectionSupervisor(policy: .init(candidateCooldown: 0))
        let old = try activate(&supervisor)
        _ = supervisor.prepareCandidate(now: 1)
        let candidate = try #require(supervisor.candidateToken)
        let actions = supervisor.fail(old, now: 2)
        #expect(actions.contains(.cancel(candidate)))
        #expect(supervisor.activeToken == nil)
        #expect(supervisor.advance(lifecycle: supervisor.lifecycle, now: 2.49).isEmpty)
        #expect(supervisor.advance(lifecycle: supervisor.lifecycle, now: 2.5) == [.discover(lifecycle: supervisor.lifecycle)])
        _ = supervisor.resolved(lifecycle: supervisor.lifecycle, now: 3)
        #expect(supervisor.pendingToken != candidate)
    }

    @Test func retryJitterIsDeterministicAndBounded() {
        let policy = ConnectionTimingPolicy()
        #expect((0..<6).map { policy.retryDelay(attempt: $0, jitterUnit: 0.5) } == [0.5,1,2,4,8,15])
        #expect(policy.retryDelay(attempt: 0, jitterUnit: 0) == 0.4)
        #expect(abs(policy.retryDelay(attempt: 0, jitterUnit: 1) - 0.6) < 0.000_001)
        #expect(policy.retryDelay(attempt: .max, jitterUnit: 1) == 15)
    }

    @Test func deterministicArbitrationAndOverlapDeduplication() {
        let first = NetworkFixture.sender, second = NetworkFixture.receiver
        #expect(ConnectionSupervisor.preferredConnectionID(first, second) == ConnectionSupervisor.preferredConnectionID(second, first))
        var frames = MediaFrameDeduplicator(broadcasterEpoch: 9)
        let firstFrame = frames.accept(epoch: 9, frame: 100)
        let duplicate = frames.accept(epoch: 9, frame: 100)
        let wrongEpoch = frames.accept(epoch: 8, frame: 101)
        let nextFrame = frames.accept(epoch: 9, frame: 101)
        #expect(firstFrame)
        #expect(!duplicate)
        #expect(!wrongEpoch)
        #expect(nextFrame)
    }
}
