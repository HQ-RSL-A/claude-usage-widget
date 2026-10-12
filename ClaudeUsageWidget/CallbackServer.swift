import Foundation
import Network

@MainActor
protocol CallbackServing: AnyObject {
    /// Binds 127.0.0.1 on a free port and returns it. Only a callback carrying `expectedState` is accepted.
    func start(expectedState: String) async throws -> UInt16
    /// The authorization code, as soon as the browser delivers it (possibly before this call), or .callbackTimeout.
    func waitForCode(timeout: TimeInterval) async throws -> String
    /// Stops listening; a pending waitForCode throws .signInCancelled.
    func stop()
}

/// One-shot HTTP listener for the OAuth redirect: GET /callback?code=&state= on 127.0.0.1.
@MainActor
final class CallbackServer: CallbackServing {
    private let queue = DispatchQueue(label: "io.rsla.ClaudeUsageWidget.callback")
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var expectedState = ""
    private var pendingCode: String?
    private var startContinuation: CheckedContinuation<UInt16, Error>?
    private var codeContinuation: CheckedContinuation<String, Error>?

    func start(expectedState: String) async throws -> UInt16 {
        self.expectedState = expectedState
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.listenerStateChanged(state) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            listener.start(queue: queue)
        }
    }

    func waitForCode(timeout: TimeInterval) async throws -> String {
        if let code = pendingCode {
            pendingCode = nil
            return code
        }
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.finishWaiting(with: .failure(ClaudeAPIError.callbackTimeout))
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            codeContinuation = continuation
        }
    }

    func stop() {
        finishWaiting(with: .failure(ClaudeAPIError.signInCancelled))
        pendingCode = nil
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }

    // MARK: - Listener

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            startContinuation?.resume(returning: listener?.port?.rawValue ?? 0)
            startContinuation = nil
        case .failed(let error):
            startContinuation?.resume(throwing: ClaudeAPIError.transport("Callback listener failed: \(error.localizedDescription)"))
            startContinuation = nil
            finishWaiting(with: .failure(ClaudeAPIError.transport("Callback listener failed")))
        default:
            break
        }
    }

    private func finishWaiting(with result: Result<String, Error>) {
        guard let continuation = codeContinuation else { return }
        codeContinuation = nil
        continuation.resume(with: result)
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let terminator = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    self.handle(head: String(decoding: buffer[..<terminator.lowerBound], as: UTF8.self), on: connection)
                } else if error != nil || isComplete || buffer.count >= 16_384 {
                    connection.cancel()
                } else {
                    self.read(connection, buffer: buffer)
                }
            }
        }
    }

    private func handle(head: String, on connection: NWConnection) {
        let requestLine = head.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")
        let target = parts.count >= 2 ? String(parts[1]) : "/"
        let components = URLComponents(string: "http://localhost\(target)")
        let path = components?.path ?? ""
        let query = components?.queryItems ?? []
        let code = query.first { $0.name == "code" }?.value ?? ""
        let state = query.first { $0.name == "state" }?.value

        guard path == "/callback" else {
            respond(connection, status: "404 Not Found", html: "<p>Not found.</p>")
            return
        }
        guard !code.isEmpty, state == expectedState else {
            respond(connection, status: "400 Bad Request", html: "<h2>Sign-in response did not match.</h2><p>Go back to the widget and try again.</p>")
            return
        }
        respond(connection, status: "200 OK", html: "<h2>Signed in to Claude Usage Widget.</h2><p>You can close this tab.</p>")
        if codeContinuation != nil {
            finishWaiting(with: .success(code))
        } else {
            pendingCode = code
        }
    }

    private func respond(_ connection: NWConnection, status: String, html: String) {
        let body = "<!doctype html><html><head><meta charset=\"utf-8\"><title>Claude Usage Widget</title></head><body style=\"font-family:-apple-system,sans-serif;padding:40px\">\(html)</body></html>"
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
