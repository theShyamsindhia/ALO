/// Current secure intent must own every requested sender lease before capture.
/// Legacy startup order remains unchanged; caller owns concrete cleanup.
@MainActor
enum VoiceCaptureStartup {
    static func perform(start: () async throws -> Void,
                        validate: () throws -> Void,
                        publishBegan: () -> Void,
                        awaitReadiness: (() async throws -> Void)? = nil,
                        retireAnnounced: () -> Void = {}) async throws {
        if let awaitReadiness {
            try Task.checkCancellation()
            try validate()
            publishBegan()
            do {
                try await awaitReadiness()
                try Task.checkCancellation()
                try validate()
                try await start()
                try Task.checkCancellation()
                try validate()
            } catch {
                retireAnnounced()
                throw error
            }
        } else {
            try await start()
            try validate()
            publishBegan()
        }
    }
}

/// Shared by both synchronous participant-removal and explicit audience edits.
struct VoiceCaptureLifecycle {
    enum Phase: Equatable { case idle, connecting, ready }
    enum Decision: Equatable { case stop, reuse, wait, restart, ignore }
    private(set) var sessionID: String?
    private(set) var recipients: Set<String> = []
    private(set) var phase: Phase = .idle

    mutating func begin(_ id: String, recipients: Set<String>) {
        sessionID = id; self.recipients = recipients; phase = .connecting
    }
    mutating func ready(_ id: String) -> Bool {
        guard sessionID == id else { return false }
        phase = .ready; return true
    }
    mutating func end(_ id: String) {
        guard sessionID == id else { return }
        sessionID = nil; recipients = []; phase = .idle
    }
    func decision(activeID: String?, requested: Set<String>) -> Decision {
        guard !requested.isEmpty else { return .stop }
        guard let activeID, sessionID == activeID, recipients == requested else { return .restart }
        return phase == .ready ? .reuse : .wait
    }
    func remoteEventDecision(activeID: String?, requested: Set<String>, ownsRestart: Bool) -> Decision {
        // Stored target selection alone is not consent to restart a microphone.
        guard activeID != nil || ownsRestart else { return .ignore }
        return decision(activeID: activeID, requested: requested)
    }
}
