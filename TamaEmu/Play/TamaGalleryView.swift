import SwiftUI
import TamaCore

struct TamaGalleryView: View {
    @State private var gallery = GalleryViewModel()
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(AppSettings.Keys.appearanceMode) private var appearanceModeRaw = AppSettings.AppearanceMode.system.rawValue
    @AppStorage(AppSettings.Keys.ambientBackgroundEnabled) private var ambientBackgroundEnabled = true

    @State private var showingSettings = false
    @State private var showingDeleteConfirm = false

    /// The device behind the page currently on screen — i.e. the one the
    /// overflow menu (toolbar), its Settings sheet, and its delete
    /// confirmation should all act on.
    private var selectedDevice: TamaDevice? {
        gallery.selectedPage.flatMap { gallery.device(withID: $0) }
    }

    /// The page currently on screen — the one whose colors the full-bleed
    /// background should show, since that's the only page actually visible.
    private var selectedViewModel: PlayViewModel? {
        guard let device = selectedDevice else { return nil }
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
        .preferredColorScheme((AppSettings.AppearanceMode(rawValue: appearanceModeRaw) ?? .system).colorScheme)
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
                ReminderNotificationScheduler.scheduleIfEnabled()
            case .active:
                gallery.pageDidAppear(current)
                ReminderNotificationScheduler.cancel()
            default:
                break
            }
        }
    }

    private func pageView(for device: TamaDevice) -> some View {
        TamaPageView(
            viewModel: gallery.viewModel(for: device),
            ambientBackgroundEnabled: ambientBackgroundEnabled
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
            .indexViewStyle(.page(backgroundDisplayMode: .never))
            .scrollContentBackground(ambientBackgroundEnabled ? .hidden : .visible)
            .background {
                if ambientBackgroundEnabled {
                    BlurredLCDBackground(image: selectedViewModel?.lcdImage)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(ambientBackgroundEnabled ? .hidden : .automatic, for: .navigationBar)
            // Attached once here, to the gallery's single NavigationStack,
            // rather than per-page in TamaPageView — see that view's doc
            // comment for why a per-page toolbar could show up twice.
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let device = selectedDevice, let viewModel = selectedViewModel {
                        Menu {
                            Button {
                                viewModel.togglePause()
                            } label: {
                                Label(
                                    viewModel.isPaused ? "Resume" : "Pause",
                                    systemImage: viewModel.isPaused ? "play.fill" : "pause.fill"
                                )
                            }
                            Button {
                                showingSettings = true
                            } label: {
                                Label("Settings for \(device.title)", systemImage: "gearshape")
                            }
                            Button {
                                gallery.showingImport = true
                            } label: {
                                Label("Add a Tama", systemImage: "plus")
                            }
                            Button {
                                gallery.showingReorder = true
                            } label: {
                                Label("Rearrange Tamas", systemImage: "arrow.up.arrow.down")
                            }
                            Button(role: .destructive) {
                                showingDeleteConfirm = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                if let device = selectedDevice, let viewModel = selectedViewModel {
                    SettingsView(
                        device: device,
                        viewModel: viewModel,
                        onDelete: { gallery.removeDevice(device) },
                        onDeviceImported: { gallery.deviceImported($0) }
                    )
                }
            }
            .confirmationDialog(
                "Delete \(selectedDevice?.title ?? "")?",
                isPresented: $showingDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let device = selectedDevice { gallery.removeDevice(device) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes its firmware and save data from this device. It can be re-imported later, but progress will be lost.")
            }
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
