import SwiftUI
import TamaCore

/// Which kind of Tama the Settings screen is for. Every model gets the
/// same screen; each part shows only when that model supports it.
enum SettingsTarget {
    case color(PlayViewModel)
    case firstGen(V1PlayViewModel)
    case t7(T7PlayViewModel)
    case t18(T18PlayViewModel)
    case tomomix(TomomixViewModel)

    var backupHost: SaveBackupHost {
        switch self {
        case .color(let vm): vm
        case .firstGen(let vm): vm
        case .t7(let vm): vm
        case .t18(let vm): vm
        case .tomomix(let model): model
        }
    }

    var isColor: Bool { if case .color = self { true } else { false } }
    var isTomomix: Bool { if case .tomomix = self { true } else { false } }

    /// Export/Import Save.
    var supportsSaveTransfer: Bool {
        if case .firstGen = self { false } else { true }
    }

    /// Restart (soft reset). Every model has one (a baseline feature).
    var supportsRestart: Bool { !isTomomix }

    @MainActor func prepareExportURL() -> URL? {
        switch self {
        case .color(let vm): vm.prepareExportURL()
        case .t7(let vm): vm.prepareExportURL()
        case .t18(let vm): vm.prepareExportURL()
        case .tomomix(let model): model.prepareExportURL()
        case .firstGen: nil
        }
    }

    @MainActor func importSave(from url: URL) throws {
        switch self {
        case .color(let vm): try vm.importSave(from: url)
        case .t7(let vm): try vm.importSave(from: url)
        case .t18(let vm): try vm.importSave(from: url)
        case .tomomix(let model): try model.importSave(from: url)
        case .firstGen: break
        }
    }

    @MainActor func restart() {
        switch self {
        case .color(let vm): vm.restartTama()
        case .firstGen(let vm): vm.restartTama()
        case .t7(let vm): vm.restartTama()
        case .t18(let vm): vm.restartTama()
        case .tomomix: break // its restart is "Send a New Shooting Star" in ⋯
        }
    }

    /// What Restart does to the game, in the confirmation.
    var restartMessage: String {
        switch self {
        case .color, .tomomix:
            "Same save data, but the CPU and clock reset — like taking the battery out and back in."
        case .firstGen:
            "Like taking the battery out and back in: this model keeps everything in memory, so the game starts over from the beginning. What's there now is kept in Backups, so you can undo this."
        case .t7:
            "Like pressing the toy's reset button. What's there now is kept in Backups, so you can undo this."
        case .t18:
            "Like taking the battery out and back in: the game's own save is kept, and it starts at CONTINUE / RESET ALL. What's there now is kept in Backups, so you can undo this."
        }
    }
}

/// The gear button's screen, for whichever Tama is on screen. The rule
/// (see the ⋯ menus in TamaGalleryView): ⋯ holds what you reach for while
/// playing; Settings holds this Tama's own settings and save, then the
/// app-wide ones, so things like Appearance are reachable from every page.
struct SettingsView: View {
    let device: TamaDevice
    let target: SettingsTarget
    var onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(PurchaseManager.self) private var purchases

    @AppStorage(AppSettings.Keys.volume) private var volume = 0.6
    @AppStorage(AppSettings.Keys.hapticsEnabled) private var hapticsEnabled = true
    @AppStorage(AppSettings.Keys.ignoreSilentSwitch) private var ignoreSilentSwitch = false
    @AppStorage(AppSettings.Keys.pauseOtherAudio) private var pauseOtherAudio = false
    @AppStorage private var speedMultiplier: Int
    @AppStorage private var stayAwake: Bool
    @AppStorage(AppSettings.Keys.catchUpCapHours) private var catchUpCapHours = 24.0
    @AppStorage(AppSettings.Keys.appearanceMode) private var appearanceModeRaw = AppSettings.AppearanceMode.system.rawValue
    @AppStorage(AppSettings.Keys.sharpPixels) private var sharpPixels = true
    @AppStorage(WidgetSharedState.lcdEffectEnabledKey, store: WidgetSharedState.sharedDefaultsOrStandard)
    private var lcdEffectEnabled = true
    @AppStorage(AppSettings.Keys.reminderNotificationsEnabled) private var reminderNotificationsEnabled = false
    @AppStorage(AppSettings.Keys.reminderIntervalHours) private var reminderIntervalHours = 8.0
    @AppStorage(AppSettings.Keys.liveTranslationUsesCloud) private var liveTranslationUsesCloud = false
    // Tomomix only.
    @AppStorage(TomoRetroScreen.settingKey) private var tomoRetro = false
    @AppStorage(TomoCareSettings.notificationsKey) private var tomoNotifications = true
    @AppStorage(TomoCareSettings.noDeathsKey) private var tomoNoDeaths = false
    @AppStorage(TomoCareSettings.difficultyKey) private var tomoDifficulty = TomoCareSettings.Difficulty.classic.rawValue
    @State private var petName = ""
    @State private var playerName = ""

    @State private var showingSaveImporter = false
    @State private var showingSaveExporter = false
    @State private var exportURL: URL?
    @State private var showingRemoveConfirm = false
    @State private var showingRestartConfirm = false
    @State private var showingScreenStyle = false
    @State private var toast: String?
    @State private var showingAPIKeyPrompt = false
    @State private var apiKeyDraft = ""
    @State private var showingPaywall = false
    @State private var showingOwnerNamePrompt = false
    @State private var ownerNameDraft = ""
    /// Prefills "Your Name" on every Tama with the last name set.
    @AppStorage("ownerName.last") private var lastOwnerName = ""

    init(
        device: TamaDevice,
        target: SettingsTarget,
        onDelete: @escaping () -> Void
    ) {
        self.device = device
        self.target = target
        self.onDelete = onDelete
        // Speed and stay-awake are per-device — the key itself depends on
        // `device`, so the usual static-key @AppStorage shorthand can't
        // express it; this underscore-prefixed form is the standard way to
        // give @AppStorage a key known only at instance-init time.
        _speedMultiplier = AppStorage(wrappedValue: 1, AppSettings.Keys.speedMultiplier(for: device))
        _stayAwake = AppStorage(wrappedValue: true, AppSettings.Keys.stayAwake(for: device))
    }

    private var colorViewModel: PlayViewModel? {
        if case .color(let vm) = target { vm } else { nil }
    }

    private var tomomix: TomomixViewModel? {
        if case .tomomix(let model) = target { model } else { nil }
    }

    /// "your tomomix" reads better than the device title in sentences.
    private var deviceName: String { target.isTomomix ? "Tomomix" : device.title }

    var body: some View {
        NavigationStack {
            Form {
                premiumSection
                // This Tama
                deviceSection
                if let tomomix { tomomixCareSection(tomomix) }
                if let colorViewModel { gameplaySection(colorViewModel) }
                saveSection
                // Every Tama
                soundSection
                displaySection
                remindersSection
                if #available(iOS 27.0, *), target.isColor {
                    liveTranslationSection
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showingSaveImporter, allowedContentTypes: [.data]) { result in
                switch result {
                case .success(let url):
                    do {
                        try target.importSave(from: url)
                        toast = "Save imported. The save it replaced is in Backups."
                    } catch {
                        toast = error.localizedDescription
                    }
                case .failure(let error):
                    toast = error.localizedDescription
                }
            }
            .background(
                // Its own view: two file dialogs on one view can stop
                // either from presenting.
                Color.clear.fileMover(isPresented: $showingSaveExporter, file: exportURL) { result in
                    if case .failure(let error) = result {
                        toast = error.localizedDescription
                    }
                }
            )
            .confirmationDialog(
                target.isTomomix ? "Delete your tomomix?" : "Delete \(device.title)?",
                isPresented: $showingRemoveConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    showingRemoveConfirm = false
                    dismiss()
                    onDelete()
                }
                Button("Cancel", role: .cancel) { showingRemoveConfirm = false }
            } message: {
                if target.isTomomix {
                    Text("Your tomomix and its progress will be gone. You can add a new one later from the ⋯ menu.")
                } else {
                    Text("This deletes its firmware and save data from this device. It can be re-imported later, but progress will be lost.")
                }
            }
            .confirmationDialog(
                "Restart \(device.title)?",
                isPresented: $showingRestartConfirm,
                titleVisibility: .visible
            ) {
                Button("Restart", role: .destructive) {
                    dismiss()
                    target.restart()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(target.restartMessage)
            }
            .alert("Your Name", isPresented: $showingOwnerNamePrompt) {
                TextField("Name", text: $ownerNameDraft)
                    .autocorrectionDisabled()
                Button("Set") { setOwnerName() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(OwnerName.hint(for: device.id))
            }
            .alert(toast ?? "", isPresented: Binding(get: { toast != nil }, set: { if !$0 { toast = nil } })) {
                Button("OK") { toast = nil }
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView()
            }
            .sheet(isPresented: $showingScreenStyle) {
                // Has its own navigation bar and Done button.
                P1ScreenStyleView(deviceID: device.id)
            }
            .alert("Gemini API Key", isPresented: $showingAPIKeyPrompt) {
                TextField("Paste your Gemini API key", text: $apiKeyDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save") { saveAPIKey() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Get a free key at aistudio.google.com — no credit card needed.")
            }
            .onAppear {
                if let tomomix {
                    petName = tomomix.petName ?? ""
                    playerName = TomomixViewModel.playerName ?? ""
                }
            }
            .onDisappear {
                if let tomomix {
                    if tomomix.brain.phase == .alive, petName != (tomomix.petName ?? "") { tomomix.rename(pet: petName) }
                    tomomix.rename(player: playerName)
                }
            }
        }
    }

    // MARK: - This Tama

    /// How this Tama looks, and (Tomomix) the names.
    @ViewBuilder
    private var deviceSection: some View {
        Section {
            if let tomomix {
                if tomomix.brain.phase == .alive {
                    nameField("Your tomomix", text: $petName)
                }
                nameField("You", text: $playerName)
                Toggle("Sound", isOn: Binding(get: { !tomomix.muted }, set: { tomomix.setMuted(!$0) }))
                Toggle("Retro Screen", isOn: $tomoRetro)
            } else {
                NavigationLink("Theme") {
                    ThemePickerView(device: device)
                }
            }
            if supportsOwnerName {
                Button("Your Name…") {
                    ownerNameDraft = lastOwnerName
                    showingOwnerNamePrompt = true
                }
            }
            if case .firstGen = target {
                Button("Screen Style…") { showingScreenStyle = true }
            }
            if case .t7(let vm) = target, vm.supportsFigures {
                NavigationLink {
                    FigureListView(viewModel: vm)
                } label: {
                    LabeledContent("Figures", value: vm.pluggedFigure?.name ?? "")
                }
            }
            if let colorViewModel, colorViewModel.supportsDownloads {
                NavigationLink("Downloads") {
                    DownloadsView(device: device, viewModel: colorViewModel)
                }
            }
        } header: {
            Text(deviceName)
        } footer: {
            if target.isTomomix {
                Text("Tomomix's sky always fills your whole screen, free. Retro Screen adds big pixels and scan lines, like an old screen.")
            } else {
                Text("Theme is the backdrop behind \(device.title). Each Tama keeps its own.")
            }
        }
    }

    /// Settings → Your Name: replaces the owner name the toy asked for at
    /// setup (see OwnerName for which models and how).
    private var supportsOwnerName: Bool {
        switch target {
        case .color, .t7: OwnerName.supports(device.id)
        case .firstGen, .t18, .tomomix: false
        }
    }

    private func setOwnerName() {
        switch OwnerName.encode(ownerNameDraft, deviceID: device.id) {
        case .failure(let error):
            showToastAfterPrompt(error.message)
        case .success(let bytes):
            lastOwnerName = ownerNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            switch target {
            case .color(let vm): vm.applyToEngine { _ = $0.setOwnerName(bytes) }
            case .t7(let vm): vm.setOwnerName(bytes)
            case .firstGen, .t18, .tomomix: break
            }
            showToastAfterPrompt("Name set. \(device.title) will use it from now on.")
        }
    }

    /// A second alert right as the name prompt closes can be dropped, so
    /// give the first one a moment to go away.
    private func showToastAfterPrompt(_ message: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { toast = message }
    }

    private func tomomixCareSection(_ model: TomomixViewModel) -> some View {
        Section {
            Toggle("Notifications", isOn: Binding(
                get: { tomoNotifications },
                set: { tomoNotifications = $0; model.refreshNotifications() }
            ))
            Picker("Difficulty", selection: $tomoDifficulty) {
                ForEach(TomoCareSettings.Difficulty.allCases) { d in
                    Text(d.label).tag(d.rawValue)
                }
            }
            Toggle("No Deaths", isOn: $tomoNoDeaths)
        } header: {
            Text("Care")
        } footer: {
            Text("Notifications let your tomomix call you when it needs something. Easy makes it get hungry, unhappy and sick about 1.5 times slower, with more time to answer a call; Hard about 1.3 times faster. With No Deaths, its life never ends: an old tomomix stays old, and leaving it hungry or unhappy too long makes it sick instead.")
        }
    }

    private func nameField(_ label: String, text: Binding<String>) -> some View {
        LabeledContent(label) {
            TextField("Name", text: text)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .onChange(of: text.wrappedValue) { _, new in
                    if new.count > TomomixViewModel.maxNameLength {
                        text.wrappedValue = String(new.prefix(TomomixViewModel.maxNameLength))
                    }
                }
        }
    }

    // MARK: - Save

    @ViewBuilder
    private var saveSection: some View {
        Section {
            if target.supportsSaveTransfer {
                Button("Export Save…") {
                    exportURL = target.prepareExportURL()
                    if exportURL != nil {
                        showingSaveExporter = true
                    } else {
                        toast = "There's no save to export yet."
                    }
                }
                Button("Import Save…") { showingSaveImporter = true }
            }
            NavigationLink("Backups") {
                BackupListView(device: device, host: target.backupHost) { dismiss() }
            }
            if target.supportsRestart {
                Button("Restart (soft reset)…") { showingRestartConfirm = true }
            }
            Button(target.isTomomix ? "Delete Tomomix…" : "Delete \(device.title)…", role: .destructive) {
                showingRemoveConfirm = true
            }
        } header: {
            Text("Save")
        } footer: {
            Text("A backup is kept automatically, about once an hour while you play.")
        }
    }

    // MARK: - Premium

    @ViewBuilder
    private var premiumSection: some View {
        Section {
            if purchases.isPremium {
                Label("Premium unlocked", systemImage: "star.fill")
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    showingPaywall = true
                } label: {
                    Label("Unlock Premium…", systemImage: "star.fill")
                }
                Button("Restore Purchase") {
                    Task { await purchases.restore() }
                }
            }
        } footer: {
            if !purchases.isPremium {
                Text("Unlocks more than one Tama, Ambient Background, extra app icons, Live Translation, Fast-Forward, photo/video capture, and the points hacks. Premium helps cover the costs of running and maintaining this app, while supporting its continued development. It's completely optional, but every bit of support helps. Thank you!")
            }
        }
    }

    // MARK: - Sound & Gameplay

    private var soundSection: some View {
        Section {
            HStack {
                Image(systemName: "speaker.fill")
                Slider(value: $volume, in: 0...1)
                Image(systemName: "speaker.wave.3.fill")
            }
            Toggle("Haptics", isOn: $hapticsEnabled)
            Toggle("Respect Silent Mode", isOn: Binding(
                get: { !ignoreSilentSwitch },
                set: { ignoreSilentSwitch = !$0; AudioOutput.applySessionCategory() }
            ))
            Picker("Other Audio", selection: Binding(
                get: { pauseOtherAudio },
                set: { pauseOtherAudio = $0; AudioOutput.applySessionCategory() }
            )) {
                Text("Mix").tag(false)
                Text("Pause").tag(true)
            }
        } header: {
            Text("Sound & Haptics")
        } footer: {
            Text("The slider sets the Tamas' volume, from silent up to as loud as your device's volume allows. Respect Silent Mode mutes them when your device is silenced. Other Audio chooses whether music and podcasts keep playing alongside or pause while the app is open. These apply to every Tama.")
        }
    }

    /// Speed, stay-awake and catch-up: only the color Tamas' engine has
    /// these knobs.
    private func gameplaySection(_ viewModel: PlayViewModel) -> some View {
        Section {
            Stepper(
                "Speed: \(speedMultiplier)×",
                onIncrement: { setSpeed(AppSettings.speedLadder.first(where: { $0 > speedMultiplier }) ?? speedMultiplier) },
                onDecrement: { setSpeed(AppSettings.speedLadder.last(where: { $0 < speedMultiplier }) ?? speedMultiplier) }
            )
            if speedMultiplier != 1 {
                Button("Reset speed to 1×") { setSpeed(1) }
            }
            Toggle("Stay awake", isOn: Binding(
                get: { stayAwake },
                set: { stayAwake = $0; viewModel.refreshSettings() }
            ))
            Picker("Catch-up when away", selection: $catchUpCapHours) {
                Text("Off").tag(0.0)
                Text("Up to 1 hour").tag(1.0)
                Text("Up to 6 hours").tag(6.0)
                Text("Up to 24 hours").tag(24.0)
            }
        } header: {
            Text("Gameplay")
        } footer: {
            Text("Speed and stay-awake apply to this Tama only. Catch-up controls how much time it ages through the next time it's opened or refreshed in the background.")
        }
    }

    private func setSpeed(_ value: Int) {
        speedMultiplier = value
        colorViewModel?.refreshSettings()
    }

    // MARK: - Reminders

    private var remindersSection: some View {
        Section {
            Toggle("Reminder Notifications", isOn: Binding(
                get: { reminderNotificationsEnabled },
                set: { newValue in
                    reminderNotificationsEnabled = newValue
                    if newValue {
                        NotificationScheduler.requestAuthorizationIfNeeded()
                    } else {
                        ReminderNotificationScheduler.cancel()
                    }
                }
            ))
            if reminderNotificationsEnabled {
                Picker("Remind me after", selection: $reminderIntervalHours) {
                    Text("4 hours").tag(4.0)
                    Text("8 hours").tag(8.0)
                    Text("12 hours").tag(12.0)
                    Text("24 hours").tag(24.0)
                }
            }
        } header: {
            Text("Reminders")
        } footer: {
            Text("A plain nudge to open the app if you haven't in a while — it has no idea whether your Tama actually needs anything, just that time has passed. Applies app-wide, not just to this Tama.")
        }
    }

    // MARK: - Display

    private var displaySection: some View {
        Section {
            Picker("Appearance", selection: $appearanceModeRaw) {
                ForEach(AppSettings.AppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            }
            // Only the color screens (LCDView) read these two; the B&W
            // screens and Tomomix draw their own look and ignore them.
            if target.isColor {
                Toggle("Sharp pixels", isOn: $sharpPixels)
                Toggle("LCD Screen Effect", isOn: Binding(
                    get: { lcdEffectEnabled },
                    set: { lcdEffectEnabled = $0; WidgetSharedState.requestWidgetRefresh() }
                ))
            }
            if AppIconChoice.isSupported {
                NavigationLink("App Icon") {
                    AppIconPickerView()
                }
            }
        } header: {
            Text("Display")
        } footer: {
            if target.isColor {
                Text("Sharp pixels keeps the LCD crisp when scaled up; turning it off smooths the pixel art instead. LCD Screen Effect adds scanlines and a glass reflection to match a real device's screen, on the play screen and the widget alike. These apply to every color Tama.")
            }
        }
    }

    // MARK: - Live Translation

    /// A techy-user feature, deliberately minimal: one choice (on-device
    /// vs. cloud) and one key field, not a provider picker or an
    /// onboarding wizard. The speech-bubble button in the gallery toolbar
    /// is what actually fires a one-shot translation of the current
    /// screen; this just decides which model it uses when it does.
    ///
    /// Two Sections, not one flat list — the mode picker is the one real
    /// top-level choice; the key rows only exist to configure the "Cloud
    /// AI" branch of it, so they read as that choice's own sub-section
    /// (the standard Settings.app pattern for "a choice with its own
    /// follow-up configuration") rather than three more options sitting
    /// as peers of "on-device" and "Cloud AI" themselves.
    @available(iOS 27.0, *)
    @ViewBuilder
    private var liveTranslationSection: some View {
        Section {
            // Empty label on purpose — with .inline style, a non-empty
            // label renders as its own row above the two options, reading
            // like a third, unselectable choice. The footer below already
            // explains what this picker is.
            Picker("", selection: $liveTranslationUsesCloud) {
                Text("On-device (offline)").tag(false)
                Text("Gemini").tag(true)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            // "(beta)" — this is genuinely rough right now (small on-device
            // model, tiny LCD font); players should go in expecting that.
            Text("Live Translation (beta)")
        } footer: {
            if liveTranslationUsesCloud {
                Text("On-device translation is free, fully offline, and private, but the tiny LCD font pushes its accuracy. Gemini reads the screen instead, for much better results, using the free API key you provide below.")
            } else {
                Text("Reads the screen with Apple's on-device model — free, fully offline, and private, but the tiny LCD font pushes its accuracy. Switch to Gemini for much better results, using a free API key from Google.")
            }
        }

        if liveTranslationUsesCloud {
            Section {
                if hasStoredKey {
                    LabeledContent("API Key") {
                        Text("Key set")
                            .foregroundStyle(.secondary)
                    }
                    Button("Change Gemini API Key…") { presentAPIKeyPrompt() }
                    Button("Remove key", role: .destructive) { KeychainStore.delete() }
                } else {
                    Button("Add Gemini API Key…") { presentAPIKeyPrompt() }
                }
            } footer: {
                Text("Get a free key at aistudio.google.com — no credit card needed. It only ever leaves this device to reach Google's own API.")
            }
        }
    }

    /// Recomputed from Keychain each time rather than cached in @State —
    /// this is the one place that can go stale (add/change/remove all
    /// happen right here), and a Keychain read is cheap enough that there's
    /// no real cost to just always reflecting the truth.
    private var hasStoredKey: Bool {
        !(KeychainStore.read()?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private func presentAPIKeyPrompt() {
        apiKeyDraft = ""
        showingAPIKeyPrompt = true
    }

    private func saveAPIKey() {
        // No format validation here on purpose: Google's key format has
        // changed before, and an earlier check rejected a real, working
        // key. Gemini itself says if a key is bad.
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        KeychainStore.write(trimmed)
    }
}

// MARK: - Backups

/// The automatic (and by-hand) backups of one Tama, newest first, with a
/// way to go back to any of them. Family-agnostic -- pushed from Settings
/// for a color Tama, shown in its own sheet from the gallery menu for the
/// families that have no Settings screen.
struct BackupListView: View {
    let device: TamaDevice
    let host: SaveBackupHost
    /// Called after a successful restore, to get out of the way and back
    /// to the Tama.
    var onRestored: () -> Void

    @State private var backups: [SaveBackup] = []
    @State private var pendingRestore: SaveBackup?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Button("Back Up Now") {
                    host.backupNow()
                    reload()
                }
            } footer: {
                Text("Tomomix keeps a backup of \(device.family == .tomomix ? "your tomomix" : device.title) automatically, about once an hour while you play, and before anything that replaces its save. The 3 most recent are kept, plus one per day for the last week.")
            }

            Section {
                if backups.isEmpty {
                    Text("No backups yet")
                        .foregroundStyle(.secondary)
                }
                ForEach(backups) { backup in
                    Button {
                        pendingRestore = backup
                    } label: {
                        BackupRow(backup: backup)
                    }
                    .tint(.primary)
                }
            } header: {
                if !backups.isEmpty { Text("Restore") }
            }
        }
        .navigationTitle("Backups")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .confirmationDialog(
            "Restore this backup?",
            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
            titleVisibility: .visible,
            presenting: pendingRestore
        ) { backup in
            Button("Restore") { restore(backup) }
            Button("Cancel", role: .cancel) {}
        } message: { backup in
            Text("\(device.title) goes back to exactly how it was \(backup.createdAt.formatted(.relative(presentation: .named))), including its clock. How it is right now is backed up first, so you can undo this.")
        }
        .alert(errorMessage ?? "", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        }
    }

    private func reload() {
        backups = SavePaths(device: device).backups()
    }

    private func restore(_ backup: SaveBackup) {
        do {
            try host.restoreBackup(backup)
            onRestored()
        } catch {
            errorMessage = "Couldn't restore this backup. \(error.localizedDescription)"
            reload()
        }
    }
}

private struct BackupRow: View {
    let backup: SaveBackup

    var body: some View {
        HStack(spacing: 12) {
            if let url = backup.frameURL, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(backup.createdAt.formatted(date: .abbreviated, time: .shortened))
                Text("\(backup.reason.label) · \(backup.createdAt.formatted(.relative(presentation: .named)))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Settings → Tama-Go → Figures: the user's own figure dumps. Tap one to
/// plug it in (tap again to unplug); the ⋯ menu does the same mid-play.
struct FigureListView: View {
    let viewModel: T7PlayViewModel
    @State private var showingImporter = false
    @State private var toast: String?

    var body: some View {
        List {
            Section {
                ForEach(viewModel.figures) { figure in
                    Button {
                        viewModel.plugIn(viewModel.pluggedFigureID == figure.id ? nil : figure)
                    } label: {
                        HStack {
                            Text(figure.name).foregroundStyle(.primary)
                            Spacer()
                            if viewModel.pluggedFigureID == figure.id {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    for i in offsets { viewModel.deleteFigure(viewModel.figures[i]) }
                }
                Button {
                    showingImporter = true
                } label: {
                    Label("Import a Figure…", systemImage: "plus")
                }
            } footer: {
                Text("Import your own dumps of Gotchi Figures (.bin files). Tap one to plug it into your Tama-Go, and tap it again to take it out. You can also do this from ⋯ while playing.")
            }
        }
        .navigationTitle("Figures")
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                var failed: [String] = []
                for url in urls {
                    do { try viewModel.importFigure(from: url) } catch { failed.append(url.lastPathComponent) }
                }
                if !failed.isEmpty {
                    toast = "These aren't Tama-Go figure dumps: \(failed.joined(separator: ", "))"
                }
            case .failure(let error):
                toast = error.localizedDescription
            }
        }
        .alert(toast ?? "", isPresented: Binding(get: { toast != nil }, set: { if !$0 { toast = nil } })) {
            Button("OK") { toast = nil }
        }
    }
}
