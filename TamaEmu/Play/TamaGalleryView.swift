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
    @State private var showingSetClockConfirm = false
    @State private var showingSetPointsPrompt = false
    @State private var pointsInputText = ""
    @State private var toast: String?
    @State private var isRecording = false
    @State private var activeRecorder: ScreenRecorder?
    @State private var recordingStartDate: Date?
    @State private var showingPaywall = false
    /// One connection to another phone at a time, for the whole gallery --
    /// it outlives the sheet that sets it up (see NearbyLinkView).
    @State private var nearbyLink = NearbyLinkSession()
    @State private var showingNearbyLink = false
    @State private var showingNewStarConfirm = false

    /// Ambient Background is a premium feature — forced off for free users
    /// regardless of their own stored preference, which is left untouched
    /// so it springs back on the moment they unlock Premium.
    private var effectiveAmbientBackgroundEnabled: Bool {
        ambientBackgroundEnabled && purchases.isPremium
    }

    /// Whether the page on screen shows its own live backdrop: Tomomix's
    /// sky (free, for everyone), or a color Tama's blurred screen with the
    /// Premium Ambient Background on. Every other page gets the theme.
    private var ambientActive: Bool {
        selectedTomomix != nil || (effectiveAmbientBackgroundEnabled && selectedViewModel != nil)
    }

    /// First Tama is always free; anything past that needs Premium.
    /// Pulled out of the `.alert` call itself — inlined there, this
    /// Binding's closures pushed an already-long modifier chain past what
    /// the type checker could resolve in reasonable time.
    private var toastIsPresented: Binding<Bool> {
        Binding(get: { toast != nil }, set: { if !$0 { toast = nil } })
    }

    private func requestAddTama() {
        // The built-in tomomix doesn't use up the free Tama.
        if gallery.emulatedDeviceCount > 0 && !purchases.isPremium {
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

    /// Same idea for a P1-era page, which gets its own (shorter) toolbar.
    private var selectedV1ViewModel: V1PlayViewModel? {
        guard let device = selectedDevice, device.family == .v1 else { return nil }
        return gallery.v1ViewModel(for: device)
    }

    private func settingsTarget(for device: TamaDevice) -> SettingsTarget {
        switch device.family {
        case .ctama: .color(gallery.viewModel(for: device))
        case .v1: .firstGen(gallery.v1ViewModel(for: device))
        case .t7: .t7(gallery.t7ViewModel(for: device))
        case .tomomix: .tomomix(gallery.tomomixViewModel())
        }
    }

    private var selectedTomomix: TomomixViewModel? {
        guard let device = selectedDevice, device.family == .tomomix else { return nil }
        return gallery.tomomixViewModel()
    }

    var body: some View {
        Group {
            if gallery.ownedDevices.isEmpty {
                // No pets at all: start the built-in one, or bring a ROM.
                WelcomeView(
                    onStartTomomix: { gallery.addTomomix() },
                    onImported: { gallery.deviceImported($0) }
                )
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
        // Tapping a Tama's notification opens the app on that Tama.
        // Picked up here on a cold launch (the tap arrived before this
        // view existed), when coming forward (below), or right away if
        // the app was already open.
        .onAppear { showNotifiedDevice() }
        .onChange(of: NotificationRouter.shared.pendingDeviceID) { _, _ in
            if scenePhase == .active { showNotifiedDevice() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Before reading the current page, so the Tama that comes to
            // life is the one the tapped notification was about.
            if newPhase == .active { showNotifiedDevice() }
            // Only the currently visible page is ever live, so background/
            // foreground only needs to touch that one page's engine.
            guard let currentID = gallery.selectedPage, let current = gallery.device(withID: currentID) else { return }
            switch newPhase {
            case .background:
                gallery.pageDidDisappear(current)
                // The tomomix's own page schedules its calls when it
                // stops; from any other page, schedule them from its save.
                if current.family != .tomomix, let save = TomomixStore.load() {
                    TomomixNotifications.schedule(for: save)
                }
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
        case .tomomix:
            TomomixPageView(model: gallery.tomomixViewModel(), ambientBackgroundEnabled: true)
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
        saveScreenshot(renderLCDSnapshot(image: viewModel.lcdImage, side: 512))
    }

    private func saveScreenshot(_ cgImage: CGImage?) {
        guard let cgImage else {
            toast = "Couldn't capture the screen."
            return
        }
        let uiImage = UIImage(cgImage: cgImage)
        requestPhotoAddAccess { granted in
            guard granted else {
                toast = "Tomomix needs permission to add photos. Enable it in Settings."
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
    private func toggleRecording(for viewModel: any ScreenRecordable) {
        if isRecording {
            stopRecording()
        } else {
            startRecording(for: viewModel)
        }
    }

    private func startRecording(for viewModel: any ScreenRecordable) {
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
                toast = "Tomomix needs permission to add photos. Enable it in Settings."
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

    // MARK: - Top bar: gear + ⋯ (same on every page)
    //
    // The rule for every model, present and future: ⋯ holds what you
    // reach for while playing (pause, model-specific actions), then
    // moving between devices. Everything else -- this Tama's look, save,
    // backups, restart, delete, and the app-wide settings -- lives in
    // Settings (the gear), so it's reachable from every page.

    @ToolbarContentBuilder
    private func topBar<PlayItems: View>(@ViewBuilder playItems: () -> PlayItems) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Section { playItems() }
                Section {
                    Button {
                        requestAddTama()
                    } label: {
                        Label("Add a Device", systemImage: "plus")
                    }
                    if gallery.canAddTomomix {
                        Button {
                            gallery.addTomomix()
                        } label: {
                            Label("Add Tomomix", systemImage: "sparkles")
                        }
                    }
                    Button {
                        gallery.showingReorder = true
                    } label: {
                        Label("Rearrange Devices", systemImage: "arrow.up.arrow.down")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
        }
    }

    private func pauseButton(isPaused: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            Label(isPaused ? "Resume" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill")
        }
    }

    /// Camera and video, Premium on every model except Tomomix.
    @ToolbarContentBuilder
    private func captureButtons(
        premiumOnly: Bool = true,
        recordable: any ScreenRecordable,
        screenshot: @escaping () -> CGImage?
    ) -> some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            Button {
                if !premiumOnly || purchases.isPremium {
                    saveScreenshot(screenshot())
                } else {
                    showingPaywall = true
                }
            } label: {
                Image(systemName: "camera")
            }
        }
        ToolbarItem(placement: .bottomBar) {
            Button {
                if !premiumOnly || purchases.isPremium {
                    toggleRecording(for: recordable)
                } else {
                    showingPaywall = true
                }
            } label: {
                Image(systemName: isRecording ? "stop.circle.fill" : "video")
                    .foregroundStyle(isRecording ? .red : .primary)
            }
        }
    }

    @ToolbarContentBuilder
    private func v1ToolbarContent(viewModel: V1PlayViewModel) -> some ToolbarContent {
        topBar {
            pauseButton(isPaused: viewModel.isPaused) { viewModel.togglePause() }
        }
        captureButtons(recordable: viewModel) { viewModel.screenshot() }
    }

    @ToolbarContentBuilder
    private func t7ToolbarContent(viewModel: T7PlayViewModel) -> some ToolbarContent {
        topBar {
            pauseButton(isPaused: viewModel.isPaused) { viewModel.togglePause() }
        }
        captureButtons(recordable: viewModel) { viewModel.screenshot() }
    }

    @ToolbarContentBuilder
    private func tomomixToolbarContent(model: TomomixViewModel) -> some ToolbarContent {
        // Screenshot and video, free on Tomomix (a taste of Premium).
        captureButtons(premiumOnly: false, recordable: model) { model.recordingFrame(side: 1024) }
        topBar {
            pauseButton(isPaused: model.paused) { model.togglePause() }
            Button {
                // Ask first only while it's alive: after the ending a
                // new star is the expected next step.
                if model.brain.phase == .departed { model.newStar() } else { showingNewStarConfirm = true }
            } label: {
                Label("Send a New Shooting Star", systemImage: "moon.stars")
            }
        }
    }

    /// Split out from `galleryStack`'s `.toolbar` — a single closure
    /// declaring all of this inline was too much for the type-checker to
    /// resolve in reasonable time, not a design choice.
    @ToolbarContentBuilder
    private func topToolbarContent(viewModel: PlayViewModel) -> some ToolbarContent {
        topBar {
            pauseButton(isPaused: viewModel.isPaused) { viewModel.togglePause() }
            Button {
                showingSetClockConfirm = true
            } label: {
                Label("Sync Clock to Now", systemImage: "clock.arrow.2.circlepath")
            }
            if NearbyLinkSession.supports(viewModel.selectedDevice) {
                Button {
                    showingNearbyLink = true
                } label: {
                    Label(
                        viewModel.linkPeerName == nil ? "Connect Nearby…" : "Nearby Connection…",
                        systemImage: "antenna.radiowaves.left.and.right"
                    )
                }
            }
            if ["plus-color", "id", "4u-plain"].contains(viewModel.selectedDevice.id) {
                Button {
                    if purchases.isPremium {
                        pointsInputText = ""
                        showingSetPointsPrompt = true
                    } else {
                        showingPaywall = true
                    }
                } label: {
                    Label(
                        purchases.isPremium ? "Set Points…" : "Set Points… (Premium)",
                        systemImage: purchases.isPremium ? "number.circle" : "star.fill"
                    )
                }
            }
        }
    }

    /// Camera and the record toggle are adjacent .bottomBar items, which
    /// iOS pairs into one capsule on its own — same mechanism as the top
    /// bar's Settings/⋯ pair. The fixed `ToolbarSpacer` (iOS 26's own API
    /// for this) is what keeps the translate button in its own separate
    /// capsule instead of fusing with that pair.
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
                    if let device = selectedDevice {
                        SettingsView(
                            device: device,
                            target: settingsTarget(for: device),
                            onDelete: { gallery.removeDevice(device) }
                        )
                    }
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
                .alert("Set Points", isPresented: $showingSetPointsPrompt) {
                    TextField("e.g. 5000", text: $pointsInputText)
                        .keyboardType(.numberPad)
                        .onChange(of: pointsInputText) { _, newValue in
                            let filtered = String(newValue.filter(\.isNumber).prefix(5))
                            if filtered != newValue { pointsInputText = filtered }
                        }
                    Button("Set") {
                        if let value = Int(pointsInputText), let viewModel = selectedViewModel {
                            viewModel.restartTamaClock { engine in
                                _ = engine.setPoints(value)
                            }
                        }
                    }
                    .disabled(pointsInputText.isEmpty)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Up to 5 digits (max 99999). This replaces the current total.")
                }
                .sheet(isPresented: $showingNearbyLink) {
                    if let device = selectedDevice {
                        NearbyLinkView(session: nearbyLink, device: device) { linkedDevice, port, peerName in
                            gallery.viewModel(for: linkedDevice).setLink(port: port, peerName: peerName)
                        }
                    }
                }
                // A connected Tama that gets deleted takes its connection
                // with it.
                .onChange(of: gallery.ownedDevices.map(\.id)) { _, ids in
                    if let linked = nearbyLink.device, !ids.contains(linked.id) {
                        nearbyLink.end()
                    }
                }
                .sheet(isPresented: $gallery.showingReorder) {
                    ReorderTamasView(gallery: gallery)
                }
                .confirmationDialog(
                    "Send a new shooting star?",
                    isPresented: $showingNewStarConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Send a New Star", role: .destructive) {
                        selectedTomomix?.newStar()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Your current tomomix will be gone, and a new one starts from a falling star.")
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
                        .navigationTitle("Add a Device")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { gallery.showingImport = false }
                            }
                        }
                    }
                }
        }
    }

    private func showNotifiedDevice() {
        guard let id = NotificationRouter.shared.take(), gallery.device(withID: id) != nil else { return }
        gallery.selectedPage = id
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
            .scrollContentBackground(.hidden)
            .background {
                if !ambientActive {
                    // Each device has its own theme ("Plain" draws the
                    // system background, so this always fills the screen).
                    if let device = selectedDevice {
                        DeviceThemeBackground(device: device)
                            .id(device.id)
                    }
                } else {
                    // Its own view on purpose: reading `lcdImage` right
                    // here made this whole gallery body — toolbar and the
                    // open ⋯ menu included — rebuild on every LCD frame
                    // change, which is what made the menu pulse and drop
                    // taps while the Tama was animating.
                    if let model = selectedTomomix {
                        // Tomomix: its own sky, edge to edge.
                        TomoAmbientSky(model: model)
                    } else {
                        LiveAmbientBackground(viewModel: selectedViewModel)
                    }
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
            .toolbarBackground(.hidden, for: .navigationBar)
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
                } else if let viewModel = selectedV1ViewModel {
                    v1ToolbarContent(viewModel: viewModel)
                } else if let model = selectedTomomix {
                    tomomixToolbarContent(model: model)
                } else if let device = selectedDevice, device.family == .t7 {
                    t7ToolbarContent(viewModel: gallery.t7ViewModel(for: device))
                }
            }
    }
}

/// The only place the gallery reads the live LCD frame, so a frame change
/// re-renders just this backdrop and nothing else on the screen.
private struct LiveAmbientBackground: View {
    let viewModel: PlayViewModel?

    var body: some View {
        BlurredLCDBackground(image: viewModel?.lcdImage)
    }
}

/// The tomomix's Ambient Background: the same sky as its window and
/// outdoors (time of day, or the starry night), filling the whole phone
/// screen, toned down for dark mode and lifted for light mode.
private struct TomoAmbientSky: View {
    let model: TomomixViewModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: model.paused)) { timeline in
            let now = model.frozenAt ?? timeline.date
            let brain = model.brain
            // Night for the birth, the ending, and the light off.
            // The light switch doesn't change the time of day outside.
            let lit = brain.phase == .alive && !model.waitingForStar
            ZStack {
                TomoSky(simNow: model.simTime(at: now), lightsOn: lit)
                if scheme == .dark {
                    Color.black.opacity(0.45)
                } else {
                    // A screen blend lifts the dark parts and leaves light ones alone.
                    Color.white.opacity(0.5).blendMode(.screen)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
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
