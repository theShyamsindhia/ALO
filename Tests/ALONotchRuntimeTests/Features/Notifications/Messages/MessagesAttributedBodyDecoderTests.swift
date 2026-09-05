import Foundation
import XCTest
@testable import ALONotchRuntime

final class MessagesAttributedBodyDecoderTests: XCTestCase {

    private let decoder = MessagesAttributedBodyDecoder()

    func testDecodeReturnsNormalizedPlainText() async {
        let text = decoder.decode(text: "\n  Hello\u{FFFC}  \n", attributedBody: nil)

        XCTAssertEqual(text, "Hello")
    }

    func testDecodePrefersPlainTextOverAttributedBody() async throws {
        let attributedBody = try keyedArchive("Archived message")

        let text = decoder.decode(text: "Plain message", attributedBody: attributedBody)

        XCTAssertEqual(text, "Plain message")
    }

    func testDecodeReturnsKeyedArchiveTextWhenPlainTextIsMissing() async throws {
        let attributedBody = try keyedArchive("Archived message")

        let text = decoder.decode(text: nil, attributedBody: attributedBody)

        XCTAssertEqual(text, "Archived message")
    }

    func testDecodeReturnsKeyedArchiveTextWhenPlainTextIsEmpty() async throws {
        let attributedBody = try keyedArchive("Archived message")

        let text = decoder.decode(text: " \n ", attributedBody: attributedBody)

        XCTAssertEqual(text, "Archived message")
    }

    func testDecodeNormalizesKeyedArchiveText() async throws {
        let attributedBody = try keyedArchive("\n  Archived\u{FFFC} message  \n")

        let text = decoder.decode(text: nil, attributedBody: attributedBody)

        XCTAssertEqual(text, "Archived message")
    }

    func testDecodeReturnsTypedStreamText() async {
        let attributedBody = typedStream("Typed stream message")

        let text = decoder.decode(text: nil, attributedBody: attributedBody)

        XCTAssertEqual(text, "Typed stream message")
    }

    func testDecodeReturnsUnicodeTypedStreamText() async {
        let attributedBody = typedStream("Привет 👋🏻 Как дела?")

        let text = decoder.decode(text: nil, attributedBody: attributedBody)

        XCTAssertEqual(text, "Привет 👋🏻 Как дела?")
    }

    func testDecodeReturnsMutableTypedStreamText() async {
        let attributedBody = typedStream("Mutable string message", className: "NSMutableString")

        let text = decoder.decode(text: nil, attributedBody: attributedBody)

        XCTAssertEqual(text, "Mutable string message")
    }

    func testDecodeReturnsLongTypedStreamText() async {
        let expectedText = Array(repeating: "Long message.", count: 30).joined(separator: " ")
        let attributedBody = typedStream(expectedText)

        let text = decoder.decode(text: nil, attributedBody: attributedBody)

        XCTAssertEqual(text, expectedText)
    }

    func testDecodeFallsBackWhenPlainTextContainsOnlyObjectReplacementCharacter() async {
        let attributedBody = typedStream("Attachment caption")

        let text = decoder.decode(text: "\u{FFFC}", attributedBody: attributedBody)

        XCTAssertEqual(text, "Attachment caption")
    }

    func testDecodeReturnsNilWhenBothValuesAreMissing() async {
        let text = decoder.decode(text: nil, attributedBody: nil)

        XCTAssertNil(text)
    }

    func testDecodeReturnsNilWhenBothValuesAreEmpty() async {
        let text = decoder.decode(text: " \n \u{FFFC} ", attributedBody: Data())

        XCTAssertNil(text)
    }

    func testDecodeReturnsNilForUnknownAttributedBody() async {
        let attributedBody = Data("Unknown binary value".utf8)

        let text = decoder.decode(text: nil, attributedBody: attributedBody)

        XCTAssertNil(text)
    }

    func testDecodeReturnsNilForTypedStreamWithoutString() async {
        let attributedBody = Data("streamtyped".utf8)

        let text = decoder.decode(text: nil, attributedBody: attributedBody)

        XCTAssertNil(text)
    }

    func testDecodeReturnsNilForTruncatedTypedStreamPayload() async {
        var bytes = Array("streamtyped".utf8)

        bytes.append(0)
        bytes.append(contentsOf: "NSString".utf8)
        bytes.append(0x2B)
        bytes.append(contentsOf: [0x81, 0x08, 0x00])
        bytes.append(0x41)

        let text = decoder.decode(text: nil, attributedBody: Data(bytes))

        XCTAssertNil(text)
    }

    func testDecodeReturnsNilForInvalidTypedStreamUTF8() async {
        var bytes = Array("streamtyped".utf8)

        bytes.append(0)
        bytes.append(contentsOf: "NSString".utf8)
        bytes.append(0x2B)
        bytes.append(2)
        bytes.append(contentsOf: [0xC3, 0x28])

        let text = decoder.decode(text: nil, attributedBody: Data(bytes))

        XCTAssertNil(text)
    }

    private func keyedArchive(_ text: String) throws -> Data {
        let attributedString = NSAttributedString(string: text)

        return try NSKeyedArchiver.archivedData(withRootObject: attributedString, requiringSecureCoding: true)
    }

    private func typedStream(_ text: String, className: String = "NSString") -> Data {
        let payload = Array(text.utf8)

        var bytes = Array("streamtyped".utf8)

        bytes.append(0)
        bytes.append(contentsOf: className.utf8)
        bytes.append(0x2B)
        bytes.append(contentsOf: encodedLength(payload.count))
        bytes.append(contentsOf: payload)

        return Data(bytes)
    }

    private func encodedLength(_ length: Int) -> [UInt8] {
        if length <= 0x7F {
            return [UInt8(length)]
        }

        if length <= Int(UInt16.max) {
            return [
                0x81,
                UInt8(truncatingIfNeeded: length),
                UInt8(truncatingIfNeeded: length >> 8)
            ]
        }

        return [
            0x82,
            UInt8(truncatingIfNeeded: length),
            UInt8(truncatingIfNeeded: length >> 8),
            UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 24)
        ]
    }
}
