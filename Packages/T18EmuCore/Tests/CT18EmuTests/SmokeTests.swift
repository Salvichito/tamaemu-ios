import CT18Emu
import XCTest

final class SmokeTests: XCTestCase {
    func testRejectsNonFirmware() {
        let junk = [UInt8](repeating: 0, count: 16)
        XCTAssertFalse(ios_t18_is_firmware(junk, UInt32(junk.count)))
        XCTAssertFalse(ios_t18_start(junk, UInt32(junk.count)))
    }
}
