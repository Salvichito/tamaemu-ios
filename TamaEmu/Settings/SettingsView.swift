import SwiftUI
import TamaCore

struct SettingsView: View {
    let viewModel: PlayViewModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppSettings.Keys.muted) private var muted = false
    @AppStorage(AppSettings.Keys.volume) private var volume = 0.6
    @AppStorage(AppSettings.Keys.hapticsEnabled) private var hapticsEnabled = true
    @AppStorage(AppSettings.Keys.ignoreSilentSwitch) private var ignoreSilentSwitch = false
    @AppStorage(AppSettings.Keys.speedMultiplier) private var speedMultiplier = 1
    @AppStorage(AppSettings.Keys.stayAwake) private var stayAwake = true
    @AppStorage(AppSettings.Keys.catchUpCapHours) private var catchUpCapHours = 24.0
    @AppStorage(AppSettings.Keys.buttonColorIndex) private var buttonColorIndex = 0
    @AppStorage(AppSettings.Keys.accentColorIndex) private var accentColorIndex = 0
    @AppStorage(AppSettings.Keys.sharpPixels) private var sharpPixels = true
    @AppStorage(WidgetSharedState.lcdEffectEnabledKey, store: WidgetSharedState.sharedDefaultsOrStandard)
    private var lcdEffectEnabled = true

    @State private var showingImportSheet = false
    @State private var showingSaveImporter = false
    @State private var showingSaveExporter = false
    @State private var exportURL: URL?
    @State private var pendingRemoval: TamaDevice?
    @State private var showingRestartConfirm = false
    @State private var showingSetClockConfirm = false
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            Form {
                firmwareSection
                soundAndGameplaySection
                displaySection
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingImportSheet) {
                NavigationStack {
                    FirmwareImportView(devices: viewModel.devices) { device, url in
                        viewModel.firmwareImported(for: device, at: url)
                        showingImportSheet = false
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
                "Remove \(pendingRemoval?.title ?? "")'s save data?",
                isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    if let device = pendingRemoval { viewModel.removeDeviceData(device) }
                    pendingRemoval = nil
                }
                Button("Cancel", role: .cancel) { pendingRemoval = nil }
            } message: {
                Text("This deletes its firmware and save data from this device. It can be re-imported later, but progress will be lost.")
            }
            .confirmationDialog(
                "Restart \(viewModel.selectedDevice.title)?",
                isPresented: $showingRestartConfirm,
                titleVisibility: .visible
            ) {
                Button("Restart", role: .destructive) { viewModel.restartTama() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Same save data, but the CPU and clock reset — like taking the battery out and back in.")
            }
            .confirmationDialog(
                "Set the clock to the current time?",
                isPresented: $showingSetClockConfirm,
                titleVisibility: .visible
            ) {
                Button("Set clock", role: .destructive) { setClockToNow() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This jumps straight to the current time, unlike normal catch-up which ages through every second in between.")
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
            ForEach(viewModel.importedDevices) { device in
                Button {
                    viewModel.switchToDevice(device)
                } label: {
                    HStack {
                        Text(device.title)
                            .foregroundStyle(.primary)
                        Spacer()
                        if device.id == viewModel.selectedDevice.id {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .swipeActions {
                    Button("Remove", role: .destructive) { pendingRemoval = device }
                }
            }
            Button("Import additional firmware…") { showingImportSheet = true }
        } header: {
            Text("Firmware")
        } footer: {
            Text("Each imported firmware keeps its own save data. Switching doesn't need a re-import.")
        }

        Section {
            Button("Export save file…") {
                exportURL = viewModel.prepareExportURL()
                if exportURL != nil { showingSaveExporter = true }
            }
            .disabled(viewModel.exportableSaveURL == nil)
            Button("Import save file…") { showingSaveImporter = true }
            Button("Set clock to current time…") { showingSetClockConfirm = true }
            Button("Restart (soft reset)…") { showingRestartConfirm = true }
            Button("Remove this device's data…", role: .destructive) {
                pendingRemoval = viewModel.selectedDevice
            }
        } header: {
            Text("Save")
        }
    }

    private func setClockToNow() {
        viewModel.restartTamaClock { engine in
            let now = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
            _ = engine.setClock(hour: now.hour ?? 0, minute: now.minute ?? 0, second: now.second ?? 0)
        }
    }

    // MARK: - Sound & Gameplay

    @ViewBuilder
    private var soundAndGameplaySection: some View {
        Section {
            Toggle("Mute", isOn: $muted)
            HStack {
                Image(systemName: "speaker.fill")
                Slider(value: $volume, in: 0...1)
                Image(systemName: "speaker.wave.3.fill")
            }
            .disabled(muted)
            .foregroundStyle(muted ? .secondary : .primary)
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
            Text("Speed only changes how fast the Tamagotchi's own clock runs, not how it responds to buttons. Catch-up controls how much time it ages through the next time it's opened or refreshed in the background.")
        }
    }

    private func setSpeed(_ value: Int) {
        speedMultiplier = value
        viewModel.refreshSettings()
    }

    // MARK: - Display

    private var displaySection: some View {
        Section {
            Picker("Button color", selection: $buttonColorIndex) {
                ForEach(0..<TamaPalette.buttonColors.count, id: \.self) { i in
                    Text(TamaPalette.buttonColors[i].name).tag(i)
                }
            }
            Picker("Accent color", selection: $accentColorIndex) {
                ForEach(0..<TamaPalette.accentColors.count, id: \.self) { i in
                    Text(TamaPalette.accentColors[i].name).tag(i)
                }
            }
            Toggle("Sharp pixels", isOn: $sharpPixels)
            Toggle("LCD Screen Effect", isOn: Binding(
                get: { lcdEffectEnabled },
                set: { lcdEffectEnabled = $0; WidgetSharedState.requestWidgetRefresh() }
            ))
        } header: {
            Text("Display")
        } footer: {
            Text("Sharp pixels keeps the LCD crisp when scaled up; turning it off smooths the pixel art instead. LCD Screen Effect adds scanlines and a glass reflection to match a real device's screen, on the play screen and the widget alike.")
        }
    }
}
