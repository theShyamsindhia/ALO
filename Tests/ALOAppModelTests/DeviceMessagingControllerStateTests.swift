import Foundation
import Testing
import ALONetworking
@testable import ALOAppModel

struct DeviceMessagingControllerStateTests {
    private let digest = Data(repeating: 3, count: 32)
    private func ready() throws -> (DeviceMessagingControllerState, UUID, UUID) {
        var state = DeviceMessagingControllerState()
        let construction = state.beginEnable()
        #expect(state.finishConstruction(construction, succeeded: true))
        let registration = try state.register(taskID: UUID(), title: "Own task")
        let challenge = try state.beginCapabilityTest(registration: registration, approvedDigest: digest, now: 100)
        try state.confirmCapability(challenge, response: challenge.nonce, approvedDigest: digest, now: 101)
        let destination = try state.bindAuthenticatedDestination(registration: registration, approvedDigest: digest)
        return (state, registration, destination)
    }
    @Test func registrationCannotEnableOrGrantAndStaleConstructionCannotPublish() throws {
        var state = DeviceMessagingControllerState()
        #expect(throws: (any Error).self) { try state.register(taskID: UUID(), title: "Off") }
        let old = state.beginEnable(); state.invalidate()
        #expect(!state.finishConstruction(old, succeeded: true))
        #expect(state.phase == .disabled)
        let fresh = state.beginEnable(); #expect(state.finishConstruction(fresh, succeeded: true))
        let registration = try state.register(taskID: UUID(), title: "Pending")
        #expect(state.registrations.first?.state == .pendingApproval)
        #expect(throws: (any Error).self) { try state.bindAuthenticatedDestination(registration: registration, approvedDigest: digest) }
    }
    @Test func admissionIsPendingAndQueriesNeverEraseReceiptOrResend() throws {
        var (state, registration, destination) = try ready()
        let message = UUID()
        let request = try LocalDeviceMessageProtocol.Request(operation: .send, registration: registration, destination: destination, messageID: message, text: "hello")
        let effect = try #require(try state.admit(request))
        #expect(state.snapshot(registration: registration, messageID: message)?.status == .pending)
        #expect(!state.finish(effect.ticket, result: .statusUnknown))
        #expect(state.isCurrent(effect.ticket))
        #expect(try state.admit(request) == nil)
        #expect(state.finish(effect.ticket, result: .receipt(.received)))
        #expect(!state.finish(effect.ticket, result: .receipt(.codexQueued)))
        let query = try LocalDeviceMessageProtocol.Request(operation: .receipt, registration: registration, messageID: message)
        let check = try #require(try state.admit(query))
        #expect(check.destination == destination && check.destination == effect.destination)
        #expect(check.request.text == nil && check.request.destination == nil && check.request.taskID == nil)
        #expect(state.finish(check.ticket, result: .statusUnknown))
        let snapshot = try #require(state.snapshot(registration: registration, messageID: message))
        #expect(snapshot.status == .authenticatedReceipt && snapshot.query == .statusUnknown)
        #expect(try state.admit(request) == nil)
    }
    @Test func unknownLocalReceiptCannotGuessOrProbeAPeer() throws {
        var (state, registration, _) = try ready()
        #expect(throws: DeviceMessagingControllerState.Failure.unknownLocalMessage) {
            try state.admit(.init(operation: .receipt, registration: registration, messageID: UUID()))
        }
        #expect(state.pendingCount == 0)
    }
    @Test func explicitRetirementRecoversPresentationCapacityWithoutClaimingDurableDeletion() throws {
        var (state, registration, destination) = try ready()
        let request = try LocalDeviceMessageProtocol.Request(operation: .send, registration: registration, destination: destination, messageID: UUID(), text: "one")
        let effect = try #require(try state.admit(request))
        #expect(throws: DeviceMessagingControllerState.Failure.unavailable) {
            try state.retirePresentation(registration: registration, messageID: request.messageID!)
        }
        #expect(state.finish(effect.ticket, result: .receipt(.codexQueued)))
        let query = try #require(try state.admit(.init(operation: .receipt, registration: registration, messageID: request.messageID)))
        #expect(!state.finish(query.ticket, result: .receipt(.received)))
        #expect(state.snapshot(registration: registration, messageID: request.messageID!)?.status == .codexQueued)
        #expect(state.finish(query.ticket, result: .unavailable))
        try state.retirePresentation(registration: registration, messageID: request.messageID!)
        #expect(state.snapshot(registration: registration, messageID: request.messageID!) == nil)
    }
    @Test func liveObservationOutlivesInitialWorkAndCannotReviveRetiredRecord() throws {
        var (state, registration, destination) = try ready()
        let message = UUID()
        let request = try LocalDeviceMessageProtocol.Request(operation: .send, registration: registration, destination: destination, messageID: message, text: "live")
        let effect = try #require(try state.admit(request))
        #expect(state.finish(effect.ticket, result: .receipt(.received)))
        #expect(state.pendingCount == 0)
        #expect(state.observe(effect.observation, receipt: .dispatching))
        #expect(state.observe(effect.observation, receipt: .codexQueued))
        #expect(!state.observe(effect.observation, receipt: .received))
        #expect(state.observe(effect.observation, receipt: .delivered))
        #expect(state.snapshot(registration: registration, messageID: message)?.status == .deliveredConfirmed)
        #expect(state.pendingCount == 0 && (try state.admit(request)) == nil)
        try state.retirePresentation(registration: registration, messageID: message)
        let replacement = try #require(try state.admit(request))
        #expect(replacement.observation != effect.observation)
        #expect(!state.observe(effect.observation, receipt: .delivered))
        #expect(state.snapshot(registration: registration, messageID: message)?.status == .pending)
        state.invalidate()
        #expect(!state.observe(replacement.observation, receipt: .codexQueued))
    }
    @Test func liveTerminalDoesNotConsumePendingQueryOwnership() throws {
        var (state, registration, destination) = try ready()
        let message = UUID()
        let effect = try #require(try state.admit(.init(operation: .send, registration: registration, destination: destination, messageID: message, text: "race")))
        #expect(state.finish(effect.ticket, result: .receipt(.received)))
        let query = try #require(try state.admit(.init(operation: .receipt, registration: registration, messageID: message)))
        #expect(query.observation == effect.observation)
        #expect(state.observe(effect.observation, receipt: .codexQueued))
        #expect(state.pendingCount == 1 && state.isCurrent(query.ticket))
        #expect(state.finish(query.ticket, result: .unavailable))
        #expect(state.snapshot(registration: registration, messageID: message)?.status == .codexQueued)
        #expect(state.observe(effect.observation, receipt: .delivered))
        state.forgetAfterLocalGrantRevocation(registration)
        #expect(!state.observe(effect.observation, receipt: .delivered))
    }
    @Test func recordsBoundedAndInvalidationRejectsHeldResults() throws {
        var (state, registration, destination) = try ready()
        var effects: [DeviceMessagingControllerState.Effect] = []
        for _ in 0..<32 {
            let request = try LocalDeviceMessageProtocol.Request(operation: .send, registration: registration, destination: destination, messageID: UUID(), text: "bounded")
            effects.append(try #require(try state.admit(request)))
        }
        #expect(state.pendingCount == 32)
        #expect(throws: DeviceMessagingControllerState.Failure.capacity) {
            try state.admit(.init(operation: .send, registration: registration, destination: destination, messageID: UUID(), text: "full"))
        }
        let first = effects[0]
        #expect(state.finish(first.ticket, result: .unavailable))
        #expect(!state.finish(first.ticket, result: .unavailable))
        #expect(state.pendingCount == 31)
        state.invalidate()
        #expect(state.pendingCount == 0 && state.phase == .disabled)
        #expect(!state.finish(effects[1].ticket, result: .receipt(.codexQueued)))
    }
    @Test func forgetRequiresGrantRevocationAcknowledgementAndOldResultsStayStale() throws {
        var (state, registration, destination) = try ready()
        let task = try #require(state.registrations.first?.taskID)
        let request = try LocalDeviceMessageProtocol.Request(operation: .send, registration: registration, destination: destination, messageID: UUID(), text: "held")
        let effect = try #require(try state.admit(request))
        state.forgetAfterLocalGrantRevocation(registration)
        let replacement = try state.register(taskID: task, title: "Again")
        #expect(replacement != registration)
        #expect(state.registrations.first?.state == .pendingApproval)
        #expect(!state.finish(effect.ticket, result: .receipt(.received)))
        #expect(state.pendingCount == 0)
    }
}
