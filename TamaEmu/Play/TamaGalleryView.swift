import SwiftUI
import TamaCore

struct TamaGalleryView: View {
    @State private var gallery = GalleryViewModel()
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(AppSettings.Keys.accentColorIndex) private var accentColorIndex = 0
    @AppStorage(AppSettings.Keys.ambientBackgroundEnabled) private var ambientBackgroundEnabled = true

    /// The page currently on screen — the one whose colors the full-bleed
    /// background should show, since that's the only page actually visible.
    private var selectedViewModel: PlayViewModel? {
        guard let id = gallery.selectedPage, let device = gallery.device(withID: id) else { return nil }
        return gallery.viewModel(for: device)
    }

    var body: some View {
        Group {
            if gallery.ownedDevices.isEmpty {
                NavigationStack {
                    FirmwareImportView(devices: DeviceCatalog.all()) { device, _ in
                        gallery.deviceImported(device)
                    }
                    .navigationTitle("TamaEmu")
                    .navigationBarTitleDisplayMode(.inline)
                }
            } else {
                galleryStack
            }
        }
        .tint(TamaPalette.accentColor(at: accentColorIndex))
        .onChange(of: gallery.selectedPage) { old, new in
            if let old, old != new, let oldDevice = gallery.device(withID: old) {
                gallery.pageDidDisappear(oldDevice)
            }
            if let new, new != old, let newDevice = gallery.device(withID: new) {
                gallery.pageDidAppear(newDevice)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Only the currently visible page is ever live, so background/
            // foreground only needs to touch that one page's engine.
            guard let currentID = gallery.selectedPage, let current = gallery.device(withID: currentID) else { return }
            switch newPhase {
            case .background:
                gallery.pageDidDisappear(current)
                BackgroundRefresh.scheduleNext()
            case .active:
                gallery.pageDidAppear(current)
            default:
                break
            }
        }
    }

    /// Pulled out of `galleryStack`'s ForEach so that closure stays a single
    /// call — with all five of TamaPageView's closures inlined there the
    /// type checker couldn't resolve the TabView/ForEach builder in
    /// reasonable time.
    private func pageView(for device: TamaDevice) -> some View {
        TamaPageView(
            viewModel: gallery.viewModel(for: device),
            onDelete: { gallery.removeDevice(device) },
            onDeviceImported: { gallery.deviceImported($0) },
            onAddTama: { gallery.showingImport = true },
            onRearrange: { gallery.showingReorder = true }
        )
    }

    private var galleryStack: some View {
        NavigationStack {
            TabView(selection: Binding(
                get: { gallery.selectedPage ?? gallery.ownedDevices[0].id },
                set: { gallery.selectedPage = $0 }
            )) {
                ForEach(gallery.ownedDevices) { device in
                    pageView(for: device)
                        .tag(device.id)
                }
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: ambientBackgroundEnabled ? .interactive : .always))
            .scrollContentBackground(ambientBackgroundEnabled ? .hidden : .visible)
            .background {
                if ambientBackgroundEnabled {
                    BlurredLCDBackground(image: selectedViewModel?.lcdImage)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(ambientBackgroundEnabled ? .hidden : .automatic, for: .navigationBar)
            .sheet(isPresented: $gallery.showingReorder) {
                ReorderTamasView(gallery: gallery)
            }
            .sheet(isPresented: $gallery.showingImport) {
                NavigationStack {
                    FirmwareImportView(devices: DeviceCatalog.all()) { device, _ in
                        gallery.deviceImported(device)
                        gallery.showingImport = false
                    }
                    .navigationTitle("Add a Tama")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { gallery.showingImport = false }
                        }
                    }
                }
            }
        }
    }
}

#Preview {
    TamaGalleryView()
}
