import AppKit
import Foundation
import Testing
import ALOCore
import ALONetworking
@testable import ALO

@MainActor @Suite(.serialized) struct SecureRoomSelectionTests {
    @Test func transportReadinessDoesNotClaimAudiblePlayback() {
        #expect(ALOViewModel.renderingState(for: "Media transport ready") == nil)
        #expect(ALOViewModel.renderingState(for: "Listening in sync") == true)
        #expect(ALOViewModel.renderingState(for: "Connected · waiting for audio") == false)
        #expect(ALOViewModel.renderingState(for: "Recovering channel audio") == false)
        #expect(ALOViewModel.renderingState(for: "Synchronizing channel audio") == false)
    }
    @Test func discoveredSecureChannelDoesNotGrantMembership() {
        _ = NSApplication.shared
        let model = ALOViewModel(discoverRooms: false)
        let id = UUID().uuidString
        let icon = RoomIcon(symbol: "film.fill", version: .init(counter: 2, nodeID: UUID().uuidString))
        model.nearbyRooms = [NearbyRoom(id: id, name: "Secure room", isPrivate: false,
            peerCount: 2, accessProof: nil, transportPolicy: .secureV2, icon: icon)]
        model.selectedRoomID = id
        #expect(model.selectedRoomConfiguration == nil)
        #expect(model.roomChoices.first { $0.id == id } == nil)
        #expect(model.phase == .idle)
    }

    @Test func oldNearbyRoomDoesNotSilentlyMigrate() {
        _ = NSApplication.shared
        let model = ALOViewModel(discoverRooms: false)
        let id = UUID().uuidString
        model.nearbyRooms = [NearbyRoom(id: id, name: "Existing room", isPrivate: false,
            peerCount: 1, accessProof: nil, transportPolicy: .legacyOnly)]
        model.selectedRoomID = id
        #expect(model.selectedRoomConfiguration == nil)
        #expect(model.roomChoices.first { $0.id == id } == nil)
    }
}
