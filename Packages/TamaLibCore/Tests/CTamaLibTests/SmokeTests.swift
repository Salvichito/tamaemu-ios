import XCTest
import CTamaLib

/// Proves the vendored TamaLib core compiles, links, and steps without
/// crashing on iOS's toolchain -- nothing more. A synthetic all-zero
/// "ROM" stands in for a real Tamagotchi P1 dump, which this project never
/// bundles (same policy as the app's existing device ROMs); running an
/// actual game needs a user-supplied dump, a later step.
final class SmokeTests: XCTestCase {
    func testCoreStepsWithoutCrashing() {
        let program = [UInt16](repeating: 0, count: 4096)
        let started = program.withUnsafeBufferPointer { buf in
            ios_hal_start(buf.baseAddress, UInt32(buf.count))
        }
        XCTAssertEqual(started, 0, "tamalib_init should report success")

        for _ in 0..<2000 {
            ios_hal_step()
        }

        XCTAssertEqual(ios_hal_step_count(), 2000)
        ios_hal_stop()
    }
}
