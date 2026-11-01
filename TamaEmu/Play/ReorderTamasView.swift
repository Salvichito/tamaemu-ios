import SwiftUI
import TamaCore

/// Lets the player drag Tamas into a new gallery order. A plain List's
/// move handles only show up once edit mode is active, and there's nothing
/// else to edit here, so edit mode is just forced on for this sheet's
/// lifetime rather than exposed as a separate toggle.
struct ReorderTamasView: View {
    let gallery: GalleryViewModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(gallery.ownedDevices) { device in
                    Text(device.title)
                }
                .onMove { gallery.moveDevices(fromOffsets: $0, toOffset: $1) }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Rearrange Tamas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
