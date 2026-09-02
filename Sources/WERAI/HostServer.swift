import Foundation
import Network
import WERAICore

final class HostServer {
    static let serviceType = "_werai-audio._tcp"

    private final class Client {
        let control: NWConnection
        let decoder = ControlLineDecoder()
        var audio: NWConnection?
        var video: NWConnection?
        var id: String?
        var name: String?
        var volume: Double = 1
        var isMuted = false

        init(control: NWConnection) {
            self.control = control
        }
    }

    private let queue = DispatchQueue(label: "in.werai.host.network", qos: .userInteractive)
    private let roomName: String
    private let statusHandler: ((String) -> Void)?
    private let receiverCountHandler: ((Int) -> Void)?
    private let packetizer = AudioPacketizer()
    private var listener: NWListener?
    private var clients = [ObjectIdentifier: Client]()
    private var videoEnabled = false
    private var nowPlaying = NowPlayingMedia()
    private var mediaQueue = [RoomQueueItem]()

    init(
        roomName: String,
        statusHandler: ((String) -> Void)? = nil,
        receiverCountHandler: ((Int) -> Void)? = nil
    ) {
        self.roomName = roomName
        self.statusHandler = statusHandler
        self.receiverCountHandler = receiverCountHandler
    }

    func start() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.service = NWListener.Service(name: roomName, type: Self.serviceType)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("Room \"\(self.roomName)\" is visible on the local network.")
                self.statusHandler?("Room is visible on your local network")
            case .failed(let error):
                fputs("Host listener failed: \(error)\n", stderr)
                self.statusHandler?("Could not open the room: \(error.localizedDescription)")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for client in clients.values {
                client.audio?.cancel()
                client.video?.cancel()
                client.control.cancel()
            }
            clients.removeAll()
            receiverCountHandler?(0)
        }
    }

    func acceptAudio(samples: [Int16], captureTimeNanos: UInt64) {
        queue.async { [weak self] in
            guard let self else { return }
            let packets = self.packetizer.append(
                samples: samples,
                captureTimeNanos: captureTimeNanos
            )
            guard !packets.isEmpty else { return }

            let audioConnections = self.clients.values.compactMap(\.audio)
            for packet in packets {
                let data = packet.encoded()
                for connection in audioConnections {
                    connection.send(
                        content: data,
                        contentContext: .defaultMessage,
                        isComplete: true,
                        completion: .contentProcessed { _ in }
                    )
                }
            }
        }
    }

    func acceptVideo(_ frame: VideoFrame) {
        let data = frame.encoded()
        queue.async { [weak self] in
            guard let self else { return }
            for connection in self.clients.values.compactMap(\.video) {
                connection.send(
                    content: data,
                    contentContext: .defaultMessage,
                    isComplete: true,
                    completion: .contentProcessed { error in
                        if let error {
                            fputs("Video send failed: \(error)\n", stderr)
                        }
                    }
                )
            }
        }
    }

    func setVideoEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.videoEnabled = enabled
            self.broadcast(ControlMessage(type: "media_state", videoEnabled: enabled))
        }
    }

    func setNowPlaying(_ media: NowPlayingMedia) {
        queue.async { [weak self] in
            guard let self, media != self.nowPlaying else { return }
            self.nowPlaying = media
            self.broadcast(ControlMessage(type: "now_playing", nowPlaying: media))
        }
    }

    func setParticipantLevel(id: String, volume: Double, muted: Bool) {
        queue.async { [weak self] in
            guard let self,
                  let client = self.clients.values.first(where: { $0.id == id })
            else { return }
            self.applyLevel(to: client, volume: volume, muted: muted)
        }
    }

    func removeQueueItem(id: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.removeQueueItem(id: id, requestedBy: nil)
        }
    }

    private func accept(_ connection: NWConnection) {
        let client = Client(control: connection)
        let identifier = ObjectIdentifier(connection)
        clients[identifier] = client

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                print("Receiver connected from \(connection.endpoint).")
            case .failed, .cancelled:
                self.removeClient(identifier)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveControl(for: client, identifier: identifier)
    }

    private func receiveControl(for client: Client, identifier: ObjectIdentifier) {
        client.control.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data {
                for message in client.decoder.append(data) {
                    self.handle(message, for: client)
                }
            }
            if isComplete || error != nil {
                self.removeClient(identifier)
                return
            }
            self.receiveControl(for: client, identifier: identifier)
        }
    }

    private func handle(_ message: ControlMessage, for client: Client) {
        switch message.type {
        case "join":
            guard let udpPort = message.udpPort,
                  let videoPort = message.videoPort,
                  let port = NWEndpoint.Port(rawValue: udpPort),
                  let videoEndpointPort = NWEndpoint.Port(rawValue: videoPort),
                  case .hostPort(let host, _) = client.control.endpoint
            else { return }

            let proposedName = message.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Mac"
            client.id = message.participantID ?? UUID().uuidString
            client.name = uniqueName(for: proposedName, client: client)
            client.audio?.cancel()
            let connection = NWConnection(host: host, port: port, using: .udp)
            connection.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    fputs("Audio path failed: \(error)\n", stderr)
                }
            }
            connection.start(queue: queue)
            client.audio = connection

            client.video?.cancel()
            let videoConnection = NWConnection(host: host, port: videoEndpointPort, using: .tcp)
            videoConnection.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    fputs("Video path failed: \(error)\n", stderr)
                }
            }
            videoConnection.start(queue: queue)
            client.video = videoConnection
            if let data = try? ControlMessage(
                type: "welcome",
                displayName: client.name,
                participantID: client.id
            ).encodedLine() {
                client.control.send(content: data, completion: .contentProcessed { _ in })
            }
            broadcastPresence()
            if let data = try? ControlMessage(type: "media_state", videoEnabled: videoEnabled).encodedLine() {
                client.control.send(content: data, completion: .contentProcessed { _ in })
            }
            if let data = try? ControlMessage(
                type: "now_playing",
                nowPlaying: nowPlaying
            ).encodedLine() {
                client.control.send(content: data, completion: .contentProcessed { _ in })
            }
            sendQueue(to: client)

        case "ping":
            guard let id = message.id, let clientNanos = message.clientNanos else { return }
            let pong = ControlMessage(
                type: "pong",
                id: id,
                clientNanos: clientNanos,
                hostNanos: MonotonicClock.nowNanos()
            )
            if let data = try? pong.encodedLine() {
                client.control.send(content: data, completion: .contentProcessed { _ in })
            }

        case "chat":
            let trimmed = message.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let sender = client.name, !trimmed.isEmpty else { return }
            broadcast(ControlMessage(
                type: "chat",
                sender: sender,
                text: String(trimmed.prefix(2_000)),
                sentNanos: MonotonicClock.nowNanos()
            ))

        case "queue_add":
            guard let sender = client.name,
                  let senderID = client.id,
                  let proposed = message.queueItem,
                  mediaQueue.count < 100,
                  let url = validMediaURL(String(proposed.url.prefix(2_048)))
            else { return }
            let title = String(proposed.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))
            guard !title.isEmpty else { return }
            let subtitle = proposed.subtitle?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(180)
                .description
            mediaQueue.append(RoomQueueItem(
                title: title,
                subtitle: subtitle?.isEmpty == false ? subtitle : nil,
                url: url.absoluteString,
                addedBy: sender,
                addedByID: senderID,
                addedNanos: MonotonicClock.nowNanos()
            ))
            broadcastQueue()

        case "queue_remove":
            guard let id = message.queueItemID else { return }
            removeQueueItem(id: id, requestedBy: client.id)

        case "set_level":
            guard message.targetID == client.id else { return }
            applyLevel(
                to: client,
                volume: message.volume ?? client.volume,
                muted: message.muted ?? client.isMuted
            )

        default:
            break
        }
    }

    private func removeClient(_ identifier: ObjectIdentifier) {
        guard let client = clients.removeValue(forKey: identifier) else { return }
        client.audio?.cancel()
        client.video?.cancel()
        receiverCountHandler?(participantNames.count)
        broadcastPresence()
    }

    private var participantNames: [String] {
        clients.values.compactMap(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var participantDetails: [RoomParticipant] {
        clients.values.compactMap { client in
            guard let id = client.id, let name = client.name else { return nil }
            return RoomParticipant(id: id, name: name, volume: client.volume, isMuted: client.isMuted)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func uniqueName(for proposedName: String, client: Client) -> String {
        let shortened = String(proposedName.prefix(40))
        let base = shortened.isEmpty ? "Mac" : shortened
        let existing = clients.values
            .filter { $0 !== client }
            .compactMap(\.name)
        var candidate = base
        var suffix = 2
        while existing.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
            candidate = "\(base) (\(suffix))"
            suffix += 1
        }
        return candidate
    }

    private func broadcastPresence() {
        let names = participantNames
        receiverCountHandler?(names.count)
        broadcast(ControlMessage(
            type: "presence",
            participants: names,
            participantDetails: participantDetails
        ))
    }

    private func sendQueue(to client: Client) {
        guard let data = try? ControlMessage(
            type: "queue_update",
            mediaQueue: mediaQueue
        ).encodedLine() else { return }
        client.control.send(content: data, completion: .contentProcessed { _ in })
    }

    private func broadcastQueue() {
        broadcast(ControlMessage(type: "queue_update", mediaQueue: mediaQueue))
    }

    private func removeQueueItem(id: String, requestedBy participantID: String?) {
        guard let index = mediaQueue.firstIndex(where: { item in
            item.id == id && (participantID == nil || item.addedByID == participantID)
        }) else { return }
        mediaQueue.remove(at: index)
        broadcastQueue()
    }

    private func validMediaURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil
        else { return nil }
        return url
    }

    private func applyLevel(to client: Client, volume: Double, muted: Bool) {
        client.volume = min(max(volume, 0), 1)
        client.isMuted = muted
        guard let id = client.id else { return }
        let message = ControlMessage(
            type: "level",
            targetID: id,
            volume: client.volume,
            muted: muted
        )
        if let data = try? message.encodedLine() {
            client.control.send(content: data, completion: .contentProcessed { _ in })
        }
        broadcastPresence()
    }

    private func broadcast(_ message: ControlMessage) {
        guard let data = try? message.encodedLine() else { return }
        for client in clients.values where client.name != nil {
            client.control.send(content: data, completion: .contentProcessed { _ in })
        }
    }
}
