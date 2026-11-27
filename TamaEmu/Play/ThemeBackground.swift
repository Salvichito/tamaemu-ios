import SwiftUI
import TamaCore
import UIKit

/// The play screen's backdrop, chosen per Tama. `ambient` is the live
/// blurred glow of the Tama's own screen (BlurredLCDBackground) — color
/// Tamas only, since the monochrome families (P1-era, Tama-Go/Friends)
/// have no screen colors to glow with; their picker shows it greyed out.
/// Every other theme is a static gradient. Tomomix keeps its own sky.
///
/// Ambient used to be one app-wide switch in Display that silently hid
/// the theme; it became a theme so there's one choice in one place (see
/// AppSettings.migrateAmbientToTheme). The old flat "Plain" theme was
/// dropped to make room: a stored "plain" no longer parses and falls back
/// to the default.
///
/// Each gradient has a light and a dark pair of colors (top → bottom), so
/// it follows the app's Appearance setting.
enum AppTheme: String, CaseIterable, Identifiable {
    case ambient
    case tomomix
    case gameboy
    case cottonCandy
    case sunshine
    case peach
    case bubblegum
    case clearBlue
    case sunrise
    case mint
    case lagoon
    case cream

    static let `default`: AppTheme = .tomomix

    var id: String { rawValue }

    /// Tomomix Purple is free; Ambient and the other colors are Premium.
    var isPremium: Bool { self != .tomomix }

    /// Only color Tamas have screen colors to glow with.
    static func supportsAmbient(_ device: TamaDevice) -> Bool {
        device.family == .ctama || device.family == .t18
    }

    /// A Tama's theme before the user has picked one. Color Tamas glow
    /// unless the old app-wide Ambient switch was turned off (that key is
    /// only read now, as this default).
    static func defaultTheme(for device: TamaDevice) -> AppTheme {
        supportsAmbient(device) && AppSettings.ambientBackgroundEnabled ? .ambient : .default
    }

    /// The stored pick, or the default when there's none (or it's the
    /// retired "plain").
    static func stored(_ raw: String?, for device: TamaDevice) -> AppTheme {
        raw.flatMap(AppTheme.init(rawValue:)) ?? defaultTheme(for: device)
    }

    /// What actually shows: a free user's Premium pick falls back to the
    /// default, but stays stored so it comes back the moment they unlock
    /// Premium. Ambient on a Tama that can't glow does the same.
    func effective(isPremium premium: Bool, device: TamaDevice) -> AppTheme {
        if isPremium && !premium { return .default }
        if self == .ambient && !Self.supportsAmbient(device) { return .default }
        return self
    }

    var label: String {
        switch self {
        case .ambient: "Ambient"
        case .tomomix: "Tomomix Purple"
        case .gameboy: "Handheld Grey"
        case .cottonCandy: "Cotton Candy"
        case .sunshine: "Sunshine"
        case .peach: "Peach"
        case .bubblegum: "Bubblegum"
        case .clearBlue: "Clear Blue"
        case .sunrise: "Sunrise"
        case .mint: "Mint"
        case .lagoon: "Lagoon"
        case .cream: "Cream"
        }
    }

    /// Top and bottom colors of the gradient, as hex, for each scheme.
    /// `nil` for `ambient`, which is drawn live rather than as a gradient.
    private func stops(for scheme: ColorScheme) -> (top: UInt32, bottom: UInt32)? {
        let light = scheme == .light
        switch self {
        case .ambient: return nil
        // The landing page / screenshot lavender.
        case .tomomix: return light ? (0xD9D1FA, 0x9F90E2) : (0x2E2658, 0x16132C)
        // A classic grey handheld's warm plastic shell.
        case .gameboy: return light ? (0xDEDBD5, 0xB3AEA6) : (0x3B3A3F, 0x1F1E22)
        // The Pastel Purple app icon: pink fading into baby blue.
        case .cottonCandy: return light ? (0xF6C3E8, 0xA9D2F6) : (0x4C2549, 0x1B2F4C)
        // The Yellow app icon.
        case .sunshine: return light ? (0xFFEA9E, 0xFFBE6A) : (0x4A3812, 0x281A07)
        // The Pastel Orange app icon.
        case .peach: return light ? (0xFFD6B3, 0xFFA175) : (0x4E2C1C, 0x28150C)
        // The Fuchsia app icon.
        case .bubblegum: return light ? (0xFBB8D6, 0xEA78AA) : (0x521A36, 0x2A0B1C)
        // The Clear Blue app icon — like a see-through blue shell.
        case .clearBlue: return light ? (0xB4D0FF, 0x5E8FEF) : (0x13295A, 0x07122C)
        // The Blue Yellow app icon: sky on top, warm glow below.
        case .sunrise: return light ? (0xA6D1FF, 0xFFE3A1) : (0x15315C, 0x3D2F12)
        case .mint: return light ? (0xCDF2DD, 0x8DD3B0) : (0x173E30, 0x0A1F17)
        // The cyan accent in the Fuchsia app icon.
        case .lagoon: return light ? (0xC2EEF2, 0x5FC2CE) : (0x103C44, 0x06191D)
        // The White app icon: warm off-white rather than stark white.
        case .cream: return light ? (0xFAF6EC, 0xE2D9C5) : (0x302D27, 0x1A1815)
        }
    }

    func colors(for scheme: ColorScheme) -> (top: Color, bottom: Color)? {
        stops(for: scheme).map { (Color(hex: $0.top), Color(hex: $0.bottom)) }
    }
}

/// Full-bleed, static (draws once — no timeline, nothing to cost battery):
/// a top-to-bottom gradient, a soft light falling from above, a gentle
/// darkening toward the bottom corners, and fine grain so it reads as a
/// surface rather than a flat fill.
struct ThemeBackground: View {
    let theme: AppTheme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let longSide = max(size.width, size.height)
            ZStack {
                if let colors = theme.colors(for: scheme) {
                    LinearGradient(
                        colors: [colors.top, colors.bottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    // Light from above, a little off-center.
                    RadialGradient(
                        colors: [.white.opacity(scheme == .light ? 0.45 : 0.10), .clear],
                        center: UnitPoint(x: 0.35, y: 0.05),
                        startRadius: 0,
                        endRadius: longSide * 0.6
                    )
                    .blendMode(.softLight)
                    RadialGradient(
                        colors: [.white.opacity(scheme == .light ? 0.30 : 0.06), .clear],
                        center: UnitPoint(x: 0.35, y: 0.05),
                        startRadius: 0,
                        endRadius: longSide * 0.45
                    )
                    // Edges fall off slightly, like a curved shell.
                    RadialGradient(
                        colors: [.clear, .black.opacity(scheme == .light ? 0.10 : 0.30)],
                        center: UnitPoint(x: 0.5, y: 0.4),
                        startRadius: longSide * 0.3,
                        endRadius: longSide * 0.85
                    )
                    Image(uiImage: ThemeGrain.tile)
                        .resizable(resizingMode: .tile)
                        .blendMode(.overlay)
                        .opacity(scheme == .light ? 0.35 : 0.5)
                } else {
                    // Only the picker's swatch lands here: the real
                    // Ambient backdrop is BlurredLCDBackground.
                    AmbientSwatch()
                }
            }
            .frame(width: size.width, height: size.height)
            .drawingGroup()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// A small tile of random grey noise, made once and tiled.
private enum ThemeGrain {
    static let tile: UIImage = {
        let side = 96
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt32 = 0x9E3779B9
        for i in 0..<(side * side) {
            // xorshift — deterministic, so the grain never changes.
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            let v = UInt8(96 + Int(seed % 64))
            pixels[i * 4] = v
            pixels[i * 4 + 1] = v
            pixels[i * 4 + 2] = v
            pixels[i * 4 + 3] = 255
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        // Scale 2 keeps each grain speck tiny on screen.
        return UIImage(cgImage: image, scale: 2, orientation: .up)
    }()
}

/// Grid of theme swatches; the backdrop behind the sheet changes as you tap.
/// Each device keeps its own theme. On a Tama that can't glow, the Ambient
/// tile stays in its place (so the grid stays full) but is greyed out.
struct ThemePickerView: View {
    let device: TamaDevice
    @AppStorage private var themeRaw: String?
    @Environment(PurchaseManager.self) private var purchases
    @State private var showingPaywall = false

    /// The highlighted tile: what's actually showing, not a locked pick.
    private var selected: AppTheme {
        AppTheme.stored(themeRaw, for: device).effective(isPremium: purchases.isPremium, device: device)
    }

    init(device: TamaDevice) {
        self.device = device
        _themeRaw = AppStorage(AppSettings.Keys.theme(for: device))
    }

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(AppTheme.allCases) { theme in
                    tile(theme)
                }
            }
            .padding()

            Text(footer)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .padding(.bottom)
        }
        .navigationTitle("Theme")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingPaywall) {
            PaywallView()
        }
    }

    private var footer: String {
        var text = AppTheme.supportsAmbient(device)
            ? "Ambient glows with \(device.title)'s own screen colors."
            : "Ambient glows with a Tama's own screen colors, so it only works on color Tamas."
        if !purchases.isPremium {
            text += " Tomomix Purple is always free. Ambient and the other colors come with Premium."
        }
        return text
    }

    private func tile(_ theme: AppTheme) -> some View {
        let unavailable = theme == .ambient && !AppTheme.supportsAmbient(device)
        let locked = theme.isPremium && !purchases.isPremium && !unavailable
        let isSelected = selected == theme
        return Button {
            if locked {
                showingPaywall = true
            } else {
                themeRaw = theme.rawValue
            }
        } label: {
            VStack(spacing: 6) {
                ThemeBackground(theme: theme)
                    .frame(height: 120)
                    .saturation(unavailable ? 0 : 1)
                    .opacity(unavailable ? 0.45 : 1)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                                lineWidth: isSelected ? 3 : 1
                            )
                    }
                    .overlay {
                        if unavailable {
                            Text("Color Tamas only")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(8)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if locked {
                            Image(systemName: "lock.fill")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(5)
                                .background(.black.opacity(0.55), in: Circle())
                                .padding(6)
                        }
                    }
                Text(theme.label)
                    .font(.caption)
                    .foregroundStyle(unavailable ? .secondary : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            // The swatch itself ignores touches (it's a
            // backdrop), so give the whole tile a tap area.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(unavailable)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(unavailable ? "Color Tamas only" : locked ? "Premium" : "")
    }
}

/// The Ambient tile's preview: soft blobs of color, like a blurred
/// screen. Static — the real thing is BlurredLCDBackground.
struct AmbientSwatch: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let side = max(geo.size.width, geo.size.height)
            ZStack {
                Color(hex: scheme == .light ? 0xF3EEF8 : 0x1C1A26)
                blob(0xFF8FC7, x: 0.25, y: 0.25, side: side)
                blob(0x7FD3FF, x: 0.8, y: 0.45, side: side)
                blob(0xFFD66B, x: 0.35, y: 0.85, side: side)
                Image(systemName: "sparkles")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.15), radius: 4)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func blob(_ hex: UInt32, x: CGFloat, y: CGFloat, side: CGFloat) -> some View {
        RadialGradient(
            colors: [Color(hex: hex).opacity(scheme == .light ? 0.9 : 0.6), .clear],
            center: UnitPoint(x: x, y: y),
            startRadius: 0,
            endRadius: side * 0.55
        )
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// One device's own theme, read from its per-device key. The gallery
/// re-creates this (`.id`) whenever the page on screen changes, since an
/// @AppStorage key can't change after init. `ambient` is drawn by the
/// caller's closure (the live blurred screen), everything else here.
struct DeviceThemeBackground<Ambient: View>: View {
    let device: TamaDevice
    @ViewBuilder let ambient: () -> Ambient
    @AppStorage private var themeRaw: String?
    @Environment(PurchaseManager.self) private var purchases

    init(device: TamaDevice, @ViewBuilder ambient: @escaping () -> Ambient) {
        self.device = device
        self.ambient = ambient
        _themeRaw = AppStorage(AppSettings.Keys.theme(for: device))
    }

    var body: some View {
        let theme = AppTheme.stored(themeRaw, for: device).effective(isPremium: purchases.isPremium, device: device)
        if theme == .ambient {
            ambient()
        } else {
            ThemeBackground(theme: theme)
        }
    }
}
