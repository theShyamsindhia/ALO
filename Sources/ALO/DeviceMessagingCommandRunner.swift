import Foundation
import Darwin
import ALONetworking

/// Called only from ALOCommand's explicit `codex` branch. Does not launch an app
/// or an app server. Transport payload/response limits remain the shared schema.
enum DeviceMessagingCommandRunner {
    static func run(_ arguments: [String]) throws {
        let parsed = try DeviceMessagingCommand.parse(arguments)
        var input: DeviceMessagingCommand.Input?
        if arguments.first == "send" {
            var bounded = DeviceMessagingCommand.Input()
            while true {
                let chunk = try FileHandle.standardInput.read(upToCount: min(4096, LocalDeviceMessageProtocol.maximumTextBytes - bounded.count + 1)) ?? Data()
                if chunk.isEmpty { break }
                try bounded.append(chunk)
            }
            input = bounded
        }
        let request = try parsed.request(input: input)
        guard Bundle.main.bundleIdentifier != nil else {
            throw ALOError("Run this command using the exact ALO app executable shown in Settings. An unbundled binary cannot choose a Dev or release endpoint.")
        }
        let response: LocalDeviceMessageProtocol.Response
        do { response = try MacOwnerSocket.request(request, directory: endpointDirectory) }
        catch MacOwnerSocket.Failure.timeout { throw ALOError("ALO device messaging timed out. Check its status in Settings; text was not automatically retried.") }
        catch MacOwnerSocket.Failure.unsafePath { throw ALOError("ALO's local messaging endpoint failed its ownership/path checks. No connection was trusted.") }
        catch MacOwnerSocket.Failure.unauthorized { throw ALOError("ALO's local messaging endpoint did not match the current user.") }
        catch DeviceMessagingLocalEndpoint.Failure.unsafeTemporaryDirectory { throw ALOError("The protected per-user messaging directory is unavailable or unsafe. No endpoint was used.") }
        catch LocalDeviceMessageProtocol.Failure.invalidFrame { throw ALOError("ALO returned an invalid local protocol frame. No receipt status was trusted.") }
        catch LocalDeviceMessageProtocol.Failure.invalidRequest { throw ALOError("The local messaging request was rejected as invalid.") }
        catch let error as MacOwnerSocket.Failure {
            switch error {
            case .system(let code):
                if code == ENOENT || code == ECONNREFUSED { throw ALOError("Open ALO and explicitly enable device messaging in Settings. This command will not start an app or server.") }
                throw ALOError("Local messaging transport failed (system code \(code)); no text retry was attempted.")
            case .closed: throw ALOError("ALO closed the local messaging connection before a response. Use an explicit status check; do not assume the text was unqueued.")
            case .capacity: throw ALOError("ALO's local messaging request capacity is full. No automatic retry was attempted.")
            default: throw ALOError("ALO's local messaging endpoint is unavailable; check Settings.")
            }
        }
        catch { throw ALOError("ALO's local response could not be decoded. No receipt status was trusted.") }
        let frame = try LocalDeviceMessageProtocol.encode(response)
        FileHandle.standardOutput.write(frame.dropFirst(4))
        FileHandle.standardOutput.write(Data([10]))
        try requireAcceptedResponse(response)
    }
    /// The JSON is emitted first, then Command.main converts this refusal to
    /// exit 1. A successful exit still never proves task delivery.
    static func requireAcceptedResponse(_ response: LocalDeviceMessageProtocol.Response) throws {
        switch response.status {
        case .disabled, .revoked, .rejected, .unavailable:
            throw ALOError("ALO did not accept the request (\(response.status.rawValue)). Inspect Settings or query existing status before resending; no automatic retry was attempted.")
        default: break
        }
    }
    static var endpointDirectory: URL {
        get throws {
            // Running an unbundled binary must not silently target release ALO
            // when the user intended the Dev application.
            try DeviceMessagingLocalEndpoint.applicationDirectory(bundleID: Bundle.main.bundleIdentifier)
        }
    }
}
