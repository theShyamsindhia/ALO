import Foundation
import ALOCore

struct RoomSyncSample: Identifiable, Equatable, Sendable {
    var id: UInt64 { sampledAtNanos }
    let sampledAtNanos: UInt64
    let driftMilliseconds: Double?
    let roundTripMilliseconds: Double?
    let occurredAt: Date
    let latePacketCount: UInt64?
    let resyncCount: UInt64?
    let bufferMilliseconds: Double?
    let jitterMilliseconds: Double?
    let outputPathMilliseconds: Double?
}

/// Numeric evidence only: participant numbers have meaning only inside this
/// monitor session. Never export the live trace's identity or display strings.
struct RoomSyncIncident: Equatable, Sendable {
    enum Trigger: String, Sendable {
        case driftExceeded = "drift-threshold"
        // An unknown measurement, not proof of failed or misaligned playback.
        case measurementMissing = "measurement-missing"
    }
    let participantNumber: Int
    let isLocal: Bool
    let trigger: Trigger
    let occurredAt: Date
    var samples: [RoomSyncSample]
}

struct RoomSyncTrace: Identifiable, Equatable {
    let id: String
    var name: String
    var isLocal: Bool
    var samples: [RoomSyncSample]

    var latest: RoomSyncSample? { samples.last }
}

struct RoomSyncEvent: Identifiable, Equatable {
    enum Kind: Equatable {
        case notice
        case warning
        case recovery
        case correction
    }

    let id: UUID
    let occurredAt: Date
    let kind: Kind
    let title: String
    let detail: String
}

/// A bounded, in-memory flight recorder for the active room. Participant names
/// are used only by the live UI and are never added to exported diagnostics.
struct RoomSyncMonitor {
    static let correctionThresholdMilliseconds = SyncHealthTolerance.driftWarningMilliseconds
    static let recoveryThresholdMilliseconds = SyncHealthTolerance.driftRecoveryMilliseconds
    static let maximumSamplesPerParticipant = 90
    static let maximumEvents = 48
    static let maximumParticipants = 32
    static let maximumIncidents = 16
    private static let incidentLeadingSamples = 15
    private static let incidentFollowingSamples = 30
    static let maximumIncidentSamples = incidentLeadingSamples + incidentFollowingSamples

    private struct IncidentRecording {
        let participantID: String
        var evidence: RoomSyncIncident
        var remainingSamples: Int
    }

    private struct ParticipantState {
        var hadFreshDrift = false
        var wasOutsideTolerance = false
        var roundTripMilliseconds: Double?
        var latePacketCount: UInt64?
        var resyncCount: UInt64?
    }

    private struct RoomState {
        var bufferMilliseconds: Double?
        var jitterMilliseconds: Double?
        var outputPathMilliseconds: Double?
        var roomTimingChangeCount: UInt64?
    }

    private(set) var traces: [String: RoomSyncTrace] = [:]
    private(set) var events: [RoomSyncEvent] = []
    private var participantStates: [String: ParticipantState] = [:]
    private var roomState = RoomState()
    private var participantNumbers: [String: Int] = [:]
    private var nextParticipantNumber = 1
    private var recordings: [IncidentRecording] = []

    var incidents: [RoomSyncIncident] { recordings.map(\.evidence) }

    var orderedTraces: [RoomSyncTrace] {
        traces.values.sorted {
            if $0.isLocal != $1.isLocal { return $0.isLocal }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var latestSampleNanos: UInt64? {
        traces.values.compactMap { $0.latest?.sampledAtNanos }.max()
    }

    mutating func reset() {
        self = RoomSyncMonitor()
    }

    mutating func observe(
        participants: [RoomParticipant],
        currentParticipantID: String?,
        timing: SessionTimingDiagnostics,
        sampledAtNanos: UInt64,
        occurredAt: Date = Date()
    ) {
        if traces.isEmpty {
            appendEvent(.notice, title: "Live timing monitor started",
                        detail: "ALO is sampling each playback clock once per second.", at: occurredAt)
        }

        let listeners = Dictionary(uniqueKeysWithValues: (timing.host?.listeners ?? []).map { ($0.peerID, $0) })
        let knownIDs = Set(participants.map(\.id))
        for participant in participants {
            let isLocal = participant.id == currentParticipantID
            let listener = listeners[participant.id]
            let peerTiming = participant.playbackTiming
            let drift: Double?
            if isLocal {
                drift = freshReceiverDrift(timing.receiver)
            } else if let listener {
                drift = freshListenerDrift(listener)
            } else {
                drift = peerTiming?.driftMilliseconds
            }
            let roundTrip = isLocal
                ? timing.receiver?.roundTripMilliseconds
                : peerTiming?.roundTripMilliseconds
            appendSample(participantID: participant.id,
                         name: isLocal ? "You" : participant.name,
                         isLocal: isLocal,
                         driftMilliseconds: freshFinite(drift),
                         roundTripMilliseconds: freshFinite(roundTrip),
                         sampledAtNanos: sampledAtNanos,
                         occurredAt: occurredAt,
                         latePacketCount: isLocal ? timing.receiver?.latePacketCount : listener?.latePacketCount,
                         resyncCount: isLocal ? timing.receiver?.resyncCount : listener?.resyncCount,
                         bufferMilliseconds: timing.host?.groupBufferMilliseconds
                            ?? timing.receiver?.activePlayoutBufferMilliseconds
                            ?? timing.receiver?.recommendedBufferMilliseconds,
                         jitterMilliseconds: isLocal ? timing.receiver?.jitterMilliseconds : nil,
                         outputPathMilliseconds: isLocal ? timing.receiver.map {
                             $0.outputLatencyMilliseconds + $0.renderHeadroomMilliseconds
                         } : nil)
            observeParticipant(participantID: participant.id,
                               name: isLocal ? "You" : participant.name,
                               driftMilliseconds: freshFinite(drift),
                               roundTripMilliseconds: freshFinite(roundTrip),
                               latePacketCount: isLocal ? timing.receiver?.latePacketCount : listener?.latePacketCount,
                               resyncCount: isLocal ? timing.receiver?.resyncCount : listener?.resyncCount,
                               occurredAt: occurredAt)
        }

        // Preserve the final shape of a departed peer's trace, but do not keep
        // appending synthetic zeroes once it is no longer in the room.
        participantStates = participantStates.filter { knownIDs.contains($0.key) }
        observeRoomMetrics(timing, occurredAt: occurredAt)
    }

    mutating func markUnavailable(
        participants: [RoomParticipant],
        currentParticipantID: String?,
        sampledAtNanos: UInt64,
        reason: String,
        kind: RoomSyncEvent.Kind = .warning,
        occurredAt: Date = Date()
    ) {
        var interrupted = false
        for participant in participants {
            guard var state = participantStates[participant.id], state.hadFreshDrift else { continue }
            let isLocal = participant.id == currentParticipantID
            appendSample(participantID: participant.id,
                         name: isLocal ? "You" : participant.name,
                         isLocal: isLocal,
                         driftMilliseconds: nil,
                         roundTripMilliseconds: nil,
                         sampledAtNanos: sampledAtNanos, occurredAt: occurredAt,
                         recordsMissingIncident: kind != .notice)
            state.hadFreshDrift = false
            participantStates[participant.id] = state
            interrupted = true
        }
        if interrupted {
            appendEvent(kind, title: "Live timing was interrupted", detail: reason, at: occurredAt)
        }
    }

    private mutating func appendSample(
        participantID: String,
        name: String,
        isLocal: Bool,
        driftMilliseconds: Double?,
        roundTripMilliseconds: Double?,
        sampledAtNanos: UInt64,
        occurredAt: Date,
        latePacketCount: UInt64? = nil,
        resyncCount: UInt64? = nil,
        bufferMilliseconds: Double? = nil,
        jitterMilliseconds: Double? = nil,
        outputPathMilliseconds: Double? = nil,
        recordsMissingIncident: Bool = true
    ) {
        if traces[participantID] == nil {
            if traces.count >= Self.maximumParticipants,
               let oldest = traces.min(by: {
                   ($0.value.latest?.sampledAtNanos ?? 0) < ($1.value.latest?.sampledAtNanos ?? 0)
               })?.key {
                traces.removeValue(forKey: oldest)
                participantStates.removeValue(forKey: oldest)
                participantNumbers.removeValue(forKey: oldest)
                // An evicted trace cannot continue an earlier recording under
                // a newly assigned anonymous participant number.
                for index in recordings.indices where recordings[index].participantID == oldest {
                    recordings[index].remainingSamples = 0
                }
            }
            participantNumbers[participantID] = nextParticipantNumber
            nextParticipantNumber += 1
        }
        var trace = traces[participantID]
            ?? RoomSyncTrace(id: participantID, name: name, isLocal: isLocal, samples: [])
        trace.name = name
        trace.isLocal = isLocal
        let sample = RoomSyncSample(sampledAtNanos: sampledAtNanos,
                                            driftMilliseconds: driftMilliseconds,
                                            roundTripMilliseconds: roundTripMilliseconds,
                                            occurredAt: occurredAt,
                                            latePacketCount: latePacketCount, resyncCount: resyncCount,
                                            bufferMilliseconds: freshFinite(bufferMilliseconds),
                                            jitterMilliseconds: freshFinite(jitterMilliseconds),
                                            outputPathMilliseconds: freshFinite(outputPathMilliseconds))
        trace.samples.append(sample)
        if trace.samples.count > Self.maximumSamplesPerParticipant {
            trace.samples.removeFirst(trace.samples.count - Self.maximumSamplesPerParticipant)
        }
        traces[participantID] = trace
        for index in recordings.indices where recordings[index].participantID == participantID
            && recordings[index].remainingSamples > 0 {
            recordings[index].evidence.samples.append(sample)
            recordings[index].remainingSamples -= 1
        }
        let state = participantStates[participantID]
        let trigger: RoomSyncIncident.Trigger?
        if let driftMilliseconds, driftMilliseconds >= Self.correctionThresholdMilliseconds,
           state?.wasOutsideTolerance != true {
            trigger = .driftExceeded
        } else if recordsMissingIncident, driftMilliseconds == nil, state?.hadFreshDrift == true {
            trigger = .measurementMissing
        } else {
            trigger = nil
        }
        if let trigger, let number = participantNumbers[participantID] {
            recordings.append(IncidentRecording(participantID: participantID,
                evidence: RoomSyncIncident(participantNumber: number, isLocal: isLocal,
                    trigger: trigger, occurredAt: occurredAt,
                    samples: Array(trace.samples.suffix(Self.incidentLeadingSamples))),
                remainingSamples: Self.incidentFollowingSamples))
            while recordings.count > Self.maximumIncidents {
                // Preserve measured excursions ahead of unknown gaps. Within
                // each kind, keep the newest evidence under the same hard cap.
                let oldestGap = recordings.firstIndex { $0.evidence.trigger == .measurementMissing }
                recordings.remove(at: oldestGap ?? recordings.startIndex)
            }
        }
    }

    private mutating func observeParticipant(
        participantID: String,
        name: String,
        driftMilliseconds: Double?,
        roundTripMilliseconds: Double?,
        latePacketCount: UInt64?,
        resyncCount: UInt64?,
        occurredAt: Date
    ) {
        var state = participantStates[participantID] ?? ParticipantState()
        if let driftMilliseconds {
            let outside = driftMilliseconds >= Self.correctionThresholdMilliseconds
            if outside && !state.wasOutsideTolerance {
                appendEvent(.warning, title: "\(name) moved out of sync",
                            detail: "Measured playback drift reached \(milliseconds(driftMilliseconds)); the correction threshold is 40 ms.",
                            at: occurredAt)
            } else if !outside && state.wasOutsideTolerance
                        && driftMilliseconds <= Self.recoveryThresholdMilliseconds {
                appendEvent(.recovery, title: "\(name) returned to sync",
                            detail: "Measured playback drift recovered to \(milliseconds(driftMilliseconds)).",
                            at: occurredAt)
            }
            if !state.hadFreshDrift, participantStates[participantID] != nil {
                appendEvent(.recovery, title: "\(name) timing report resumed",
                            detail: "Fresh playback measurements are available again.", at: occurredAt)
            }
            state.hadFreshDrift = true
            // Stay in warning through the hysteresis band and missing samples;
            // only a measured recovery at <=20 ms closes this incident.
            if outside { state.wasOutsideTolerance = true }
            else if driftMilliseconds <= Self.recoveryThresholdMilliseconds {
                state.wasOutsideTolerance = false
            }
        } else {
            if state.hadFreshDrift {
                appendEvent(.warning, title: "\(name) timing report paused",
                            detail: "No fresh render-clock measurement arrived in this sample.", at: occurredAt)
            }
            state.hadFreshDrift = false
        }

        if let previous = state.roundTripMilliseconds, let roundTripMilliseconds,
           roundTripMilliseconds >= 80,
           roundTripMilliseconds - previous >= 35 {
            appendEvent(.warning, title: "\(name) network delay rose",
                        detail: "Round-trip time increased from \(milliseconds(previous)) to \(milliseconds(roundTripMilliseconds)).",
                        at: occurredAt)
        }
        state.roundTripMilliseconds = roundTripMilliseconds

        if let previous = state.latePacketCount, let latePacketCount, latePacketCount > previous {
            appendEvent(.warning, title: "\(name) received audio late",
                        detail: countDetail(latePacketCount - previous, singular: "late packet", plural: "late packets"),
                        at: occurredAt)
        }
        state.latePacketCount = latePacketCount

        if let previous = state.resyncCount, let resyncCount, resyncCount > previous {
            appendEvent(.correction, title: "\(name) playback was realigned",
                        detail: countDetail(resyncCount - previous, singular: "resync ran", plural: "resyncs ran"),
                        at: occurredAt)
        }
        state.resyncCount = resyncCount
        participantStates[participantID] = state
    }

    private mutating func observeRoomMetrics(_ timing: SessionTimingDiagnostics, occurredAt: Date) {
        let buffer = timing.host?.groupBufferMilliseconds ?? timing.receiver?.activePlayoutBufferMilliseconds
            ?? timing.receiver?.recommendedBufferMilliseconds
        if let previous = roomState.bufferMilliseconds, let buffer,
           abs(buffer - previous) >= 20 {
            appendEvent(.notice, title: "Channel playback buffer changed",
                        detail: "ALO adjusted the buffer from \(milliseconds(previous)) to \(milliseconds(buffer)).",
                        at: occurredAt)
        }
        roomState.bufferMilliseconds = buffer

        let jitter = timing.receiver?.jitterMilliseconds
        if let previous = roomState.jitterMilliseconds, let jitter,
           jitter >= 20, jitter - previous >= 15 {
            appendEvent(.warning, title: "Network jitter increased",
                        detail: "Packet timing variation rose from \(milliseconds(previous)) to \(milliseconds(jitter)).",
                        at: occurredAt)
        }
        roomState.jitterMilliseconds = jitter

        let output = timing.receiver.map { $0.outputLatencyMilliseconds + $0.renderHeadroomMilliseconds }
        if let previous = roomState.outputPathMilliseconds, let output,
           abs(output - previous) >= 10 {
            appendEvent(.notice, title: "Audio output timing changed",
                        detail: "The reported output path changed from \(milliseconds(previous)) to \(milliseconds(output)).",
                        at: occurredAt)
        }
        roomState.outputPathMilliseconds = output

        let timingChanges = timing.host?.roomTimingChangeCount
        if let previous = roomState.roomTimingChangeCount, let timingChanges, timingChanges > previous {
            appendEvent(.correction, title: "Channel timing was recalculated",
                        detail: countDetail(timingChanges - previous, singular: "timing adjustment ran", plural: "timing adjustments ran"),
                        at: occurredAt)
        }
        roomState.roomTimingChangeCount = timingChanges
    }

    private mutating func appendEvent(_ kind: RoomSyncEvent.Kind, title: String, detail: String, at date: Date) {
        events.append(RoomSyncEvent(id: UUID(), occurredAt: date, kind: kind, title: title, detail: detail))
        if events.count > Self.maximumEvents {
            events.removeFirst(events.count - Self.maximumEvents)
        }
    }

    private func freshFinite(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private func freshReceiverDrift(_ receiver: ReceiverTimingDiagnostics?) -> Double? {
        guard let receiver, let age = receiver.driftMeasurementAgeMilliseconds,
              age.isFinite, (0...500).contains(age) else { return nil }
        return freshFinite(receiver.currentDriftMilliseconds)
    }

    private func freshListenerDrift(_ listener: HostListenerTimingDiagnostics) -> Double? {
        guard let driftAge = listener.driftSampleAgeMilliseconds,
              let reportAge = listener.playbackReportAgeMilliseconds,
              driftAge.isFinite, (0...500).contains(driftAge),
              reportAge.isFinite, (0...2_500).contains(reportAge) else { return nil }
        return freshFinite(listener.driftMilliseconds)
    }

    private func milliseconds(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f ms", value) : String(format: "%.0f ms", value)
    }

    private func countDetail(_ count: UInt64, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural) since the previous sample."
    }
}
