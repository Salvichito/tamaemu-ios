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
final class T7PlayViewModel {
    let selectedDevice: TamaDevice
    private(set) var screenState: T7ScreenState = .blank
    private(set) var errorMessage: String?
    /// True while a resume's catch-up pass (time spent away) is running
    /// off the main thread -- same meaning as V1PlayViewModel's own flag.
    private(set) var isLoading = false

    private var engine: T7EmulatorEngine?
    private var startGeneration = 0

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
        guard let engine else { return }
        engine.stop()
        let paths = SavePaths(device: selectedDevice)
        try? paths.ensureDirectoriesExist()
        if let state = engine.saveState() {
            try? state.write(to: paths.t7StatePath)
            paths.lastSavedAt = Date()
        }
        if let eeprom = engine.saveEeprom() {
            try? eeprom.write(to: paths.t7EepromPath)
        }
        self.engine = nil
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
        let savedState = try? Data(contentsOf: paths.t7StatePath)
        let savedEeprom = try? Data(contentsOf: paths.t7EepromPath)
        let backlogSeconds = paths.lastSavedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0
        startGeneration += 1
        let generation = startGeneration
        isLoading = true

        Task.detached(priority: .userInitiated) { [weak self] in
            let stateToLoad: Data?
            let eepromToLoad: Data?
            if let savedState, backlogSeconds > 1 {
                let result = T7EmulatorEngine.catchUp(
                    romData: romData,
                    eepromData: savedEeprom,
                    from: savedState,
                    backlogSeconds: backlogSeconds,
                    wallClockBudget: Self.catchUpWallClockBudget
                )
                stateToLoad = result.state
                eepromToLoad = result.eeprom
            } else {
                stateToLoad = savedState
                eepromToLoad = savedEeprom
            }
            guard let self else { return }
            await MainActor.run {
                guard self.startGeneration == generation else { return }
                let newEngine = T7EmulatorEngine(onFrame: { [weak self] state in
                    self?.screenState = state
                })
                guard newEngine.start(romData: romData, eepromData: eepromToLoad, stateData: stateToLoad) else {
                    self.errorMessage = "Couldn't start this Tama's emulator core."
                    self.isLoading = false
                    return
                }
                self.errorMessage = nil
                self.isLoading = false
                self.engine = newEngine
            }
        }
    }
}
