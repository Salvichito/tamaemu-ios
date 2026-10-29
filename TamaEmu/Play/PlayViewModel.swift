import CoreGraphics
import Foundation
import Observation
import TamaCore

@MainActor
@Observable
final class PlayViewModel {
    let devices = DeviceCatalog.all()
    var selectedDevice: TamaDevice
    private(set) var lcdImage: CGImage?
    private(set) var hasFirmware = false
    private(set) var errorMessage: String?

    private var engine: EmulatorEngine?
    private var displayTimer: Timer?
    /// Bumped by stopEngine() and every startEngine() call — a load that
    /// finishes after being superseded (stopped, switched, restarted
    /// again) checks this before applying its result, so it discards
    /// itself instead of resurrecting a stale engine.
    private var startGeneration = 0

    init() {
        // The filesystem is the ground truth — a lost/stale preference
        // should never hide an already-imported firmware behind the
        // import screen.
        if let found = ActiveDeviceLookup.find() {
            selectedDevice = found
        } else {
            selectedDevice = DeviceCatalog.defaultDevice()
        }

        if ActiveDeviceLookup.hasImportedROM(selectedDevice) {
            hasFirmware = true
            // Covers anyone who imported firmware before this permission
            // request existed — firmwareImported(for:at:) only asks on a
            // brand-new import, which would otherwise leave existing users
            // never actually prompted, so no notification could ever be
            // delivered regardless of whether a call was detected.
            NotificationScheduler.requestAuthorizationIfNeeded()
            startEngine()
        } else {
            lcdImage = LCDImageBuilder.makeImage(
                from: Self.testPattern(width: 128, height: 128),
                width: 128,
                height: 128
            )
        }
    }

    func firmwareImported(for device: TamaDevice, at url: URL) {
        selectedDevice = device
        UserDefaults.standard.set(device.id, forKey: ActiveDeviceLookup.selectedDeviceIDKey)
        hasFirmware = true
        NotificationScheduler.requestAuthorizationIfNeeded()
        startEngine()
    }

    /// Devices that already have firmware imported — each keeps its own
    /// independent save slot (see SavePaths), so switching between them
    /// needs no re-import.
    var importedDevices: [TamaDevice] {
        devices.filter(ActiveDeviceLookup.hasImportedROM)
    }

    /// Switches the active device among ones that already have firmware
    /// imported — no re-import, each device's own save data picks up where
    /// it left off.
    func switchToDevice(_ device: TamaDevice) {
        guard device.id != selectedDevice.id, ActiveDeviceLookup.hasImportedROM(device) else { return }
        selectedDevice = device
        UserDefaults.standard.set(device.id, forKey: ActiveDeviceLookup.selectedDeviceIDKey)
        hasFirmware = true
        startEngine()
    }

    /// Deletes one device's ROM/save data outright. If it's the currently
    /// active device, falls back to the import screen exactly like
    /// `resetFirmware()`; otherwise it's just removed silently.
    func removeDeviceData(_ device: TamaDevice) {
        if device.id == selectedDevice.id {
            resetFirmware()
        } else {
            SavePaths(device: device).deleteAll()
        }
    }

    /// For when the wrong device was picked at import time: that data is
    /// simply wrong (e.g. a black screen from a ROM mismatch), not progress
    /// worth keeping, so it's deleted outright and the import screen comes
    /// back to let the user try again.
    func resetFirmware() {
        stopEngine()
        SavePaths(device: selectedDevice).deleteAll()
        UserDefaults.standard.removeObject(forKey: ActiveDeviceLookup.selectedDeviceIDKey)
        hasFirmware = false
        errorMessage = nil
        lcdImage = LCDImageBuilder.makeImage(
            from: Self.testPattern(width: 128, height: 128),
            width: 128,
            height: 128
        )
    }

    /// Stops the emulator thread and audio (once there is audio) entirely,
    /// after persisting state — this app does not age in the background for
    /// the MVP. Call on scenePhase == .background.
    func stopEngine() {
        startGeneration += 1  // invalidates any startEngine() load still in flight
        displayTimer?.invalidate()
        displayTimer = nil
        // stop() must come first: it blocks until the emulator thread has
        // actually exited, which save() and renderCurrentFrame() both
        // depend on to safely read the Emu struct without a concurrent
        // writer.
        engine?.stop()
        // Publishes the actual last-seen frame to the widget — previously
        // this only ever happened once, right at session start (before
        // any play), so the widget never reflected anything the user had
        // actually just done.
        if let engine, let image = LCDImageBuilder.makeImage(
            from: engine.renderCurrentFrame(), width: 128, height: 128
        ) {
            WidgetSharedState.publish(image: image, deviceTitle: selectedDevice.title)
        }
        engine?.save()
        engine = nil
    }

    /// Call on scenePhase == .active. Re-creates the engine (which restores
    /// from the state/flash saved in stopEngine()) if it isn't running.
    func resumeIfNeeded() {
        guard hasFirmware, engine == nil else { return }
        startEngine()
    }

    func pressButton(_ button: InputController.Button) {
        engine?.input.press(button)
    }

    func releaseButton(_ button: InputController.Button) {
        engine?.input.release(button)
    }

    /// Re-applies speed/stay-awake to the running engine right after a
    /// Settings change — these take effect immediately, no restart needed.
    func refreshSettings() {
        engine?.applySettings()
    }

    /// Soft reset: same ROM/flash/RAM, CPU state and clock back to the
    /// firmware's own boot vector. Distinct from `resetFirmware()`, which
    /// deletes everything.
    func restartTama() {
        guard engine != nil else { return }
        pauseEngine { $0.resetCPU() }
    }

    /// Runs an arbitrary action on the stopped engine (e.g. `setClock`)
    /// between stop and save/restart, for Settings actions that need
    /// direct engine access without exposing `engine` itself.
    func restartTamaClock(_ action: (EmulatorEngine) -> Void) {
        guard engine != nil else { return }
        pauseEngine(action)
    }

    /// Path to the current device's live flash/save image, if any exists
    /// yet — for the Settings screen's export action (disabled otherwise).
    var exportableSaveURL: URL? {
        let path = SavePaths(device: selectedDevice).liveFlashPath
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    /// Briefly stops and restarts the engine around `save()` so an export
    /// reflects state current to the moment of export, not just the last
    /// backgrounding — `save()` itself isn't safe to call while the
    /// emulator thread might still be stepping (see `EmulatorEngine.save`).
    func prepareExportURL() -> URL? {
        if engine != nil { pauseEngine() }
        return exportableSaveURL
    }

    /// Stops the engine, runs an optional action on it (e.g. a soft
    /// reset) between stop and save, saves, then restarts it — the common
    /// shape behind both a plain "flush to disk" and `restartTama()`.
    private func pauseEngine(_ between: (EmulatorEngine) -> Void = { _ in }) {
        displayTimer?.invalidate()
        displayTimer = nil
        guard let engine else { return }
        engine.stop()
        between(engine)
        engine.save()
        engine.start()
        beginDisplayTimer()
    }

    /// Overwrites the active device's live flash image with an imported
    /// `.sav` file and discards its CPU/RAM snapshot, so the next load
    /// boots fresh from that flash content — mirrors the Android port's
    /// own save-import (replace flash, drop state, reload).
    func importSave(from url: URL) throws {
        guard url.startAccessingSecurityScopedResource() else {
            throw CocoaError(.fileReadNoPermission)
        }
        defer { url.stopAccessingSecurityScopedResource() }
        let paths = SavePaths(device: selectedDevice)
        try paths.ensureDirectoriesExist()
        if FileManager.default.fileExists(atPath: paths.liveFlashPath.path) {
            try FileManager.default.removeItem(at: paths.liveFlashPath)
        }
        try FileManager.default.copyItem(at: url, to: paths.liveFlashPath)
        paths.deleteStateOnly()
        startEngine()
    }

    private func beginDisplayTimer() {
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, let frame = self.engine?.latestFrame() else { return }
            self.lcdImage = LCDImageBuilder.makeImage(from: frame, width: 128, height: 128)
        }
    }

    /// Loading an engine runs catch-up synchronously inside its init() —
    /// and real-device throughput turned out to be far below what the
    /// previous fixed, blocking budget assumed (measured ~12x real time
    /// on an actual phone, not the ~230x Simulator figure the budget was
    /// originally sized against). No fixed synchronous budget can both
    /// keep launch instant AND make real progress at that throughput, so
    /// this now runs entirely off the main thread instead of inside
    /// PlayViewModel's (and ultimately the UI's) call stack — the catch-up
    /// pass can take however long it actually needs without the app ever
    /// appearing to hang. A larger per-attempt budget is safe now that
    /// nothing is waiting on it.
    private nonisolated static let catchUpWallClockBudget: TimeInterval = 10.0

    private func startEngine() {
        stopEngine()
        startGeneration += 1
        let generation = startGeneration
        let device = selectedDevice
        let paths = SavePaths(device: device)
        let deviceTitle = device.title

        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result {
                try EmulatorEngine(
                    device: device,
                    savePaths: paths,
                    catchUpWallClockBudget: Self.catchUpWallClockBudget,
                    onCallDetected: {
                        NotificationScheduler.fireCallingNotification(deviceTitle: deviceTitle)
                    }
                )
            }
            guard let self else { return }
            switch result {
            case .success(let newEngine):
                let image = LCDImageBuilder.makeImage(
                    from: newEngine.renderCurrentFrame(), width: 128, height: 128
                )
                await MainActor.run {
                    guard self.startGeneration == generation else {
                        // Superseded while this was loading (stopped,
                        // switched devices, restarted) — this engine
                        // never started running, so just persist whatever
                        // catch-up progress it made and let it go.
                        newEngine.save()
                        return
                    }
                    if let image {
                        WidgetSharedState.publish(image: image, deviceTitle: deviceTitle)
                    }
                    newEngine.start()
                    self.engine = newEngine
                    self.errorMessage = nil
                    self.beginDisplayTimer()
                }
            case .failure(let error):
                await MainActor.run {
                    guard self.startGeneration == generation else { return }
                    self.errorMessage = error.localizedDescription
                    self.hasFirmware = false
                }
            }
        }
    }

    /// Eight vertical color bars in the same 0xAARRGGBB word format
    /// `lcd_render` writes. Shown only until firmware is imported.
    private static func testPattern(width: Int, height: Int) -> [UInt32] {
        let bars: [UInt32] = [
            0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0xFFFFFFFF,
            0xFF000000, 0xFFFFFF00, 0xFF00FFFF, 0xFFFF00FF
        ]
        var buffer = [UInt32](repeating: 0, count: width * height)
        let barWidth = max(1, width / bars.count)
        for y in 0..<height {
            for x in 0..<width {
                buffer[y * width + x] = bars[min(x / barWidth, bars.count - 1)]
            }
        }
        return buffer
    }
}
