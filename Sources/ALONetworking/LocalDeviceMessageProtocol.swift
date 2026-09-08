import Foundation

/// Owner-local ingress only. A registration is not remote consent or evidence
/// that its supplied task UUID belongs to the calling process.
public enum LocalDeviceMessageProtocol {
    public static let maximumFrameBytes = 24 * 1024
    public static let maximumTextBytes = 16 * 1024
    public enum Failure: Error, Equatable { case invalidFrame, invalidRequest }
    public enum Operation: String, Codable, Sendable { case register, status, send, receipt }

    public struct Request: Codable, Equatable, Sendable {
        public let version: Int
        public let operation: Operation
        public let taskID: UUID?
        public let title: String?
        public let registration: UUID?
        public let destination: UUID?
        public let messageID: UUID?
        public let text: String?

        public init(operation: Operation, taskID: UUID? = nil, title: String? = nil,
                    registration: UUID? = nil, destination: UUID? = nil,
                    messageID: UUID? = nil, text: String? = nil) throws {
            version = 1; self.operation = operation; self.taskID = taskID; self.title = title
            self.registration = registration; self.destination = destination
            self.messageID = messageID; self.text = text
            try validate()
        }

        public func validate() throws {
            guard version == 1 else { throw Failure.invalidRequest }
            switch operation {
            case .register:
                guard taskID != nil, let title, !title.isEmpty, title.utf8.count <= 160,
                      !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }),
                      registration == nil, destination == nil, messageID == nil, text == nil else {
                    throw Failure.invalidRequest
                }
            case .status:
                guard registration != nil, taskID == nil, title == nil,
                      destination == nil, messageID == nil, text == nil else { throw Failure.invalidRequest }
            case .receipt:
                guard registration != nil, messageID != nil, taskID == nil, title == nil,
                      destination == nil, text == nil else { throw Failure.invalidRequest }
            case .send:
                guard registration != nil, destination != nil, messageID != nil,
                      taskID == nil, title == nil, let text, !text.isEmpty,
                      text.utf8.count <= maximumTextBytes, !text.utf8.contains(0) else {
                    throw Failure.invalidRequest
                }
            }
            guard try JSONEncoder().encode(self).count <= maximumFrameBytes else { throw Failure.invalidRequest }
        }
    }

    /// No arbitrary stdout/stderr or destination task identifiers cross ingress.
    public struct Response: Codable, Equatable, Sendable {
        public enum Status: String, Codable, Sendable {
            case pendingApproval, capabilityPending, ready, revoked, disabled
            case authenticatedReceipt, codexQueued, deliveredConfirmed, definitelyNotQueued, uncertain
            case rejected, unavailable
        }
        public let version: Int
        public let status: Status
        public let registration: UUID?
        public let messageID: UUID?
        public init(status: Status, registration: UUID? = nil, messageID: UUID? = nil) {
            version = 1; self.status = status; self.registration = registration; self.messageID = messageID
        }
    }

    public static func encode(_ request: Request) throws -> Data {
        try request.validate()
        return try frame(JSONEncoder().encode(request))
    }

    public static func encode(_ response: Response) throws -> Data {
        guard response.version == 1 else { throw Failure.invalidFrame }
        return try frame(JSONEncoder().encode(response))
    }

    public static func decodeRequest(_ payload: Data) throws -> Request {
        try validateKeys(payload, allowed: ["version", "operation", "taskID", "title", "registration", "destination", "messageID", "text"])
        let request: Request
        do { request = try JSONDecoder().decode(Request.self, from: payload) }
        catch { throw Failure.invalidFrame }
        try request.validate()
        return request
    }

    public static func decodeResponse(_ payload: Data) throws -> Response {
        try validateKeys(payload, allowed: ["version", "status", "registration", "messageID"])
        let result: Response
        do { result = try JSONDecoder().decode(Response.self, from: payload) }
        catch { throw Failure.invalidFrame }
        guard result.version == 1 else { throw Failure.invalidFrame }
        return result
    }

    private static func validateKeys(_ data: Data, allowed: Set<String>) throws {
        guard !data.isEmpty, data.count <= maximumFrameBytes else { throw Failure.invalidFrame }
        let decoded: Any
        do { decoded = try JSONSerialization.jsonObject(with: data) }
        catch { throw Failure.invalidFrame }
        guard let object = decoded as? [String: Any],
              Set(object.keys).isSubset(of: allowed) else { throw Failure.invalidFrame }
    }

    private static func frame(_ payload: Data) throws -> Data {
        guard !payload.isEmpty, payload.count <= maximumFrameBytes else { throw Failure.invalidFrame }
        let count = UInt32(payload.count)
        var result = Data([UInt8(count >> 24), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)])
        result.append(payload)
        return result
    }

    public static func payloadLength(header: Data) throws -> Int {
        guard header.count == 4 else { throw Failure.invalidFrame }
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= maximumFrameBytes else { throw Failure.invalidFrame }
        return Int(length)
    }
}
