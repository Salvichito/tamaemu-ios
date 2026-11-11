import Photos
import SwiftUI
import TamaCore
import UIKit

struct TamaGalleryView: View {
    @State private var gallery = GalleryViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(PurchaseManager.self) private var purchases

    @AppStorage(AppSettings.Keys.appearanceMode) private var appearanceModeRaw = AppSettings.AppearanceMode.system.rawValue
    @AppStorage(AppSettings.Keys.ambientBackgroundEnabled) private var ambientBackgroundEnabled = true

    @State private var showingSettings = false
    @State private var showingDeleteConfirm = false
    @State private var showingSetClockConfirm = false
    @State private var toast: String?
    @State private var isRecording = false
    @State private var activeRecorder: ScreenRecorder?
    @State private var recordingStartDate: Date?
    @State private var showingPaywall = false

    /// Ambient Background is a premium feature — forced off for free users
    /// regardless of their own stored preference, which is left untouched
    /// so it springs back on the moment they unlock Premium.
    private var effectiveAmbientBackgroundEnabled: Bool {
        ambientBackgroundEnabled && purchases.isPremium
    }

    /// First Tama is always free; anything past that needs Premium.
    /// Pulled out of the `.alert` call itself — inlined there, this
    /// Binding's closures pushed an already-long modifier chain past what
    /// the type checker could resolve in reasonable time.
    private var toastIsPresented: Binding<Bool> {
        Binding(get: { toast != nil }, set: { if !$0 { toast = nil } })
    }

    private func requestAddTama() {
        if !gallery.ownedDevices.isEmpty && !purchases.isPremium {
            showingPaywall = true
        } else {
            gallery.showingImport = true
        }
    }

    /// The device behind the page currently on screen — i.e. the one the
    /// overflow menu (toolbar), its Settings sheet, and its delete
    /// confirmation should all act on.
    private var selectedDevice: TamaDevice? {
        gallery.selectedPage.flatMap { gallery.device(withID: $0) }
    }

    /// The page currently on screen — the one whose colors the full-bleed
    /// background should show, since that's the only page actually visible.
    /// `nil` for a V1 or T7 page: neither family has a PlayViewModel at
    /// all, which is also what keeps the CTama-specific toolbar
    /// (screenshot, recording, translation, set clock) from showing for
    /// them below.
    private var selectedViewModel: PlayViewModel? {
        guard let device = selectedDevice, device.family == .ctama else { return nil }
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
                // Scoped to this one onChange — not GalleryViewModel's
                // pageDidDisappear, which also fires on an ordinary swipe
                // between owned Tamas while the app stays open. The lock
                // screen widget's timer is about leaving the app entirely.
                WidgetSharedState.recordAppClosed()
            case .active:
                gallery.pageDidAppear(current)
                ReminderNotificationScheduler.cancel()
            default:
                break
            }
        }
    }

    @ViewBuilder
    private func pageView(for device: TamaDevice) -> some View {
        switch device.family {
        case .ctama:
            TamaPageView(
                viewModel: gallery.viewModel(for: device),
                ambientBackgroundEnabled: effectiveAmbientBackgroundEnabled
            )
        case .v1:
            V1PageView(
                viewModel: gallery.v1ViewModel(for: device),
                ambientBackgroundEnabled: effectiveAmbientBackgroundEnabled
            )
        case .t7:
            T7PageView(
                viewModel: gallery.t7ViewModel(for: device),
                ambientBackgroundEnabled: effectiveAmbientBackgroundEnabled
            )
        }
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

    /// The video button is a toggle, not a hold: tap once to start, tap
    /// again to stop — matched to it being its own dedicated button now,
    /// rather than sharing the camera button via tap-vs-hold.
    private func toggleRecording(for viewModel: PlayViewModel) {
        if isRecording {
            stopRecording()
        } else {
            startRecording(for: viewModel)
        }
    }

    private func startRecording(for viewModel: PlayViewModel) {
        guard !isRecording else { return }
        let recorder = ScreenRecorder()
        do {
            try recorder.start(viewModel: viewModel)
            activeRecorder = recorder
            isRecording = true
            recordingStartDate = Date()
        } catch {
            toast = "Couldn't start recording."
        }
    }

    private func stopRecording() {
        guard let recorder = activeRecorder else { return }
        isRecording = false
        activeRecorder = nil
        recordingStartDate = nil
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

    /// Moved here from SettingsView — jumps straight to the current time,
    /// unlike normal catch-up which ages through every second in between.
    private func syncClockToNow(for viewModel: PlayViewModel) {
        viewModel.restartTamaClock { engine in
            let now = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
            _ = engine.setClock(hour: now.hour ?? 0, minute: now.minute ?? 0, second: now.second ?? 0)
        }
    }

    /// A V1 page's whole toolbar: just enough to add/rearrange/delete
    /// Tamas without being stranded on this page, since it has no
    /// PlayViewModel for the pause/settings/screenshot/recording/
    /// translation/set-clock items below to hook into — those are all
    /// still CTama-only, undecided whether (or how) they'd apply to this
    /// family at all.
    @ToolbarContentBuilder
    private func minimalToolbarContent() -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    requestAddTama()
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

    /// Split out from `galleryStack`'s `.toolbar` — a single closure
    /// declaring all of this inline was too much for the type-checker to
    /// resolve in reasonable time, not a design choice.
    @ToolbarContentBuilder
    private func topToolbarContent(viewModel: PlayViewModel) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
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
                    requestAddTama()
                } label: {
                    Label("Add a Tama", systemImage: "plus")
                }
                Button {
                    gallery.showingReorder = true
                } label: {
                    Label("Rearrange Tamas", systemImage: "arrow.up.arrow.down")
                }
                Button {
                    showingSetClockConfirm = true
                } label: {
                    Label("Sync Clock to Now", systemImage: "clock.arrow.2.circlepath")
                }
                if ["plus-color", "id", "4u-plain"].contains(viewModel.selectedDevice.id) {
                    Button {
                        if purchases.isPremium {
                            viewModel.restartTamaClock { engine in
                                _ = engine.addPoints(1000)
                            }
                        } else {
                            showingPaywall = true
                        }
                    } label: {
                        Label(purchases.isPremium ? "Add 1000 Points" : "Add 1000 Points (Premium)", systemImage: "plus.circle")
                    }
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

    /// Camera and the record toggle are adjacent .bottomBar items, which
    /// iOS pairs into one capsule on its own — same mechanism as the top
    /// bar's Settings/⋯ pair. The fixed `ToolbarSpacer` (iOS 26's own API
    /// for this) is what keeps the translate button in its own separate
    /// capsule instead of fusing with that pair; below iOS 26 none of this
    /// capsule-pairing exists in the first place, so there's nothing to
    /// fall back to.
    @ToolbarContentBuilder
    private func bottomToolbarContent(viewModel: PlayViewModel) -> some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            Button {
                if purchases.isPremium {
                    saveScreenshot(of: viewModel)
                } else {
                    showingPaywall = true
                }
            } label: {
                Image(systemName: "camera")
            }
        }
        ToolbarItem(placement: .bottomBar) {
            Button {
                if purchases.isPremium {
                    toggleRecording(for: viewModel)
                } else {
                    showingPaywall = true
                }
            } label: {
                Image(systemName: isRecording ? "stop.circle.fill" : "video")
                    .foregroundStyle(isRecording ? .red : .primary)
            }
        }
        if #available(iOS 27.0, *) {
            // Its own capsule, not fused with camera/video — the spacer
            // above splits it off.
            ToolbarSpacer(.fixed, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                // One-shot: tap grabs whatever's on the LCD right now and
                // translates it once — not a toggle, nothing keeps
                // watching the screen afterward. Which engine it uses (and
                // whether a key is set at all) is a Settings question.
                Button {
                    if purchases.isPremium {
                        viewModel.translateNow()
                    } else {
                        showingPaywall = true
                    }
                } label: {
                    // Both the icon and the spinner stay mounted the whole
                    // time — only their opacity toggles. An if/else here
                    // swaps between two different view identities, and
                    // iOS 26's bottom-bar capsules visibly animate an
                    // item's insertion/removal (that's the "jumps to the
                    // bottom center" — a system transition playing, not an
                    // actual layout bug). Never removing either view in
                    // the first place sidesteps that entirely.
                    ZStack {
                        Image(systemName: "character.bubble")
                            .opacity(viewModel.isTranslating ? 0 : 1)
                        ProgressView()
                            .opacity(viewModel.isTranslating ? 1 : 0)
                    }
                    .frame(width: 20, height: 20)
                }
                .disabled(viewModel.isTranslating)
            }
        }
    }

    private var galleryStack: some View {
        NavigationStack {
            tabViewWithToolbar
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
                .confirmationDialog(
                    "Set the clock to the current time?",
                    isPresented: $showingSetClockConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Set clock", role: .destructive) {
                        if let viewModel = selectedViewModel { syncClockToNow(for: viewModel) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This jumps straight to the current time, unlike normal catch-up which ages through every second in between.")
                }
                .sheet(isPresented: $gallery.showingReorder) {
                    ReorderTamasView(gallery: gallery)
                }
                .sheet(isPresented: $showingPaywall) {
                    PaywallView()
                }
                .alert(toast ?? "", isPresented: toastIsPresented) {
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

    /// Split out of `galleryStack` — folding this back into one modifier
    /// chain (adding the paywall sheet to it did, briefly) is enough to
    /// push the type checker past "reasonable time"; two separate `some
    /// View` properties keep each chain's inference small.
    private var tabViewWithToolbar: some View {
        TabView(selection: Binding(
                // Not ownedDevices[0] — removing the last Tama can leave
                // this read running one more time (SwiftUI re-evaluates the
                // old galleryStack graph briefly while swapping to the
                // empty-state view), and an unconditional [0] subscript on
                // an empty array there was a real crash on-device, not just
                // in theory.
                get: { gallery.selectedPage ?? gallery.ownedDevices.first?.id ?? "" },
                set: { gallery.selectedPage = $0 }
            )) {
                ForEach(gallery.ownedDevices) { device in
                    pageView(for: device)
                        .tag(device.id)
                }
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .never))
            .scrollContentBackground(effectiveAmbientBackgroundEnabled ? .hidden : .visible)
            .background {
                if effectiveAmbientBackgroundEnabled {
                    BlurredLCDBackground(image: selectedViewModel?.lcdImage)
                }
            }
            // Shows while recording regardless of which page is visible —
            // the LCD it's floating over is whichever one is currently on
            // screen, which is always the one being recorded.
            .overlay(alignment: .top) {
                if let recordingStartDate {
                    RecordingBadge(startDate: recordingStartDate)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(effectiveAmbientBackgroundEnabled ? .hidden : .automatic, for: .navigationBar)
            // Attached once here, to the gallery's single NavigationStack,
            // rather than per-page in TamaPageView — see that view's doc
            // comment for why a per-page toolbar could show up twice.
            //
            // Plain ToolbarItems at standard placements, nothing hand-
            // drawn — this is what actually matches the system apps
            // (Calendar's own top/bottom bars collapse into the same kind
            // of trailing sidebar on an iPhone Duo that this does). Settings
            // and ⋯ are adjacent .topBarTrailing items, which iOS pairs
            // into one capsule on its own. Camera and the record toggle
            // are adjacent .bottomBar items for the same reason; a fixed
            // ToolbarSpacer (iOS 26's own API for this — unavailable
            // below that, where none of this capsule-pairing happens
            // regardless) breaks Time Sync into its own, separate capsule
            // rather than fusing all three together.
            .toolbar {
                if let viewModel = selectedViewModel {
                    topToolbarContent(viewModel: viewModel)
                    bottomToolbarContent(viewModel: viewModel)
                } else if selectedDevice != nil {
                    minimalToolbarContent()
                }
            }
    }
}

/// A red blinking dot + live MM:SS, shown while recording. `Text(_:style:
/// .timer)` ticks on its own — no Timer/@State needed to keep the count
/// current.
private struct RecordingBadge: View {
    let startDate: Date
    @State private var dotVisible = true

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .opacity(dotVisible ? 1 : 0.25)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                        dotVisible = false
                    }
                }
            Text(startDate, style: .timer)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.55), in: Capsule())
    }
}

#Preview {
    TamaGalleryView()
        .environment(PurchaseManager())
}
