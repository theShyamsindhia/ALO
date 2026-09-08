import Foundation
import Testing
@testable import ALONetworking

@Suite("Owner-local message protocol")
struct LocalDeviceMessageProtocolTests {
    @Test func roundTripDoesNotCreateAuthority() throws {
        let request = try LocalDeviceMessageProtocol.Request(operation: .register, taskID: UUID(), title: "My task")
        let bytes = try LocalDeviceMessageProtocol.encode(request)
        #expect(try LocalDeviceMessageProtocol.payloadLength(header: Data(bytes.prefix(4))) == bytes.count - 4)
        #expect(try LocalDeviceMessageProtocol.decodeRequest(Data(bytes.dropFirst(4))) == request)
        let response = LocalDeviceMessageProtocol.Response(status: .pendingApproval, registration: UUID())
        #expect(try LocalDeviceMessageProtocol.decodeResponse(Data(LocalDeviceMessageProtocol.encode(response).dropFirst(4))) == response)
    }
    @Test func rejectsExtraAuthorityAndUnknownFields() throws {
        let text = "{\"version\":1,\"operation\":\"status\",\"registration\":\"\(UUID())\",\"executable\":\"/bin/sh\"}"
        #expect(throws: LocalDeviceMessageProtocol.Failure.invalidFrame) {
            try LocalDeviceMessageProtocol.decodeRequest(Data(text.utf8))
        }
        #expect(throws: LocalDeviceMessageProtocol.Failure.invalidRequest) {
            try LocalDeviceMessageProtocol.Request(operation: .send, taskID: UUID(), registration: UUID(),
                destination: UUID(), messageID: UUID(), text: "hello")
        }
    }
    @Test func textAndFrameBounds() throws {
        for text in ["", "bad\0text", String(repeating: "a", count: 16 * 1024 + 1)] {
            #expect(throws: LocalDeviceMessageProtocol.Failure.invalidRequest) {
                try LocalDeviceMessageProtocol.Request(operation: .send, registration: UUID(),
                    destination: UUID(), messageID: UUID(), text: text)
            }
        }
        let unicode = try LocalDeviceMessageProtocol.Request(operation: .send, registration: UUID(),
            destination: UUID(), messageID: UUID(), text: String(repeating: "🐱", count: 4096))
        #expect(try LocalDeviceMessageProtocol.decodeRequest(Data(LocalDeviceMessageProtocol.encode(unicode).dropFirst(4))) == unicode)
        for header in [Data(), Data([0,0,0,0]), Data([0,1,0,0])] {
            #expect(throws: LocalDeviceMessageProtocol.Failure.invalidFrame) {
                try LocalDeviceMessageProtocol.payloadLength(header: header)
            }
        }
    }
    @Test func receiptStatesStayDistinct() {
        #expect(LocalDeviceMessageProtocol.Response.Status.codexQueued != .deliveredConfirmed)
        #expect(LocalDeviceMessageProtocol.Response.Status.uncertain != .definitelyNotQueued)
    }
    @Test(arguments: ["\"", "\u{0001}"])
    func encodedFrameOverflowIsRejectedAtConstruction(character: String) throws {
        let text = String(repeating: character, count: 13 * 1024)
        try #require(text.utf8.count <= LocalDeviceMessageProtocol.maximumTextBytes)
        #expect(throws: LocalDeviceMessageProtocol.Failure.invalidRequest) {
            try LocalDeviceMessageProtocol.Request(operation: .send, registration: UUID(),
                destination: UUID(), messageID: UUID(), text: text)
        }
        #expect(LocalDeviceMessageProtocol.maximumFrameBytes == 24 * 1024)
    }
    @Test func malformedJSONHasStableProtocolError() {
        for payload in [Data("{".utf8), Data("{}".utf8), Data("{\"version\":1,\"operation\":\"unknown\"}".utf8)] {
            #expect(throws: LocalDeviceMessageProtocol.Failure.invalidFrame) {
                try LocalDeviceMessageProtocol.decodeRequest(payload)
            }
            #expect(throws: LocalDeviceMessageProtocol.Failure.invalidFrame) {
                try LocalDeviceMessageProtocol.decodeResponse(payload)
            }
        }
    }
    @Test(arguments: ["\u{2028}", "\u{2029}"])
    func registrationTitleCannotInsertDisplayLines(separator: String) {
        #expect(throws: LocalDeviceMessageProtocol.Failure.invalidRequest) {
            try LocalDeviceMessageProtocol.Request(operation: .register, taskID: UUID(), title: "Task\(separator)Approval")
        }
    }
}
