import Foundation
import ALOCore

/// Local-only evidence about why the existing estimator accepted/rejected a
/// poll. These are policy gates, not diagnoses of hardware or acoustic output.
enum RenderObservationReason: Int, CaseIterable, Sendable {
    case detached, paused, notStarted, recovery, missingClock, missingAnchor
    case missingRenderTime, invalidHostTime, missingPlayerTime, invalidSampleTime
    case stalePacket, clockRange, renderAheadOfPoll, staleRender, invalidTimeline, measured
    case measuredRealigned

    static func afterMeasurement(realigned: Bool) -> Self { realigned ? .measuredRealigned : .measured }

    var label: String {
        switch self {
        case .detached: "detached"
        case .paused: "paused"
        case .notStarted: "not-started"
        case .recovery: "recovery"
        case .missingClock: "missing-clock"
        case .missingAnchor: "missing-anchor"
        case .missingRenderTime: "missing-render-time"
        case .invalidHostTime: "host-time-unavailable"
        case .missingPlayerTime: "missing-player-time"
        case .invalidSampleTime: "sample-time-unavailable"
        case .stalePacket: "packet-not-fresh"
        case .clockRange: "clock-range"
        case .renderAheadOfPoll: "render-ahead-of-poll"
        case .staleRender: "render-stale"
        case .invalidTimeline: "timeline-not-estimable"
        case .measured: "measured"
        case .measuredRealigned: "measured-realigned"
        }
    }
}

struct RenderObservationSample: Sendable, Equatable {
    var reason: RenderObservationReason = .detached
    var observedAtNanos: UInt64
    var renderAgeAtPollMilliseconds: Double?
    var renderAgeAtObservationMilliseconds: Double?
    var packetAgeMilliseconds: Double?
    var anchorMarginMilliseconds: Double?
    var sampleTime: Int64?
    var sampleRate: Double?
    var outputBufferMilliseconds: Double?
    var outputSafetyMilliseconds: Double?
    var permittedFutureLeadMilliseconds: Double?

    static func signedAgeMilliseconds(now: UInt64, sample: UInt64) -> Double {
        now >= sample ? Double(now - sample) / 1_000_000 : -Double(sample - now) / 1_000_000
    }

    static func clockGate(pollNanos: UInt64, renderNanos: UInt64,
                          permittedFutureLeadNanos: UInt64 = 0) -> RenderObservationReason? {
        if RenderDriftEstimate.clockIsWithinWindow(nowNanos: pollNanos, renderLocalNanos: renderNanos,
            permittedFutureLeadNanos: permittedFutureLeadNanos) { return nil }
        if renderNanos > pollNanos { return .renderAheadOfPoll }
        return .staleRender
    }
}

struct RenderObservation: Sendable, Equatable {
    let sample: RenderObservationSample
    let observationAgeMilliseconds: Double
    let sampleTimeDelta: Int64?
    /// Fixed cardinality; no timestamp/event history or media content is retained.
    let counts: [UInt64]

    var detail: String {
        func number(_ value: Double?) -> String {
            value.map { String(format: "%.3f", $0) } ?? "unavailable"
        }
        let counters = RenderObservationReason.allCases.compactMap { reason -> String? in
            let count = counts[reason.rawValue]
            return count == 0 ? nil : "\(reason.label)=\(count)"
        }.joined(separator: ",")
        return "render observation \(sample.reason.label), age \(number(observationAgeMilliseconds)) ms, poll/observed render ages \(number(sample.renderAgeAtPollMilliseconds))/\(number(sample.renderAgeAtObservationMilliseconds)) ms, packet age \(number(sample.packetAgeMilliseconds)) ms, anchor margin \(number(sample.anchorMarginMilliseconds)) ms, sample delta \(sampleTimeDelta.map(String.init) ?? "unavailable"), player Hz \(number(sample.sampleRate)), output buffer/safety \(number(sample.outputBufferMilliseconds))/\(number(sample.outputSafetyMilliseconds)) ms, permitted future lead \(sample.permittedFutureLeadMilliseconds.map { number($0) + " ms" } ?? "unavailable (strict 0)"), polls {\(counters)}"
    }
}

struct RenderObservationRecorder {
    private var counts = [UInt64](repeating: 0, count: RenderObservationReason.allCases.count)
    private var latest: RenderObservationSample?
    private var previousSampleTime: Int64?
    private var sampleTimeDelta: Int64?

    mutating func record(_ sample: RenderObservationSample) {
        let index = sample.reason.rawValue
        if counts[index] < UInt64.max { counts[index] += 1 }
        sampleTimeDelta = nil
        if let current = sample.sampleTime {
            if let previousSampleTime {
                let difference = current.subtractingReportingOverflow(previousSampleTime)
                if !difference.overflow { sampleTimeDelta = difference.partialValue }
            }
            previousSampleTime = current
        }
        latest = sample
        // The defer recording a recovery still contains the pre-stop sample.
        // Do not reseed continuity from it after hardResynchronize cleared it.
        if sample.reason == .recovery || sample.reason == .measuredRealigned {
            resetSampleTimeContinuity()
        }
    }

    mutating func resetSampleTimeContinuity() {
        previousSampleTime = nil
        sampleTimeDelta = nil
    }

    func snapshot(at now: UInt64) -> RenderObservation? {
        latest.map { RenderObservation(sample: $0,
            observationAgeMilliseconds: RenderObservationSample.signedAgeMilliseconds(now: now, sample: $0.observedAtNanos),
            sampleTimeDelta: sampleTimeDelta, counts: counts) }
    }
}
