import PhotosUI
import SwiftUI
import UIKit

/// The P1-era screen: icons and the pixel matrix sit directly on a
/// background, no separate boxed panel for either. Square overall
/// footprint -- same size and proportions as every other Tamagotchi in
/// the gallery (LCDView forces the same `.aspectRatio(1, contentMode: .fit)`).
///
/// Nothing branded ships in the app: the default look is a plain
/// gradient and Tabler Icons (MIT, see NOTICE.md). Users can supply their own background image
/// and their own icon sheet from the page's menu (see P1ScreenStyleView
/// and P1CustomArt).
struct P1ScreenView: View {
    let state: P1ScreenState
    /// False for screenshots and video, which can't carry transparent
    /// corners -- see renderP1Snapshot.
    var rounded: Bool = true

    private let onColor = Color(red: 0.169, green: 0.165, blue: 0.157)
    private static let cornerRadius: CGFloat = 16
    private static let iconSize: CGFloat = 36
    /// A custom sheet's slot is 128px with a 96px safe area, so the whole
    /// slot is drawn this much larger to keep the artwork inside the safe
    /// area the same visual size as a default icon.
    private static let customSlotSize: CGFloat = iconSize * 128 / 96

    /// TamaLib's own icon index order (confirmed against jcrona/tamatool
    /// and the user's own real P1 -- see the integration-research
    /// memory). Index 7 (attention) lights up on its own; it's not a
    /// selectable menu item, but still just an icon here. Same order as
    /// the slots of a custom icon sheet. The artwork is from Tabler Icons'
    /// filled set (MIT), bundled as template SVGs.
    private static let defaultIconAssets = [
        "P1IconFood",      // 0 food
        "P1IconLight",     // 1 light
        "P1IconGame",      // 2 game
        "P1IconMedicine",  // 3 medicine
        "P1IconBathroom",  // 4 poop cleaning
        "P1IconStatus",    // 5 stats
        "P1IconTraining",  // 6 scolding
        "P1IconAttention"  // 7 attention
    ]

    /// Each icon's center, as a fraction of the square's own width/height
    /// -- an even 4-over-4 layout that doesn't depend on any particular
    /// background image.
    private static let iconPositions: [(x: CGFloat, y: CGFloat)] = [
        (0.17, 0.14), (0.39, 0.14), (0.61, 0.14), (0.83, 0.14),
        (0.17, 0.86), (0.39, 0.86), (0.61, 0.86), (0.83, 0.86)
    ]

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            screenContent(side: side)
                .frame(width: side, height: side)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func screenContent(side: CGFloat) -> some View {
        ZStack {
            if let background = P1CustomArt.shared.background {
                Image(uiImage: background)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
            } else {
                LinearGradient(
                    colors: [Color(red: 0.86, green: 0.89, blue: 0.80), Color(red: 0.74, green: 0.79, blue: 0.69)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }

            pixelGrid
                .aspectRatio(32.0 / 16.0, contentMode: .fit)
                .frame(width: side)

            ForEach(0..<8, id: \.self) { i in
                icon(i)
                    .opacity(state.icons[i] ? 1.0 : 0.35)
                    .position(x: Self.iconPositions[i].x * side, y: Self.iconPositions[i].y * side)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: rounded ? Self.cornerRadius : 0, style: .continuous))
    }

    @ViewBuilder
    private func icon(_ i: Int) -> some View {
        if let icons = P1CustomArt.shared.icons {
            Image(uiImage: icons[i])
                .resizable()
                .scaledToFit()
                .frame(width: Self.customSlotSize, height: Self.customSlotSize)
        } else {
            Image(Self.defaultIconAssets[i])
                .resizable()
                .scaledToFit()
                .frame(width: Self.iconSize, height: Self.iconSize)
                .foregroundStyle(onColor)
        }
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

    /// "Off" pixels are fully transparent, not a solid LCD tint -- the
    /// background pattern shows straight through them, same as the icons
    /// sitting directly on it. "On" pixels are mostly opaque but not fully --
    /// the background pattern underneath still shows through faintly.
    private static let onAlpha: CGFloat = 0.9
    private static let cols = 32, rows = 16
    /// Each logical LCD pixel is rendered as an oversample x oversample
    /// block, with its rightmost/bottommost texel left transparent -- a
    /// thin gap line so adjacent "on" pixels read as separate squares
    /// instead of one solid blob, same as a real LCD's pixel grid.
    private static let oversample = 24
    private func makeBitmapImage() -> CGImage? {
        let scale = Self.oversample
        let w = Self.cols * scale, h = Self.rows * scale
        // Premultiplied alpha: RGB must be scaled by onAlpha too, or the
        // "on" color comes out brighter than intended (CG reads raw bytes,
        // it doesn't premultiply them for us).
        let alpha = UInt8((Self.onAlpha * 255).rounded())
        let r = UInt8((43 * Self.onAlpha).rounded())
        let g = UInt8((42 * Self.onAlpha).rounded())
        let b = UInt8((40 * Self.onAlpha).rounded())
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let localY = y % scale
            guard localY < scale - 1 else { continue }
            let py = y / scale
            for x in 0..<w {
                let localX = x % scale
                guard localX < scale - 1 else { continue }
                let px = x / scale
                guard state.pixel(px, py) else { continue }
                let i = (y * w + x) * 4
                pixels[i] = r
                pixels[i + 1] = g
                pixels[i + 2] = b
                pixels[i + 3] = alpha
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

#Preview {
    P1ScreenView(state: .blank)
        .padding()
}

// MARK: - User-supplied artwork

/// The user's own background image and icon sheet for the P1 screen,
/// picked from their photo library in P1ScreenStyleView. Kept as two PNGs in
/// Application Support and loaded once; P1ScreenView reads them straight
/// off `shared`, so the play screen, screenshots and recordings all pick
/// up a change immediately.
///
/// An icon sheet is one image holding 8 equal slots, 4 across and 2
/// down, in P1ScreenView's icon order (food, light, game, medicine /
/// bathroom, status, training, attention).
@MainActor
@Observable
final class P1CustomArt {
    static let shared = P1CustomArt()

    private(set) var background: UIImage?
    private(set) var icons: [UIImage]?

    enum ImportError: LocalizedError {
        case unreadable
        case wrongSheetShape

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return "That image couldn't be opened."
            case .wrongSheetShape:
                return "An icon sheet needs to be twice as wide as it is tall: 8 equal slots, 4 across and 2 down."
            }
        }
    }

    private static let maxDimension: CGFloat = 1024

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("P1CustomArt", isDirectory: true)
    }
    private static var backgroundURL: URL { directory.appendingPathComponent("background.png") }
    private static var iconSheetURL: URL { directory.appendingPathComponent("icons.png") }

    private init() {
        background = UIImage(contentsOfFile: Self.backgroundURL.path)
        if let sheet = UIImage(contentsOfFile: Self.iconSheetURL.path) {
            icons = Self.slice(sheet)
        }
    }

    /// Center-crops to a square, since the screen is square.
    func setBackground(from data: Data) throws {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
            throw ImportError.unreadable
        }
        let side = min(image.size.width * image.scale, image.size.height * image.scale, Self.maxDimension)
        let fill = max(side / image.size.width, side / image.size.height)
        let drawn = CGSize(width: image.size.width * fill, height: image.size.height * fill)
        let square = Self.render(size: CGSize(width: side, height: side), opaque: true) {
            image.draw(in: CGRect(
                x: (side - drawn.width) / 2, y: (side - drawn.height) / 2,
                width: drawn.width, height: drawn.height
            ))
        }
        try Self.write(square, to: Self.backgroundURL)
        background = square
    }

    func setIconSheet(from data: Data) throws {
        guard let image = UIImage(data: data), image.size.height > 0 else { throw ImportError.unreadable }
        let ratio = image.size.width / image.size.height
        guard abs(ratio - 2) < 0.1 else { throw ImportError.wrongSheetShape }
        let width = min(image.size.width * image.scale, Self.maxDimension).rounded()
        // A multiple of 8 so every slot is a whole number of pixels.
        let size = CGSize(width: (width / 8).rounded(.down) * 8, height: (width / 8).rounded(.down) * 4)
        var sheet = Self.render(size: size, opaque: false) {
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        if !Self.hasTransparency(image) {
            sheet = Self.inkOnly(sheet) ?? sheet
        }
        guard let sliced = Self.slice(sheet) else { throw ImportError.unreadable }
        try Self.write(sheet, to: Self.iconSheetURL)
        icons = sliced
    }

    func resetBackground() {
        try? FileManager.default.removeItem(at: Self.backgroundURL)
        background = nil
    }

    func resetIcons() {
        try? FileManager.default.removeItem(at: Self.iconSheetURL)
        icons = nil
    }

    // MARK: Helpers

    private static func render(size: CGSize, opaque: Bool, _ draw: () -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in draw() }
    }

    private static func write(_ image: UIImage, to url: URL) throws {
        guard let data = image.pngData() else { throw ImportError.unreadable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func slice(_ sheet: UIImage) -> [UIImage]? {
        guard let cg = sheet.cgImage else { return nil }
        let w = cg.width / 4, h = cg.height / 2
        guard w > 0, h > 0 else { return nil }
        var result: [UIImage] = []
        for i in 0..<8 {
            guard let slot = cg.cropping(to: CGRect(x: (i % 4) * w, y: (i / 4) * h, width: w, height: h)) else {
                return nil
            }
            result.append(UIImage(cgImage: slot))
        }
        return result
    }

    private static func hasTransparency(_ image: UIImage) -> Bool {
        switch image.cgImage?.alphaInfo {
        case .none?, .noneSkipFirst?, .noneSkipLast?, nil: return false
        default: return true
        }
    }

    /// For a sheet saved without transparency (dark icons on a light
    /// page, e.g. a JPEG): keeps the dark ink and drops the page, so the
    /// icons don't show up as eight solid boxes.
    private static func inkOnly(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let luminance = (Int(pixels[i]) * 299 + Int(pixels[i + 1]) * 587 + Int(pixels[i + 2]) * 114) / 1000
            // Premultiplied black ink: color stays 0, only alpha varies.
            pixels[i] = 0
            pixels[i + 1] = 0
            pixels[i + 2] = 0
            pixels[i + 3] = UInt8(255 - luminance)
        }
        return context.makeImage().map { UIImage(cgImage: $0) }
    }
}

// MARK: - Screen Style sheet

/// "Screen Style" in a P1 page's menu: pick or reset the background
/// image and the icon sheet. This family has no Settings screen of its
/// own, so this is a small sheet rather than a Settings section.
struct P1ScreenStyleView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var backgroundPick: PhotosPickerItem?
    @State private var iconSheetPick: PhotosPickerItem?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker(selection: $backgroundPick, matching: .images) {
                        Label("Choose Background", systemImage: "photo")
                    }
                    if P1CustomArt.shared.background != nil {
                        Button("Reset Background", role: .destructive) { P1CustomArt.shared.resetBackground() }
                    }
                } header: {
                    Text("Background")
                } footer: {
                    Text("Any image from your photo library. It's cropped to a square.")
                }
                Section {
                    PhotosPicker(selection: $iconSheetPick, matching: .images) {
                        Label("Choose Icon Sheet", systemImage: "square.grid.2x2")
                    }
                    if P1CustomArt.shared.icons != nil {
                        Button("Reset Icons", role: .destructive) { P1CustomArt.shared.resetIcons() }
                    }
                } header: {
                    Text("Icons")
                } footer: {
                    Text("A single image with 8 equal slots, 4 across and 2 down, in this order: food, light, game, medicine, then bathroom, status, training, attention. A transparent PNG works best.")
                }
            }
            .navigationTitle("Screen Style")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: backgroundPick) { _, item in
                load(item) { try P1CustomArt.shared.setBackground(from: $0) }
                backgroundPick = nil
            }
            .onChange(of: iconSheetPick) { _, item in
                load(item) { try P1CustomArt.shared.setIconSheet(from: $0) }
                iconSheetPick = nil
            }
            .alert(
                errorMessage ?? "",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("OK") { errorMessage = nil }
            }
        }
    }

    private func load(_ item: PhotosPickerItem?, apply: @escaping @MainActor (Data) throws -> Void) {
        guard let item else { return }
        Task { @MainActor in
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw P1CustomArt.ImportError.unreadable
                }
                try apply(data)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
