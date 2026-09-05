import Foundation
import Darwin
import OSLog

extension Notification.Name {
    static let mailDatabaseDidReceiveMessage = Notification.Name("mailDatabaseDidReceiveMessage")
}

final class MailDatabaseWatcher {

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "DynamicNotch", category: "MailDatabaseWatcher")

    private let reader: MailDatabaseReader
    private let queue = DispatchQueue(label: "com.dynamicnotch.mail-database-watcher", qos: .utility)

    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var lastRowID: Int64 = 0
    private var debounceWorkItem: DispatchWorkItem?
    private var monitoringRequested = false
    private var generation = UUID()

    var isWatching: Bool { queue.sync { source != nil } }

    init(reader: MailDatabaseReader) {
        self.reader = reader
    }

    deinit {
        debounceWorkItem?.cancel()
        source?.cancel()
    }
    
    func startMonitoring() {
        queue.async { [weak self] in
            guard let self, !monitoringRequested else { return }
            monitoringRequested = true
            generation = UUID()

            guard let latestRowID = reader.latestRowID() else {
                logger.error("Could not read latest Mail RowID")
                scheduleRestart()
                return
            }

            lastRowID = latestRowID
            startWatchingWriteAheadLog()
        }
    }
    
    func stopMonitoring() {
        queue.async { [weak self] in
            guard let self else { return }
            monitoringRequested = false
            generation = UUID()

            debounceWorkItem?.cancel()
            debounceWorkItem = nil

            source?.cancel()
            source = nil
        }
    }
    
    private func startWatchingWriteAheadLog() {
        guard monitoringRequested else { return }
        guard let databaseURL = reader.databaseURL() else {
            logger.error("Mail database was not found")
            return
        }
        let writeAheadLogURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        fileDescriptor = open(writeAheadLogURL.path, O_EVTONLY)

        guard fileDescriptor >= 0 else {
            logger.error("Could not open Mail database WAL file")
            scheduleRestart()
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: queue
        )

        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }

            let event = source.data

            if event.contains(.rename) || event.contains(.delete) {
                restartMonitoring()
                return
            }

            scheduleDatabaseRead()
        }
        
        let descriptor = fileDescriptor
        source.setCancelHandler {
            close(descriptor)
        }

        self.source = source
        source.resume()

        logger.info("Started watching Mail database WAL file")
    }
    
    private func scheduleDatabaseRead() {
        guard monitoringRequested else { return }
        debounceWorkItem?.cancel()
        let scheduledGeneration = generation

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, monitoringRequested, generation == scheduledGeneration else { return }
            readNewMessages()
        }

        debounceWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }
    
    private func readNewMessages() {
        guard monitoringRequested else { return }
        let messages = reader.messages(after: lastRowID)

        guard !messages.isEmpty else { return }

        lastRowID = messages.map(\.rowID).max() ?? lastRowID

        for message in messages {
            message.summary?.isEmpty == false ? post(message) : scheduleMessageRefresh(for: message)
        }
    }
    
    private func restartMonitoring() {
        source?.cancel()
        source = nil

        scheduleRestart()
    }
    
    private func scheduleRestart() {
        let scheduledGeneration = generation
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, monitoringRequested, generation == scheduledGeneration, source == nil else { return }

            startWatchingWriteAheadLog()
        }
    }

    private func post(_ message: MailMessage) {
        let scheduledGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, queue.sync(execute: { self.monitoringRequested && self.generation == scheduledGeneration }) else { return }
            NotificationCenter.default.post(
                name: .mailDatabaseDidReceiveMessage,
                object: message
            )
        }
    }
    
    private func scheduleMessageRefresh(
        for message: MailMessage,
        attempt: Int = 1
    ) {
        let scheduledGeneration = generation
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, monitoringRequested, generation == scheduledGeneration else { return }

            guard let refreshedMessage = reader.message(withRowID: message.rowID) else {
                post(message)
                return
            }

            if refreshedMessage.summary?.isEmpty == false {
                post(refreshedMessage)
                return
            }

            if attempt >= 10 {
                post(refreshedMessage)
                return
            }

            scheduleMessageRefresh(
                for: refreshedMessage,
                attempt: attempt + 1
            )
        }
    }
}
