import SwiftUI
import TamaCore

/// Always scoped to one device — there's no more global "selected device"
/// to switch between in here; switching is just swiping the gallery.
/// Opened from TamaGalleryView's overflow menu, for whichever device is
/// currently on screen.
struct SettingsView: View {
    let device: TamaDevice
    let viewModel: PlayViewModel
    var onDelete: () -> Void
    var onDeviceImported: (TamaDevice) -> Void
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppSettings.Keys.volume) private var volume = 0.6
    @AppStorage(AppSettings.Keys.hapticsEnabled) private var hapticsEnabled = true
    @AppStorage(AppSettings.Keys.ignoreSilentSwitch) private var ignoreSilentSwitch = false
    @AppStorage private var speedMultiplier: Int
    @AppStorage private var stayAwake: Bool
    @AppStorage(AppSettings.Keys.catchUpCapHours) private var catchUpCapHours = 24.0
    @AppStorage(AppSettings.Keys.appearanceMode) private var appearanceModeRaw = AppSettings.AppearanceMode.system.rawValue
    @AppStorage(AppSettings.Keys.sharpPixels) private var sharpPixels = true
    @AppStorage(WidgetSharedState.lcdEffectEnabledKey, store: WidgetSharedState.sharedDefaultsOrStandard)
    private var lcdEffectEnabled = true
    @AppStorage(AppSettings.Keys.ambientBackgroundEnabled) private var ambientBackgroundEnabled = true
    @AppStorage(AppSettings.Keys.reminderNotificationsEnabled) private var reminderNotificationsEnabled = false
    @AppStorage(AppSettings.Keys.reminderIntervalHours) private var reminderIntervalHours = 8.0

    @State private var showingImportSheet = false
    @State private var showingSaveImporter = false
    @State private var showingSaveExporter = false
    @State private var exportURL: URL?
    @State private var showingRemoveConfirm = false
    @State private var showingRestartConfirm = false
    @State private var toast: String?

    init(
        device: TamaDevice,
        viewModel: PlayViewModel,
        onDelete: @escaping () -> Void,
        onDeviceImported: @escaping (TamaDevice) -> Void
    ) {
        self.device = device
        self.viewModel = viewModel
        self.onDelete = onDelete
        self.onDeviceImported = onDeviceImported
        // Speed and stay-awake are per-device — the key itself depends on
        // `device`, so the usual static-key @AppStorage shorthand can't
        // express it; this underscore-prefixed form is the standard way to
        // give @AppStorage a key known only at instance-init time.
        _speedMultiplier = AppStorage(wrappedValue: 1, AppSettings.Keys.speedMultiplier(for: device))
        _stayAwake = AppStorage(wrappedValue: true, AppSettings.Keys.stayAwake(for: device))
    }

    var body: some View {
        NavigationStack {
            Form {
                firmwareSection
                soundAndGameplaySection
                remindersSection
                displaySection
            }
            .navigationTitle("Settings for \(device.title)")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingImportSheet) {
                NavigationStack {
                    FirmwareImportView(devices: DeviceCatalog.all()) { importedDevice, url in
                        showingImportSheet = false
                        onDeviceImported(importedDevice)
                    }
                    .navigationTitle("Import firmware")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showingImportSheet = false }
                        }
                    }
                }
            }
            .fileImporter(isPresented: $showingSaveImporter, allowedContentTypes: [.data]) { result in
                switch result {
                case .success(let url):
                    do {
                        try viewModel.importSave(from: url)
                        toast = "Save imported."
                    } catch {
                        toast = error.localizedDescription
                    }
                case .failure(let error):
                    toast = error.localizedDescription
                }
            }
            .fileMover(isPresented: $showingSaveExporter, file: exportURL) { result in
                if case .failure(let error) = result {
                    toast = error.localizedDescription
                }
            }
            .confirmationDialog(
                "Remove \(device.title)'s save data?",
                isPresented: $showingRemoveConfirm,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    showingRemoveConfirm = false
                    dismiss()
                    onDelete()
                }
                Button("Cancel", role: .cancel) { showingRemoveConfirm = false }
            } message: {
                Text("This deletes its firmware and save data from this device. It can be re-imported later, but progress will be lost.")
            }
            .confirmationDialog(
                "Restart \(device.title)?",
                isPresented: $showingRestartConfirm,
                titleVisibility: .visible
            ) {
                Button("Restart", role: .destructive) {
                    dismiss()
                    viewModel.restartTama()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Same save data, but the CPU and clock reset — like taking the battery out and back in.")
            }
            .alert(toast ?? "", isPresented: Binding(get: { toast != nil }, set: { if !$0 { toast = nil } })) {
                Button("OK") { toast = nil }
            }
        }
    }

    // MARK: - Firmware & Save

    @ViewBuilder
    private var firmwareSection: some View {
        Section {
            Button("Export save file…") {
                exportURL = viewModel.prepareExportURL()
                if exportURL != nil { showingSaveExporter = true }
            }
            .disabled(viewModel.exportableSaveURL == nil)
            Button("Import save file…") { showingSaveImporter = true }
            Button("Restart (soft reset)…") { showingRestartConfirm = true }
            Button("Remove this device's data…", role: .destructive) {
                showingRemoveConfirm = true
            }
        } header: {
            Text("Save")
        } footer: {
            Text("Add more Tamas from the \"+\" button in the gallery, or re-import this one's firmware below.")
        }

        Section {
            Button("Import additional firmware…") { showingImportSheet = true }
        } header: {
            Text("Firmware")
        }
    }

    // MARK: - Sound & Gameplay

    @ViewBuilder
    private var soundAndGameplaySection: some View {
        Section {
            HStack {
                Image(systemName: "speaker.fill")
                Slider(value: $volume, in: 0...1)
                Image(systemName: "speaker.wave.3.fill")
            }
            Toggle("Haptics", isOn: $hapticsEnabled)
            Toggle("Play in Silent Mode", isOn: Binding(
                get: { ignoreSilentSwitch },
                set: { ignoreSilentSwitch = $0; viewModel.refreshSettings() }
            ))
        } header: {
            Text("Sound & Haptics")
        } footer: {
            Text("Overrides the phone's silent switch so the Tama's sound plays anyway — like any game, this also pauses whatever else might be playing while it's on.")
        }

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
        viewModel.refreshSettings()
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
            Toggle("Sharp pixels", isOn: $sharpPixels)
            Toggle("LCD Screen Effect", isOn: Binding(
                get: { lcdEffectEnabled },
                set: { lcdEffectEnabled = $0; WidgetSharedState.requestWidgetRefresh() }
            ))
            Toggle("Ambient Background", isOn: $ambientBackgroundEnabled)
        } header: {
            Text("Display")
        } footer: {
            Text("Sharp pixels keeps the LCD crisp when scaled up; turning it off smooths the pixel art instead. LCD Screen Effect adds scanlines and a glass reflection to match a real device's screen, on the play screen and the widget alike. Ambient Background glows the play screen with the Tama's own colors, blurred full-bleed behind it. These apply app-wide, not just to this Tama.")
        }
    }
}
