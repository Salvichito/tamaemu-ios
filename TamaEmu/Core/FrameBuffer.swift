import CoreGraphics
import Foundation

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
