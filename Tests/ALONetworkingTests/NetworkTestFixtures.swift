import Foundation
import ALOCore
import ALOIdentity
import ALORooms
@testable import ALONetworking

/// Each independently generated test room gets one ephemeral user root. Nodes retain this fixture;
/// the weak registry only lets existing mesh/media helper call sites share that per-test root.
/// Every installation still has its own real TLS key, binding, and disposable policy repository.
final class NetworkTestRoomFixture: @unchecked Sendable {
    private final class Weak {
        weak var value: NetworkTestRoomFixture?
        init(_ value: NetworkTestRoomFixture) { self.value = value }
    }
    private static let lock = NSLock()
    private static var fixtures: [String: Weak] = [:]
    let owner: UserIdentity
    let manifest: NetworkManifest
    let channelID: UUID
    let directory: URL

    static func shared(for room: RoomConfiguration) throws -> NetworkTestRoomFixture {
        try lock.withLock {
            if let existing = fixtures[room.id]?.value { return existing }
            let fixture = try NetworkTestRoomFixture(room: room)
            fixtures = fixtures.filter { $0.value.value != nil }
            fixtures[room.id] = Weak(fixture)
            return fixture
        }
    }

    private init(room: RoomConfiguration) throws {
        guard let channelID = UUID(uuidString: room.id) else { throw NetworkAuthorityError.invalidIdentifier }
        self.channelID = channelID
        owner = .ephemeral()
        let base = try NetworkManifest.create(name: "Test Network", owner: owner)
        let channel = try ALORooms.NetworkChannel(id: channelID, name: "Test Channel",
            visibility: room.isPrivate ? .privateMembers : .publicToMembers)
        manifest = try base.addingChannel(channel, signedBy: owner)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alo-network-test-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func authorization(for identity: InstallationIdentity) throws -> NetworkChannelAuthorization {
        let repository = NetworkRepository(directoryURL: directory.appendingPathComponent(identity.publicIdentity.nodeID.uuidString))
        try repository.accept(manifest, for: owner.publicIdentity)
        let policy = try NetworkPolicyCenter(repository: repository, networkID: manifest.id)
        let device = try DeviceIdentityBinding(user: owner, deviceName: "Test installation", generation: 1,
                                              installationPublicKeyHash: identity.publicIdentity.publicKeyHash)
        return try NetworkChannelAuthorization(policy: policy, channelID: channelID, localDevice: device)
    }
}
