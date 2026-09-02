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
                let roomName = arguments.dropFirst().first ?? Host.current().localizedName ?? "WERAI Room"
                try await runHost(roomName: roomName)

            case "join":
                let roomName = arguments.dropFirst().first
                try runReceiver(roomName: roomName)

            case "help", "--help", "-h":
                printHelp()

            default:
                throw WERAIError("Unknown command \"\(command)\". Run 'werai help'.")
            }
        } catch {
            fputs("werai: \(error.localizedDescription)\n", stderr)
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
        WERAI — free, synchronized Mac-to-Mac screen and audio over local Wi-Fi

        Usage:
          werai host [room-name]   Stream this Mac's screen and system audio
          werai join [room-name]   Find and play a room on the local network

        Examples:
          werai host "Studio"
          werai join "Studio"

        Requirements: macOS 14.2 or newer; all Macs on the same local network.
        """)
    }
}
