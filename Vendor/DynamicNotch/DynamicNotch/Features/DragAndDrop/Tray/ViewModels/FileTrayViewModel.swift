//
//  FileTrayViewModel.swift
//  DynamicNotch
//
//  Created by Евгений Петрукович on 4/26/26.
//

import Foundation
import Combine
internal import AppKit

enum FileTrayPasteboard {
    static let localDragTypeIdentifier = "com.dynamicnotch.file-tray.local-drag"
    static let localDragPasteboardType = NSPasteboard.PasteboardType(localDragTypeIdentifier)
}

final class FileTrayPasteboardWriter: NSObject, NSPasteboardWriting {
    private let url: URL

    init(url: URL) {
        self.url = url.standardizedFileURL
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, FileTrayPasteboard.localDragPasteboardType]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .fileURL, .URL:
            return url.absoluteString
        case FileTrayPasteboard.localDragPasteboardType:
            return Data([1])
        default:
            return nil
        }
    }
}

private enum FileTrayRemovalPolicy: String, Codable {
    case deleteCopy
    case trashMovedOriginal
}

struct FileTrayItem: Identifiable, Equatable {
    let id: String
    let localURL: URL?
    let displayName: String
    let isDirectory: Bool
    let byteCount: Int?
    let transferState: RoomTraySnapshot.Item.TransferState
    fileprivate let removalPolicy: FileTrayRemovalPolicy

    fileprivate init(
        url: URL,
        id: String = UUID().uuidString,
        removalPolicy: FileTrayRemovalPolicy = .deleteCopy
    ) {
        let standardizedURL = url.standardizedFileURL
        var isDirectoryValue: ObjCBool = false

        FileManager.default.fileExists(
            atPath: standardizedURL.path,
            isDirectory: &isDirectoryValue
        )

        self.id = id
        self.localURL = standardizedURL
        self.displayName = standardizedURL.lastPathComponent.isEmpty ?
        standardizedURL.deletingLastPathComponent().lastPathComponent :
        standardizedURL.lastPathComponent
        self.isDirectory = isDirectoryValue.boolValue
        self.byteCount = try? standardizedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        self.transferState = .available
        self.removalPolicy = removalPolicy
    }

    fileprivate init(snapshot: RoomTraySnapshot.Item) {
        let candidateURL = snapshot.localFileURL?.standardizedFileURL
        var isDirectoryValue: ObjCBool = false
        let hasLocalFile = candidateURL.map {
            FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectoryValue)
        } ?? false

        id = snapshot.id
        localURL = hasLocalFile ? candidateURL : nil
        displayName = URL(fileURLWithPath: snapshot.fileName).lastPathComponent
        isDirectory = hasLocalFile && isDirectoryValue.boolValue
        byteCount = snapshot.byteCount
        transferState = hasLocalFile ? .available :
            (snapshot.transferState == .available ? .unavailable : snapshot.transferState)
        removalPolicy = .deleteCopy
    }

    var icon: NSImage {
        if let localURL {
            return NSWorkspace.shared.icon(forFile: localURL.path)
        }
        return NSWorkspace.shared.icon(for: .data)
    }

    var itemProvider: NSItemProvider? {
        guard let localURL else { return nil }
        let provider = NSItemProvider(object: localURL as NSURL)
        provider.suggestedName = displayName
        provider.registerDataRepresentation(
            forTypeIdentifier: FileTrayPasteboard.localDragTypeIdentifier,
            visibility: .ownProcess
        ) { completion in
            completion(Data([1]), nil)
            return nil
        }
        return provider
    }

    var movesOutOfTrayOnDrag: Bool {
        removalPolicy == .trashMovedOriginal
    }

    var isAvailable: Bool { localURL != nil }
}

private struct FileTrayStoredItem: Codable {
    let id: String
    let path: String
    let removalPolicy: FileTrayRemovalPolicy

    init(id: String, path: String, removalPolicy: FileTrayRemovalPolicy) {
        self.id = id
        self.path = path
        self.removalPolicy = removalPolicy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let stringID = try? container.decode(String.self, forKey: .id) {
            id = stringID
        } else {
            id = try container.decode(UUID.self, forKey: .id).uuidString
        }
        path = try container.decode(String.self, forKey: .path)
        removalPolicy = try container.decodeIfPresent(
            FileTrayRemovalPolicy.self,
            forKey: .removalPolicy
        ) ?? .trashMovedOriginal
    }
}

@MainActor
final class FileTrayViewModel: ObservableObject {
    // Lifecycle stops explicitly; ARC release must not enter an isolated
    // deinit backdeployment thunk when SwiftUI releases this owner on macOS 15.
    nonisolated deinit {}

    @Published var selectedItemIDs: Set<FileTrayItem.ID> = []
    @Published private(set) var items: [FileTrayItem] = []

    private static let persistedItemsKey = "settings.live.tray.persistedItems"
    private let defaults: UserDefaults
    private var localItems: [FileTrayItem] = []
    private(set) var isRoomBacked = false
    var onRoomAddRequested: (([URL]) -> Void)?
    var onRoomRemoveRequested: (([String]) -> Void)?
    var onRoomDownloadRequested: ((String) -> Void)?
    var onRoomExportRequested: ((String, URL) -> Void)?

    init(defaults: UserDefaults = .aloNotch) {
        self.defaults = defaults

    }

    private var hasLoadedItems = false
    func activate() {
        guard !hasLoadedItems else { return }
        hasLoadedItems = true
        if isRoomBacked {
            let sharedItems = items
            restorePersistedItems()
            localItems = items
            items = sharedItems
            selectedItemIDs.formIntersection(Set(sharedItems.map(\.id)))
            FileTrayStorage.removeUntrackedItems(keeping: localItems.compactMap(\.localURL))
        } else {
            restorePersistedItems()
            FileTrayStorage.removeUntrackedItems(keeping: items.compactMap(\.localURL))
        }
    }

    var onItemsChange: (([FileTrayItem]) -> Void)? {
        didSet {
            onItemsChange?(items)
        }
    }

    var count: Int {
        items.count
    }

    var selectedCount: Int {
        selectedItems.count
    }

    var hasSelection: Bool {
        selectedItemIDs.isEmpty == false
    }

    var selectedItems: [FileTrayItem] {
        items.filter { selectedItemIDs.contains($0.id) }
    }

    func add(_ urls: [URL]) {
        add(urls, removalPolicy: .deleteCopy)
    }

    private func add(_ urls: [URL], removalPolicy: FileTrayRemovalPolicy) {
        if isRoomBacked {
            let files = urls.map(\.standardizedFileURL).filter(\.isFileURL)
            if !files.isEmpty { onRoomAddRequested?(files) }
            return
        }

        var knownIdentities = Set(items.compactMap(\.localURL).map { Self.identity(for: $0) })
        let newItems = urls.compactMap { url -> FileTrayItem? in
            let standardizedURL = url.standardizedFileURL
            guard standardizedURL.isFileURL else { return nil }

            let identity = Self.identity(for: standardizedURL)
            guard knownIdentities.insert(identity).inserted else { return nil }

            return FileTrayItem(url: standardizedURL, removalPolicy: removalPolicy)
        }

        guard !newItems.isEmpty else { return }

        updateItems(items + newItems)
    }

    func add(_ urls: [URL], mode: FileTrayUsageMode) throws {
        if isRoomBacked {
            // Room files are uploaded from their original URLs. Never apply the
            // standalone tray's destructive move mode to a member's file.
            add(urls, removalPolicy: .deleteCopy)
            return
        }
        switch mode {
        case .copy:
            let importedURLs = try FileTrayStorage.importItems(from: urls, moveOriginals: false)
            add(importedURLs, removalPolicy: .deleteCopy)

        case .moveOriginals:
            let importedURLs = try FileTrayStorage.importItems(from: urls, moveOriginals: true)
            add(importedURLs, removalPolicy: .trashMovedOriginal)
        }
    }

    func toggleSelection(for item: FileTrayItem) {
        if selectedItemIDs.contains(item.id) {
            selectedItemIDs.remove(item.id)
        } else {
            selectedItemIDs.insert(item.id)
        }
    }

    func selectAll() {
        selectedItemIDs = Set(items.map { $0.id })
    }

    func clearSelection() {
        selectedItemIDs.removeAll()
    }

    func itemsForDrag(startingAt item: FileTrayItem) -> [FileTrayItem] {
        if selectedItemIDs.contains(item.id) {
            return selectedItems
        }

        return [item]
    }

    func remove(_ item: FileTrayItem) {
        if isRoomBacked {
            onRoomRemoveRequested?([item.id])
            return
        }
        updateItems(items.filter { $0.id != item.id })
        removeStoredFiles(for: [item])
    }

    func removeSelectedItems() {
        guard hasSelection else { return }

        let removedItems = items.filter { selectedItemIDs.contains($0.id) }
        if isRoomBacked {
            onRoomRemoveRequested?(removedItems.map(\.id))
            return
        }
        let remainingItems = items.filter { selectedItemIDs.contains($0.id) == false }

        updateItems(remainingItems)
        removeStoredFiles(for: removedItems)
    }

    func clear() {
        let removedItems = items

        if isRoomBacked {
            onRoomRemoveRequested?(removedItems.map(\.id))
            return
        }

        updateItems([])
        removeStoredFiles(for: removedItems)
    }

    func forgetMovedOutItems(_ movedItems: [FileTrayItem]) {
        guard !isRoomBacked else { return }
        let movedItemIDs = Set(
            movedItems
                .filter(\.movesOutOfTrayOnDrag)
                .map(\.id)
        )

        guard movedItemIDs.isEmpty == false else {
            return
        }

        updateItems(items.filter { movedItemIDs.contains($0.id) == false })
    }

    func requestDownload(_ item: FileTrayItem) {
        guard isRoomBacked, !item.isAvailable, item.transferState != .downloading else { return }
        onRoomDownloadRequested?(item.id)
    }

    func export(_ item: FileTrayItem, to destinationURL: URL) {
        guard let sourceURL = item.localURL else { return }
        if isRoomBacked {
            onRoomExportRequested?(item.id, destinationURL.standardizedFileURL)
            return
        }
        try? FileManager.default.copyItem(at: sourceURL, to: destinationURL.standardizedFileURL)
    }

    func applyRoomSnapshot(_ snapshot: RoomTraySnapshot?) {
        if let snapshot {
            if !isRoomBacked { localItems = items }
            isRoomBacked = true
            var knownIDs = Set<String>()
            let validItems = snapshot.items.compactMap { item -> FileTrayItem? in
                guard !item.id.isEmpty,
                      knownIDs.insert(item.id).inserted,
                      !item.fileName.isEmpty,
                      URL(fileURLWithPath: item.fileName).lastPathComponent == item.fileName,
                      item.byteCount > 0 else { return nil }
                return FileTrayItem(snapshot: item)
            }
            updateItems(validItems, persist: false)
        } else if isRoomBacked {
            isRoomBacked = false
            updateItems(localItems, persist: false)
            localItems = []
        }
    }


    private func updateItems(_ newItems: [FileTrayItem], persist: Bool = true) {
        items = newItems
        selectedItemIDs.formIntersection(Set(newItems.map(\.id)))
        if persist { persistItems() }
        onItemsChange?(newItems)
    }

    private static func identity(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func removeStoredFiles(for removedItems: [FileTrayItem]) {
        for item in removedItems {
            switch item.removalPolicy {
            case .deleteCopy:
                if let localURL = item.localURL {
                    FileTrayStorage.deleteIfStoredInTray(localURL)
                }

            case .trashMovedOriginal:
                if let localURL = item.localURL {
                    FileTrayStorage.trashIfStoredInTray(localURL)
                }
            }
        }
    }


    private func persistItems() {
        let storedItems: [FileTrayStoredItem] = items.compactMap {
            guard let localURL = $0.localURL else { return nil }
            return FileTrayStoredItem(
                id: $0.id,
                path: localURL.path,
                removalPolicy: $0.removalPolicy
            )
        }

        do {
            let data = try JSONEncoder().encode(storedItems)
            defaults.set(data, forKey: Self.persistedItemsKey)
        } catch {
            defaults.removeObject(forKey: Self.persistedItemsKey)
        }
    }

    private func restorePersistedItems() {
        guard let data = defaults.data(forKey: Self.persistedItemsKey) else {
            return
        }

        do {
            let storedItems = try JSONDecoder().decode([FileTrayStoredItem].self, from: data)

            let restoredItems = storedItems.compactMap { storedItem -> FileTrayItem? in
                let url = URL(fileURLWithPath: storedItem.path).standardizedFileURL

                guard FileManager.default.fileExists(atPath: url.path) else {
                    return nil
                }

                return FileTrayItem(
                    url: url,
                    id: storedItem.id,
                    removalPolicy: storedItem.removalPolicy
                )
            }

            items = restoredItems
            selectedItemIDs = []

            if restoredItems.count != storedItems.count {
                persistItems()
            }
        } catch {
            defaults.removeObject(forKey: Self.persistedItemsKey)
        }
    }
}

private enum FileTrayStorage {
    static var rootURL: URL {
        NotchStoragePaths.fileTray
    }

    static func removeUntrackedItems(keeping keptURLs: [URL]) {
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let keptPaths = Set(
            keptURLs.map {
                $0.standardizedFileURL.resolvingSymlinksInPath().path
            }
        )

        guard let storedURLs = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for storedURL in storedURLs {
            let storedPath = storedURL.standardizedFileURL.resolvingSymlinksInPath().path

            guard keptPaths.contains(storedPath) == false else {
                continue
            }

            deleteIfStoredInTray(storedURL)
        }
    }

    static func deleteIfStoredInTray(_ url: URL) {
        guard let fileURL = storedFileURL(for: url) else {
            return
        }

        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            NSLog("Failed to delete File Tray copy: %@", error.localizedDescription)
        }
    }

    static func trashIfStoredInTray(_ url: URL) {
        guard let fileURL = storedFileURL(for: url) else {
            return
        }

        var trashedURL: NSURL?
        do {
            try FileManager.default.trashItem(at: fileURL, resultingItemURL: &trashedURL)
        } catch {
            NSLog("Failed to move File Tray item to Trash: %@", error.localizedDescription)
        }
    }

    private static func storedFileURL(for url: URL) -> URL? {
        let fileURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let storageRootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let storageRootPath = storageRootURL.path + "/"

        guard fileURL.path.hasPrefix(storageRootPath),
              FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        return fileURL
    }

    static func importItems(from urls: [URL], moveOriginals: Bool) throws -> [URL] {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )

        return try urls.map { sourceURL in
            let standardizedURL = sourceURL.standardizedFileURL
            let destinationURL = uniqueDestinationURL(for: standardizedURL, in: rootURL)

            if moveOriginals {
                try FileManager.default.moveItem(at: standardizedURL, to: destinationURL)
            } else {
                try FileManager.default.copyItem(at: standardizedURL, to: destinationURL)
            }

            return destinationURL
        }
    }

    private static func uniqueDestinationURL(for sourceURL: URL, in folder: URL) -> URL {
        let preferredName = sourceURL.lastPathComponent
        let baseURL = folder.appendingPathComponent(preferredName, isDirectory: sourceURL.hasDirectoryPath)

        guard FileManager.default.fileExists(atPath: baseURL.path) else {
            return baseURL
        }

        let name = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension

        for index in 1...999 {
            let fileName = ext.isEmpty ? "\(name) \(index)" : "\(name) \(index).\(ext)"
            let candidate = folder.appendingPathComponent(fileName, isDirectory: sourceURL.hasDirectoryPath)

            if FileManager.default.fileExists(atPath: candidate.path) == false {
                return candidate
            }
        }

        return folder.appendingPathComponent(UUID().uuidString, isDirectory: sourceURL.hasDirectoryPath)
    }
}
