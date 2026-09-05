import Foundation
import CryptoKit
import Testing
@testable import ALO

struct NetworkFixture {
    static let room = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let sender = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let receiver = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    static let session = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    static let secret = Data(0..<32)
    static let exporter = Data(32..<64)
    static var key: SymmetricKey { SymmetricKey(data: secret) }
    static func context(room: UUID = room, sender: UUID = sender, receiver: UUID = receiver,
                        epoch: UInt64 = 7, session: UUID = session, generation: UInt64 = 9,
                        channel: DatagramChannel = .audio) -> SecureDatagramContext {
        .init(roomID: room, senderID: sender, receiverID: receiver, broadcasterEpoch: epoch,
              sessionID: session, generation: generation, channel: channel)
    }
}

@Suite("Authenticated media datagrams")
struct SecureDatagramTests {
    @Test func realAESGCMRoundTripAndAudioSize() throws {
        let context = NetworkFixture.context()
        let sender = try DatagramSealer(secret: NetworkFixture.key, context: context)
        let receiver = try DatagramOpener(secret: NetworkFixture.key, context: context)
        let audio = Data(repeating: 0xA5, count: 36 + 960)
        let packet = try sender.seal(audio)
        #expect(packet.count == 1_060)
        #expect(Data(packet.prefix(8)) == Data([0x41, 0x4c, 0x4f, 0x32, 2, 1, 0, 0]))
        #expect(try receiver.open(packet) == audio)
        #expect(try receiver.open(sender.seal(Data())) == Data())
    }

    @Test func payloadCeilingAndLengthBounds() throws {
        let context = NetworkFixture.context()
        let sender = try DatagramSealer(secret: NetworkFixture.key, context: context)
        let receiver = try DatagramOpener(secret: NetworkFixture.key, context: context)
        let payload = Data(repeating: 7, count: SecureDatagram.maximumPayloadSize)
        let packet = try sender.seal(payload)
        #expect(packet.count == 1_200)
        #expect(try receiver.open(packet) == payload)
        #expect(throws: SecureTransportError.oversized) { try sender.seal(payload + Data([1])) }
        #expect(throws: SecureTransportError.oversized) { try receiver.open(packet + Data([1])) }
        for length in 0..<64 {
            #expect(throws: SecureTransportError.malformed) { try receiver.open(Data(repeating: 0, count: length)) }
        }
        var forgedLength = packet
        forgedLength.replaceSubrange(40..<44, with: [255,255,255,255])
        #expect(throws: SecureTransportError.malformed) { try receiver.open(forgedLength) }
    }

    @Test func fullContextAndDirectionalKeySeparation() throws {
        let base = NetworkFixture.context()
        let packet = try DatagramSealer(secret: NetworkFixture.key, context: base).seal(Data([1,2,3]))
        let variations = [
            NetworkFixture.context(room: UUID()), NetworkFixture.context(sender: UUID()),
            NetworkFixture.context(receiver: UUID()), NetworkFixture.context(epoch: 8),
            NetworkFixture.context(session: UUID()), NetworkFixture.context(generation: 10),
            NetworkFixture.context(channel: .voice),
            NetworkFixture.context(sender: NetworkFixture.receiver, receiver: NetworkFixture.sender)
        ]
        for different in variations {
            #expect(throws: (any Error).self) { try DatagramOpener(secret: NetworkFixture.key, context: different).open(packet) }
            let alternative = try DatagramSealer(secret: NetworkFixture.key, context: different).seal(Data([1,2,3]))
            #expect(packet.suffix(19) != alternative.suffix(19))
        }
        #expect(throws: (any Error).self) {
            try DatagramOpener(secret: SymmetricKey(data: Data(repeating: 8, count: 32)), context: base).open(packet)
        }
    }

    @Test func everyByteIsAuthenticatedOrStrictlyParsed() throws {
        let context = NetworkFixture.context()
        let packet = try DatagramSealer(secret: NetworkFixture.key, context: context).seal(Data(repeating: 42, count: 96))
        for index in packet.indices {
            var corrupt = packet; corrupt[index] ^= 1
            let receiver = try DatagramOpener(secret: NetworkFixture.key, context: context)
            #expect(throws: (any Error).self) { try receiver.open(corrupt) }
            #expect(try receiver.open(packet) == Data(repeating: 42, count: 96))
        }
    }

    @Test func replayWindowHandlesReorderingAndDoesNotAdvanceOnBadTag() throws {
        let context = NetworkFixture.context()
        let sender = try DatagramSealer(secret: NetworkFixture.key, context: context)
        let receiver = try DatagramOpener(secret: NetworkFixture.key, context: context)
        let packets = try (0..<80).map { try sender.seal(Data([UInt8($0)])) }
        var forgedFuture = packets[0]
        forgedFuture.replaceSubrange(32..<40, with: Array(repeating: UInt8(255), count: 8))
        #expect(throws: (any Error).self) { try receiver.open(forgedFuture) }
        #expect(try receiver.open(packets[1]) == Data([1]))
        #expect(try receiver.open(packets[0]) == Data([0]))
        #expect(throws: SecureTransportError.replay) { try receiver.open(packets[1]) }
        #expect(try receiver.open(packets[79]) == Data([79]))
        #expect(try receiver.open(packets[16]) == Data([16])) // last position in window
        #expect(throws: SecureTransportError.replay) { try receiver.open(packets[15]) }
        #expect(throws: SecureTransportError.replay) { try receiver.open(packets[16]) }
    }

    @Test func nonceExhaustionFailsClosedAndCopiesShareSequence() throws {
        let context = NetworkFixture.context()
        let sender = try DatagramSealer(secret: NetworkFixture.key, context: context, initialSequence: .max - 1)
        let alias = sender
        let receiver = try DatagramOpener(secret: NetworkFixture.key, context: context)
        let first = try sender.seal(Data([1]))
        let final = try alias.seal(Data([1]))
        #expect(first != final)
        #expect(try receiver.open(first) == Data([1]))
        #expect(try receiver.open(final) == Data([1]))
        #expect(throws: SecureTransportError.nonceExhausted) { try sender.seal(Data()) }
    }

    @Test func deterministicParserFuzzBounds() throws {
        let receiver = try DatagramOpener(secret: NetworkFixture.key, context: NetworkFixture.context())
        var seed: UInt64 = 0xA10C0DE
        for length in 0...1_240 {
            var bytes = Data(capacity: length)
            for _ in 0..<length {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1
                bytes.append(UInt8(truncatingIfNeeded: seed >> 32))
            }
            #expect(throws: (any Error).self) { try receiver.open(bytes) }
        }
    }
}
