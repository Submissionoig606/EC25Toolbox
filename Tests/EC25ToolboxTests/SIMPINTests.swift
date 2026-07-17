import XCTest
@testable import EC25Toolbox

final class SIMPINTests: XCTestCase {
    func testRenamedKeychainServiceKeepsLegacyMigrationSource() {
        XCTAssertEqual(SIMPINKeychain.service, "ing.fuyaoskyrocket.ec25toolbox.sim-pin")
        XCTAssertEqual(SIMPINKeychain.legacyServices, ["one.nickspace.ec25-manager.sim-pin"])
    }

    func testPINValidation() throws {
        XCTAssertEqual(try normalizedSIMPIN("1234"), "1234")
        XCTAssertEqual(try normalizedSIMPIN(" 12345678 "), "12345678")
        XCTAssertThrowsError(try normalizedSIMPIN("123"))
        XCTAssertThrowsError(try normalizedSIMPIN("123456789"))
        XCTAssertThrowsError(try normalizedSIMPIN("12A4"))
        XCTAssertThrowsError(try normalizedSIMPIN("１２３４"))
        XCTAssertThrowsError(try normalizedSIMPIN("1234\""))
    }

    func testSIMStatusParsing() {
        XCTAssertEqual(parseSIMStatus(["+CPIN: READY"]), "READY")
        XCTAssertEqual(parseSIMStatus(["+CPIN: SIM PIN"]), "SIM PIN")
        XCTAssertEqual(parseSIMStatus([]), "-")
    }

    func testSIMLockAndRetryParsing() {
        XCTAssertEqual(parseSIMLockEnabled(["+CLCK: 1"]), true)
        XCTAssertEqual(parseSIMLockEnabled(["+CLCK: 0"]), false)
        XCTAssertNil(parseSIMLockEnabled([]))

        let retries = parseSIMRetries(["+QPINC: \"SC\",3,10"])
        XCTAssertEqual(retries.pin, 3)
        XCTAssertEqual(retries.puk, 10)
    }

    func testICCIDNormalizationAndKeychainAccount() {
        let iccid = normalizedSIMICCID(["+QCCID: 89860012345678901234"])
        XCTAssertEqual(iccid, "89860012345678901234")
        XCTAssertEqual(SIMPINKeychain.account(for: "8986 0012-3456"), "898600123456")
    }

    func testOldSettingsPayloadDecodesWithoutSIMPINKey() throws {
        let json = #"""
        {
          "openAtLogin": true,
          "infoPollSeconds": 12,
          "smsPollSeconds": 30,
          "restartOnWake": true,
          "preferredLanguage": null,
          "visibleFields": ["imei"]
        }
        """#

        let settings = try JSONDecoder().decode(ModemSettings.self, from: Data(json.utf8))
        XCTAssertNil(settings.simAutoUnlock)
    }
}
