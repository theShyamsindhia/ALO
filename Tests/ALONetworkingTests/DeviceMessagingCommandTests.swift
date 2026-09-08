import Foundation
import Testing
@testable import ALONetworking

struct DeviceMessagingCommandTests {
    @Test func strictCommandsAndPreservedMessageIdentity() throws {
        let task = UUID(), registration = UUID(), destination = UUID(), message = UUID()
        let register = try DeviceMessagingCommand.parse(["register", "--task", task.uuidString, "--title", "Own task"])
        #expect(try register.request().taskID == task)
        let status = try DeviceMessagingCommand.parse(["status", "--registration", registration.uuidString])
        #expect(try status.request().operation == .status)
        let receipt = try DeviceMessagingCommand.parse(["receipt", "--registration", registration.uuidString, "--message", message.uuidString])
        #expect(try receipt.request().messageID == message)
        let send = try DeviceMessagingCommand.parse(["send", "--registration", registration.uuidString, "--destination", destination.uuidString, "--message", message.uuidString])
        var input = DeviceMessagingCommand.Input()
        try input.append(Data("hello 🌍".utf8))
        let request = try send.request(input: input)
        #expect(request.messageID == message && request.destination == destination)
        #expect(request.text == "hello 🌍" && request.taskID == nil)
        #expect(try LocalDeviceMessageProtocol.decodeRequest(LocalDeviceMessageProtocol.encode(request).dropFirst(4)) == request)
    }
    @Test func RejectsUnknownDuplicateAndAuthorityFields() {
        for args in [["enable"], ["status"], ["status", "--registration", "bad"],
                     ["status", "--registration", UUID().uuidString, "--registration", UUID().uuidString],
                     ["send", "--task", UUID().uuidString], ["status", "--executable", "/bin/sh"],
                     ["register", "--task", UUID().uuidString, "--title", "ok", "extra"]] {
            #expect(throws: (any Error).self) { try DeviceMessagingCommand.parse(args) }
        }
    }
    @Test func boundedStdinUTF8AndExactWireSize() throws {
        let command = try DeviceMessagingCommand.parse(["send", "--registration", UUID().uuidString, "--destination", UUID().uuidString, "--message", UUID().uuidString])
        var input = DeviceMessagingCommand.Input()
        try input.append(Data(repeating: 65, count: 16 * 1024))
        #expect(try command.request(input: input).text?.utf8.count == 16 * 1024)
        #expect(throws: (any Error).self) { try input.append(Data([65])) }
        #expect(input.count == 16 * 1024)
        for bytes in [Data(), Data([0]), Data([0xff]), Data(repeating: 1, count: 16 * 1024)] {
            var invalid = DeviceMessagingCommand.Input(); try invalid.append(bytes)
            #expect(throws: (any Error).self) { try command.request(input: invalid) }
        }
    }
}
