import SwiftUI

/// The retro screen (Tomomix settings): big pixels and dark scan lines
/// between the rows, like an old low-resolution screen. iOS draws the
/// screen at about 96 pixels across and blows it up without smoothing,
/// plus a still overlay of lines: no per-frame work of our own.
struct TomoRetroScreen: ViewModifier {
    static let settingKey = "tomomix.retroScreen"
    let enabled: Bool
    let side: CGFloat

    /// The same dot grid as the color Tamas' 128×128 screens.
    private static let pixelsAcross: CGFloat = 128

    func body(content: Content) -> some View {
        if enabled, side > 0 {
            // Skies switch to flat color bands (TomoSky), so nothing gets
            // dithered when it's blown up into big pixels.
            LowResolution(content: content.environment(\.tomoRetro, true),
                          pixelsPerPoint: Self.pixelsAcross / side)
                // Exactly the other Tamas' scanlines and glass sheen.
                .lcdScreenEffect(rows: Self.pixelsAcross)
        } else {
            content
        }
    }
}

private struct TomoRetroKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Inside the Retro Screen: draw flat colors, no smooth gradients.
    var tomoRetro: Bool {
        get { self[TomoRetroKey.self] }
        set { self[TomoRetroKey.self] = newValue }
    }
}

/// Hosts a view in a layer that iOS renders at a low resolution and
/// scales up with "nearest" filtering: hard square pixels.
private struct LowResolution<Content: View>: UIViewControllerRepresentable {
    let content: Content
    let pixelsPerPoint: CGFloat

    func makeUIViewController(context: Context) -> UIHostingController<Content> {
        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        host.view.layer.shouldRasterize = true
        host.view.layer.rasterizationScale = pixelsPerPoint
        host.view.layer.magnificationFilter = .nearest
        return host
    }

    func updateUIViewController(_ host: UIHostingController<Content>, context: Context) {
        host.rootView = content
        host.view.layer.rasterizationScale = pixelsPerPoint
    }
}
