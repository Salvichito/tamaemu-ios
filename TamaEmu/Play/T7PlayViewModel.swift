import Foundation
import Observation
import TamaCore

/// Owns exactly one Tama-Go/Tamagotchi Friends (T7Emu) Tama's engine
/// lifecycle. Mirrors V1PlayViewModel's shape (one instance per owned
/// device, cached by GalleryViewModel, construction cheap/side-effect
/// free) but drives T7EmulatorEngine and this family's own two save
/// files (state + EEPROM, see SavePaths). No translation here either --
/// same deliberately-not-built-yet list as V1PlayViewModel.
@MainActor
@Observable
final class T7PlayViewModel: SaveBackupHost {
    let selectedDevice: TamaDevice
    private(set) var screenState: T7ScreenState = .blank
    private(set) var errorMessage: String?
    /// True while a resume's catch-up pass (time spent away) is running
    /// off the main thread -- same meaning as V1PlayViewModel's own flag.
    private(set) var isLoading = false

    private var engine: T7EmulatorEngine?
    private var startGeneration = 0
    /// See PlayViewModel's own loadCancel / holdsGate.
    private var loadCancel: CancelFlag?
    private var holdsGate = false
    /// The real wall-clock moment the live engine's state was caught up
    /// to when it started. stopEngine() adds the emulated time the live
    /// loop actually stepped to get the moment it's caught up to at the
    /// end -- rather than assuming "now", which forgets both an
    /// unfinished catch-up and any time the live loop stalled.
    private var liveStartCaughtUpTo: Date?

    private nonisolated static let catchUpWallClockBudget: TimeInterval = 10.0

    init(device: TamaDevice) {
        selectedDevice = device
    }

    static func removeDeviceData(_ device: TamaDevice) {
        SavePaths(device: device).deleteAll()
    }

    func resumeIfNeeded() {
        guard engine == nil, !isLoading else { return }
        startEngine()
    }

    /// Stops the engine and persists both save files -- stop() itself
    /// blocks until the stepping thread has actually exited, which both
    /// save calls depend on to read the core's state without a concurrent
    /// writer (same reasoning as V1EmulatorEngine's stop()/saveState()).
    func stopEngine() {
        startGeneration += 1 // invalidates any startEngine() catch-up still in flight
        loadCancel?.cancel()
        loadCancel = nil
        // See V1PlayViewModel.stopEngine(): left set, this Tama could
        // never be resumed again after being stopped mid-catch-up.
        isLoading = false
        guard let engine else { return }
        engine.stop()
        let paths = SavePaths(device: selectedDevice)
        try? paths.ensureDirectoriesExist()
        if let state = engine.saveState(),
           (try? state.write(to: paths.t7StatePath, options: .atomic)) != nil {
            let now = Date()
            let caughtUpTo = liveStartCaughtUpTo?.addingTimeInterval(engine.liveSecondsAdvanced) ?? now
            paths.lastSavedAt = min(caughtUpTo, now)
        }
        if let eeprom = engine.saveEeprom() {
            try? eeprom.write(to: paths.t7EepromPath, options: .atomic)
        }
        engine.release()
        // See PlayViewModel.stopEngine(): at most hourly, and still inside
        // the gate.
        paths.makeBackup(reason: .automatic)
        self.engine = nil
        if holdsGate {
            holdsGate = false
            EngineGate.gate(for: selectedDevice).release()
        }
    }

    /// See V1PlayViewModel.backupNow().
    func backupNow() {
        guard engine != nil else {
            SavePaths(device: selectedDevice).makeBackup(reason: .manual)
            return
        }
        stopEngine()
        SavePaths(device: selectedDevice).makeBackup(reason: .manual)
        startEngine()
    }

    func restoreBackup(_ backup: SaveBackup) throws {
        stopEngine()
        try SavePaths(device: selectedDevice).restore(backup)
        startEngine()
    }

    func pressButton(_ button: InputController.Button) {
        engine?.input.press(button)
    }

    func releaseButton(_ button: InputController.Button) {
        engine?.input.release(button)
    }

    private func startEngine() {
        let device = selectedDevice
        let paths = SavePaths(device: device)
        guard let romData = try? Data(contentsOf: paths.importedROMPath) else {
            errorMessage = "Couldn't read this Tama's firmware."
            return
        }
        startGeneration += 1
        let generation = startGeneration
        let cancel = CancelFlag()
        loadCancel = cancel
        let gate = EngineGate.gate(for: device)
        isLoading = true

        Task.detached(priority: .userInitiated) { [weak self] in
            // Same shape as V1PlayViewModel.startEngine() -- see its
            // comments for why each step is where it is.
            let holdsGate = gate.acquire(timeout: 15)
            @Sendable func releaseGate() { if holdsGate { gate.release() } }
            guard !cancel.isCancelled else { releaseGate(); return }

            var state = try? Data(contentsOf: paths.t7StatePath)
            var eeprom = try? Data(contentsOf: paths.t7EepromPath)
            var caughtUpTo = paths.lastSavedAt ?? Date()
            var madeProgress = false
            if let loaded = state {
                var current = loaded
                while !cancel.isCancelled {
                    let owed = Date().timeIntervalSince(caughtUpTo)
                    guard owed > 0.5 else { break }
                    let result = T7EmulatorEngine.catchUp(
                        romData: romData,
                        eepromData: eeprom,
                        from: current,
                        backlogSeconds: owed,
                        wallClockBudget: Self.catchUpWallClockBudget,
                        shouldAbort: { cancel.isCancelled }
                    )
                    guard result.advancedSeconds > 0 else { break }
                    current = result.state
                    eeprom = result.eeprom
                    caughtUpTo = caughtUpTo.addingTimeInterval(result.advancedSeconds)
                    madeProgress = true
                }
                state = current
            }

            func persistProgress() {
                guard madeProgress, let state else { return }
                if (try? state.write(to: paths.t7StatePath, options: .atomic)) != nil {
                    paths.lastSavedAt = caughtUpTo
                }
                if let eeprom {
                    try? eeprom.write(to: paths.t7EepromPath, options: .atomic)
                }
            }

            guard !cancel.isCancelled, let self else {
                persistProgress()
                releaseGate()
                return
            }
            persistProgress()
            let stateToLoad = state
            let eepromToLoad = eeprom
            let stateCaughtUpTo = caughtUpTo
            let didCatchUp = madeProgress
            await MainActor.run {
                guard self.startGeneration == generation else { releaseGate(); return }
                let newEngine = T7EmulatorEngine(onFrame: { [weak self] state in
                    self?.screenState = state
                })
                guard newEngine.start(romData: romData, eepromData: eepromToLoad, stateData: stateToLoad) else {
                    releaseGate()
                    self.errorMessage = "Couldn't start this Tama's emulator core."
                    self.isLoading = false
                    return
                }
                // A state the core couldn't advance at all has no
                // meaningful gap to carry -- treat it as current.
                let stillBehind = Date().timeIntervalSince(stateCaughtUpTo) > 0.5
                self.liveStartCaughtUpTo = (stateToLoad == nil || (stillBehind && !didCatchUp)) ? Date() : stateCaughtUpTo
                self.holdsGate = holdsGate
                self.errorMessage = nil
                self.isLoading = false
                self.engine = newEngine
            }
        }
    }
}
