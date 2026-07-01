import XCTest
@testable import PitStop

final class KeychainDehexTests: XCTestCase {
    private func hex(_ data: Data) -> Data {
        Data(data.map { String(format: "%02x", $0) }.joined().utf8)
    }

    func testDecodesHexOfPrettyJSON() {
        let pretty = Data("{\n  \"access_token\": \"AT\"\n}".utf8)
        XCTAssertEqual(Keychain.dehexed(hex(pretty)), pretty)
    }

    func testDecodesHexOfGoKeyringString() {
        let raw = Data("go-keyring-base64:aGVsbG8=".utf8)
        XCTAssertEqual(Keychain.dehexed(hex(raw)), raw)
    }

    func testPassesThroughPlainJSON() {
        let json = Data(#"{"access_token":"AT"}"#.utf8)
        XCTAssertEqual(Keychain.dehexed(json), json)
    }

    func testPassesThroughHexThatDecodesToGarbage() {
        let junk = Data("deadbeef".utf8)   // decodes to non-UTF8/non-JSON bytes
        XCTAssertEqual(Keychain.dehexed(junk), junk)
    }

    func testPassesThroughOddLengthAndEmpty() {
        XCTAssertEqual(Keychain.dehexed(Data("abc".utf8)), Data("abc".utf8))
        XCTAssertEqual(Keychain.dehexed(Data()), Data())
    }
}
