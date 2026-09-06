import CryptoKit
import Foundation

/// Integrity metadata carried by the shared-room tray protocol. The store is
/// deliberately independent of the room reducer so untrusted file bytes cross
/// one small, testable boundary before they become available to AppKit.
struct RoomTrayFileDescriptor: Codable, Hashable, Sendable {
    static let maximumBytes = 8 * 1_024 * 1_024

    let itemID: UUID
    let fileName: String
    let byteCount: Int
    let sha256: Data

    init?(itemID: UUID, fileName: String, byteCount: Int, sha256: Data) {
        guard let safeName = Self.sanitizedFileName(fileName),
              byteCount > 0, byteCount <= Self.maximumBytes,
              sha256.count == SHA256.Digest.byteCount else { return nil }
        self.itemID = itemID
        self.fileName = safeName
        self.byteCount = byteCount
        self.sha256 = sha256
    }

    static func sanitizedFileName(_ proposed: String) -> String? {
        let name = proposed.precomposedStringWithCanonicalMapping
        guard !name.isEmpty, name != ".", name != "..",
              name.utf8.count <= 255,
              URL(fileURLWithPath: name).lastPathComponent == name,
              !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return name
    }
}

enum RoomTrayStoreError: Error, Equatable {
    case invalidRoomID
    case invalidDescriptor
    case invalidSource
    case fileTooLarge
    case integrityMismatch
    case identityCollision
    case cacheLimitExceeded
    case missingFile
    case invalidExportDirectory
}

/// Owns only verified copies below an ALO-managed cache root. Source files and
/// copies exported by the user are never moved, replaced, or removed.
struct RoomTrayStore {
    static let maximumCacheBytes = 128 * 1_024 * 1_024

    private let rootURL: URL
    private let cacheLimitBytes: Int
    private let manager: FileManager

    init(
        rootURL: URL? = nil,
        maximumCacheBytes: Int = Self.maximumCacheBytes,
        fileManager: FileManager = .default
    ) {
        self.manager = fileManager
        self.cacheLimitBytes = max(1, maximumCacheBytes)
        if let rootURL {
            self.rootURL = rootURL.standardizedFileURL
        } else {
            let cache = try? fileManager.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let bundleFolder = Bundle.main.bundleIdentifier == "in.werai.audio.dev" ? "ALO-Dev" : "ALO"
            self.rootURL = (cache ?? fileManager.temporaryDirectory)
                .appendingPathComponent(bundleFolder, isDirectory: true)
                .appendingPathComponent("Shared Room Tray", isDirectory: true)
                .standardizedFileURL
        }
    }

    /// Copies a local regular file into managed storage and returns the wire
    /// descriptor together with the URL whose last component is the safe,
    /// original display name.
    func importFile(
        at sourceURL: URL,
        roomID: String,
        itemID: UUID = UUID()
    ) throws -> (descriptor: RoomTrayFileDescriptor, url: URL) {
        try validateRoomID(roomID)
        try validateRegularFile(sourceURL)
        let data = try readBoundedFile(sourceURL)
        let digest = Data(SHA256.hash(data: data))
        guard let descriptor = RoomTrayFileDescriptor(
            itemID: itemID,
            fileName: sourceURL.lastPathComponent,
            byteCount: data.count,
            sha256: digest
        ) else { throw RoomTrayStoreError.invalidSource }
        return (descriptor, try storeIncoming(data, descriptor: descriptor, roomID: roomID))
    }

    /// Verifies exact length and SHA-256 before an atomic managed-cache write.
    @discardableResult
    func storeIncoming(
        _ data: Data,
        descriptor: RoomTrayFileDescriptor,
        roomID: String
    ) throws -> URL {
        try validateRoomID(roomID)
        guard descriptor.byteCount > 0,
              descriptor.byteCount <= RoomTrayFileDescriptor.maximumBytes,
              descriptor.sha256.count == SHA256.Digest.byteCount,
              RoomTrayFileDescriptor.sanitizedFileName(descriptor.fileName) == descriptor.fileName
        else { throw RoomTrayStoreError.invalidDescriptor }
        guard data.count == descriptor.byteCount,
              Data(SHA256.hash(data: data)) == descriptor.sha256
        else { throw RoomTrayStoreError.integrityMismatch }
        guard data.count <= cacheLimitBytes else { throw RoomTrayStoreError.cacheLimitExceeded }

        let roomDirectory = try ensureRoomDirectory(roomID)
        let itemDirectory = roomDirectory.appendingPathComponent(
            descriptor.itemID.uuidString.lowercased(),
            isDirectory: true
        )
        let destination = itemDirectory.appendingPathComponent(descriptor.fileName, isDirectory: false)
        if manager.fileExists(atPath: itemDirectory.path) {
            try validateManagedDirectory(itemDirectory)
            let contents = contents(of: itemDirectory)
            let existing = regularFiles(in: itemDirectory)
            guard existing.count == 1, existing[0].standardizedFileURL == destination.standardizedFileURL else {
                throw RoomTrayStoreError.identityCollision
            }
            guard contents.count == existing.count else { throw RoomTrayStoreError.identityCollision }
            let current = try readBoundedFile(destination)
            guard current.count == descriptor.byteCount,
                  Data(SHA256.hash(data: current)) == descriptor.sha256
            else { throw RoomTrayStoreError.identityCollision }
            touch(itemDirectory, file: destination)
            return destination
        }

        try manager.createDirectory(at: itemDirectory, withIntermediateDirectories: false)
        do {
            try data.write(to: destination, options: [.atomic])
            touch(itemDirectory, file: destination)
            try prune(roomDirectory: roomDirectory, preserving: itemDirectory)
            return destination
        } catch {
            try? manager.removeItem(at: itemDirectory)
            throw error
        }
    }

    /// Returns a managed, regular file URL suitable for Finder drag-out. Its
    /// last path component is the sanitized display filename.
    func fileURL(itemID: UUID, roomID: String) -> URL? {
        guard (try? validateRoomID(roomID)) != nil else { return nil }
        let directory = itemDirectory(itemID: itemID, roomID: roomID)
        guard (try? validateManagedDirectory(directory)) != nil,
              isInsideManagedRoot(directory) else { return nil }
        let files = regularFiles(in: directory)
        guard files.count == 1,
              let size = try? files[0].resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= RoomTrayFileDescriptor.maximumBytes,
              isInsideManagedRoot(files[0]) else { return nil }
        touch(directory, file: files[0])
        // FileManager may canonicalize `/var` to `/private/var` while listing.
        // Rebuild from our managed root so repeated lookups return the same URL
        // identity as import/store without changing the file being referenced.
        return directory.appendingPathComponent(files[0].lastPathComponent)
    }

    /// Atomically copies to the exact URL selected by the user. If that URL
    /// already exists, only that explicitly selected destination is replaced.
    /// The managed source is left intact and later tray removal cannot affect
    /// the exported result.
    @discardableResult
    func export(itemID: UUID, roomID: String, to destinationURL: URL) throws -> URL {
        guard let source = fileURL(itemID: itemID, roomID: roomID) else {
            throw RoomTrayStoreError.missingFile
        }
        try validateExportDestination(destinationURL)
        let destination = destinationURL.standardizedFileURL
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".alo-export-\(UUID().uuidString)")
        do {
            try manager.copyItem(at: source, to: temporary)
            if manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try manager.moveItem(at: temporary, to: destination)
            }
            return destination
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    /// Removes one item directory below the managed root. It cannot address a
    /// source file or a copy previously exported by the user.
    func remove(itemID: UUID, roomID: String) throws {
        try validateRoomID(roomID)
        let room = roomDirectory(roomID)
        let directory = itemDirectory(itemID: itemID, roomID: roomID)
        guard manager.fileExists(atPath: directory.path) else { return }
        try validateManagedDirectory(room)
        try validateManagedDirectory(directory)
        guard isInsideManagedRoot(directory) else { throw RoomTrayStoreError.invalidSource }
        try manager.removeItem(at: directory)
    }

    func removeAll(roomID: String) throws {
        try validateRoomID(roomID)
        let directory = roomDirectory(roomID)
        guard manager.fileExists(atPath: directory.path) else { return }
        try validateManagedDirectory(rootURL)
        try validateManagedDirectory(directory)
        guard isInsideManagedRoot(directory) else { throw RoomTrayStoreError.invalidSource }
        try manager.removeItem(at: directory)
    }

    private func validateRoomID(_ roomID: String) throws {
        guard !roomID.isEmpty, roomID.utf8.count <= 512,
              !roomID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw RoomTrayStoreError.invalidRoomID }
    }

    private func validateRegularFile(_ url: URL) throws {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true
        else { throw RoomTrayStoreError.invalidSource }
    }

    private func readBoundedFile(_ url: URL) throws -> Data {
        try validateRegularFile(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: RoomTrayFileDescriptor.maximumBytes + 1) ?? Data()
        guard !data.isEmpty else { throw RoomTrayStoreError.invalidSource }
        guard data.count <= RoomTrayFileDescriptor.maximumBytes else { throw RoomTrayStoreError.fileTooLarge }
        return data
    }

    private func ensureRoomDirectory(_ roomID: String) throws -> URL {
        try manager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try validateManagedDirectory(rootURL)
        let directory = roomDirectory(roomID)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try validateManagedDirectory(directory)
        return directory
    }

    private func roomDirectory(_ roomID: String) -> URL {
        let hash = SHA256.hash(data: Data(roomID.utf8)).map { String(format: "%02x", $0) }.joined()
        return rootURL.appendingPathComponent("room-" + hash, isDirectory: true)
    }

    private func itemDirectory(itemID: UUID, roomID: String) -> URL {
        roomDirectory(roomID).appendingPathComponent(itemID.uuidString.lowercased(), isDirectory: true)
    }

    private func regularFiles(in directory: URL) -> [URL] {
        contents(of: directory).filter { url in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                return false
            }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }
    }

    private func contents(of directory: URL) -> [URL] {
        (try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        )) ?? []
    }

    private func validateManagedDirectory(_ directory: URL) throws {
        guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true
        else { throw RoomTrayStoreError.invalidSource }
    }

    private func touch(_ directory: URL, file: URL) {
        let attributes: [FileAttributeKey: Any] = [.modificationDate: Date()]
        try? manager.setAttributes(attributes, ofItemAtPath: file.path)
        try? manager.setAttributes(attributes, ofItemAtPath: directory.path)
    }

    private func prune(roomDirectory: URL, preserving kept: URL) throws {
        let itemDirectories = (try? manager.contentsOfDirectory(
            at: roomDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var entries = itemDirectories.compactMap { directory -> (URL, Date, Int)? in
            guard let values = try? directory.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
                  values.isDirectory == true else { return nil }
            let bytes = regularFiles(in: directory).reduce(0) { total, file in
                total + ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            return (directory, values.contentModificationDate ?? .distantPast, bytes)
        }
        var total = entries.reduce(0) { $0 + $1.2 }
        entries.sort { $0.1 < $1.1 }
        for entry in entries where total > cacheLimitBytes && entry.0.standardizedFileURL != kept.standardizedFileURL {
            do {
                try manager.removeItem(at: entry.0)
                total -= entry.2
            } catch {
                continue
            }
        }
        guard total <= cacheLimitBytes else { throw RoomTrayStoreError.cacheLimitExceeded }
    }

    private func validateExportDestination(_ destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        let existingValues = try? destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard destination.isFileURL, !destination.lastPathComponent.isEmpty,
              let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true,
              existingValues?.isSymbolicLink != true,
              existingValues == nil || existingValues?.isRegularFile == true,
              !isInsideManagedRoot(destination)
        else { throw RoomTrayStoreError.invalidExportDirectory }
    }

    private func isInsideManagedRoot(_ url: URL) -> Bool {
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        return candidate == root || candidate.hasPrefix(root + "/")
    }

}
