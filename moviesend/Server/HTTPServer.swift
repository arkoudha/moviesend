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

    /// Starts the server.
    /// - onReady:  called (on a background queue) once the listener is actually bound and accepting.
    /// - onError:  called if the listener fails to start or encounters an error later.
    func start(onReady: @escaping (UInt16) -> Void,
               onError: @escaping (Error) -> Void) throws {

        // Plain TCP – no interface restriction so the listener binds on every
        // available interface (WiFi, Ethernet, USB-tethering, etc.)
        let params = NWParameters.tcp

        let listener = try NWListener(using: params,
                                      on: NWEndpoint.Port(rawValue: port)!)
        self.listener = listener

        // ▶ Register a Bonjour service.
        //   This is REQUIRED on iOS 14+ to:
        //   1. Trigger the "Local Network" permission dialog.
        //   2. Let devices discover the server via mDNS without knowing the IP.
        listener.service = NWListener.Service(name: "MovieSend", type: "_http._tcp")

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.isRunning = true
                let actualPort = self?.listener?.port?.rawValue ?? self?.port ?? 8080
                onReady(actualPort)
            case .failed(let err):
                self?.isRunning = false
                print("[HTTPServer] listener failed: \(err)")
                onError(err)
            case .cancelled:
                self?.isRunning = false
            default:
                break
            }
        }

        listener.start(queue: .global(qos: .userInitiated))
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

    /// Accumulates incoming bytes until a complete HTTP request has arrived.
    private func receive(from connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            var buf = buffer
            if let data, !data.isEmpty { buf.append(data) }

            if let request = HTTPRequest.parse(from: buf),
               self.isCompleteRequest(buf, request: request) {
                self.router.handle(request: request, connection: connection) { }
            } else if !isComplete && error == nil {
                self.receive(from: connection, buffer: buf)
            } else {
                connection.cancel()
            }
        }
    }

    private func isCompleteRequest(_ data: Data, request: HTTPRequest) -> Bool {
        if request.method == "GET" || request.method == "HEAD" { return true }
        guard let cls = request.headers["content-length"], let cl = Int(cls) else { return true }
        return request.body.count >= cl
    }
}
