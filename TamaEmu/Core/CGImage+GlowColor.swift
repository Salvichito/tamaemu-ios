import CoreGraphics
import SwiftUI
import UIKit

extension CGImage {
    /// A single representative color for this frame, boosted toward its own
    /// most saturated hue rather than a flat average — a plain average over
    /// a multi-color LCD scene tends toward a muddy grey/brown that reads as
    /// "no color" rather than "this screen's color". Used for the play
    /// screen's ambient glow; `nil` when the frame is too flat/dark to read
    /// as a real color, so callers can fall back to a plain white glow.
    ///
    /// This runs once per genuine pixel change on the live LCD — which,
    /// between idle animation and normal play, is often — so it's a plain
    /// CPU downsample (one `CGContext.draw` into a 1×1 bitmap, letting
    /// Core Graphics' own interpolation average the image) rather than a
    /// Core Image filter graph. The previous version built a `CIImage`
    /// and ran a `CIAreaAverage` filter through a `CIContext`, which spins
    /// up a Metal render pass for every call — measurable GPU work for a
    /// single averaged pixel, happening continuously just from the Tama
    /// sitting there idling. A `CGContext` this tiny never touches the
    /// GPU at all.
    func vividGlowColor() -> Color? {
        guard let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(self, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let data = context.data else { return nil }
        let pixel = data.assumingMemoryBound(to: UInt8.self)

        // byteOrder32Little + noneSkipFirst lays the word out in memory as
        // B, G, R, (skipped alpha byte) — same convention LCDImageBuilder
        // itself uses to build these frames.
        let uiColor = UIColor(
            red: CGFloat(pixel[2]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[0]) / 255,
            alpha: 1
        )
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        uiColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        guard saturation > 0.12, brightness > 0.1 else { return nil }

        let vivid = UIColor(
            hue: hue,
            saturation: min(1, saturation * 1.6),
            brightness: min(1, max(brightness, 0.55) * 1.1),
            alpha: 1
        )
        return Color(vivid)
    }
}
