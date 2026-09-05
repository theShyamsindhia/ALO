import Testing
@testable import ALO

struct VoiceCaptureIntentTests {
    @Test("An active maximum-size Talk audience cannot expand before its old wire is retired")
    func activeAudienceExpansionIsRejected() {
        let active = Set((0..<32).map { "peer-\($0)" })
        #expect(VoiceCaptureIntent.acceptsAudience(active))
        #expect(!VoiceCaptureIntent.acceptsAudience(active.union(["new-peer"])))
        #expect(VoiceCaptureIntent.acceptsAudience(active.subtracting(["peer-0"]).union(["new-peer"])))
        #expect(!VoiceCaptureIntent.isCurrent(requested: active.union(["new-peer"]),
            effective: active.union(["new-peer"]), present: active.union(["new-peer"]),
            requestedGeneration: 1, currentGeneration: 1))
    }

    @Test("Open Line contributes to the same directed audience cap, without double-counting a Talk target")
    func openLineSharesAudienceLimit() {
        let talk = Set((0..<32).map { "peer-\($0)" })
        #expect(VoiceCaptureIntent.acceptsAudience(talk.union(["peer-0"])))
        #expect(!VoiceCaptureIntent.acceptsAudience(talk.union(["open-line-peer"])))
        #expect(VoiceCaptureIntent.acceptsAudience([]), "An empty update must remain legal so Talk can stop")
    }

    @Test("Permission completion cannot restore a recipient who left while another remains")
    func departedRecipientDuringPermission() {
        let requested: Set<String> = ["B", "C"]
        #expect(VoiceCaptureIntent.isCurrent(requested: requested, effective: requested,
            present: ["B", "C"], requestedGeneration: 1, currentGeneration: 1))
        #expect(!VoiceCaptureIntent.isCurrent(requested: requested, effective: ["C"],
            present: ["C"], requestedGeneration: 1, currentGeneration: 1))
        #expect(!VoiceCaptureIntent.isCurrent(requested: requested, effective: ["C"],
            present: ["B", "C"], requestedGeneration: 1, currentGeneration: 1),
            "Reconnecting cannot restore authorization removed during the prompt")
    }

    @Test("A second check is required after asynchronous microphone startup")
    func targetChangeDuringMicrophoneStart() {
        let requested: Set<String> = ["B", "C"]
        #expect(VoiceCaptureIntent.isCurrent(requested: requested, effective: requested,
            present: ["B", "C", "D"], requestedGeneration: 7, currentGeneration: 7))
        // Permission succeeded, then microphone startup yielded while the user
        // replaced B with D. The earlier successful check must not be reused.
        #expect(!VoiceCaptureIntent.isCurrent(requested: requested, effective: ["C", "D"],
            present: ["B", "C", "D"], requestedGeneration: 7, currentGeneration: 7))
        #expect(!VoiceCaptureIntent.isCurrent(requested: requested, effective: ["B", "C", "D"],
            present: ["B", "C", "D"], requestedGeneration: 7, currentGeneration: 7))
    }

    @Test("Cancel and reselect cannot revive a previous capture generation")
    func cancelAndReselectSameAudience() {
        let audience: Set<String> = ["B"]
        #expect(!VoiceCaptureIntent.isCurrent(requested: audience, effective: audience,
            present: audience, requestedGeneration: 1, currentGeneration: nil))
        #expect(!VoiceCaptureIntent.isCurrent(requested: audience, effective: audience,
            present: audience, requestedGeneration: 1, currentGeneration: 3))
        #expect(VoiceCaptureIntent.isCurrent(requested: audience, effective: audience,
            present: audience, requestedGeneration: 3, currentGeneration: 3))
    }

    @Test("Empty or absent audiences cannot authorize microphone publication")
    func requireExplicitPresentAudience() {
        #expect(!VoiceCaptureIntent.isCurrent(requested: [], effective: [], present: [],
            requestedGeneration: 1, currentGeneration: 1))
        #expect(!VoiceCaptureIntent.isCurrent(requested: ["B"], effective: ["B"], present: [],
            requestedGeneration: 1, currentGeneration: 1))
        #expect(VoiceCaptureIntent.isCurrent(requested: ["B"], effective: ["B"], present: ["B", "C"],
            requestedGeneration: 1, currentGeneration: 1),
            "An unrelated join must not expand or cancel an unchanged directed audience")
    }
}
