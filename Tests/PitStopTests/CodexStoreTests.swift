import XCTest
@testable import PitStop

final class CodexStoreTests: XCTestCase {
    func testPreservingAPIKeyMergesFromLive() {
        let live = try! JSONSerialization.data(withJSONObject: ["OPENAI_API_KEY": "sk-live"])
        let saved = try! JSONSerialization.data(withJSONObject:
            ["tokens": ["access_token": "AT", "account_id": "acc", "id_token": "x.y.z"]])
        let merged = Codex.preservingAPIKey(from: live, into: saved)
        let root = try! JSONSerialization.jsonObject(with: merged) as! [String: Any]
        XCTAssertEqual(root["OPENAI_API_KEY"] as? String, "sk-live")
        XCTAssertNotNil(root["tokens"])
    }

    func testPreservingAPIKeyNoopWithoutLiveKey() {
        let live = try! JSONSerialization.data(withJSONObject: ["tokens": ["access_token": "A"]])
        let saved = Data(#"{"tokens":{"access_token":"B"}}"#.utf8)
        XCTAssertEqual(Codex.preservingAPIKey(from: live, into: saved), saved)
        XCTAssertEqual(Codex.preservingAPIKey(from: nil, into: saved), saved)
    }

    func testPreservingAPIKeyDoesNotOverwriteSavedKey() {
        let live = try! JSONSerialization.data(withJSONObject: ["OPENAI_API_KEY": "sk-live"])
        let saved = try! JSONSerialization.data(withJSONObject: ["OPENAI_API_KEY": "sk-saved"])
        let root = try! JSONSerialization.jsonObject(
            with: Codex.preservingAPIKey(from: live, into: saved)) as! [String: Any]
        XCTAssertEqual(root["OPENAI_API_KEY"] as? String, "sk-saved")
    }
}
