import Testing
@testable import ALONetworking
@testable import ALO

@Suite struct MediaAttachmentGateTests {
    @Test func oldOpenCompletionCannotReplaceNewAnnotationBinding() {
        let gate = MediaAttachmentGate()
        let old = TransportToken(lifecycle: 1, generation: 1)
        let current = TransportToken(lifecycle: 1, generation: 2)
        var binding: TransportToken?
        gate.set(old)
        gate.set(current)
        if gate.accepts(current) { binding = current }
        // The older connection finishes after the current one attached.
        if gate.accepts(old) { binding = old }
        #expect(binding == current)
        gate.set(nil)
        #expect(!gate.accepts(current))
        gate.set(TransportToken(lifecycle: 2, generation: 1))
        #expect(!gate.accepts(old))
    }
}
