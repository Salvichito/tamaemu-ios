import SwiftUI
import TamaCore

struct TamaGalleryView: View {
    @State private var gallery = GalleryViewModel()
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(AppSettings.Keys.accentColorIndex) private var accentColorIndex = 0

    var body: some View {
        Group {
            if gallery.ownedDevices.isEmpty {
                NavigationStack {
                    FirmwareImportView(devices: DeviceCatalog.all()) { device, _ in
                        gallery.deviceImported(device)
                    }
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                }
            } else {
                NavigationStack {
                    TabView(selection: Binding(
                        get: { gallery.selectedPage ?? gallery.ownedDevices[0].id },
                        set: { gallery.selectedPage = $0 }
                    )) {
                        ForEach(gallery.ownedDevices) { device in
                            TamaPageView(
                                viewModel: gallery.viewModel(for: device),
                                onDelete: { gallery.removeDevice(device) },
                                onDeviceImported: { gallery.deviceImported($0) }
                            )
                            .tag(device.id)
                        }
                    }
                    .tabViewStyle(.page)
                    .indexViewStyle(.page(backgroundDisplayMode: .always))
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                gallery.showingImport = true
                            } label: {
                                Image(systemName: "plus")
                            }
                        }
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
}

#Preview {
    TamaGalleryView()
}
