import CoreGraphics
import Foundation
import Testing
@testable import ALO
import ALOCore

@MainActor
struct SecureMacAnnotationHostTests {
    private final class Overlay: AnnotationOverlayPresenting {
        var updates: [CapturedFrameMetadata] = []
        var hides = 0
        var closes = 0
        func update(metadata: CapturedFrameMetadata) { updates.append(metadata) }
        func hide() { hides += 1 }
        func close() { closes += 1 }
    }

    private func metadata(time: UInt64 = 10) -> CapturedFrameMetadata {
        CapturedFrameMetadata(captureTimeNanos: time,
            contentRect: CGRect(x: 10, y: 20, width: 600, height: 400),
            screenRect: CGRect(x: -900, y: 60, width: 600, height: 400),
            contentScale: 1, scaleFactor: 1, status: .complete)
    }

    private let frameSize = CGSize(width: 800, height: 600)

    private func flushUI() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test("Presenter can place and moderate annotations before any remote peer joins")
    func presenterAlone() async throws {
        let presenterID = UUID(), overlay = Overlay()
        var published: AnnotationSceneModel?
        let host = SecureMacAnnotationHost(roomID: UUID(), presenterID: presenterID, isPublic: false,
            onScene: { published = $0 }, makeOverlay: { _ in overlay })
        host.updateParticipants([presenterID.uuidString: "Presenter", "viewer": "Guest"])
        host.start(scheduling: { $0() }, automaticTicks: false)
        let generation = host.beginSource()
        host.captureMetadata(metadata(), frameSize: frameSize, generation: generation)
        await flushUI()
        let scene = try #require(published)
        #expect(scene.isPresenter && scene.inputAvailable)
        #expect(scene.authorNames["viewer"] == "Guest")
        #expect(overlay.updates.last?.screenRect == metadata().screenRect,
                "The local presenter retains desktop geometry; only the wire representation strips it")
        scene.tool = .sticker
        scene.toggleAnnotations()
        scene.begin(at: CGPoint(x: 0.25, y: 0.5))
        await flushUI()
        #expect(scene.snapshot?.objects.count == 1)
        #expect(scene.snapshot?.objects.first?.authorID == presenterID.uuidString)
        #expect(scene.optimisticStickers.isEmpty)
        scene.setDefaultStickerTTL(.threeHundred)
        scene.disablePeer("viewer")
        await flushUI()
        #expect(scene.snapshot?.policy.defaultStickerTTL == .threeHundred)
        #expect(scene.snapshot?.policy.disabledIDs.contains("viewer") == true)
        var policy = try #require(scene.snapshot?.policy)
        policy.paused = true
        scene.setPolicy(policy)
        await flushUI()
        #expect(!scene.inputAvailable)
        policy.paused = false
        scene.setPolicy(policy)
        await flushUI()
        #expect(scene.inputAvailable, "The presenter can resume moderation while annotation input is paused")
        host.stop()
        await flushUI()
        #expect(published == nil && overlay.closes == 1)
    }

    @Test("New capture generations discard old metadata and objects while retaining tool choice")
    func sourceReplacement() async throws {
        let overlay = Overlay()
        var published: AnnotationSceneModel?
        let host = SecureMacAnnotationHost(roomID: UUID(), presenterID: UUID(), isPublic: false,
            onScene: { published = $0 }, makeOverlay: { _ in overlay })
        host.start(scheduling: { $0() }, automaticTicks: false)
        let first = host.beginSource()
        host.captureMetadata(metadata(), frameSize: frameSize, generation: first)
        await flushUI()
        let scene = try #require(published)
        let sourceID = try #require(scene.snapshot?.sessionID)
        scene.tool = .sticker
        scene.toggleAnnotations()
        scene.begin(at: CGPoint(x: 0.2, y: 0.2))
        await flushUI()
        #expect(scene.snapshot?.objects.count == 1)
        scene.tool = .ellipse
        let second = host.beginSource()
        host.captureMetadata(metadata(time: 100), frameSize: frameSize, generation: first)
        await flushUI()
        #expect(published === scene)
        #expect(scene.snapshot?.sessionID != sourceID && scene.snapshot?.objects.isEmpty == true)
        #expect(scene.captureMetadata == nil && !scene.inputAvailable)
        #expect(scene.tool == .ellipse)
        host.captureMetadata(metadata(time: 30), frameSize: frameSize, generation: second)
        host.captureMetadata(metadata(time: 20), frameSize: frameSize, generation: second)
        await flushUI()
        #expect(scene.captureMetadata?.captureTimeNanos == 30)
        scene.toggleAnnotations()
        #expect(scene.annotationEnabled && scene.tool == .ellipse)
        host.endSource()
        host.captureMetadata(metadata(time: 40), frameSize: frameSize, generation: second)
        await flushUI()
        #expect(published == nil && scene.snapshot == nil && scene.captureMetadata == nil)
        host.stop()
        await flushUI()
        #expect(overlay.closes == 1)
    }

    @Test("Capture callbacks coalesce into one bounded scheduled drain")
    func captureCoalescing() async throws {
        let overlay = Overlay()
        var scheduled: [@Sendable () -> Void] = []
        var published: AnnotationSceneModel?
        let host = SecureMacAnnotationHost(roomID: UUID(), presenterID: UUID(), isPublic: false,
            onScene: { published = $0 }, makeOverlay: { _ in overlay })
        host.start(scheduling: { scheduled.append($0) }, automaticTicks: false)
        let generation = host.beginSource()
        #expect(scheduled.count == 1)
        scheduled.removeFirst()()
        await flushUI()
        let scene = try #require(published)
        for time in 1...1_000 {
            host.captureMetadata(metadata(time: UInt64(time)), frameSize: frameSize, generation: generation)
        }
        #expect(scheduled.count == 1)
        scheduled.removeFirst()()
        await flushUI()
        #expect(scene.captureMetadata?.captureTimeNanos == 1_000)
        #expect(overlay.updates.count == 1)
        host.stop()
        scheduled.removeFirst()()
        await flushUI()
        #expect(overlay.closes == 1)
    }

    @Test("Stopped owners cannot be resurrected by queued source snapshots")
    func stopBeforeUIDelivery() async {
        var scenes: [AnnotationSceneModel?] = []
        var host: SecureMacAnnotationHost? = SecureMacAnnotationHost(roomID: UUID(), presenterID: UUID(),
            isPublic: false, onScene: { scenes.append($0) })
        weak var retained = host
        host?.start(scheduling: { $0() }, automaticTicks: false)
        _ = host?.beginSource()
        host?.stop()
        host?.stop()
        host = nil
        #expect(retained != nil)
        await flushUI()
        #expect(scenes.count == 1 && scenes.allSatisfy { $0 == nil })
        #expect(retained == nil)
    }

    @Test("Overflow disables annotations and clears their overlay without a media stop dependency")
    func boundedCommandOverflow() async throws {
        var scheduled: [@Sendable () -> Void] = []
        var published: AnnotationSceneModel?
        let overlay = Overlay()
        let host = SecureMacAnnotationHost(roomID: UUID(), presenterID: UUID(), isPublic: false,
            onScene: { published = $0 }, makeOverlay: { _ in overlay })
        host.start(scheduling: { scheduled.append($0) }, automaticTicks: false)
        let generation = host.beginSource()
        scheduled.removeFirst()()
        host.captureMetadata(metadata(), frameSize: frameSize, generation: generation)
        scheduled.removeFirst()()
        await flushUI()
        let scene = try #require(published)
        for _ in 0..<129 { scene.requestSnapshot() }
        #expect(scheduled.count == 1)
        scheduled.removeFirst()()
        await flushUI()
        #expect(published == nil && scene.snapshot == nil && overlay.closes == 1)
        host.stop()
        scheduled.removeFirst()()
        await flushUI()
        #expect(overlay.closes == 1)
    }
}
