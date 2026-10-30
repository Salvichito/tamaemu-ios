import CoreGraphics
import Foundation
import os

/// Builds a CGImage from an RGBA8888 (0xAARRGGBB-per-word) pixel buffer,
/// the exact format `lcd_render` in the C core writes.
enum LCDImageBuilder {
    static func makeImage(from buffer: [UInt32], width: Int, height: Int) -> CGImage? {
        let data = buffer.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

/// Lock-guarded handoff of the latest framebuffer from the emulator thread
/// to whichever thread reads it for display. Writer and reader never block
/// each other for more than the time of a 64KB copy.
final class FrameStore: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var buffer: [UInt32]
    private var changeCounter: UInt64 = 0
    private var lastRead: UInt64 = 0

    init(width: Int, height: Int) {
        buffer = [UInt32](repeating: 0xFF000000, count: width * height)
    }

    /// Only bumps `changeCounter` when the pixels actually differ from the
    /// last write — `runLoop()` calls this every emulated frame (60Hz)
    /// regardless of whether anything visibly changed, and this display is
    /// mostly static (a watch LCD, not video), so without this check the
    /// display timer would rebuild a CGImage and redraw the whole LCDView
    /// (including the scanline/glare Canvas overlay) 60 times a second even
    /// while the Tama is just sitting idle on screen — real, needless
    /// CPU/GPU work for a picture that hasn't moved.
    func write(_ newBuffer: [UInt32]) {
        withUnsafeMutablePointer(to: &lock) { os_unfair_lock_lock($0) }
        if newBuffer != buffer {
            buffer = newBuffer
            changeCounter &+= 1
        }
        withUnsafeMutablePointer(to: &lock) { os_unfair_lock_unlock($0) }
    }

    /// Returns the latest frame only if it changed since the last call.
    func readIfChanged() -> [UInt32]? {
        withUnsafeMutablePointer(to: &lock) { os_unfair_lock_lock($0) }
        defer { withUnsafeMutablePointer(to: &lock) { os_unfair_lock_unlock($0) } }
        guard changeCounter != lastRead else { return nil }
        lastRead = changeCounter
        return buffer
    }
}
