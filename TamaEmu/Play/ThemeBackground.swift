import SwiftUI
import TamaCore
import UIKit

/// The play screen's backdrop color whenever there's no Ambient
/// Background behind it: always for the monochrome families (P1-era and
/// Tama-Go/Friends — they have no screen colors to glow with), and for a
/// color Tama when Ambient Background is off. Tomomix keeps its own sky.
///
/// Each theme has a light and a dark pair of colors (top → bottom), so it
/// follows the app's Appearance setting. `plain` is the old flat system
/// white/black, kept for anyone who prefers it.
enum AppTheme: String, CaseIterable, Identifiable {
    case plain
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

    var label: String {
        switch self {
        case .plain: "Plain"
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
    /// `nil` for `plain`, which uses the system background.
    private func stops(for scheme: ColorScheme) -> (top: UInt32, bottom: UInt32)? {
        let light = scheme == .light
        switch self {
        case .plain: return nil
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
                    Color(.systemBackground)
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
/// Each device keeps its own theme.
struct ThemePickerView: View {
    @AppStorage private var themeRaw: String

    init(device: TamaDevice) {
        _themeRaw = AppStorage(wrappedValue: AppTheme.default.rawValue, AppSettings.Keys.theme(for: device))
    }

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(AppTheme.allCases) { theme in
                    Button {
                        themeRaw = theme.rawValue
                    } label: {
                        VStack(spacing: 6) {
                            ThemeBackground(theme: theme)
                                .frame(height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .strokeBorder(
                                            themeRaw == theme.rawValue ? Color.accentColor : Color.primary.opacity(0.12),
                                            lineWidth: themeRaw == theme.rawValue ? 3 : 1
                                        )
                                }
                            Text(theme.label)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        // The swatch itself ignores touches (it's a
                        // backdrop), so give the whole tile a tap area.
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(themeRaw == theme.rawValue ? .isSelected : [])
                }
            }
            .padding()
        }
        .navigationTitle("Theme")
        .navigationBarTitleDisplayMode(.inline)
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
/// @AppStorage key can't change after init.
struct DeviceThemeBackground: View {
    @AppStorage private var themeRaw: String

    init(device: TamaDevice) {
        _themeRaw = AppStorage(wrappedValue: AppTheme.default.rawValue, AppSettings.Keys.theme(for: device))
    }

    var body: some View {
        ThemeBackground(theme: AppTheme(rawValue: themeRaw) ?? .default)
    }
}
