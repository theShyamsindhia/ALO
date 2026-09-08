import Foundation
import Testing
import ALONetworking
@testable import ALOAppModel

struct DeviceMessagingControllerStateTests {
    private let digest = Data(repeating: 3, count: 32)
    private func ready() throws -> (DeviceMessagingControllerState, UUID, UUID) {
        var state = DeviceMessagingControllerState()
        let construction = state.beginEnable()
        let evaluated1 = state.finishConstruction(construction, succeeded: true)
        #expect(evaluated1)
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
        let evaluated2 = !state.finishConstruction(old, succeeded: true)
        #expect(evaluated2)
        #expect(state.phase == .disabled)
        let fresh = state.beginEnable(); let evaluated3 = state.finishConstruction(fresh, succeeded: true)
        #expect(evaluated3)
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
        let evaluated4 = !state.finish(effect.ticket, result: .statusUnknown)
        #expect(evaluated4)
        #expect(state.isCurrent(effect.ticket))
        let evaluated5 = try state.admit(request) == nil
        #expect(evaluated5)
        let evaluated6 = state.finish(effect.ticket, result: .receipt(.received))
        #expect(evaluated6)
        let evaluated7 = !state.finish(effect.ticket, result: .receipt(.codexQueued))
        #expect(evaluated7)
        let query = try LocalDeviceMessageProtocol.Request(operation: .receipt, registration: registration, messageID: message)
        let check = try #require(try state.admit(query))
        #expect(check.destination == destination && check.destination == effect.destination)
        #expect(check.request.text == nil && check.request.destination == nil && check.request.taskID == nil)
        let evaluated8 = state.finish(check.ticket, result: .statusUnknown)
        #expect(evaluated8)
        let snapshot = try #require(state.snapshot(registration: registration, messageID: message))
        #expect(snapshot.status == .authenticatedReceipt && snapshot.query == .statusUnknown)
        let evaluated9 = try state.admit(request) == nil
        #expect(evaluated9)
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
        let evaluated10 = state.finish(effect.ticket, result: .receipt(.codexQueued))
        #expect(evaluated10)
        let query = try #require(try state.admit(.init(operation: .receipt, registration: registration, messageID: request.messageID)))
        let evaluated11 = !state.finish(query.ticket, result: .receipt(.received))
        #expect(evaluated11)
        #expect(state.snapshot(registration: registration, messageID: request.messageID!)?.status == .codexQueued)
        let evaluated12 = state.finish(query.ticket, result: .unavailable)
        #expect(evaluated12)
        try state.retirePresentation(registration: registration, messageID: request.messageID!)
        #expect(state.snapshot(registration: registration, messageID: request.messageID!) == nil)
    }
    @Test func liveObservationOutlivesInitialWorkAndCannotReviveRetiredRecord() throws {
        var (state, registration, destination) = try ready()
        let message = UUID()
        let request = try LocalDeviceMessageProtocol.Request(operation: .send, registration: registration, destination: destination, messageID: message, text: "live")
        let effect = try #require(try state.admit(request))
        let evaluated13 = state.finish(effect.ticket, result: .receipt(.received))
        #expect(evaluated13)
        #expect(state.pendingCount == 0)
        let evaluated14 = state.observe(effect.observation, receipt: .dispatching)
        #expect(evaluated14)
        let evaluated15 = state.observe(effect.observation, receipt: .codexQueued)
        #expect(evaluated15)
        let evaluated16 = !state.observe(effect.observation, receipt: .received)
        #expect(evaluated16)
        let evaluated17 = state.observe(effect.observation, receipt: .delivered)
        #expect(evaluated17)
        #expect(state.snapshot(registration: registration, messageID: message)?.status == .deliveredConfirmed)
        let evaluated18 = try state.pendingCount == 0 && (state.admit(request)) == nil
        #expect(evaluated18)
        try state.retirePresentation(registration: registration, messageID: message)
        let replacement = try #require(try state.admit(request))
        #expect(replacement.observation != effect.observation)
        let evaluated19 = !state.observe(effect.observation, receipt: .delivered)
        #expect(evaluated19)
        #expect(state.snapshot(registration: registration, messageID: message)?.status == .pending)
        state.invalidate()
        let evaluated20 = !state.observe(replacement.observation, receipt: .codexQueued)
        #expect(evaluated20)
    }
    @Test func liveTerminalDoesNotConsumePendingQueryOwnership() throws {
        var (state, registration, destination) = try ready()
        let message = UUID()
        let effect = try #require(try state.admit(.init(operation: .send, registration: registration, destination: destination, messageID: message, text: "race")))
        let evaluated21 = state.finish(effect.ticket, result: .receipt(.received))
        #expect(evaluated21)
        let query = try #require(try state.admit(.init(operation: .receipt, registration: registration, messageID: message)))
        #expect(query.observation == effect.observation)
        let evaluated22 = state.observe(effect.observation, receipt: .codexQueued)
        #expect(evaluated22)
        #expect(state.pendingCount == 1 && state.isCurrent(query.ticket))
        let evaluated23 = state.finish(query.ticket, result: .unavailable)
        #expect(evaluated23)
        #expect(state.snapshot(registration: registration, messageID: message)?.status == .codexQueued)
        let evaluated24 = state.observe(effect.observation, receipt: .delivered)
        #expect(evaluated24)
        state.forgetAfterLocalGrantRevocation(registration)
        let evaluated25 = !state.observe(effect.observation, receipt: .delivered)
        #expect(evaluated25)
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
        let evaluated26 = state.finish(first.ticket, result: .unavailable)
        #expect(evaluated26)
        let evaluated27 = !state.finish(first.ticket, result: .unavailable)
        #expect(evaluated27)
        #expect(state.pendingCount == 31)
        state.invalidate()
        #expect(state.pendingCount == 0 && state.phase == .disabled)
        let evaluated28 = !state.finish(effects[1].ticket, result: .receipt(.codexQueued))
        #expect(evaluated28)
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
        let evaluated29 = !state.finish(effect.ticket, result: .receipt(.received))
        #expect(evaluated29)
        #expect(state.pendingCount == 0)
    }
}
