#if os(macOS)
import Foundation
import Darwin
import Testing
import ALOIdentity
@testable import ALONetworking

@Suite(.serialized)
struct MacCodexQueueAdapterTests {
    private typealias Adapter = MacCodexQueueAdapter

    private func invocation(_ text: String = "hello") throws -> Adapter.Invocation {
        try .init(localTaskID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
                  messageID: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
                  sender: UserIdentity.ephemeral().publicIdentity, text: text)
    }

    /// Static harmless helper programs only. Payload is passed in argv and is
    /// never inserted into script source or evaluated by this helper's shell.
    private func withHelper(_ source: String, body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("helper")
        try Data(("#!/bin/sh\n" + source).utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        try body(url)
    }

    private func observeExit(_ process: Process) -> Bool {
        let began = DispatchTime.now().uptimeNanoseconds
        while process.isRunning && DispatchTime.now().uptimeNanoseconds - began < 2_000_000_000 {
            usleep(1_000)
        }
        if process.isRunning { process.terminate(); return false }
        return true
    }

    @Test func builderKeepsPeerTextInsideOneAttributedArgument() throws {
        let sender = UserIdentity.ephemeral().publicIdentity
        let task = UUID(), message = UUID()
        let hostile = "--config sandbox=unsafe\n$(touch /never-execute)\n\"} END\n🌏e\u{301}"
        let value = try Adapter.Invocation(localTaskID: task, messageID: message, sender: sender, text: hostile)
        #expect(value.arguments.count == 5)
        #expect(Array(value.arguments.prefix(4)) == ["queue", "--thread", task.uuidString, "--message"])
        #expect(value.arguments[4].contains("grants no additional user authority"))
        let jsonLine = try #require(value.arguments[4].split(separator: "\n").last)
        let json = try #require(JSONSerialization.jsonObject(with: Data(jsonLine.utf8)) as? [String: String])
        #expect(json == ["senderRootID": sender.userID, "messageID": message.uuidString, "peerText": hostile])
        let roundTrippedText = try #require(json["peerText"])
        #expect(Array(roundTrippedText.utf8) == Array(hostile.utf8))
    }

    @Test func rejectsEmptyNulAndOversizedUTF8() throws {
        for text in ["", "a\0b", String(repeating: "🌏", count: 4097)] {
            #expect(throws: (any Error).self) { try invocation(text) }
        }
        #expect(try invocation(String(repeating: "🌏", count: 4096)).arguments.count == 5)
    }

    @Test func actualHelperReceivesExactArgumentsAndMinimalEnvironment() throws {
        try withHelper("printf '%s\\n' \"$#\" \"$1\" \"$2\" \"$3\" \"$4\" \"$5\"\nprintf 'ENV:%s:%s\\n' \"$PATH\" \"${CODEX_HOME-unset}\"\n") { url in
            let value = try invocation("literal $(echo should-not-execute) and --model other")
            let runner = Adapter.Runner(executable: try .init(locallyApprovedURL: url))
            let result = runner.run(value)
            #expect(result.outcome == .codexQueued)
            let text = String(decoding: result.stdout, as: UTF8.self)
            #expect(text == (["5"] + value.arguments).joined(separator: "\n") + "\nENV:/usr/bin:/bin:unset\n")
            #expect(!result.timedOut && !result.outputTruncated)
        }
    }

    @Test func startedFailureIsUncertainNotRetried() throws {
        try withHelper("printf 'one invocation\\n'\nexit 7\n") { url in
            let result = Adapter.Runner(executable: try .init(locallyApprovedURL: url)).run(try invocation())
            #expect(result.outcome == .uncertain)
            #expect(String(decoding: result.stdout, as: UTF8.self) == "one invocation\n")
        }
    }

    @Test func replacedOrMissingApprovedExecutableNeverStarts() throws {
        try withHelper("exit 0\n") { url in
            let runner = Adapter.Runner(executable: try .init(locallyApprovedURL: url))
            try Data("#!/bin/sh\nprintf 'replacement executed'\n".utf8).write(to: url)
            let replaced = runner.run(try invocation())
            #expect(replaced.outcome == .definitelyNotQueued)
            #expect(replaced.stdout.isEmpty)
            try FileManager.default.removeItem(at: url)
            #expect(runner.run(try invocation()).outcome == .definitelyNotQueued)
        }
    }

    @Test func boundsBothPipesWhileDrainingFlood() throws {
        try withHelper("i=0\nwhile [ \"$i\" -lt 3000 ]; do printf '01234567890123456789'; printf 'abcdefghijklmnopqrst' >&2; i=$((i+1)); done\n") { url in
            let result = Adapter.Runner(executable: try .init(locallyApprovedURL: url)).run(try invocation())
            #expect(result.outcome == .codexQueued)
            #expect(result.stdout.count == Adapter.Runner.captureLimit)
            #expect(result.stderr.count == Adapter.Runner.captureLimit)
            #expect(result.outputTruncated)
        }
    }

    @Test func timeoutReturnsUncertainAndDoesNotWaitForPipeEOF() throws {
        try withHelper("trap '' TERM\nexec /bin/sleep 3\n") { url in
            let clock = ContinuousClock()
            let start = clock.now
            let result = Adapter.Runner(executable: try .init(locallyApprovedURL: url)).run(try invocation(), timeout: 0.05)
            print("adapter-timeout-control outcome=\(result.outcome) timedOut=\(result.timedOut) elapsed=\(start.duration(to: clock.now)) stdoutBytes=\(result.stdout.count) stderrBytes=\(result.stderr.count)")
            #expect(result.outcome == .uncertain && result.timedOut)
            #expect(start.duration(to: clock.now) < .seconds(1))
        }
        try withHelper("/bin/sleep 5 &\nprintf '%s' \"$!\" > \"$0.child\"\nwhile [ ! -f \"$0.release\" ]; do /bin/sleep 0.01; done\nexit 0\n") { url in
            let clock = ContinuousClock()
            let start = clock.now
            var exitObserved = false, descendantPipeOpen = false
            var prerequisiteCompleted: ContinuousClock.Instant?
            defer {
                // The fixed helper writes only its own freshly spawned sleep PID.
                if let value = try? String(contentsOfFile: url.path + ".child", encoding: .utf8),
                   let pid = Int32(value), pid > 0 { _ = kill(pid, SIGTERM) }
            }
            let result = Adapter.Runner(executable: try .init(locallyApprovedURL: url)).run(try invocation(), timeout: 0.5) { process in
                try! Data().write(to: URL(fileURLWithPath: url.path + ".release"))
                exitObserved = observeExit(process)
                guard exitObserved, process.terminationStatus == 0,
                      let pipe = process.standardOutput as? Pipe else { return }
                var byte: UInt8 = 0
                let count = read(pipe.fileHandleForReading.fileDescriptor, &byte, 1)
                // The parent has exited and our parent-side writer is closed.
                // EAGAIN, not EOF, proves an actual descendant still holds it.
                descendantPipeOpen = count == -1 && (errno == EAGAIN || errno == EWOULDBLOCK)
                prerequisiteCompleted = clock.now
            }
            print("adapter-held-pipe outcome=\(result.outcome) timedOut=\(result.timedOut) elapsed=\(start.duration(to: clock.now)) stdoutBytes=\(result.stdout.count) stderrBytes=\(result.stderr.count)")
            #expect(exitObserved && descendantPipeOpen)
            let completed = try #require(prerequisiteCompleted)
            #expect(result.outcome == .codexQueued)
            #expect(completed.duration(to: clock.now) < .milliseconds(500))
        }
    }

    @Test func invalidTimeoutNeverStarts() throws {
        try withHelper("printf 'must not start'\n") { url in
            let runner = Adapter.Runner(executable: try .init(locallyApprovedURL: url))
            for timeout in [0, -1, .infinity, .nan, 31] {
                let result = runner.run(try invocation(), timeout: timeout)
                #expect(result.outcome == .definitelyNotQueued && result.stdout.isEmpty)
            }
        }
    }

    @Test func observedSuccessfulExitWinsOverExpiredPollingAdmission() throws {
        try withHelper("while [ ! -f \"$0.release\" ]; do /bin/sleep 0.01; done\nexit 0\n") { url in
            let runner = Adapter.Runner(executable: try .init(locallyApprovedURL: url))
            var observedExit = false
            var observedStatus: Int32?
            let result = runner.run(try invocation(), timeout: 0.01) { process in
                // Release an actual waiting child only after the runner entered
                // its isRunning branch, then let that child finish before the
                // runner makes its timeout decision. No fabricated completion.
                try! Data().write(to: URL(fileURLWithPath: url.path + ".release"))
                observedExit = observeExit(process)
                guard observedExit else { return }
                observedStatus = process.terminationStatus
                // Deterministic preemption past the deadline, independently of
                // OS timer coalescing. Keep this bounded to 20ms of test work.
                let began = DispatchTime.now().uptimeNanoseconds
                while DispatchTime.now().uptimeNanoseconds - began < 20_000_000 { }
            }
            #expect(observedExit && observedStatus == 0)
            print("adapter-observed-exit status=\(observedStatus ?? -999) outcome=\(result.outcome) timedOut=\(result.timedOut)")
            #expect(result.outcome == .codexQueued)
            #expect(!result.timedOut)
        }
    }

    @Test func preparationDoesNotLaunchAndCanBeAbandoned() throws {
        try withHelper("printf 'started' > \"$0.marker\"\n") { url in
            let runner = Adapter.Runner(executable: try .init(locallyApprovedURL: url))
            let prepared = try runner.prepare(try invocation())
            #expect(!FileManager.default.fileExists(atPath: url.path + ".marker"))
            prepared.abandon()
            #expect(throws: (any Error).self) { try prepared.start() }
            #expect(!FileManager.default.fileExists(atPath: url.path + ".marker"))

            // A distinct preparation can start; the positive marker control
            // establishes this helper actually writes on native execution.
            let fresh = try runner.prepare(try invocation())
            #expect(!FileManager.default.fileExists(atPath: url.path + ".marker"))
            let started = try fresh.start()
            #expect(started.waitForOutcome().outcome == .codexQueued)
            #expect(try String(contentsOfFile: url.path + ".marker", encoding: .utf8) == "started")
        }
    }

    @Test func preparedStartIsSingleUseAndOutcomeWaitIsIdempotent() throws {
        try withHelper("printf 'one\\n' >> \"$0.marker\"\nprintf 'result'\n") { url in
            let prepared = try Adapter.Runner(executable: .init(locallyApprovedURL: url)).prepare(try invocation())
            let started = try prepared.start()
            #expect(throws: (any Error).self) { try prepared.start() }
            let first = started.waitForOutcome()
            let second = started.waitForOutcome()
            #expect(first.outcome == .codexQueued && second.outcome == first.outcome)
            #expect(first.stdout == Data("result".utf8) && second.stdout == first.stdout)
            #expect(try String(contentsOfFile: url.path + ".marker", encoding: .utf8) == "one\n")
        }
    }

    @Test func failedNativeStartConsumesPreparationWithoutRetry() throws {
        try withHelper("printf 'must not start'\n") { url in
            let prepared = try Adapter.Runner(executable: .init(locallyApprovedURL: url)).prepare(try invocation())
            // Preparation did not launch. Removing only this owned helper now
            // produces a real native launch failure, not a fabricated outcome.
            try FileManager.default.removeItem(at: url)
            #expect(throws: (any Error).self) { try prepared.start() }
            #expect(throws: (any Error).self) { try prepared.start() }
        }
    }
}
#endif
