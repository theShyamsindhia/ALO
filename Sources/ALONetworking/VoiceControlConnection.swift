import Foundation
import Network

/// Queue-confined bounded reliable signaling; PCM never enters this channel.
final class VoiceControlConnection {
    let credentials: AuthenticatedChannelCredentials
    let resolve: (UInt16, @escaping (Result<NWEndpoint, Error>) -> Void) -> Void
    private let transportSend: (Data, @escaping (Result<Void, Error>) -> Void) -> Void
    private let transportClose: () -> Void
    private let now: () -> UInt64
    private var pending: [UUID: UInt64] = [:]
    private var stopped = false
    private var receiveWindow: UInt64 = 0
    private var receiveCount = 0
    var payload: ((DirectedVoiceWire.Message) -> Void)?
    var failed: (() -> Void)?

    init(credentials: AuthenticatedChannelCredentials,
         send: @escaping (Data, @escaping (Result<Void, Error>) -> Void) -> Void,
         close: @escaping () -> Void,
         resolve: @escaping (UInt16, @escaping (Result<NWEndpoint, Error>) -> Void) -> Void,
         now: @escaping () -> UInt64) {
        self.credentials = credentials; transportSend = send; transportClose = close
        self.resolve = resolve; self.now = now
    }
    static func attach(_ channel: SecurePeerChannel, queue: DispatchQueue,
                       completion: @escaping (Result<VoiceControlConnection, Error>) -> Void) {
        channel.withAuthenticatedCredentials { result in
            do {
                guard channel.mediaExecutor === queue else { throw SecureTransportError.invalidState }
                let credentials = try result.get()
                guard credentials.channelRole == .voiceControl,
                      credentials.negotiated.initiatorCapabilities.contains(.voice),
                      credentials.negotiated.responderCapabilities.contains(.voice) else { throw SecureTransportError.invalidCredentials }
                let connection = VoiceControlConnection(credentials: credentials,
                    send: { channel.send(payload: $0, completion: $1) }, close: { channel.cancel() },
                    resolve: { rawPort, reply in
                        guard let port = NWEndpoint.Port(rawValue: rawPort) else { reply(.failure(SecureTransportError.malformed)); return }
                        channel.withAuthenticatedDatagramEndpoint(port: port, completion: reply)
                    }, now: MonotonicClock.nowNanos)
                channel.onPayload = { [weak connection] in connection?.receive($0) }
                channel.onState = { [weak connection] state in
                    if case .failed = state { connection?.fail() }
                    if state == .cancelled { connection?.fail() }
                }
                completion(.success(connection))
            } catch { channel.cancel(); queue.async { completion(.failure(error)) } }
        }
    }
    func receive(_ bytes: Data) {
        guard !stopped else { return }
        let time = now()
        if time < receiveWindow || time - receiveWindow >= 1_000_000_000 { receiveWindow = time; receiveCount = 0 }
        guard credentials.isActive, receiveCount < 32 else { fail(); return }
        receiveCount += 1
        do { payload?(try DirectedVoiceWire.decode(bytes)) } catch { fail() }
    }
    func send(_ message: DirectedVoiceWire.Message) {
        guard !stopped else { return }
        guard credentials.isActive, pending.count < 8, let bytes = try? DirectedVoiceWire.encode(message) else { fail(); return }
        let id = UUID(); pending[id] = now() + 2_000_000_000
        transportSend(bytes) { [weak self] result in
            guard let self, !self.stopped, let deadline = self.pending.removeValue(forKey: id) else { return }
            if case .failure = result { self.fail() }
            else if deadline <= self.now() { self.fail() }
        }
    }
    func tick() {
        if !credentials.isActive || pending.values.contains(where: { $0 <= now() }) { fail() }
    }
    func close() { guard !stopped else { return }; stopped = true; pending.removeAll(); transportClose() }
    private func fail() { guard !stopped else { return }; close(); failed?() }
}
