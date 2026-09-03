import Foundation
import WERAICore

struct WERAIError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

@main
enum WERAICommand {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let command = arguments.first, !command.hasPrefix("-psn") else {
                GUIApplication.run()
                return
            }

            switch command {
            case "host":
                let roomName = arguments.dropFirst().first ?? Host.current().localizedName ?? "ALO Room"
                try await runHost(roomName: roomName)

            case "join":
                let roomName = arguments.dropFirst().first
                try runReceiver(roomName: roomName)

            case "room":
                let roomArguments = Array(arguments.dropFirst())
                let flags = roomArguments.filter { $0.hasPrefix("--") }
                let roomNames = roomArguments.filter { !$0.hasPrefix("--") }
                let supportedFlags = Set(["--broadcast", "--take-over"])
                guard flags.allSatisfy(supportedFlags.contains) else {
                    throw WERAIError("Unknown room option. Run 'alo help'.")
                }
                guard roomNames.count <= 1 else {
                    throw WERAIError("Pass at most one saved room ID or name.")
                }
                guard !(flags.contains("--broadcast") && flags.contains("--take-over")) else {
                    throw WERAIError("Choose either --broadcast or --take-over, not both.")
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
                throw WERAIError("Unknown command \"\(command)\". Run 'alo help'.")
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

        let capture = SystemAudioCapture()
        do {
            try await capture.start { samples, captureTimeNanos in
                host.acceptAudio(samples: samples, captureTimeNanos: captureTimeNanos)
            }
        } catch {
            throw WERAIError(
                "System-audio capture could not start. Allow Screen & System Audio Recording "
                + "for Terminal in System Settings → Privacy & Security, then run the command again. "
                + "Details: \(error.localizedDescription)"
            )
        }

        guard #available(macOS 14.2, *) else {
            throw WERAIError("Synchronized source playback requires macOS 14.2 or newer.")
        }
        let muteTap = SourceMuteTap()
        try muteTap.start()

        print("Streaming system audio; this Mac is playing through the synchronized path too.")
        print("Keep this process running; press Control-C to stop.")
        await stayAlive(
            capturing: capture,
            hosting: host,
            localReceiver: localReceiver,
            muteTap: muteTap
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
        let store = RoomStore()
        let rooms = store.load()
        let room = if let roomIDOrName {
            rooms.first {
                $0.id.caseInsensitiveCompare(roomIDOrName) == .orderedSame
                    || $0.name.caseInsensitiveCompare(roomIDOrName) == .orderedSame
            }
        } else {
            rooms.first
        }
        guard let room else {
            throw WERAIError("That room is not saved on this Mac. Open or join it once in ALO first.")
        }

        let defaults = UserDefaults.standard
        let nodeID: String
        if let stored = defaults.string(forKey: "meshNodeID"), !stored.isEmpty {
            nodeID = stored
        } else {
            nodeID = UUID().uuidString
            defaults.set(nodeID, forKey: "meshNodeID")
        }
        let displayName: String
        if let stored = defaults.string(forKey: "meshDeviceDisplayName"), !stored.isEmpty {
            displayName = stored
        } else {
            displayName = DeviceDisplayName.generated(from: nodeID)
            defaults.set(displayName, forKey: "meshDeviceDisplayName")
        }
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
            initialEvents: store.loadEvents(roomID: room.id),
            statusHandler: report,
            identityHandler: { id, name in report("identity \(name) \(id)") },
            participantsHandler: { report("participants \($0.count)") },
            mediaStateHandler: { report("video \($0 ? "available" : "off")") },
            nowPlayingHandler: { media in
                report("media \(media.isPlaying == false ? "paused" : "playing-or-unknown")")
            },
            chatHandler: { _, _, _, _ in },
            queueHandler: { _ in },
            videoHandler: { _ in },
            peerVersionHandler: { report("peer-version \($0)") },
            errorHandler: { error in
                broadcastFailure = error
                report("error \(error.localizedDescription)")
            },
            replicaPersistenceHandler: { store.saveEvents($0.events, roomID: room.id) }
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
                throw WERAIError(
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
        localReceiver: Receiver,
        muteTap: AnyObject
    ) async {
        while !Task.isCancelled {
            _ = capturing
            _ = hosting
            _ = localReceiver
            _ = muteTap
            try? await Task.sleep(nanoseconds: 3_600_000_000_000)
        }
    }

    private static func printHelp() {
        print("""
        ALO — free, synchronized Mac-to-Mac screen and audio over local Wi-Fi

        Usage:
          alo host [room-name]     Stream this Mac's screen and system audio
          alo join [room-name]     Find and play a room on the local network
          alo room [id-or-name] [--broadcast|--take-over]
                                   Open a saved mesh room for headless QA

        Examples:
          alo host "Studio"
          alo join "Studio"
          alo room "Studio"
          alo room "Studio" --broadcast
          alo room "Studio" --take-over

        Requirements: macOS 14.2 or newer; all Macs on the same local network.
        """)
    }
}
