import Foundation
import Darwin

/// One-shot loopback HTTP server on a raw BSD socket, bound to `127.0.0.1`.
/// Captures the first `GET …?code=…&state=…`, replies 200, yields it.
///
/// Raw sockets (not Network.framework) because `NWListener` fails to bind in
/// some environments, and a short-lived localhost OAuth callback needs exactly
/// this and nothing more.
final class LoopbackServer {
    struct Captured { let code: String; let state: String }
    struct ServerError: LocalizedError {
        let msg: String
        var errorDescription: String? { msg }
    }

    private var fd: Int32 = -1
    private(set) var port: UInt16 = 0

    /// Parse an HTTP request line's query. Pure.
    static func parse(requestLine: String) -> Captured? {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2,
              let query = parts[1].split(separator: "?").dropFirst().first else { return nil }
        return captured(fromQuery: String(query))
    }

    /// Parse a value the user pasted from claude.ai's callback page. Accepts a
    /// full redirect URL, a "CODE#STATE" string, or a "code=…&state=…" query.
    static func parsePasted(_ input: String) -> Captured? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let comps = URLComponents(string: s), comps.scheme != nil,
           let cap = captured(fromItems: comps.queryItems) { return cap }
        if s.contains("#") {
            let hs = s.split(separator: "#", maxSplits: 1)
            if hs.count == 2 {
                let code = String(hs[0]), state = String(hs[1])
                return Captured(code: code.removingPercentEncoding ?? code,
                                state: state.removingPercentEncoding ?? state)
            }
        }
        return captured(fromQuery: s)
    }

    private static func captured(fromQuery query: String) -> Captured? {
        var code: String?, state: String?
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let v = kv[1].removingPercentEncoding ?? String(kv[1])
            if kv[0] == "code" { code = v } else if kv[0] == "state" { state = v }
        }
        guard let code, let state else { return nil }
        return Captured(code: code, state: state)
    }

    private static func captured(fromItems items: [URLQueryItem]?) -> Captured? {
        guard let items else { return nil }
        guard let code = items.first(where: { $0.name == "code" })?.value,
              let state = items.first(where: { $0.name == "state" })?.value else { return nil }
        return Captured(code: code, state: state)
    }

    /// What one HTTP request means to the OAuth wait loop.
    enum CallbackOutcome {
        case captured(Captured)
        case denied          // OAuth error redirect (?error=access_denied&…)
        case notCallback     // favicon, probes — answer 404 and keep waiting
    }

    static func classify(requestLine: String) -> CallbackOutcome {
        if let cap = parse(requestLine: requestLine) { return .captured(cap) }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2,
              let query = parts[1].split(separator: "?").dropFirst().first else { return .notCallback }
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == "error" { return .denied }
        }
        return .notCallback
    }

    /// Bind the first available loopback port in `ports`.
    func start(ports: [UInt16]) throws {
        for p in ports {
            let s = socket(AF_INET, SOCK_STREAM, 0)
            guard s >= 0 else { continue }
            var yes: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = p.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bound == 0, listen(s, 16) == 0 { fd = s; port = p; return }
            close(s)
        }
        throw ServerError(msg: "No free loopback port in \(ports)")
    }

    /// How long an accepted connection gets to send its request. Short: the
    /// real redirect sends immediately; browser preconnect sockets never do,
    /// and each one holds up the accept loop for this long. Test seam.
    static var clientReadTimeoutMs: Int32 = 3000

    /// Await the redirect callback. Accepts (and answers) any number of stray
    /// connections — browser preconnects, favicon fetches — until a parseable
    /// callback arrives; an OAuth error redirect (user denied) throws
    /// `LoginError.cancelled`. Uses `poll()` with a deadline so the timeout
    /// path never leaves a thread blocked in `accept()` — a task-group race with
    /// a blocking accept deadlocks, because the group awaits the (still-blocked)
    /// accept child before it can return the timeout.
    func waitForCallback(timeout: TimeInterval) async throws -> Captured {
        let listenFD = fd
        guard listenFD >= 0 else { throw ServerError(msg: "Loopback server not started") }
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let deadline = Date().addingTimeInterval(timeout)
                while true {
                    let remaining = deadline.timeIntervalSinceNow
                    guard remaining > 0 else {
                        cont.resume(throwing: ServerError(msg: "Timed out waiting for the browser")); return
                    }
                    var pfd = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
                    let pr = poll(&pfd, 1, Int32(remaining * 1000))
                    if pr == 0 {
                        cont.resume(throwing: ServerError(msg: "Timed out waiting for the browser")); return
                    }
                    if pr < 0 {
                        if errno == EINTR { continue }   // signal (e.g. SIGCHLD) — keep waiting
                        cont.resume(throwing: ServerError(msg: "poll failed (errno \(errno))")); return
                    }
                    if (pfd.revents & Int16(POLLIN)) == 0 {
                        cont.resume(throwing: ServerError(msg: "Loopback socket closed")); return
                    }
                    let client = accept(listenFD, nil, nil)
                    guard client >= 0 else {
                        if errno == EINTR || errno == ECONNABORTED { continue }
                        cont.resume(throwing: ServerError(msg: "accept failed (errno \(errno))")); return
                    }
                    switch Self.handleClient(client) {
                    case .captured(let cap): cont.resume(returning: cap); return
                    case .denied: cont.resume(throwing: LoginError.cancelled); return
                    case .notCallback: continue
                    }
                }
            }
        }
    }

    /// Read one request from an accepted connection, answer it, classify it.
    /// A connection that never sends (browser preconnect) counts as notCallback.
    private static func handleClient(_ client: Int32) -> CallbackOutcome {
        defer { close(client) }
        var cpfd = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
        var cpr = poll(&cpfd, 1, clientReadTimeoutMs)
        while cpr < 0 && errno == EINTR { cpr = poll(&cpfd, 1, clientReadTimeoutMs) }
        guard cpr > 0, (cpfd.revents & Int16(POLLIN)) != 0 else { return .notCallback }
        var buf = [UInt8](repeating: 0, count: 8192)
        let n = read(client, &buf, buf.count)
        guard n > 0, let text = String(bytes: buf[0..<n], encoding: .utf8) else { return .notCallback }
        let outcome = classify(requestLine: text.components(separatedBy: "\r\n").first ?? "")
        switch outcome {
        case .captured: respond(client, status: "200 OK",
                                body: "You can close this tab and return to PitStop.")
        case .denied: respond(client, status: "200 OK",
                              body: "Sign-in was cancelled. You can close this tab.")
        case .notCallback: respond(client, status: "404 Not Found",
                                   body: "PitStop is waiting for the sign-in callback.")
        }
        return outcome
    }

    private static func respond(_ client: Int32, status: String, body: String) {
        let resp = "HTTP/1.1 \(status)\r\nContent-Type: text/plain\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        _ = resp.withCString { write(client, $0, strlen($0)) }
    }

    func stop() {
        if fd >= 0 { close(fd); fd = -1 }
    }
}
