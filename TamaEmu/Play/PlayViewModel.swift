import CoreGraphics
import Observation
import TamaCore

@MainActor
@Observable
final class PlayViewModel {
    private(set) var lcdImage: CGImage?
    private(set) var deviceSummary: String = ""

    init() {
        // M0: prove the Swift <-> C bridge works end to end.
        let devices = DeviceCatalog.all()
        deviceSummary = "\(devices.count) devices: " + devices.map(\.id).joined(separator: ", ")

        // M1: push a hand-built test pattern through the exact pixel
        // pipeline lcd_render's real output will later use, in isolation
        // from cpu_step/the real firmware.
        lcdImage = LCDImageBuilder.makeImage(
            from: Self.testPattern(width: 128, height: 128),
            width: 128,
            height: 128
        )
    }

    /// Eight vertical color bars in the same 0xAARRGGBB word format
    /// `lcd_render` writes. Stand-in for a real framebuffer until M3 wires
    /// up the actual emulator loop.
    private static func testPattern(width: Int, height: Int) -> [UInt32] {
        let bars: [UInt32] = [
            0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0xFFFFFFFF,
            0xFF000000, 0xFFFFFF00, 0xFF00FFFF, 0xFFFF00FF
        ]
        var buffer = [UInt32](repeating: 0, count: width * height)
        let barWidth = max(1, width / bars.count)
        for y in 0..<height {
            for x in 0..<width {
                buffer[y * width + x] = bars[min(x / barWidth, bars.count - 1)]
            }
        }
        return buffer
    }
}
