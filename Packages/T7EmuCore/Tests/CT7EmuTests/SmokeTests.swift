import XCTest
import CT7Emu

/// Proves the vendored T7Emu core compiles, links, and steps without
/// crashing on iOS's toolchain -- nothing more. A synthetic all-zero
/// "ROM" stands in for a real Tama-Go/Friends dump, which this project
/// never bundles (same policy as the app's existing device ROMs); running
/// an actual game needs a user-supplied dump, a later step.
final class SmokeTests: XCTestCase {
    func testCoreStepsWithoutCrashing() {
        // A 640 KB all-zero buffer: not a real firmware image (it does
        // nothing meaningful once running), just enough bytes for
        // t7_load_static_rom to accept as a Tama-Go-sized ROM.
        let rom = [UInt8](repeating: 0, count: 640 * 1024)

        let started = rom.withUnsafeBufferPointer { buf in
            ios_t7_start(buf.baseAddress, UInt32(buf.count))
        }
        XCTAssertTrue(started, "ios_t7_start should report success")

        for _ in 0..<2000 {
            _ = ios_t7_step_frame()
        }

        XCTAssertEqual(ios_t7_step_count(), 2000)
        ios_t7_stop()
    }
}
