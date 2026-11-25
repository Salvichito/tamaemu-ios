import SwiftUI
import UIKit

/// The home-screen icons someone can pick from. Each `id` matches an
/// Icon Composer file in Resources (`TamaEmu-<id>.icon`) and a preview
/// image in Assets (`IconPreview-<id>`, made by
/// Tools/render-icon-previews.sh). `default` is the main TamaEmu.icon.
///
/// Adding an icon: drop `TamaEmu-<id>.icon` into Resources, add it to the
/// app target + ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES, re-run the
/// preview script, then add a row here.
struct AppIconChoice: Identifiable, Hashable {
    let id: String
    let label: String

    /// What iOS calls this icon; nil means the main icon.
    var alternateName: String? { id == "default" ? nil : "TamaEmu-\(id)" }
    var previewImage: String { "IconPreview-\(id)" }
    var isPremium: Bool { id != "default" }

    /// Alternate icons are Icon Composer files, and Xcode only makes
    /// old-style fallback images for the main icon — not the alternates.
    /// So below iOS 26 the App Icon option is hidden; the main icon still
    /// shows fine there.
    static var isSupported: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    static let all: [AppIconChoice] = [
        .init(id: "default", label: "Classic"),
        .init(id: "yellow", label: "Yellow"),
        .init(id: "pastelorange", label: "Pastel Orange"),
        .init(id: "fuchsia", label: "Fuchsia"),
        .init(id: "pastelpurple", label: "Pastel Purple"),
        .init(id: "blueyellow", label: "Blue Yellow"),
        .init(id: "clearblue", label: "Clear Blue"),
        .init(id: "white", label: "White"),
    ]
}

/// Grid of icon choices. The main icon is free; the rest are Premium —
/// tapping one without Premium opens the paywall instead of switching.
struct AppIconPickerView: View {
    @Environment(PurchaseManager.self) private var purchases
    @State private var current: String? = UIApplication.shared.alternateIconName
    @State private var showingPaywall = false
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 88), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(AppIconChoice.all) { choice in
                    tile(choice)
                }
            }
            .padding()

            if !purchases.isPremium {
                Text("The Classic icon is always free. The other colors come with Premium.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .navigationTitle("App Icon")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingPaywall) {
            PaywallView()
        }
        .alert("Couldn't change the icon", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func tile(_ choice: AppIconChoice) -> some View {
        let selected = current == choice.alternateName
        let locked = choice.isPremium && !purchases.isPremium
        return Button {
            select(choice, locked: locked)
        } label: {
            VStack(spacing: 6) {
                Image(choice.previewImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .overlay(alignment: .topTrailing) {
                        if locked {
                            Image(systemName: "lock.fill")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(5)
                                .background(.black.opacity(0.55), in: Circle())
                                .offset(x: 4, y: -4)
                        }
                    }
                    .padding(4)
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3)
                    }
                Text(choice.label)
                    .font(.caption)
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(choice.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(locked ? "Premium" : "")
    }

    private func select(_ choice: AppIconChoice, locked: Bool) {
        if locked {
            showingPaywall = true
            return
        }
        guard choice.alternateName != current,
              UIApplication.shared.supportsAlternateIcons else { return }
        Task { @MainActor in
            do {
                try await UIApplication.shared.setAlternateIconName(choice.alternateName)
                current = choice.alternateName
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
