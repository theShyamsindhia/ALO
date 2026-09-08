import Foundation

/// Pure CLI parsing. The eventual command owner supplies bounded stdin and uses
/// the already-running app socket; this type performs no I/O or app startup.
public struct DeviceMessagingCommand: Sendable {
    public enum Failure: Error, Equatable { case invalidArguments, invalidInput, inputTooLarge }
    public struct Input: Sendable {
        private var bytes = Data()
        public init() {}
        public var count: Int { bytes.count }
        public mutating func append(_ chunk: Data) throws {
            guard chunk.count <= LocalDeviceMessageProtocol.maximumTextBytes - bytes.count else { throw Failure.inputTooLarge }
            bytes.append(chunk)
        }
        fileprivate func text() throws -> String {
            guard !bytes.isEmpty, !bytes.contains(0), let result = String(data: bytes, encoding: .utf8) else { throw Failure.invalidInput }
            return result
        }
    }
    private let operation: LocalDeviceMessageProtocol.Operation
    private let values: [String: String]

    public static func parse(_ arguments: [String]) throws -> Self {
        guard let first = arguments.first, let operation = LocalDeviceMessageProtocol.Operation(rawValue: first),
              arguments.count <= 7, arguments.count % 2 == 1 else { throw Failure.invalidArguments }
        var values: [String: String] = [:]
        for index in stride(from: 1, to: arguments.count, by: 2) {
            let key = arguments[index], value = arguments[index + 1]
            guard values[key] == nil, !value.utf8.contains(0), value.utf8.count <= 160 else { throw Failure.invalidArguments }
            values[key] = value
        }
        let required: Set<String>
        switch operation {
        case .register: required = ["--task", "--title"]
        case .status: required = ["--registration"]
        case .send: required = ["--registration", "--destination", "--message"]
        case .receipt: required = ["--registration", "--message"]
        }
        guard Set(values.keys) == required else { throw Failure.invalidArguments }
        for (key, value) in values where key != "--title" {
            guard UUID(uuidString: value) != nil else { throw Failure.invalidArguments }
        }
        let result = Self(operation: operation, values: values)
        if operation != .send { _ = try result.request() }
        return result
    }

    public func request(input: Input? = nil) throws -> LocalDeviceMessageProtocol.Request {
        guard operation == .send || input == nil else { throw Failure.invalidInput }
        let text: String?
        if operation == .send {
            guard let input else { throw Failure.invalidInput }
            text = try input.text()
        } else { text = nil }
        let result = try LocalDeviceMessageProtocol.Request(operation: operation,
            taskID: values["--task"].flatMap(UUID.init(uuidString:)), title: values["--title"],
            registration: values["--registration"].flatMap(UUID.init(uuidString:)),
            destination: values["--destination"].flatMap(UUID.init(uuidString:)),
            messageID: values["--message"].flatMap(UUID.init(uuidString:)), text: text)
        // JSON escaping can exceed the frame limit even for legal UTF-8 input.
        _ = try LocalDeviceMessageProtocol.encode(result)
        return result
    }
}
