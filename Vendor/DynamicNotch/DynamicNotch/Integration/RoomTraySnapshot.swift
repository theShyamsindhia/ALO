import Foundation

/// ALO's room-owned view of the shared file tray. The room keeps the stable
/// identity and transfer state; DynamicNotch only presents it.
public struct RoomTraySnapshot: Sendable, Equatable {
    public struct Item: Identifiable, Sendable, Equatable {
        public enum TransferState: String, Sendable, Equatable {
            case unavailable
            case downloading
            case available
        }

        public let id: String
        public let fileName: String
        public let byteCount: Int
        public let localFileURL: URL?
        public let transferState: TransferState

        public init(
            id: String,
            fileName: String,
            byteCount: Int,
            localFileURL: URL? = nil,
            transferState: TransferState
        ) {
            self.id = id
            self.fileName = fileName
            self.byteCount = byteCount
            self.localFileURL = localFileURL
            self.transferState = transferState
        }
    }

    public let items: [Item]

    public init(items: [Item]) {
        self.items = items
    }
}
