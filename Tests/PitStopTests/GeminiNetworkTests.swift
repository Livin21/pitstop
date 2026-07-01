import XCTest
@testable import PitStop

final class GeminiNetworkTests: XCTestCase {
    func testRefreshRequestIsGoogleForm() {
        let req = Gemini.refreshRequest(refreshToken: "R+T", client: Gemini.cliClient)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.absoluteString, "https://oauth2.googleapis.com/token")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let body = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("grant_type=refresh_token"))
        XCTAssertTrue(body.contains("refresh_token=R%2BT"))
        XCTAssertTrue(body.contains("client_id=\(Gemini.cliClient.id)"))
        XCTAssertTrue(body.contains("client_secret="))
    }

    func testQuotaRequestShape() {
        let req = Gemini.quotaRequest(accessToken: "AT", project: "proj-1")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.absoluteString,
                       "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer AT")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try! JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(body?["project"] as? String, "proj-1")
    }

    func testLoadCodeAssistRequestShape() {
        let req = Gemini.loadCodeAssistRequest(accessToken: "AT")
        XCTAssertEqual(req.url?.absoluteString,
                       "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer AT")
        let body = try! JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
        XCTAssertNotNil(body?["metadata"])
    }

    func testTwoClientsDiffer() {
        XCTAssertNotEqual(Gemini.cliClient.id, Gemini.antigravityClient.id)
        XCTAssertTrue(Gemini.antigravityClient.scopes.contains("cclog"))
    }
}
