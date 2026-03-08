import Foundation
import Network

/// Lightweight HTTP/1.1 server backed by Network.framework NWListener.
/// Handles up to 3 concurrent connections; each request is processed on a
/// global background queue.
final class HTTPServer {
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let connectionsLock = NSLock()
    private let router: Router
    let port: UInt16 = 8080

    private(set) var isRunning = false

    init(router: Router) {
        self.router = router
    }

    // MARK: - Lifecycle

    func start() throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .wifi          // WiFi only
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .failed(let err): print("[HTTPServer] failed: \(err)")
            default: break
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        isRunning = true
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connectionsLock.lock()
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        connectionsLock.unlock()
        isRunning = false
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connectionsLock.lock()
        guard connections.count < 3 else {
            connectionsLock.unlock()
            connection.cancel()
            return
        }
        connections[ObjectIdentifier(connection)] = connection
        connectionsLock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.removeConnection(connection)
            default: break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        receive(from: connection, buffer: Data())
    }

    private func removeConnection(_ connection: NWConnection) {
        connectionsLock.lock()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        connectionsLock.unlock()
    }

    // MARK: - Receiving

    /// Accumulates data until we have a complete HTTP request, then dispatches.
    private func receive(from connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            var buf = buffer
            if let data, !data.isEmpty { buf.append(data) }

            if let request = HTTPRequest.parse(from: buf), self.isCompleteRequest(buf, request: request) {
                self.router.handle(request: request, connection: connection) {
                    // after response sent – keep-alive not supported, connection closed by router
                }
            } else if !isComplete && error == nil {
                // Need more data
                self.receive(from: connection, buffer: buf)
            } else {
                connection.cancel()
            }
        }
    }

    /// Heuristic: a GET has no body; POST is complete when Content-Length bytes are present.
    private func isCompleteRequest(_ data: Data, request: HTTPRequest) -> Bool {
        if request.method == "GET" || request.method == "HEAD" { return true }
        guard let cls = request.headers["content-length"], let cl = Int(cls) else { return true }
        return request.body.count >= cl
    }
}
