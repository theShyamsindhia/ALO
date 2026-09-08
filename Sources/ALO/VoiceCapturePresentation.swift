/// Pure presentation boundary used by the live phase callback. It does not
/// authorize capture; the caller retains its channel-generation fence.
struct VoiceCapturePresentation {
    let starting: Bool
    let talking: Bool
    let status: String

    static func phase(_ phase: VoiceCaptureLifecycle.Phase, hasTalkTargets: Bool,
                      talkingStatus: String,
                      otherVoiceStatus: String?) -> Self {
        let status: String
        switch phase {
        case .connecting where hasTalkTargets:
            status = "Connecting voice to selected devices…"
        case .ready where hasTalkTargets:
            status = talkingStatus
        case .idle:
            status = otherVoiceStatus ?? (hasTalkTargets ? "Talk paused" : "Talk is off")
        default:
            status = otherVoiceStatus ?? "Talk is off"
        }
        return .init(starting: phase == .connecting && hasTalkTargets,
                     talking: phase == .ready && hasTalkTargets, status: status)
    }

    static func isSpeaking(isLocal: Bool, talk: Bool, openLineMicrophone: Bool,
                           incoming: Bool) -> Bool {
        incoming || (isLocal && (talk || openLineMicrophone))
    }
}
