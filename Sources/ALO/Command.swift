import Foundation
import ALOCore
import ALONetworking
import ALOAppModel

struct ALOError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

@main
enum ALOCommand {
    static func main() async {
        do {
            #if DEBUG
            if Bundle.main.object(forInfoDictionaryKey: "ALORoomPreview") as? Bool == true {
                RoomPresentationPreview.run(); return
            }
            #endif
            if Bundle.main.object(forInfoDictionaryKey: "ALOActivityPreview") as? Bool == true {
                ArenaStandalone.run(); return
            }
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let command = arguments.first, !command.hasPrefix("-psn") else {
                GUIApplication.run()
                return
            }

            switch command {
            case "verify-network-configuration":
                try RoomDiscovery.validateApplicationConfiguration(Bundle.main.infoDictionary ?? [:])
                print("Secure Bonjour and local-network declarations verified.")
            case "verify-secure-identity":
                try InstallationIdentity.verifyKeychainAccess()
                print("Secure channel identity and peer-pin persistence verified.")
            case "verify-game-resources":
                try BreachScene.verifyPackagedResources()

            case "breach":
                BreachStandalone.run()

            case "arena":
                ArenaStandalone.run()

            case "stick-fight":
                ArenaStandalone.run(stickFight: true)

            case "host":
                throw ALOError("Legacy host discovery is disabled. Set up an identity in ALO, then use 'alo channel <channel-id> --broadcast'.")

            case "join":
                throw ALOError("Legacy join-by-name is disabled. Join a network in ALO, then use 'alo channel <channel-id>'.")

            case "channel":
                let roomArguments = Array(arguments.dropFirst())
                let flags = roomArguments.filter { $0.hasPrefix("--") }
                let roomNames = roomArguments.filter { !$0.hasPrefix("--") }
                let supportedFlags = Set(["--broadcast", "--take-over"])
                guard flags.allSatisfy(supportedFlags.contains) else {
                    throw ALOError("Unknown channel option. Run 'alo help'.")
                }
                guard roomNames.count <= 1 else {
                    throw ALOError("Pass at most one saved channel ID or name.")
                }
                guard !(flags.contains("--broadcast") && flags.contains("--take-over")) else {
                    throw ALOError("Choose either --broadcast or --take-over, not both.")
                }
                let roomIDOrName = roomNames.first
                try await runSavedRoom(
                    roomIDOrName,
                    broadcastInitially: roomArguments.contains("--broadcast"),
                    takeOverAfterJoining: roomArguments.contains("--take-over")
                )

            case "help", "--help", "-h":
                printHelp()

            default:
                throw ALOError("Unknown command \"\(command)\". Run 'alo help'.")
            }
        } catch {
            fputs("alo: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runHost(roomName: String) async throws {
        let host = HostServer(roomName: roomName)
        try host.start()

        let localReceiver = try Receiver(
            requestedRoom: roomName,
            capturesSystemMediaCommands: false
        )
        try localReceiver.start()
        localReceiver.setLocalPlaybackMuted(true)

        let capture = SystemAudioCapture()
        do {
            try await capture.start { samples, captureTimeNanos in
                host.acceptAudio(samples: samples, captureTimeNanos: captureTimeNanos)
            }
        } catch {
            throw ALOError(
                "System-audio capture could not start. Allow Screen & System Audio Recording "
                + "for Terminal in System Settings → Privacy & Security, then run the command again. "
                + "Details: \(error.localizedDescription)"
            )
        }

        print("Streaming system audio; this Mac keeps using the source application's local playback.")
        print("Keep this process running; press Control-C to stop.")
        await stayAlive(
            capturing: capture,
            hosting: host,
            localReceiver: localReceiver
        )
    }

    private static func runReceiver(roomName: String?) throws {
        let receiver = try Receiver(requestedRoom: roomName)
        try receiver.start()
        dispatchMain()
    }

    /// Opens the same saved mesh room and receiver stack as the GUI without
    /// requiring UI automation. This is useful for repeatable multi-Mac QA.
    @MainActor
    private static func runSavedRoom(
        _ roomIDOrName: String?,
        broadcastInitially: Bool,
        takeOverAfterJoining: Bool
    ) async throws {
        let account = NetworkAccountModel()
        account.resume()
        guard account.identityReady else { throw NetworkAccountError.setupRequired }
        let store = RoomStore(fileURL: NetworkChannelStorage.fileURL)
        let rooms = account.networks.flatMap { $0.channels }.compactMap { account.room(channelID: $0.id.uuidString) }
        let room = if let roomIDOrName {
            rooms.first {
                $0.id.caseInsensitiveCompare(roomIDOrName) == .orderedSame
                    || $0.name.caseInsensitiveCompare(roomIDOrName) == .orderedSame
            }
        } else {
            rooms.first
        }
        guard let room else {
            throw ALOError("That channel is unavailable to this identity. Import a network invitation in ALO first.")
        }

        let defaults = UserDefaults.standard
        let installation = try MacSecureRoomIdentity()
        let nodeID = installation.identity.publicIdentity.nodeID.uuidString
        let displayName = account.displayName
        let authorization = try account.authorization(channelID: room.id,
            installationHash: installation.identity.publicIdentity.publicKeyHash, deviceName: displayName)
        let generatedAppearance = DeviceAppearance.generated(from: nodeID)
        let appearance = DeviceAppearance(
            icon: defaults.string(forKey: "meshDeviceIcon") ?? generatedAppearance.icon,
            colorHex: defaults.string(forKey: "meshDeviceColorHex") ?? generatedAppearance.colorHex
        )
        let profileImageData = DeviceAppearance.sanitizedProfileImageData(
            defaults.data(forKey: "meshDeviceProfileImageData")
        )

        func report(_ value: String) {
            print("ALO_QA status=\(value)")
            fflush(stdout)
            if value == "Sharing system audio" { broadcastReady = true }
        }
        var broadcastReady = false
        var broadcastFailure: Error?
        let session = MeshSession(
            room: room,
            nodeID: nodeID,
            displayName: displayName,
            deviceIcon: appearance.icon,
            deviceColorHex: appearance.colorHex,
            profileImageData: profileImageData,
            installationIdentity: installation.identity,
            peerPins: installation.pins,
            networkAuthorization: authorization,
            initialEvents: store.loadEvents(roomID: room.id),
            initialRoomStateDocument: store.loadRoomStateDocument(roomID: room.id),
            statusHandler: report,
            identityHandler: { id, name in report("identity \(name) \(id)") },
            participantsHandler: { report("participants \($0.count)") },
            mediaStateHandler: { report("video \($0 ? "available" : "off")") },
            nowPlayingHandler: { media in
                report("media \(media.isPlaying == false ? "paused" : "playing-or-unknown")")
            },
            chatHandler: { _, _, _, _, _ in },
            queueHandler: { _ in },
            videoHandler: { _ in },
            peerVersionHandler: { report("peer-version \($0)") },
            errorHandler: { error in
                broadcastFailure = error
                report("error \(error.localizedDescription)")
            },
            replicaPersistenceHandler: { store.saveEvents($0.events, roomID: room.id) },
            roomStatePersistenceHandler: { store.saveRoomStateDocument($0, roomID: room.id) }
        )
        try session.start(broadcastInitially: broadcastInitially)
        report("room-open \(room.name) \(room.id)")
        if takeOverAfterJoining {
            report("take-over scheduled")
            try await Task.sleep(nanoseconds: 3_000_000_000)
            session.beginBroadcasting()
        }
        if broadcastInitially || takeOverAfterJoining {
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while !broadcastReady, broadcastFailure == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            if let broadcastFailure { throw broadcastFailure }
            guard broadcastReady else {
                throw ALOError(
                    "Broadcast did not become ready within 20 seconds. Open the GUI on this Mac "
                    + "and grant Screen & System Audio Recording before headless QA."
                )
            }
        }
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        }
        await session.stop()
    }

    private static func stayAlive(
        capturing: SystemAudioCapture,
        hosting: HostServer,
        localReceiver: Receiver
    ) async {
        while !Task.isCancelled {
            _ = capturing
            _ = hosting
            _ = localReceiver
            try? await Task.sleep(nanoseconds: 3_600_000_000_000)
        }
    }

    private static func printHelp() {
        print("""
        ALO — free, synchronized Mac-to-Mac screen and audio over local Wi-Fi

        Usage:
          alo arena               Open the standalone games library
          alo stick-fight          Open standalone Stick Fight
          alo breach              Open Breach tactical FPS bot match
          alo channel [id-or-name] [--broadcast|--take-over]
                                   Open a saved mesh room for headless QA

        Examples:
          alo channel "Studio / #Main"
          alo channel "Studio / #Main" --broadcast
          alo channel "Studio / #Main" --take-over

        Requirements: macOS 14.2 or newer; all Macs on the same local network.
        """)
    }
}
