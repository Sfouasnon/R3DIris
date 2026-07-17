//  RCP2Session.swift — R3DIris / RCP2Core
//  One WebSocket session to one camera, on Network.framework.
//
//  Ported unchanged (logic-for-logic) from REDConductorV3/RCP2/RCP2Session.swift —
//  the proven implementation. Do not "improve" this file without bench evidence;
//  every choice below was paid for on set.
//
//  Chosen over URLSessionWebSocketTask because NWProtocolTCP.Options exposes
//  kernel TCP keepalive — ONE of the two liveness layers RED Control Pro uses.
//  (The other, its ~4s `rcp_get CAMERA_ID` health probe, is deliberately omitted
//  in favor of the quieter bench-derived watchdog — RCP2_FIELD_NOTES.md rules 6-7.)
//  Rules enforced here:
//    5  — never send client WebSocket pings (FW 2.2.4 does not pong)
//    6  — TCP keepalive idle 5s / interval 3s / count 3 (RED Control Pro uses 3/3/3)
//    3  — graceful close (frees the camera-side session slot) before abort
//   16  — optional source-IP binding for link-local multi-NIC setups

import Foundation
import Network

final class RCP2Session: @unchecked Sendable {
    enum SessionError: Error, CustomStringConvertible {
        case connectFailed(String)
        case connectTimeout
        case notConnected
        case sendFailed(String)

        var description: String {
            switch self {
            case .connectFailed(let s): return "connect failed: \(s)"
            case .connectTimeout: return "connect timeout"
            case .notConnected: return "not connected"
            case .sendFailed(let s): return "send failed: \(s)"
            }
        }
    }

    let incoming: AsyncStream<Data>

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "rcp2.session")
    private var incomingCont: AsyncStream<Data>.Continuation?
    private var openCont: CheckedContinuation<Void, Error>?
    private var openResumed = false
    private var finished = false

    init(ip: String, port: UInt16 = RCP2.wsPort, sourceIP: String? = nil) {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true                 // rule 6 — one of two liveness layers
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 3
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 5
        tcp.noDelay = true

        let params = NWParameters(tls: nil, tcp: tcp)
        if let sourceIP, !sourceIP.isEmpty {
            // rule 16 — on link-local networks the default route may egress the
            // wrong NIC; binding the source IP forces the correct interface.
            params.requiredLocalEndpoint = .hostPort(host: .init(sourceIP), port: .any)
        }
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true                    // pong if the CAMERA ever pings us
        // NOTE: no client ping timer exists in Network.framework unless we send
        // pings ourselves — we never do (rule 5).
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)

        var cont: AsyncStream<Data>.Continuation!
        incoming = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        incomingCont = cont

        guard let url = URL(string: "ws://\(ip):\(port)") else {
            // Invalid IP string — build a connection that will fail on open.
            connection = NWConnection(to: .hostPort(host: .init(ip), port: .init(rawValue: port) ?? 9998), using: params)
            return
        }
        connection = NWConnection(to: .url(url), using: params)
    }

    /// Open the socket and complete the WebSocket handshake.
    func open(timeout: TimeInterval = 5) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                self.openCont = cont
                self.connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.resumeOpen(with: nil)
                        self.receiveLoop()
                    case .failed(let error):
                        self.resumeOpen(with: SessionError.connectFailed(String(describing: error)))
                        self.finishStream()
                    case .cancelled:
                        self.resumeOpen(with: SessionError.connectFailed("cancelled"))
                        self.finishStream()
                    case .waiting:
                        break   // still trying; the open timeout below bounds this
                    default:
                        break
                    }
                }
                self.connection.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.resumeOpen(with: SessionError.connectTimeout)
                }
            }
        }
    }

    /// Serialize and send one RCP2 JSON message as a text frame.
    func send(_ object: [String: Any]) async throws {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            throw SessionError.sendFailed("payload not serializable")
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, contentContext: context, isComplete: true,
                            completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: SessionError.sendFailed(String(describing: error)))
                } else {
                    cont.resume()
                }
            })
        }
    }

    /// Rule 3 — graceful close: send a proper close frame and give the camera a
    /// moment to complete the handshake (this frees its session-pool slot even on
    /// a mute session), only then tear the TCP connection down.
    func close(gracefulTimeout: TimeInterval = 3) async {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .protocolCode(.normalClosure)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        connection.send(content: nil, contentContext: context, isComplete: true,
                        completion: .contentProcessed { _ in })
        try? await Task.sleep(nanoseconds: UInt64(gracefulTimeout * 1_000_000_000))
        connection.cancel()
        queue.async { self.finishStream() }
    }

    /// Last resort only (unreachable peer); an aborted socket can linger as a
    /// zombie against the camera's ~8-session pool.
    func abort() {
        connection.forceCancel()
        queue.async { self.finishStream() }
    }

    // MARK: - Private

    private func resumeOpen(with error: Error?) {
        // queue-confined
        guard !openResumed, let cont = openCont else { return }
        openResumed = true
        openCont = nil
        if let error { cont.resume(throwing: error) } else { cont.resume() }
    }

    private func finishStream() {
        // queue-confined
        guard !finished else { return }
        finished = true
        incomingCont?.finish()
        incomingCont = nil
    }

    private func receiveLoop() {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.incomingCont?.yield(data)
            }
            if error != nil {
                self.finishStream()
                return
            }
            if let context, context.isFinal {   // peer sent a close frame
                self.finishStream()
                return
            }
            self.receiveLoop()
        }
    }
}
