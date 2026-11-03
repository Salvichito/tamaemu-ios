import Photos
import SwiftUI
import TamaCore
import UIKit

struct TamaGalleryView: View {
    @State private var gallery = GalleryViewModel()
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(AppSettings.Keys.appearanceMode) private var appearanceModeRaw = AppSettings.AppearanceMode.system.rawValue
    @AppStorage(AppSettings.Keys.ambientBackgroundEnabled) private var ambientBackgroundEnabled = true

    @State private var showingSettings = false
    @State private var showingDeleteConfirm = false
    @State private var toast: String?
    @State private var isRecording = false
    @State private var activeRecorder: ScreenRecorder?

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

    /// Asks for add-only Photos access (never full-library) and runs
    /// `save`, reporting the outcome via `toast`. Shared by the screenshot
    /// and the video recording, which only differ in what they hand to
    /// `save`.
    private func requestPhotoAddAccess(_ completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            DispatchQueue.main.async {
                completion(status == .authorized || status == .limited)
            }
        }
    }

    /// Renders the LCD exactly as it looks on screen — same sharp-pixels/
    /// scanline settings LCDView itself reads from AppStorage, via the
    /// same renderLCDSnapshot ScreenRecorder samples once per video frame
    /// — then saves it to Photos.
    private func saveScreenshot(of viewModel: PlayViewModel) {
        guard let cgImage = renderLCDSnapshot(image: viewModel.lcdImage, side: 512) else {
            toast = "Couldn't capture the screen."
            return
        }
        let uiImage = UIImage(cgImage: cgImage)
        requestPhotoAddAccess { granted in
            guard granted else {
                toast = "TamaEmu needs permission to add photos. Enable it in Settings."
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: uiImage)
            }) { success, error in
                DispatchQueue.main.async {
                    toast = success ? "Saved to Photos." : (error?.localizedDescription ?? "Couldn't save the screenshot.")
                }
            }
        }
    }

    /// Hold-to-record: starts on the record button's long-press `perform`,
    /// stopped by `stopRecording()` on release (see the toolbar below).
    private func startRecording(for viewModel: PlayViewModel) {
        guard !isRecording else { return }
        let recorder = ScreenRecorder()
        do {
            try recorder.start(viewModel: viewModel)
            activeRecorder = recorder
            isRecording = true
        } catch {
            toast = "Couldn't start recording."
        }
    }

    private func stopRecording() {
        guard let recorder = activeRecorder else { return }
        isRecording = false
        activeRecorder = nil
        recorder.stop(discard: false) { url in
            guard let url else {
                toast = "Couldn't save the recording."
                return
            }
            saveVideo(at: url)
        }
    }

    private func saveVideo(at url: URL) {
        requestPhotoAddAccess { granted in
            guard granted else {
                toast = "TamaEmu needs permission to add photos. Enable it in Settings."
                try? FileManager.default.removeItem(at: url)
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { success, error in
                DispatchQueue.main.async {
                    toast = success ? "Saved to Photos." : (error?.localizedDescription ?? "Couldn't save the recording.")
                }
                try? FileManager.default.removeItem(at: url)
            }
        }
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
                    if let viewModel = selectedViewModel {
                        // Tap vs. hold, like the system Camera app's
                        // shutter: `perform` only fires after the hold
                        // clears minimumDuration, so by the time
                        // `onPressingChanged` sees the release, `isRecording`
                        // reliably tells the two cases apart — a quick tap
                        // (never fired `perform`) from a held recording.
                        Image(systemName: isRecording ? "record.circle.fill" : "camera")
                            .foregroundStyle(isRecording ? .red : .primary)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                            .onLongPressGesture(
                                minimumDuration: 0.35,
                                maximumDistance: 50,
                                perform: { startRecording(for: viewModel) },
                                onPressingChanged: { pressing in
                                    guard !pressing else { return }
                                    if isRecording {
                                        stopRecording()
                                    } else {
                                        saveScreenshot(of: viewModel)
                                    }
                                }
                            )
                    }
                }
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
            .alert(toast ?? "", isPresented: Binding(get: { toast != nil }, set: { if !$0 { toast = nil } })) {
                Button("OK") { toast = nil }
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
