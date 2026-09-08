import Foundation
import ALOCore

enum PlaybackConcealmentPolicy {
    static let maximumPacketsPerDrain = 10 // 50ms; never backfill a long underrun.
    static func earliestSequence(_ sequences: [UInt32], from expected: UInt32) -> UInt32? {
        sequences.filter { Int32(bitPattern: $0 &- expected) >= 0 }
            .min { $0 &- expected < $1 &- expected }
    }

    static func canFill(expectedSequence: UInt32, nextSequence: UInt32,
                        sourceEndFrame: UInt64?, nextFrame: UInt64,
                        missingRenderNanos: UInt64?, nowNanos: UInt64) -> Bool {
        let packets = nextSequence &- expectedSequence
        guard packets > 0, packets <= UInt32(maximumPacketsPerDrain),
              let sourceEndFrame, nextFrame >= sourceEndFrame,
              let missingRenderNanos, missingRenderNanos > nowNanos else { return false }
        // A missing partial/ambiguous packet cannot be replaced by a guessed
        // fixed-size buffer without changing the source-frame mapping.
        return nextFrame - sourceEndFrame == UInt64(packets) * UInt64(AudioPacket.framesPerPacket)
    }
}
