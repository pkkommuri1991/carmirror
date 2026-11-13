import Foundation
import Network

/// Minimal HTTP/1.1 file server (GET/HEAD only) that serves the HLS files the
/// broadcast extension writes. AVPlayer reads from it and AirPlays the video.
final class LocalHLSServer {
    private let root: URL
    private let queue = DispatchQueue(label: "carmirror.http")
    private var listener: NWListener?
    /// Previous listener that is still giving the port back. Cancelling is
    /// asynchronous: binding again before it reports `.cancelled` fails with
    /// "Address already in use" (seen when toggling "Serve on local network").
    private var releasing: NWListener?

    /// Called on the main queue when the listener dies (port in use, or iOS reclaimed
    /// the socket while the app was suspended). Nil message = listening again.
    var onStateChange: ((_ errorMessage: String?) -> Void)?

    init(root: URL) { self.root = root }

    /// Call from the main thread.
    /// - Parameter loopbackOnly: true = only this iPhone can connect (default, private).
    ///   false = devices on the same Wi-Fi/hotspot can connect too (needed if a
    ///   receiver fetches the URL itself instead of the phone pushing the video).
    func start(port: UInt16, loopbackOnly: Bool) throws {
        let listener = try makeListener(port: port, loopbackOnly: loopbackOnly)
        if let old = self.listener {
            release(old)
        }
        self.listener = listener
        if releasing == nil { listener.start(queue: queue) }
        // else: started by release(_:) once the old listener has let go of the port.
    }

    func stop() {
        if let old = listener { release(old) }
        listener = nil
    }

    private func release(_ old: NWListener) {
        guard old.state != .setup else { old.cancel(); return }   // never started: holds no port
        if releasing != nil { old.stateUpdateHandler = nil; old.cancel(); return }  // already waiting on one
        releasing = old
        old.stateUpdateHandler = { [weak self] state in
            guard case .cancelled = state else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.releasing = nil
                if let current = self.listener, current.state == .setup { current.start(queue: self.queue) }
            }
        }
        old.cancel()
    }

    private func makeListener(port: UInt16, loopbackOnly: Bool) throws -> NWListener {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if loopbackOnly { params.requiredInterfaceType = .loopback }

        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            let message: String?
            switch state {
            case .ready: message = nil
            case .failed(let error):
                NSLog("CarMirror HTTP listener failed: \(error)")
                message = "Stream server stopped: \(error.localizedDescription)"
            default: return
            }
            DispatchQueue.main.async {
                // Ignore events from a listener we've already replaced.
                guard let self, let listener, self.listener === listener else { return }
                self.onStateChange?(message)
            }
        }
        return listener
    }

    // MARK: - Connections

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                self.respond(on: connection, head: head)
            } else if error != nil || isComplete || buffer.count > 65_536 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(on connection: NWConnection, head: String) {
        let requestLine = head.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else {
            send(on: connection, status: "405 Method Not Allowed", type: "text/plain", body: Data())
            return
        }
        let isHead = parts[0] == "HEAD"

        // Only serve plain file names from the stream folder (blocks ../ traversal).
        let path = String(parts[1]).components(separatedBy: "?").first ?? "/"
        let name = (path as NSString).lastPathComponent
        let file = root.appendingPathComponent(name)

        guard !name.isEmpty, name != "/", let body = try? Data(contentsOf: file) else {
            send(on: connection, status: "404 Not Found", type: "text/plain", body: Data())
            return
        }
        send(on: connection, status: "200 OK", type: Self.contentType(for: name),
             body: body, omitBody: isHead, noCache: name.hasSuffix(".m3u8"))
    }

    private func send(on connection: NWConnection, status: String, type: String, body: Data,
                      omitBody: Bool = false, noCache: Bool = true) {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(type)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += noCache ? "Cache-Control: no-cache\r\n" : "Cache-Control: max-age=60\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Connection: close\r\n\r\n"

        var payload = Data(header.utf8)
        if !omitBody { payload.append(body) }
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func contentType(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "mp4":  return "video/mp4"
        case "m4s":  return "video/iso.segment"
        default:     return "application/octet-stream"
        }
    }
}
