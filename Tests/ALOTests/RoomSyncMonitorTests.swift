import Foundation
import Testing
import ALOCore
@testable import ALO

@Suite("Room synchronization monitor")
struct RoomSyncMonitorTests {
    @Test("Incident export keeps anonymous pre-failure and recovery evidence after graph rolls over")
    func incidentEvidenceSurvivesRecovery() {
        var monitor = RoomSyncMonitor()
        let participant = RoomParticipant(id: "secret-peer-id", name: "Private Mac Name")
        for index in 0..<130 {
            let drift: Double? = index == 4 ? 70 : (index == 5 ? nil : 10)
            monitor.observe(participants: [participant], currentParticipantID: participant.id,
                timing: timing(localDrift: drift, localRTT: 2, buffer: 250, jitter: 1,
                    output: 20, localLate: 0, localResync: 0,
                    peerID: nil, peerDrift: nil, peerLate: 0, peerResync: 0, roomTimingChanges: 0),
                sampledAtNanos: UInt64(index + 1) * 1_000_000_000,
                occurredAt: Date(timeIntervalSince1970: Double(index)))
        }
        let evidence = monitor.incidents
        #expect(evidence.count == 2)
        #expect(evidence[0].samples.first?.driftMilliseconds == 10)
        #expect(evidence[0].samples.contains { $0.driftMilliseconds == 70 } == true)
        #expect(evidence[0].samples.contains { $0.driftMilliseconds == nil } == true)
        #expect(evidence[0].samples.last?.driftMilliseconds == 10)
        #expect(evidence[0].samples.count <= 45)
        let room = DiagnosticRoomContext(isActive: false, role: .none, participantCount: 0,
            remotePeerCount: 0, syncLabel: "Disconnected", audioIsRendering: false,
            hasBroadcaster: false, timing: nil)
        let context = DiagnosticReportContext(generatedAt: Date(), appVersion: "test", appBuild: "test",
            operatingSystem: "macOS", architecture: "arm64", room: room,
            microphoneSelection: "system default", syncIncidents: evidence)
        let report = DiagnosticReportBuilder.build(context: context, results: [:])
        #expect(report.contains("1970-01-01T00:00:04Z"))
        #expect(report.contains("drift-ms=70.0"))
        #expect(report.contains("drift-ms=unavailable"))
        #expect(!report.contains(participant.id))
        #expect(!report.contains(participant.name))
        #expect(report.contains("acoustic"))
    }

    @Test("Recovery survives intermediate drift and missing measurements")
    func recoveryHysteresis() {
        for values: [Double?] in [[70, 30, 10], [70, nil, 30, 10]] {
            var monitor = RoomSyncMonitor()
            for (index, drift) in values.enumerated() {
                monitor.observe(participants: [RoomParticipant(id: "local", name: "Private Mac")],
                    currentParticipantID: "local",
                    timing: timing(localDrift: drift, localRTT: 2, buffer: 250, jitter: 1,
                        output: 20, localLate: 0, localResync: 0,
                        peerID: nil, peerDrift: nil, peerLate: 0, peerResync: 0, roomTimingChanges: 0),
                    sampledAtNanos: UInt64(index + 1) * 1_000_000_000)
            }
            #expect(monitor.events.filter { $0.title == "You returned to sync" }.count == 1)
            #expect(monitor.events.filter { $0.title == "You moved out of sync" }.count == 1)
        }
    }

    @Test("Participant churn and repeated failures stay bounded, and new sessions clear evidence")
    func boundedIncidentsAndParticipants() {
        var monitor = RoomSyncMonitor()
        for index in 0..<80 {
            let participant = RoomParticipant(id: "peer-\(index)", name: "Private name \(index)")
            monitor.observe(participants: [participant], currentParticipantID: participant.id,
                timing: timing(localDrift: 70, localRTT: 2, buffer: 250, jitter: 1,
                    output: 20, localLate: 0, localResync: 0,
                    peerID: nil, peerDrift: nil, peerLate: 0, peerResync: 0, roomTimingChanges: 0),
                sampledAtNanos: UInt64(index + 1) * 1_000_000_000)
        }
        #expect(monitor.traces.count == RoomSyncMonitor.maximumParticipants)
        #expect(monitor.incidents.count == RoomSyncMonitor.maximumIncidents)
        #expect(Set(monitor.incidents.map(\.participantNumber)).count == RoomSyncMonitor.maximumIncidents)
        #expect(monitor.events.count <= RoomSyncMonitor.maximumEvents)
        monitor.reset()
        #expect(monitor.traces.isEmpty)
        #expect(monitor.incidents.isEmpty)
    }

    @Test("Explicit interruption records a missing sample without inventing recovery")
    func explicitInterruptionEvidence() {
        var monitor = RoomSyncMonitor()
        let participants = [RoomParticipant(id: "local", name: "Private Mac")]
        monitor.observe(participants: participants, currentParticipantID: "local",
            timing: timing(localDrift: 70, localRTT: 2, buffer: 250, jitter: 1,
                output: 20, localLate: 0, localResync: 0,
                peerID: nil, peerDrift: nil, peerLate: 0, peerResync: 0, roomTimingChanges: 0),
            sampledAtNanos: 1_000_000_000, occurredAt: Date(timeIntervalSince1970: 1))
        for second in 2...3 {
            monitor.markUnavailable(participants: participants, currentParticipantID: "local",
                sampledAtNanos: UInt64(second) * 1_000_000_000,
                reason: "private interruption text", occurredAt: Date(timeIntervalSince1970: Double(second)))
        }
        #expect(monitor.incidents.count == 2)
        #expect(monitor.incidents[0].samples.count == 2)
        #expect(monitor.incidents[0].samples.last?.driftMilliseconds == nil)
        #expect(!monitor.events.contains { $0.title == "You returned to sync" })
    }

    @Test("Records every participant and explains measured timing changes")
    func recordsTracesAndObservedEvents() {
        var monitor = RoomSyncMonitor()
        let localID = "local"
        let peerID = "peer"
        var participants = [
            RoomParticipant(id: localID, name: "Local Mac"),
            RoomParticipant(id: peerID, name: "Living Room")
        ]
        participants[1].playbackTiming = PeerPlaybackTiming(roundTripMilliseconds: 12, driftMilliseconds: 8)

        monitor.observe(participants: participants, currentParticipantID: localID,
                        timing: timing(localDrift: 5, localRTT: 4, buffer: 250, jitter: 2,
                                       output: 20, localLate: 0, localResync: 0,
                                       peerID: peerID, peerDrift: 8, peerLate: 0, peerResync: 0,
                                       roomTimingChanges: 0),
                        sampledAtNanos: 1_000_000_000,
                        occurredAt: Date(timeIntervalSince1970: 1))
        #expect(monitor.orderedTraces.map(\.name) == ["You", "Living Room"])
        #expect(monitor.orderedTraces.allSatisfy { $0.samples.count == 1 })
        #expect(monitor.events.map(\.title) == ["Live timing monitor started"])

        participants[1].playbackTiming = PeerPlaybackTiming(roundTripMilliseconds: 110, driftMilliseconds: 90)
        monitor.observe(participants: participants, currentParticipantID: localID,
                        timing: timing(localDrift: 70, localRTT: 100, buffer: 320, jitter: 35,
                                       output: 55, localLate: 2, localResync: 1,
                                       peerID: peerID, peerDrift: 90, peerLate: 3, peerResync: 1,
                                       roomTimingChanges: 1),
                        sampledAtNanos: 2_000_000_000,
                        occurredAt: Date(timeIntervalSince1970: 2))
        let titles = monitor.events.map(\.title)
        #expect(titles.contains("You moved out of sync"))
        #expect(titles.contains("Living Room moved out of sync"))
        #expect(titles.contains("You received audio late"))
        #expect(titles.contains("Living Room playback was realigned"))
        #expect(titles.contains("Channel playback buffer changed"))
        #expect(titles.contains("Network jitter increased"))
        #expect(titles.contains("Audio output timing changed"))
        #expect(titles.contains("Channel timing was recalculated"))

        participants[1].playbackTiming = PeerPlaybackTiming(roundTripMilliseconds: 12, driftMilliseconds: 9)
        monitor.observe(participants: participants, currentParticipantID: localID,
                        timing: timing(localDrift: 7, localRTT: 4, buffer: 320, jitter: 4,
                                       output: 55, localLate: 2, localResync: 1,
                                       peerID: peerID, peerDrift: 9, peerLate: 3, peerResync: 1,
                                       roomTimingChanges: 1),
                        sampledAtNanos: 3_000_000_000,
                        occurredAt: Date(timeIntervalSince1970: 3))
        #expect(monitor.events.map(\.title).contains("You returned to sync"))
        #expect(monitor.events.map(\.title).contains("Living Room returned to sync"))
    }

    @Test("Keeps graph memory bounded and represents unavailable timing as gaps")
    func boundedHistoryAndMissingSamples() {
        var monitor = RoomSyncMonitor()
        let participant = RoomParticipant(id: "local", name: "Mac")
        for index in 0..<(RoomSyncMonitor.maximumSamplesPerParticipant + 12) {
            let drift: Double? = index == RoomSyncMonitor.maximumSamplesPerParticipant ? nil : Double(index % 10)
            monitor.observe(participants: [participant], currentParticipantID: "local",
                            timing: timing(localDrift: drift, localRTT: 2, buffer: 250, jitter: 1,
                                           output: 20, localLate: 0, localResync: 0,
                                           peerID: nil, peerDrift: nil, peerLate: 0, peerResync: 0,
                                           roomTimingChanges: 0),
                            sampledAtNanos: UInt64(index + 1) * 1_000_000_000)
        }
        let trace = monitor.orderedTraces[0]
        #expect(trace.samples.count == RoomSyncMonitor.maximumSamplesPerParticipant)
        #expect(trace.samples.contains { $0.driftMilliseconds == nil })
        #expect(monitor.events.count <= RoomSyncMonitor.maximumEvents)
        #expect(monitor.events.map(\.title).contains("You timing report paused"))
        #expect(monitor.events.map(\.title).contains("You timing report resumed"))
    }

    private func timing(
        localDrift: Double?, localRTT: Double?, buffer: Double, jitter: Double,
        output: Double, localLate: UInt64, localResync: UInt64,
        peerID: String?, peerDrift: Double?, peerLate: UInt64, peerResync: UInt64,
        roomTimingChanges: UInt64
    ) -> SessionTimingDiagnostics {
        var receiver = ReceiverTimingDiagnostics(
            roundTripMilliseconds: localRTT, clockOffsetMilliseconds: 0,
            jitterMilliseconds: jitter, recommendedBufferMilliseconds: buffer,
            outputLatencyMilliseconds: output - 5, renderHeadroomMilliseconds: 5,
            outputSampleRate: 48_000, outputChannelCount: 2,
            latenessMilliseconds: localDrift ?? 0, latePacketCount: localLate,
            resyncCount: localResync, currentDriftMilliseconds: localDrift,
            driftMeasurementAgeMilliseconds: localDrift == nil ? nil : 10)
        receiver.activePlayoutBufferMilliseconds = buffer
        let listeners = peerID.map { id in
            [HostListenerTimingDiagnostics(peerID: id, isTimingEligible: true,
                reportAgeMilliseconds: 10, recommendedBufferMilliseconds: buffer,
                hardwareFloorMilliseconds: 20, driftMilliseconds: peerDrift,
                driftSampleAgeMilliseconds: peerDrift == nil ? nil : 10,
                playbackReportAgeMilliseconds: 10, latenessMilliseconds: peerDrift ?? 0,
                latePacketCount: peerLate, resyncCount: peerResync)]
        } ?? []
        let host = HostTimingDiagnostics(listenerCount: listeners.count,
            reportingListenerCount: listeners.count, groupBufferMilliseconds: buffer,
            maximumLatenessMilliseconds: peerDrift ?? 0,
            totalResyncCount: peerResync, roomTimingChangeCount: roomTimingChanges,
            listeners: listeners)
        return SessionTimingDiagnostics(receiver: receiver, host: host)
    }
}
