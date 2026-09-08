import Foundation
import ALOCore

/// Already validated/DSP-processed PCM. One bounded cohort is held on the
/// playback executor; packet credits remain distinct from native buffer count.
struct PlaybackPCMCohort {
    static let maximumPackets = 4
    static let maximumFrames = 960
    static let maximumHoldNanos: UInt64 = 20_000_000
    struct Context: Equatable {
        var offset: Int64
        var targetLatency: UInt64
        var outputLatency: UInt64
    }
    let sourceFrame: UInt64
    let firstRenderNanos: UInt64
    let heldAtNanos: UInt64
    let context: Context
    private(set) var samples: [Int16]
    private(set) var packetCount = 1
    private(set) var endFrame: UInt64
    private(set) var endRenderNanos: UInt64
    var frameCount: Int { samples.count / Int(AudioPacket.channelCount) }
    var isFull: Bool { packetCount == Self.maximumPackets || frameCount == Self.maximumFrames }

    init?(samples: [Int16], sourceFrame: UInt64, renderNanos: UInt64,
          heldAtNanos: UInt64, context: Context) {
        guard !samples.isEmpty, samples.count % Int(AudioPacket.channelCount) == 0,
              samples.count / Int(AudioPacket.channelCount) <= Int(AudioPacket.framesPerPacket) else { return nil }
        let frames = UInt64(samples.count / Int(AudioPacket.channelCount))
        let end = sourceFrame.addingReportingOverflow(frames)
        let renderEnd = renderNanos.addingReportingOverflow(frames * 1_000_000_000 / UInt64(AudioPacket.sampleRate))
        guard !end.overflow, !renderEnd.overflow else { return nil }
        self.sourceFrame = sourceFrame; self.firstRenderNanos = renderNanos
        self.heldAtNanos = heldAtNanos; self.context = context
        self.samples = samples; self.endFrame = end.partialValue
        self.endRenderNanos = renderEnd.partialValue
    }

    mutating func append(_ next: Self) -> Bool {
        guard context == next.context, endFrame == next.sourceFrame,
              packetCount + next.packetCount <= Self.maximumPackets,
              frameCount + next.frameCount <= Self.maximumFrames else { return false }
        // Capture validation permits small timestamp jitter. Native PCM is
        // contiguous in source frames, so never stretch its ledger to the last
        // packet's jittered wall deadline.
        let duration = UInt64(frameCount + next.frameCount) * 1_000_000_000 / UInt64(AudioPacket.sampleRate)
        let renderEnd = firstRenderNanos.addingReportingOverflow(duration)
        guard !renderEnd.overflow else { return false }
        samples.append(contentsOf: next.samples)
        packetCount += next.packetCount
        endFrame = next.endFrame; endRenderNanos = renderEnd.partialValue
        return true
    }

    func flushDeadline(headroomNanos: UInt64) -> UInt64 {
        let age = heldAtNanos.addingReportingOverflow(Self.maximumHoldNanos)
        let ageDeadline = age.overflow ? UInt64.max : age.partialValue
        let renderDeadline = firstRenderNanos > headroomNanos ? firstRenderNanos - headroomNanos : 0
        return min(ageDeadline, renderDeadline)
    }
}
