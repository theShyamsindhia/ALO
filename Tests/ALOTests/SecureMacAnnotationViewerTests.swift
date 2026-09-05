import Foundation
import Testing
@testable import ALO

@MainActor
struct SecureMacAnnotationViewerTests {
    @Test("Stopping retains the annotation owner until queued UI cleanup completes")
    func stopCleanupOutlivesTheSessionsLastReference() async {
        var clears = 0
        var viewer: SecureMacAnnotationViewer? = SecureMacAnnotationViewer(localID: UUID(), presenterID: UUID()) { scene in
            #expect(scene == nil)
            clears += 1
        }
        weak var retained = viewer
        viewer?.stop()
        viewer?.stop()
        viewer?.disconnect()
        viewer = nil
        #expect(retained != nil)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(clears == 1)
        #expect(retained == nil)
    }
}
