//
// OAuthLoopbackListener.swift — one-shot HTTP server bound to
// 127.0.0.1:{ephemeral-port} that captures the OAuth redirect.
//
// Why loopback (vs custom URL scheme):
//   • RFC 8252 §7.3 recommends loopback for desktop apps.
//   • Loopback ports can't be hijacked by another app on the same
//     machine; only the process that bound the port receives the
//     callback.
//   • Custom URL schemes (`diskjockey://`) on macOS can be claimed
//     by any other app's Info.plist — even with PKCE saving us from
//     token theft, a hijacker can DoS the sign-in.
//
// Lifecycle:
//   1. `start()` binds a random port via `NWListener` (port=0 →
//      OS picks). On the first inbound TCP connection, we accept it,
//      parse the HTTP request line for the redirect path, and pull
//      the `code` and `state` query params off it.
//   2. Reply with a tiny HTML page so the user sees confirmation in
//      their browser instead of "the page can't be loaded".
//   3. Tear the listener down and resolve the awaiting continuation
//      with the captured params (or an error).
//
// Designed for one round-trip then gone — there's nothing to
// reconnect to once the auth code is in hand.
//

import Foundation
import Network

/// What the listener returns to the awaiting OAuth coordinator.
public struct OAuthCallback: Sendable {
    public let code: String
    public let state: String
}

public enum OAuthLoopbackError: Error, LocalizedError {
    case timedOut
    case missingCode
    case providerError(code: String, description: String?)
    case bindFailed(underlying: Error)
    case parseFailed
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .timedOut:
            return "The browser didn't return to DiskJockey within 5 minutes."
        case .missingCode:
            return "OAuth provider didn't return an authorization code."
        case .providerError(let code, let desc):
            return "Authorization failed: \(code)\(desc.map { " — \($0)" } ?? "")"
        case .bindFailed(let e):
            return "Couldn't bind a local port for the OAuth callback: \(e.localizedDescription)"
        case .parseFailed:
            return "OAuth callback was malformed."
        case .cancelled:
            return "OAuth flow was cancelled."
        }
    }
}

final class OAuthLoopbackListener {
    /// Resolves once the listener has either captured a callback or
    /// errored out. Single-shot — the listener tears itself down on
    /// either path.
    private var continuation: CheckedContinuation<OAuthCallback, Error>?
    private var listener: NWListener?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.antimatterstudios.diskjockey.oauth.loopback")
    private var timeoutWork: DispatchWorkItem?
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 300) {
        self.timeout = timeout
    }

    /// Bind, return the chosen port, and asynchronously deliver the
    /// captured `OAuthCallback`. Caller composes the authorize URL
    /// with `redirect_uri=http://127.0.0.1:{port}` and opens the
    /// browser; the await resumes when the browser hits us.
    func start() async throws -> (port: UInt16, callback: Task<OAuthCallback, Error>) {
        let port = try await bind()
        let task = Task<OAuthCallback, Error> {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<OAuthCallback, Error>) in
                self.continuation = cont
                self.armTimeout()
            }
        }
        return (port, task)
    }

    func cancel() {
        finish(.failure(OAuthLoopbackError.cancelled))
    }

    // MARK: - Binding

    /// Bring the listener to `.ready` and return the OS-assigned
    /// loopback port. We wait on `stateUpdateHandler` instead of
    /// polling `listener.port` because `port` reads as `nil` (or
    /// the placeholder `0`) until binding completes — NWListener
    /// publishes the real port via the state update.
    private func bind() async throws -> UInt16 {
        let params = NWParameters.tcp
        // Loopback only — never accept off-machine connections.
        params.requiredInterfaceType = .loopback

        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: .any)
        } catch {
            throw OAuthLoopbackError.bindFailed(underlying: error)
        }

        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }

        self.listener = listener

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            // The continuation is resumed exactly once: either when
            // the listener reaches `.ready` (success) or `.failed`
            // (bind error). After that we install a no-op state
            // handler so post-bind state changes (cancel etc.)
            // don't try to resume a dead continuation.
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    if let p = listener.port?.rawValue {
                        resumed = true
                        listener.stateUpdateHandler = { [weak self] s in
                            if case .failed(let err) = s {
                                self?.finish(.failure(OAuthLoopbackError.bindFailed(underlying: err)))
                            }
                        }
                        cont.resume(returning: p)
                    }
                case .failed(let err):
                    resumed = true
                    cont.resume(throwing: OAuthLoopbackError.bindFailed(underlying: err))
                default:
                    break
                }
            }
            listener.start(queue: self.queue)
        }
    }

    // MARK: - Connection handling

    private func handle(_ conn: NWConnection) {
        // Reject any extra connection beyond the first; we only ever
        // need one round-trip.
        if connection != nil {
            conn.cancel()
            return
        }
        connection = conn
        conn.start(queue: queue)
        receive(on: conn, accumulator: Data())
    }

    private func receive(on conn: NWConnection, accumulator: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let error = error {
                self.finish(.failure(OAuthLoopbackError.bindFailed(underlying: error)))
                return
            }
            var buffer = accumulator
            if let data = data { buffer.append(data) }

            // We only need the request line + headers — body is
            // empty for the GET callback. End of headers = `\r\n\r\n`.
            if let endOfHeaders = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = buffer.subdata(in: 0..<endOfHeaders.lowerBound)
                self.parseAndRespond(headData: head, on: conn)
                return
            }

            // Defensive cap: even a long URL shouldn't push us past
            // a few KB. Bail if a misbehaving client streams forever.
            if buffer.count > 32 * 1024 {
                self.respondAndClose(conn: conn, status: 400, body: "request too large")
                self.finish(.failure(OAuthLoopbackError.parseFailed))
                return
            }
            if isComplete {
                self.finish(.failure(OAuthLoopbackError.parseFailed))
                return
            }
            self.receive(on: conn, accumulator: buffer)
        }
    }

    private func parseAndRespond(headData: Data, on conn: NWConnection) {
        guard let head = String(data: headData, encoding: .utf8),
              let firstLine = head.components(separatedBy: "\r\n").first else {
            respondAndClose(conn: conn, status: 400, body: "bad request")
            finish(.failure(OAuthLoopbackError.parseFailed))
            return
        }
        // "GET /?code=...&state=... HTTP/1.1"
        let parts = firstLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            respondAndClose(conn: conn, status: 400, body: "bad request")
            finish(.failure(OAuthLoopbackError.parseFailed))
            return
        }
        let target = String(parts[1])
        let queryString: String
        if let q = target.firstIndex(of: "?") {
            queryString = String(target[target.index(after: q)...])
        } else {
            queryString = ""
        }
        let params = parseQuery(queryString)

        // Provider-side error — `?error=access_denied&error_description=...`.
        if let err = params["error"] {
            respondAndClose(conn: conn, status: 200,
                            body: htmlPage(title: "Authorization failed",
                                           message: "You can close this tab and return to DiskJockey."))
            finish(.failure(OAuthLoopbackError.providerError(
                code: err,
                description: params["error_description"]
            )))
            return
        }

        guard let code = params["code"], !code.isEmpty,
              let state = params["state"], !state.isEmpty else {
            respondAndClose(conn: conn, status: 400,
                            body: htmlPage(title: "OAuth callback was missing parameters",
                                           message: "DiskJockey didn't receive an authorization code."))
            finish(.failure(OAuthLoopbackError.missingCode))
            return
        }

        respondAndClose(conn: conn, status: 200,
                        body: htmlPage(title: "Signed in to DiskJockey",
                                       message: "You can close this tab and return to the app."))
        finish(.success(OAuthCallback(code: code, state: state)))
    }

    private func respondAndClose(conn: NWConnection, status: Int, body: String) {
        let reason = (status == 200) ? "OK" : "Bad Request"
        let bytes = Data(body.utf8)
        let response = """
        HTTP/1.1 \(status) \(reason)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(bytes.count)\r
        Connection: close\r
        \r

        """
        var data = Data(response.utf8)
        data.append(bytes)
        conn.send(content: data, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func htmlPage(title: String, message: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>\(title)</title>
        <style>body{font-family:-apple-system,sans-serif;max-width:640px;margin:80px auto;padding:0 24px;color:#222}h1{font-size:20px}p{color:#555}</style>
        </head><body><h1>\(title)</h1><p>\(message)</p></body></html>
        """
    }

    private func parseQuery(_ s: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in s.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let v = kv.count > 1
                ? (String(kv[1]).removingPercentEncoding ?? String(kv[1]))
                : ""
            result[k] = v
        }
        return result
    }

    // MARK: - Lifecycle

    private func armTimeout() {
        let work = DispatchWorkItem { [weak self] in
            self?.finish(.failure(OAuthLoopbackError.timedOut))
        }
        timeoutWork = work
        queue.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    /// Resolve the awaiting continuation exactly once and tear the
    /// listener down. Idempotent — repeat calls are no-ops.
    private func finish(_ result: Result<OAuthCallback, Error>) {
        timeoutWork?.cancel()
        timeoutWork = nil
        let cont = continuation
        continuation = nil
        listener?.cancel()
        listener = nil
        connection?.cancel()
        connection = nil
        guard let cont = cont else { return }
        switch result {
        case .success(let cb): cont.resume(returning: cb)
        case .failure(let err): cont.resume(throwing: err)
        }
    }
}
