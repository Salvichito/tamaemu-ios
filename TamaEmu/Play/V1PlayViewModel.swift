import Foundation
import Observation
import TamaCore

/// Owns exactly one P1-era (TamaLib) Tama's engine lifecycle. Mirrors
/// PlayViewModel's shape (one instance per owned device, cached by
/// GalleryViewModel, construction cheap/side-effect free) but drives
/// V1EmulatorEngine instead of CTama's EmulatorEngine -- kept as its own
/// type rather than shared with PlayViewModel since the two cores have
/// almost nothing in common yet (no pause, no save/resume, no
/// translation here still -- see the integration-research memory for
/// what's deliberately not built yet).
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

    /// Deletes this device's firmware -- there's no separate save/state
    /// file yet, so this is just the ROM import SavePaths already tracks.
    static func removeDeviceData(_ device: TamaDevice) {
        SavePaths(device: device).deleteAll()
    }

    func resumeIfNeeded() {
        guard engine == nil else { return }
        startEngine()
    }

    func stopEngine() {
        engine?.stop()
        engine = nil
    }

    func pressButton(_ button: InputController.Button) {
        engine?.input.press(button)
    }

    func releaseButton(_ button: InputController.Button) {
        engine?.input.release(button)
    }

    private func startEngine() {
        let device = selectedDevice
        guard let romData = try? Data(contentsOf: SavePaths(device: device).importedROMPath) else {
            errorMessage = "Couldn't read this Tama's firmware."
            return
        }
        let newEngine = V1EmulatorEngine { [weak self] state in
            self?.screenState = state
        }
        guard newEngine.start(romData: romData) else {
            errorMessage = "Couldn't start this Tama's emulator core."
            return
        }
        errorMessage = nil
        engine = newEngine
    }
}
