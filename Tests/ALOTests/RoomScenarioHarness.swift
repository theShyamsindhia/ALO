import Foundation
import Network
import Testing
@testable import ALO
@testable import ALOCore

/// Real mesh instances, each with its own disk store. No Bonjour advertising,
/// microphone capture, system-audio capture, or production preferences.
final class ScenarioMeshDevice {
    let id: String
    let room: RoomConfiguration
    let store: RoomStore
    let observation = ScenarioObservation()
    private(set) var control: MeshControlPlane!
    private var stopped = false

    init(id: String, room: RoomConfiguration, directory: URL) throws {
        self.id = id
        self.room = room
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = RoomStore(fileURL: directory.appendingPathComponent("rooms.json"))
        let observation = self.observation
        let store = self.store
        control = MeshControlPlane(
            room: room, nodeID: id, displayName: id, appVersion: "0.13.41",
            initialEvents: store.loadEvents(roomID: room.id),
            initialRoomStateDocument: store.loadRoomStateDocument(roomID: room.id),
            listenerReadyHandler: { port in observation.update { $0.port = port } },
            replicaHandler: { replica in
                store.saveEvents(replica.events, roomID: room.id)
                observation.update { $0.replica = replica }
            },
            participantsHandler: { participants in
                observation.update { $0.participants = Set(participants.map(\.id)) }
            },
            walkieTalkieHandler: { message in
                observation.update { $0.voice.append(message) }
            },
            roomStatePersistenceHandler: { store.saveRoomStateDocument($0, roomID: room.id) },
            roomStateDowngradeHandler: { _ in observation.update { $0.downgrades += 1 } }
        )
        do {
            try control.start(advertise: false)
            try scenarioEventually("\(id) listener ready") { observation.read { $0.port != nil } }
        } catch {
            try? stop()
            throw error
        }
    }

    func connect(to other: ScenarioMeshDevice) throws {
        precondition(id < other.id, "Match the production canonical connection direction")
        let port = try #require(other.observation.read { $0.port })
        control.connectForTesting(to: .hostPort(host: "127.0.0.1", port: port))
    }

    func stop() throws {
        guard !stopped else { return }
        stopped = true
        let done = DispatchSemaphore(value: 0)
        control.stop { done.signal() }
        try #require(done.wait(timeout: .now() + 5) == .success, "\(id) stop flush timed out")
        // Barrier behind the asynchronously scheduled disk write.
        _ = store.loadRoomStateDocument(roomID: room.id)
    }

    func persistedChat() throws -> Set<String> {
        let data = try #require(store.loadRoomStateDocument(roomID: room.id))
        let state = try AutomergeRoomStateSync(roomID: room.id, savedDocument: data)
        return Set(try state.snapshot().chatEvents.compactMap(\.text))
    }
}

final class ScenarioObservation: @unchecked Sendable {
    struct State {
        var port: NWEndpoint.Port?
        var replica = MeshRoomReplica()
        var participants = Set<String>()
        var voice = [WalkieTalkieMessage]()
        var downgrades = 0
    }
    private let lock = NSLock()
    private var state = State()
    func update(_ body: (inout State) -> Void) { lock.withLock { body(&state) } }
    func read<T>(_ body: (State) -> T) -> T { lock.withLock { body(state) } }
}

func scenarioEventually(
    _ stage: String,
    timeout: TimeInterval = 5,
    condition: () throws -> Bool
) throws {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    repeat {
        if try condition() { return }
        Thread.sleep(forTimeInterval: 0.01)
    } while ProcessInfo.processInfo.systemUptime < deadline
    try #require(try condition(), "Scenario failed at: \(stage)")
}
