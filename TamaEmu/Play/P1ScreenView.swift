import SwiftUI

/// The P1-era screen, styled to match the real 1997 hardware: a chunky
/// monochrome 32x16 matrix on a yellow-green LCD, in a dark bezel, with
/// the 8 fixed status icons below it. Chosen over a modern-chrome
/// treatment after reviewing mockups of both -- see the
/// integration-research memory.
struct P1ScreenView: View {
    let state: P1ScreenState

    private let lcdTint = Color(red: 0.624, green: 0.682, blue: 0.510)
    private let onColor = Color(red: 0.169, green: 0.165, blue: 0.157)
    private let bezelColor = Color(red: 0.169, green: 0.165, blue: 0.157)

    var body: some View {
        VStack(spacing: 6) {
            pixelGrid
                .aspectRatio(32.0 / 16.0, contentMode: .fit)
                .padding(6)
                .background(lcdTint)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            HStack {
                ForEach(0..<8, id: \.self) { i in
                    Circle()
                        .fill(state.icons[i] ? bezelColor : bezelColor.opacity(0.4))
                        .frame(width: 5, height: 5)
                    if i < 7 { Spacer() }
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(EdgeInsets(top: 14, leading: 12, bottom: 10, trailing: 12))
        .background(bezelColor)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var pixelGrid: some View {
        GeometryReader { geo in
            if let image = makeBitmapImage() {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    private func makeBitmapImage() -> CGImage? {
        let w = 32, h = 16
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let on = (UInt8(43), UInt8(42), UInt8(40))
        let off = lcdTint.rgbaBytes()
        for y in 0..<h {
            for x in 0..<w {
                let c = state.pixel(x, y) ? on : off
                let i = (y * w + x) * 4
                pixels[i] = c.0
                pixels[i + 1] = c.1
                pixels[i + 2] = c.2
                pixels[i + 3] = 255
            }
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        return context.makeImage()
    }
}

private extension Color {
    func rgbaBytes() -> (UInt8, UInt8, UInt8) {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (UInt8(r * 255), UInt8(g * 255), UInt8(b * 255))
    }
}

#Preview {
    P1ScreenView(state: .blank)
        .padding()
}
