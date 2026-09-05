/// A permission prompt or microphone startup cannot authorize an obsolete Talk
/// audience. Call after each asynchronous boundary, before publishing capture.
/// Equality is deliberate: both removals and additions require fresh intent.
enum VoiceCaptureIntent {
    static let maximumRecipients = 32

    /// Empty is legal for a stop/update; starting capture separately requires a
    /// nonempty audience. Check before changing capture or wire-session state.
    static func acceptsAudience(_ recipients: Set<String>) -> Bool {
        recipients.count <= maximumRecipients
    }

    static func isCurrent(requested: Set<String>, effective: Set<String>, present: Set<String>,
                          requestedGeneration: Int, currentGeneration: Int?) -> Bool {
        currentGeneration == requestedGeneration
            && !requested.isEmpty
            && acceptsAudience(requested)
            && requested == effective
            && requested.isSubset(of: present)
    }
}
