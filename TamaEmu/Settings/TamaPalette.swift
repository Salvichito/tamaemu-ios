import SwiftUI

/// Named color options for the two cosmetic settings (button color, accent
/// color) — a fixed, small palette rather than a full color picker, mirroring
/// the Android port's own small enumerated choices (`btn_colors`/`egg_colors`
/// arrays) rather than a free-form picker.
enum TamaPalette {
    static let buttonColors: [(name: String, color: Color)] = [
        ("Gray", Color(.secondarySystemBackground).opacity(0.25)),
        ("Blue", .blue.opacity(0.25)),
        ("Green", .green.opacity(0.25)),
        ("Orange", .orange.opacity(0.25)),
        ("Pink", .pink.opacity(0.25)),
        ("Purple", .purple.opacity(0.25)),
    ]

    /// `nil` for "Default" means no override — SwiftUI's own system tint
    /// (blue), not a color choice of our own.
    static let accentColors: [(name: String, color: Color?)] = [
        ("Default", nil),
        ("Blue", .blue),
        ("Green", .green),
        ("Orange", .orange),
        ("Pink", .pink),
        ("Purple", .purple),
    ]

    static func buttonColor(at index: Int) -> Color {
        buttonColors[index % buttonColors.count].color
    }

    static func accentColor(at index: Int) -> Color? {
        accentColors[index % accentColors.count].color
    }
}
