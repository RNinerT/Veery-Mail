import Foundation
import Network

/// Receives the OAuth redirect on 127.0.0.1 (RFC 8252 §7.3). Listens on a random port,
/// accepts one request for the expected path, answers with a short page, and stops.
public final class LoopbackRedirectListener: @unchecked Sendable {
    private let path: String
    private let queue = DispatchQueue(label: "veerymail.oauth.loopback")
    private var listener: NWListener?
    private var continuation: CheckedContinuation<URL, Error>?
    private var finished = false
    /// A redirect that arrived before anyone was waiting.
    private var early: URL?

    public init(path: String) { self.path = path }

    /// Starts listening and returns the port.
    public func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        params.acceptLocalOnly = true
        let listener = try NWListener(using: params)
        self.listener = listener
        return try await withCheckedThrowingContinuation { (ready: CheckedContinuation<UInt16, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    ready.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    resumed = true
                    ready.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        }
    }

    /// Waits for the browser to arrive at the redirect address.
    public func waitForCallback(timeout: TimeInterval = 600) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
                queue.async {
                    if let early = self.early {
                        self.finished = true
                        self.listener?.cancel()
                        c.resume(returning: early)
                        return
                    }
                    self.continuation = c
                    self.queue.asyncAfter(deadline: .now() + timeout) { self.finish(.failure(OAuthError.canceled)) }
                }
            }
        } onCancel: {
            queue.async { self.finish(.failure(OAuthError.canceled)) }
        }
    }

    public func stop() {
        queue.async { self.finish(.failure(OAuthError.canceled)) }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let target = request.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let port = self.listener?.port?.rawValue ?? 0
            let url = URL(string: "http://127.0.0.1:\(port)\(target)")
            let matches = request.hasPrefix("GET ") && url?.path == self.path
            let page = matches
                ? "<!doctype html><meta charset=utf-8><title>Veery Mail</title><body style=\"font:16px -apple-system;margin:3em\"><h2>You’re signed in</h2><p>You can close this tab and return to Veery Mail.</p>"
                : "<!doctype html><meta charset=utf-8><title>Not found</title>"
            let body = Data(page.utf8)
            let head = "HTTP/1.1 \(matches ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            if matches, let url { self.finish(.success(url)) }
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !finished else { return }
        guard let continuation else {
            if case .success(let url) = result { early = url; return }   // keep it for the waiter
            finished = true
            listener?.cancel()
            return
        }
        finished = true
        self.continuation = nil
        listener?.cancel()
        continuation.resume(with: result)
    }
}
