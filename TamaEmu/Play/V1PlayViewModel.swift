import Foundation
import Observation
import TamaCore

/// Owns exactly one P1-era (TamaLib) Tama's engine lifecycle. Mirrors
/// PlayViewModel's shape (one instance per owned device, cached by
/// GalleryViewModel, construction cheap/side-effect free) but drives
/// V1EmulatorEngine instead of CTama's EmulatorEngine -- kept as its own
/// type rather than shared with PlayViewModel since the two cores have
/// almost nothing in common yet (no pause, no translation here still --
/// see the integration-research memory for what's deliberately not built
/// yet). Save/resume, including catching up on time spent away, is
/// handled via V1EmulatorEngine's saveState()/start(savedState:)/
/// catchUp(_:).
@MainActor
@Observable
final class V1PlayViewModel {
    let selectedDevice: TamaDevice
    private(set) var screenState: P1ScreenState = .blank
    private(set) var errorMessage: String?
    /// True while a resume's catch-up pass (time spent away) is running
    /// off the main thread -- the screen still shows the last saved
    /// frame during this (see WidgetSharedState in PlayViewModel's own
    /// equivalent), it just isn't live/interactive yet.
    private(set) var isLoading = false

    private var engine: V1EmulatorEngine?
    /// Bumped by stopEngine() and every startEngine() call -- a catch-up
    /// pass that finishes after being superseded (page swiped away,
    /// stopped, started again) checks this before applying its result,
    /// mirroring PlayViewModel's own startGeneration.
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

    /// Stops the engine and persists its state -- stop() itself blocks
    /// until the stepping thread has actually exited, which saveState()
    /// depends on to read the core's state without a concurrent writer
    /// (see both methods' own doc comments on V1EmulatorEngine).
    func stopEngine() {
        startGeneration += 1  // invalidates any startEngine() catch-up still in flight
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

    /// Catch-up (if there's a saved state and real time has passed since
    /// it) runs off the main thread, same reason as PlayViewModel's own
    /// startEngine(): it can take real wall-clock time (bounded by
    /// catchUpWallClockBudget), and nothing should wait on it inside the
    /// UI's own call stack.
    private func startEngine() {
        let device = selectedDevice
        let paths = SavePaths(device: device)
        guard let romData = try? Data(contentsOf: paths.importedROMPath) else {
            errorMessage = "Couldn't read this Tama's firmware."
            return
        }
        let savedState = try? Data(contentsOf: paths.v1StatePath)
        let backlogSeconds = paths.lastSavedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0
        startGeneration += 1
        let generation = startGeneration
        isLoading = true

        Task.detached(priority: .userInitiated) { [weak self] in
            let stateToLoad: Data?
            if let savedState, backlogSeconds > 1 {
                let words = V1EmulatorEngine.parseROM(romData)
                stateToLoad = V1EmulatorEngine.catchUp(
                    romWords: words,
                    from: savedState,
                    backlogSeconds: backlogSeconds,
                    wallClockBudget: Self.catchUpWallClockBudget
                )
            } else {
                stateToLoad = savedState
            }
            guard let self else { return }
            await MainActor.run {
                guard self.startGeneration == generation else { return }
                let newEngine = V1EmulatorEngine { [weak self] state in
                    self?.screenState = state
                }
                guard newEngine.start(romData: romData, savedState: stateToLoad) else {
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
