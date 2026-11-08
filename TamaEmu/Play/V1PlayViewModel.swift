import Foundation
import Observation
import TamaCore

/// Owns exactly one P1-era (TamaLib) Tama's engine lifecycle. Mirrors
/// PlayViewModel's shape (one instance per owned device, cached by
/// GalleryViewModel, construction cheap/side-effect free) but drives
/// V1EmulatorEngine instead of CTama's EmulatorEngine -- kept as its own
/// type rather than shared with PlayViewModel since the two cores have
/// almost nothing in common yet (no pause, no catch-up for time spent
/// away, no translation here still -- see the integration-research
/// memory for what's deliberately not built yet). Save/resume (frozen
/// exactly as left, not caught up to now) is the one piece of that list
/// this class does handle, via V1EmulatorEngine's saveState()/
/// start(savedState:).
@MainActor
@Observable
final class V1PlayViewModel {
    let selectedDevice: TamaDevice
    private(set) var screenState: P1ScreenState = .blank
    private(set) var errorMessage: String?

    private var engine: V1EmulatorEngine?

    init(device: TamaDevice) {
        selectedDevice = device
    }

    static func removeDeviceData(_ device: TamaDevice) {
        SavePaths(device: device).deleteAll()
    }

    func resumeIfNeeded() {
        guard engine == nil else { return }
        startEngine()
    }

    /// Stops the engine and persists its state -- stop() itself blocks
    /// until the stepping thread has actually exited, which saveState()
    /// depends on to read the core's state without a concurrent writer
    /// (see both methods' own doc comments on V1EmulatorEngine).
    func stopEngine() {
        guard let engine else { return }
        engine.stop()
        if let data = engine.saveState() {
            let paths = SavePaths(device: selectedDevice)
            try? paths.ensureDirectoriesExist()
            try? data.write(to: paths.v1StatePath)
            paths.lastSavedAt = Date()
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
        let savedState = try? Data(contentsOf: paths.v1StatePath)
        let newEngine = V1EmulatorEngine { [weak self] state in
            self?.screenState = state
        }
        guard newEngine.start(romData: romData, savedState: savedState) else {
            errorMessage = "Couldn't start this Tama's emulator core."
            return
        }
        errorMessage = nil
        engine = newEngine
    }
}
