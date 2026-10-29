import SwiftUI
import WidgetKit

struct TamaWidgetView: View {
    let entry: TamaEntry

    var body: some View {
        Group {
            if let image = entry.image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(1, contentMode: .fit)
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "pawprint.fill")
                        .font(.title2)
                    Text("Open TamaEmu")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
        }
        // Mandatory on iOS 17 — a plain background color/material alone
        // triggers a runtime warning and visibly broken rendering.
        .containerBackground(for: .widget) {
            Color(.systemBackground)
        }
    }
}
