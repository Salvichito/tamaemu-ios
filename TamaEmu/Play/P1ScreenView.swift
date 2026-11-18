import CTamaLib
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
    /// Which first-gen model this is (a `TamaDevice.id`, e.g. "p1",
    /// "angel"): picks its icon profile and its own custom art.
    let deviceID: String
    /// For a model whose icons are real buttons (the Yasashii's lit care
    /// buttons): called with true on touch-down and false on release.
    /// nil draws them inert, as in screenshots and recordings.
    var onButton: ((InputController.Button, Bool) -> Void)?
    /// False for screenshots and video, which can't carry transparent
    /// corners -- see renderP1Snapshot.
    var rounded: Bool = true

    private let onColor = Color(red: 0.169, green: 0.165, blue: 0.157)
    private static let cornerRadius: CGFloat = 16
    private static let iconSize: CGFloat = 36
    /// The Yasashii's care buttons: a disc around the same-size icon.
    private static let lampSize: CGFloat = 58
    /// A custom sheet's slot is 128px with a 96px safe area, so the whole
    /// slot is drawn this much larger to keep the artwork inside the safe
    /// area the same visual size as a default icon.
    private static let customSlotSize: CGFloat = iconSize * 128 / 96

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
            if let background = P1CustomArt.shared.background(for: deviceID) {
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

            let profile = V1IconProfile.forDevice(deviceID)
            ForEach(profile.slots.indices, id: \.self) { i in
                let slot = profile.slots[i]
                if let button = slot.button {
                    LampButton(
                        lit: state.lamps & slot.lamp != 0,
                        size: Self.lampSize,
                        icon: icon(sheetSlot: i, asset: slot.asset),
                        onChange: onButton.map { handler in { handler(button, $0) } }
                    )
                    .position(x: slot.x * side, y: slot.y * side)
                } else {
                    icon(sheetSlot: i, asset: slot.asset)
                        .opacity(state.icons[slot.light] ? 1.0 : 0.35)
                        .position(x: slot.x * side, y: slot.y * side)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: rounded ? Self.cornerRadius : 0, style: .continuous))
    }

    @ViewBuilder
    private func icon(sheetSlot i: Int, asset: String) -> some View {
        if let icons = P1CustomArt.shared.icons(for: deviceID), i < icons.count {
            Image(uiImage: icons[i])
                .resizable()
                .scaledToFit()
                .frame(width: Self.customSlotSize, height: Self.customSlotSize)
        } else {
            Image(asset)
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

/// One of the Yasashii's lit care buttons: a disc that glows warm while
/// the toy lights it, with the icon on top. Pressable when `onChange` is
/// given (true on touch-down, false on release), inert otherwise.
private struct LampButton<Icon: View>: View {
    let lit: Bool
    let size: CGFloat
    let icon: Icon
    let onChange: ((Bool) -> Void)?

    @AppStorage(AppSettings.Keys.hapticsEnabled) private var hapticsEnabled = true
    @State private var isPressed = false

    private static var glow: Color { Color(red: 1.0, green: 0.82, blue: 0.35) }

    var body: some View {
        ZStack {
            Circle()
                .fill(lit ? Self.glow : Color.white.opacity(0.28))
                .shadow(color: lit ? Self.glow.opacity(0.9) : .clear, radius: lit ? 10 : 0)
            Circle()
                .strokeBorder(Color.black.opacity(lit ? 0.25 : 0.15), lineWidth: 1)
            icon
                .opacity(lit ? 1.0 : 0.55)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .scaleEffect(isPressed ? 0.9 : 1)
        .animation(.easeOut(duration: 0.08), value: isPressed)
        .sensoryFeedback(trigger: isPressed) { _, new in
            hapticsEnabled && new ? .impact(weight: .light) : nil
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard let onChange, !isPressed else { return }
                    isPressed = true
                    onChange(true)
                }
                .onEnded { _ in
                    guard let onChange, isPressed else { return }
                    isPressed = false
                    onChange(false)
                },
            including: onChange == nil ? .none : .all
        )
    }
}

#Preview {
    P1ScreenView(state: .blank, deviceID: "p1")
        .padding()
}

// MARK: - Per-model icon profiles

/// What the 8 icon lights mean on one first-gen model, and where each is
/// drawn. The core only reports "light n is on" -- the real icons are
/// printed on each toy's screen glass, not stored in its ROM -- so this
/// table is the app's own knowledge of each model.
///
/// A custom icon sheet's slots follow `slots` in order (slot 0 = the
/// first entry), so each model's sheet can have its own order.
struct V1IconProfile {
    struct Slot {
        /// The core's light index (`P1ScreenState.icons`), 0-7.
        let light: Int
        /// What the icon means, shown in Screen Style.
        let label: String
        /// The bundled placeholder glyph (Tabler Icons, MIT).
        let asset: String
        /// Center, as a fraction of the square screen's width/height.
        let x: CGFloat
        let y: CGFloat
        /// Yasashii: the IOS_HAL_LAMP_* bit that lights this slot instead
        /// of `light`, and the button it presses.
        var lamp: UInt8 = 0
        var button: InputController.Button?
    }

    let slots: [Slot]

    /// The P1/P2 set, in TamaLib's own light order (confirmed against
    /// jcrona/tamatool and the user's own real P1). Light 7 (attention)
    /// lights up on its own; it isn't a menu item. An even 4-over-4 layout
    /// that doesn't depend on any particular background image.
    static let original = V1IconProfile(slots: [
        Slot(light: 0, label: "food", asset: "P1IconFood", x: 0.17, y: 0.14),
        Slot(light: 1, label: "light", asset: "P1IconLight", x: 0.39, y: 0.14),
        Slot(light: 2, label: "game", asset: "P1IconGame", x: 0.61, y: 0.14),
        Slot(light: 3, label: "medicine", asset: "P1IconMedicine", x: 0.83, y: 0.14),
        Slot(light: 4, label: "bathroom", asset: "P1IconBathroom", x: 0.17, y: 0.86),
        Slot(light: 5, label: "status", asset: "P1IconStatus", x: 0.39, y: 0.86),
        Slot(light: 6, label: "training", asset: "P1IconTraining", x: 0.61, y: 0.86),
        Slot(light: 7, label: "attention", asset: "P1IconAttention", x: 0.83, y: 0.86)
    ])

    /// Tamagotchi Angel. Order and positions: the measured A cycle below
    /// (lights 0-6, 7 = attention) on the P1's wiring (0-3 top row, 4-7
    /// bottom row), matching the English manual's icon order (mimitchi.com
    /// "tainst") and a fan summary that also gives the rows. Placeholder
    /// glyphs only -- not the real toy's art (spoon, shooting star, bell,
    /// bow and arrow, haloed face).
    static let angel = V1IconProfile(slots: [
        Slot(light: 0, label: "status", asset: "P1IconStatus", x: 0.17, y: 0.14),
        Slot(light: 1, label: "food", asset: "P1IconFood", x: 0.39, y: 0.14),
        Slot(light: 2, label: "game", asset: "P1IconGame", x: 0.61, y: 0.14),
        Slot(light: 3, label: "bathroom", asset: "P1IconBathroom", x: 0.83, y: 0.14),
        Slot(light: 4, label: "praise", asset: "P1IconPraise", x: 0.17, y: 0.86),
        Slot(light: 5, label: "medicine", asset: "P1IconMedicine", x: 0.39, y: 0.86),
        Slot(light: 6, label: "light", asset: "P1IconLight", x: 0.61, y: 0.86),
        Slot(light: 7, label: "attention", asset: "P1IconAttention", x: 0.83, y: 0.86)
    ])

    /// Lights 0-3 across the top row and 4-7 across the bottom, left to
    /// right -- how every model measured so far is wired.
    private static func grid(_ icons: [(label: String, asset: String)]) -> V1IconProfile {
        let xs: [CGFloat] = [0.17, 0.39, 0.61, 0.83]
        return V1IconProfile(slots: icons.enumerated().map { i, icon in
            Slot(light: i, label: icon.label, asset: icon.asset, x: xs[i % 4], y: i < 4 ? 0.14 : 0.86)
        })
    }

    /// Tamagotchi Ocean (Umi de Hakken). Measured: A cycles lights 0-6,
    /// matching mimitchi.com's "Tamagotchi Ocean: The Icons" numbering
    /// (1-8, top to bottom, left to right).
    static let umino = grid([
        ("status", "P1IconStatus"), ("food", "P1IconFood"),
        ("game", "P1IconGame"), ("bathroom", "P1IconBathroom"),
        ("calling box", "P1IconCall"), ("medicine", "P1IconMedicine"),
        ("light", "P1IconLight"), ("attention", "P1IconAttention")
    ])

    /// The Japanese manuals' labelled screen diagrams (scans collected
    /// 2026-11-18 in the user's research folder, vintage-care-icons) are
    /// the source for Morino, Mothra and Tamaotch below; the Digimon
    /// layout is from a contemporary Japanese guidebook diagram. None of
    /// these four could be measured: the headless runner hasn't got them
    /// past their eggs, so the light numbering relies on the core's wiring
    /// (lights 0-3 top row, 4-7 bottom, left to right, as on every model
    /// measured).

    /// Mori de Hakken (Morino / Forest). "? box" (predator response) and
    /// attention light on their own; the ? box is auto-selected when you
    /// press A during an attack.
    static let morino = grid([
        ("status", "P1IconStatus"), ("food", "P1IconFood"),
        ("game", "P1IconGame"), ("toilet", "P1IconBathroom"),
        ("? box", "P1IconPredator"), ("first aid", "P1IconMedicine"),
        ("lights", "P1IconLight"), ("attention", "P1IconAttention")
    ])

    /// Mothra Tamagotchi. Discipline raises its "justice" meter.
    static let mothra = grid([
        ("status", "P1IconStatus"), ("food", "P1IconFood"),
        ("game", "P1IconGame"), ("toilet", "P1IconBathroom"),
        ("discipline", "P1IconTraining"), ("treatment", "P1IconMedicine"),
        ("lights", "P1IconLight"), ("attention", "P1IconAttention")
    ])

    /// Tamaotch (玉緒っち). All eight are selectable: no attention icon,
    /// it calls with text on the pixel screen instead.
    static let tamaotch = grid([
        ("status", "P1IconStatus"), ("rest break", "P1IconFood"),
        ("slots", "P1IconGame"), ("rehearsal", "P1IconRehearsal"),
        ("toilet", "P1IconBathroom"), ("medicine", "P1IconMedicine"),
        ("lights", "P1IconLight"), ("discipline", "P1IconTraining")
    ])

    /// Digital Monster Ver. 1-3. Call (bottom right) lights on its own.
    static let digimon = grid([
        ("status", "P1IconStatus"), ("food", "P1IconFood"),
        ("training", "P1IconTraining"), ("battle", "P1IconBattle"),
        ("toilet", "P1IconBathroom"), ("lights", "P1IconLight"),
        ("treatment", "P1IconMedicine"), ("call", "P1IconAttention")
    ])

    /// Genjintch: measured A cycle 0-6 + attention, same as the P1. The
    /// only icon difference found in sources: praise replaces the P1's
    /// discipline icon. Assumed in the P1's slot -- not confirmed.
    static let genjintch = grid([
        ("food", "P1IconFood"), ("light", "P1IconLight"),
        ("game", "P1IconGame"), ("medicine", "P1IconMedicine"),
        ("bathroom", "P1IconBathroom"), ("status", "P1IconStatus"),
        ("praise", "P1IconPraise"), ("attention", "P1IconAttention")
    ])

    /// Yasashii: no screen icons at all. Per its manual, six lit care
    /// buttons sit around the LCD -- meal, happiness, affection above it;
    /// toilet, lights, status below -- with small select/cancel buttons
    /// underneath (those go on the button pad as B and C). Drawn here as
    /// real buttons where the other models' icons go. Button pins and
    /// lamps measured headless 2026-11-18, see IOS_HAL_LAMP_* in
    /// ios_hal.h (affection, toilet and status lamps inferred).
    static let yasashii: V1IconProfile = {
        let xs: [CGFloat] = [0.22, 0.5, 0.78]
        let buttons: [(String, String, UInt8, InputController.Button)] = [
            ("meal", "P1IconFood", UInt8(IOS_HAL_LAMP_MEAL), .k13),
            ("happiness", "P1IconHappiness", UInt8(IOS_HAL_LAMP_HAPPINESS), .k12),
            ("affection", "P1IconAffection", UInt8(IOS_HAL_LAMP_AFFECTION), .k11),
            ("toilet", "P1IconBathroom", UInt8(IOS_HAL_LAMP_TOILET), .k10),
            ("lights", "P1IconLight", UInt8(IOS_HAL_LAMP_LIGHTS), .tap),
            ("status", "P1IconStatus", UInt8(IOS_HAL_LAMP_STATUS), .a)
        ]
        return V1IconProfile(slots: buttons.enumerated().map { i, b in
            Slot(light: 0, label: b.0, asset: b.1, x: xs[i % 3], y: i < 3 ? 0.13 : 0.87, lamp: b.2, button: b.3)
        })
    }()

    /// The two small buttons under the Yasashii's care buttons, in place
    /// of A/B/C: select (B pin) and cancel (C pin).
    static func padButtons(for deviceID: String) -> [InputController.Button] {
        deviceID == "yasashii" ? [.b, .c] : [.a, .b, .c]
    }

    /// True when this model's icons are buttons (see `onButton`).
    var hasButtons: Bool { slots.contains { $0.button != nil } }
    ///
    /// Measured headless (2026-11-18, set the clock with B, A, C, wait
    /// 10 min, then press A repeatedly):
    /// - P1, P2: A steps lights 0-6 then none; 7 lights on its own.
    /// - Angel, Genjintch: same 0-6 cycle, with 7 lit while calling.
    /// - Umino: 0-6 too (light 1 repeated once, likely press timing).
    /// - Morino, Mothra, Tamaotch, Yasashii, Digimon 1-3: still eggs after
    ///   30 min with every start-up sequence tried.
    private static let byDevice: [String: V1IconProfile] = [
        "p1": original,
        "angel": angel,
        "morino": morino,
        "umino": umino,
        "genjintch": genjintch,
        "tamaotch": tamaotch,
        "mothra": mothra,
        "yasashii": yasashii,
        "digimon-v1": digimon,
        "digimon-v2": digimon,
        "digimon-v3": digimon
    ]

    static func forDevice(_ id: String) -> V1IconProfile {
        byDevice[id] ?? original
    }

    /// "food, light, game, medicine, then bathroom, ..." for Screen Style.
    var sheetOrderDescription: String {
        // Top row, then bottom row: 4 + 4 on most models, 3 + 3 on the Yasashii.
        let labels = slots.map(\.label)
        let perRow = (labels.count + 1) / 2
        guard labels.count > 4 else { return labels.joined(separator: ", ") }
        return labels.prefix(perRow).joined(separator: ", ") + ", then " + labels.dropFirst(perRow).joined(separator: ", ")
    }
}

// MARK: - User-supplied artwork

/// The user's own background image and icon sheet for each first-gen
/// model, picked from their photo library in P1ScreenStyleView. Kept as
/// PNGs in Application Support and loaded once; P1ScreenView reads them
/// straight off `shared`, so the play screen, screenshots and recordings
/// all pick up a change immediately.
///
/// Each model has its own pair, so a P1 sheet never shows on an Angel.
/// The P1's live at the folder's top level, where the single shared pair
/// lived before art became per-model, so existing art stays on the P1
/// with no migration; every other model gets a subfolder named by its
/// device ID.
///
/// An icon sheet is one image holding 8 equal slots, 4 across and 2
/// down, in the order of that model's `V1IconProfile.slots`.
@MainActor
@Observable
final class P1CustomArt {
    static let shared = P1CustomArt()

    private var backgrounds: [String: UIImage] = [:]
    private var iconSets: [String: [UIImage]] = [:]

    func background(for deviceID: String) -> UIImage? { backgrounds[deviceID] }
    func icons(for deviceID: String) -> [UIImage]? { iconSets[deviceID] }

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

    private static var rootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("P1CustomArt", isDirectory: true)
    }
    private static func directory(for deviceID: String) -> URL {
        deviceID == "p1" ? rootDirectory : rootDirectory.appendingPathComponent(deviceID, isDirectory: true)
    }
    private static func backgroundURL(for deviceID: String) -> URL {
        directory(for: deviceID).appendingPathComponent("background.png")
    }
    private static func iconSheetURL(for deviceID: String) -> URL {
        directory(for: deviceID).appendingPathComponent("icons.png")
    }

    private init() {
        let subfolders = (try? FileManager.default.contentsOfDirectory(
            at: Self.rootDirectory, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        let deviceIDs = ["p1"] + subfolders
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
        for id in deviceIDs {
            if let image = UIImage(contentsOfFile: Self.backgroundURL(for: id).path) {
                backgrounds[id] = image
            }
            if let sheet = UIImage(contentsOfFile: Self.iconSheetURL(for: id).path), let sliced = Self.slice(sheet) {
                iconSets[id] = sliced
            }
        }
    }

    /// Center-crops to a square, since the screen is square.
    func setBackground(from data: Data, for deviceID: String) throws {
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
        try Self.write(square, to: Self.backgroundURL(for: deviceID))
        backgrounds[deviceID] = square
    }

    func setIconSheet(from data: Data, for deviceID: String) throws {
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
        try Self.write(sheet, to: Self.iconSheetURL(for: deviceID))
        iconSets[deviceID] = sliced
    }

    func resetBackground(for deviceID: String) {
        try? FileManager.default.removeItem(at: Self.backgroundURL(for: deviceID))
        backgrounds[deviceID] = nil
    }

    func resetIcons(for deviceID: String) {
        try? FileManager.default.removeItem(at: Self.iconSheetURL(for: deviceID))
        iconSets[deviceID] = nil
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
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
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
    /// The model whose art this edits (a `TamaDevice.id`).
    let deviceID: String
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
                    if P1CustomArt.shared.background(for: deviceID) != nil {
                        Button("Reset Background", role: .destructive) { P1CustomArt.shared.resetBackground(for: deviceID) }
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
                    if P1CustomArt.shared.icons(for: deviceID) != nil {
                        Button("Reset Icons", role: .destructive) { P1CustomArt.shared.resetIcons(for: deviceID) }
                    }
                } header: {
                    Text("Icons")
                } footer: {
                    Text("A single image with 8 equal slots, 4 across and 2 down, in this order: \(V1IconProfile.forDevice(deviceID).sheetOrderDescription). A transparent PNG works best.")
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
                load(item) { [deviceID] in try P1CustomArt.shared.setBackground(from: $0, for: deviceID) }
                backgroundPick = nil
            }
            .onChange(of: iconSheetPick) { _, item in
                load(item) { [deviceID] in try P1CustomArt.shared.setIconSheet(from: $0, for: deviceID) }
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
