import CoreImage
import SwiftUI
import UIKit

extension CGImage {
    /// Reused across every call — a `CIContext` sets up its own Metal
    /// pipeline, which Apple's own guidance says to create once and share
    /// rather than rebuild per render.
    private static let glowContext = CIContext(options: [.workingColorSpace: NSNull()])

    /// A single representative color for this frame, boosted toward its own
    /// most saturated hue rather than a flat average — a plain average over
    /// a multi-color LCD scene tends toward a muddy grey/brown that reads as
    /// "no color" rather than "this screen's color". Used for the play
    /// screen's ambient glow; `nil` when the frame is too flat/dark to read
    /// as a real color, so callers can fall back to a plain white glow.
    func vividGlowColor() -> Color? {
        let ciImage = CIImage(cgImage: self)
        guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: ciImage.extent), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        Self.glowContext.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        let uiColor = UIColor(
            red: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
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
