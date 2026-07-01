import XCTest
@testable import PitStop

final class LoopbackServerTests: XCTestCase {
    func testParseRequestLine() {
        let c = LoopbackServer.parse(requestLine: "GET /callback?code=ab%2Fc&state=xyz HTTP/1.1")
        XCTAssertEqual(c?.code, "ab/c")
        XCTAssertEqual(c?.state, "xyz")
        XCTAssertNil(LoopbackServer.parse(requestLine: "GET /favicon.ico HTTP/1.1"))
    }

    func testParsePastedFormats() {
        // Full redirect URL
        XCTAssertEqual(LoopbackServer.parsePasted(
            "https://platform.claude.com/oauth/code/callback?code=AAA&state=BBB")?.code, "AAA")
        // CODE#STATE
        let hash = LoopbackServer.parsePasted("AAA#BBB")
        XCTAssertEqual(hash?.code, "AAA"); XCTAssertEqual(hash?.state, "BBB")
        // urlencoded query fragment
        let q = LoopbackServer.parsePasted("code=AAA&state=BBB")
        XCTAssertEqual(q?.code, "AAA"); XCTAssertEqual(q?.state, "BBB")
        XCTAssertNil(LoopbackServer.parsePasted("   "))
    }

    func testRoundTrip() async throws {
        let srv = LoopbackServer()
        try srv.start(ports: [49260, 49261])
        defer { srv.stop() }
        XCTAssertGreaterThan(srv.port, 0)
        let waiter = Task { try await srv.waitForCallback(timeout: 5) }
        _ = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(srv.port)/callback?code=THECODE&state=THESTATE")!)
        let cap = try await waiter.value
        XCTAssertEqual(cap.code, "THECODE")
        XCTAssertEqual(cap.state, "THESTATE")
    }

    func testPortFallbackWhenBusy() throws {
        let hog = LoopbackServer(); try hog.start(ports: [49270]); defer { hog.stop() }
        let srv = LoopbackServer(); try srv.start(ports: [49270, 49271]); defer { srv.stop() }
        XCTAssertEqual(srv.port, 49271)
    }

    func testClassifyRequestLine() {
        if case .captured(let cap) = LoopbackServer.classify(requestLine: "GET /cb?code=C&state=S HTTP/1.1") {
            XCTAssertEqual(cap.code, "C")
        } else { XCTFail("expected captured") }
        if case .denied = LoopbackServer.classify(requestLine: "GET /cb?error=access_denied&state=S HTTP/1.1") {
        } else { XCTFail("expected denied") }
        if case .notCallback = LoopbackServer.classify(requestLine: "GET /favicon.ico HTTP/1.1") {
        } else { XCTFail("expected notCallback") }
    }

    func testStrayRequestDoesNotConsumeTheCallback() async throws {
        let srv = LoopbackServer(); try srv.start(ports: [49290, 49291]); defer { srv.stop() }
        let waiter = Task { try await srv.waitForCallback(timeout: 5) }
        _ = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(srv.port)/favicon.ico")!)
        _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(srv.port)/callback?code=C&state=S")!)
        let cap = try await waiter.value
        XCTAssertEqual(cap.code, "C")
    }

    func testDeniedCallbackThrowsCancelled() async throws {
        let srv = LoopbackServer(); try srv.start(ports: [49295, 49296]); defer { srv.stop() }
        let waiter = Task { try await srv.waitForCallback(timeout: 5) }
        _ = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(srv.port)/callback?error=access_denied&state=S")!)
        do { _ = try await waiter.value; XCTFail("expected cancelled") }
        catch LoginError.cancelled { /* expected */ }
    }

    func testSilentConnectionIsIgnored() async throws {
        let old = LoopbackServer.clientReadTimeoutMs
        LoopbackServer.clientReadTimeoutMs = 200
        defer { LoopbackServer.clientReadTimeoutMs = old }
        let srv = LoopbackServer(); try srv.start(ports: [49297, 49298]); defer { srv.stop() }
        let waiter = Task { try await srv.waitForCallback(timeout: 5) }
        // A preconnect-style socket that never sends a byte.
        let s = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = srv.port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        defer { close(s) }
        try await Task.sleep(nanoseconds: 300_000_000)
        _ = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(srv.port)/callback?code=C2&state=S2")!)
        let cap = try await waiter.value
        XCTAssertEqual(cap.code, "C2")
    }

    func testTimeoutThrows() async throws {
        let srv = LoopbackServer(); try srv.start(ports: [49280]); defer { srv.stop() }
        do {
            _ = try await srv.waitForCallback(timeout: 0.3)
            XCTFail("expected timeout")
        } catch { /* expected */ }
    }
}
