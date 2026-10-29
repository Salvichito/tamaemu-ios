import SwiftUI
import WidgetKit

struct TamaWidgetView: View {
    let entry: TamaEntry

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image = entry.image {
                    // .fill + clipped, not .fit — this is meant to use the
                    // full rounded-square area; letting the system's own
                    // corner rounding cut into the image is the point, not
                    // a bug to work around with extra padding.
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "pawprint.fill")
                            .font(.title2)
                        Text("Open TamaEmu")
                            .font(.caption2)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .foregroundStyle(.secondary)
                }
            }
        }
        // Mandatory on iOS 17 — a plain background color/material alone
        // triggers a runtime warning and visibly broken rendering.
        .containerBackground(for: .widget) {
            Color(.systemBackground)
        }
    }
}
