import CoreGraphics
import Foundation

/// Shared screen-image prep for anything that asks a model to read the
/// LCD's text. Every device this core currently emulates (Plus Color,
/// ID/4U) shares the same layout: a strip of stat icons along the top and
/// bottom, with the actual readable text centered in a box in the middle —
/// those icon strips cost a model's visual budget without giving it
/// anything to read. Fixed fractions, not pixel constants, so this holds
/// regardless of source resolution. Not device-aware — if a future device
/// family uses a different layout, this will need to become
/// device-specific, or fall back to the uncropped frame for it.
enum ScreenImagePrep {
    static func croppedToTextArea(_ cgImage: CGImage) -> CGImage? {
        let height = CGFloat(cgImage.height)
        let margin = (height * 0.15).rounded()
        let cropRect = CGRect(x: 0, y: margin, width: CGFloat(cgImage.width), height: height - margin * 2)
        return cgImage.cropping(to: cropRect)
    }

    /// Nearest-neighbor (no blur) upscale of the cropped text area — the
    /// raw framebuffer has no scanline/glass effect baked in (that's a
    /// separate Canvas overlay LCDView draws at display time only), so
    /// this keeps the glyphs as clean as possible for a model to read,
    /// independent of the user's own display-effect settings.
    static func textAreaUpscaled(_ cgImage: CGImage, scale: Int = 4) -> CGImage? {
        guard let cropped = croppedToTextArea(cgImage) else { return nil }
        let width = cropped.width * scale
        let height = cropped.height * scale
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
