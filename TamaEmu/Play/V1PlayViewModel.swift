import AVFoundation
import CoreGraphics
import Foundation
import Observation
import TamaCore

/// Owns exactly one P1-era (TamaLib) Tama's engine lifecycle. Mirrors
/// PlayViewModel's shape (one instance per owned device, cached by
/// GalleryViewModel, construction cheap/side-effect free) but drives
/// V1EmulatorEngine instead of CTama's EmulatorEngine -- kept as its own
/// type rather than shared with PlayViewModel since the two cores have
/// almost nothing in common (no translation here -- P1 screens have no
/// text to translate). Pause, hold-to-fast-forward, screenshots and video
/// all mirror PlayViewModel's own. Save/resume, including catching up on time spent away, is
/// handled via V1EmulatorEngine's saveState()/start(savedState:)/
/// catchUp(_:).
@MainActor
@Observable
final class V1PlayViewModel: SaveBackupHost {
    let selectedDevice: TamaDevice
    private(set) var screenState: P1ScreenState = .blank
    private(set) var errorMessage: String?
    /// True while a resume's catch-up pass (time spent away) is running
    /// off the main thread -- the screen still shows the last saved
    /// frame during this (see WidgetSharedState in PlayViewModel's own
    /// equivalent), it just isn't live/interactive yet.
    private(set) var isLoading = false
    /// Mirrors DevicePauseState, same as PlayViewModel's own: a paused
    /// Tama has no live engine and is skipped by catch-up, so no time
    /// passes for it at all until it's unpaused.
    private(set) var isPaused: Bool
    /// True while the screen is being held down -- see
    /// PlayViewModel.isFastForwarding. Never persisted.
    private(set) var isFastForwarding = false

    /// Whether `screenState` has ever been given a real frame -- a paused
    /// Tama has no engine to supply one, so resumeIfNeeded() reads it
    /// from the save instead, once.
    private var hasShownFrame = false
    /// ScreenRecorder asks for a frame 30 times a second; a P1 screen
    /// changes a couple of times a second at most, so the last render is
    /// reused until the screen actually differs.
    private var recordingFrameCache: (state: P1ScreenState, image: CGImage)?

    private var engine: V1EmulatorEngine?
    /// Bumped by stopEngine() and every startEngine() call -- a catch-up
    /// pass that finishes after being superseded (page swiped away,
    /// stopped, started again) checks this before applying its result,
    /// mirroring PlayViewModel's own startGeneration.
    private var startGeneration = 0
    /// Tells the in-flight catch-up (if any) to stop right away -- see
    /// PlayViewModel's own loadCancel.
    private var loadCancel: CancelFlag?
    /// Whether the live engine holds the V1 family's EngineGate -- see
    /// PlayViewModel's own holdsGate.
    private var holdsGate = false
    /// Real seconds the live engine's state was still behind when it
    /// started (a catch-up that couldn't quite finish). The live core
    /// keeps pace with real time from there, so the same amount is still
    /// owed when it stops -- stopEngine() back-dates lastSavedAt by it
    /// rather than stamping "now" and forgetting it.
    private var owedAtLiveStart: TimeInterval = 0

    private nonisolated static let catchUpWallClockBudget: TimeInterval = 10.0

    init(device: TamaDevice) {
        selectedDevice = device
        isPaused = DevicePauseState.isPaused(device)
    }

    static func removeDeviceData(_ device: TamaDevice) {
        SavePaths(device: device).deleteAll()
        DevicePauseState.clear(device)
    }

    func resumeIfNeeded() {
        guard engine == nil, !isLoading else { return }
        guard !isPaused else {
            showSavedScreenIfNeeded()
            return
        }
        startEngine()
    }

    /// Tapping the screen -- see PlayViewModel.togglePause().
    func togglePause() {
        isPaused.toggle()
        DevicePauseState.setPaused(isPaused, for: selectedDevice)
        if isPaused {
            stopEngine()
        } else {
            // Nothing is owed for the time spent paused -- see
            // startEngine(discardingGap:).
            startEngine(discardingGap: true)
        }
    }

    /// Holding the screen down. A no-op without a running engine.
    func beginFastForward() {
        guard !isPaused, !isFastForwarding, let engine else { return }
        isFastForwarding = true
        engine.setFastForward(true)
    }

    func endFastForward() {
        guard isFastForwarding else { return }
        isFastForwarding = false
        engine?.setFastForward(false)
    }

    /// A Tama that's paused when the app opens has nothing on screen
    /// until it's unpaused -- so read what its save was showing. Waits
    /// its turn for the core like everything else (see EngineGate), and
    /// simply gives up if it can't get it.
    private func showSavedScreenIfNeeded() {
        guard !hasShownFrame else { return }
        hasShownFrame = true
        let paths = SavePaths(device: selectedDevice)
        let gate = EngineGate.gate(for: selectedDevice)
        Task.detached(priority: .userInitiated) { [weak self] in
            guard gate.acquire(timeout: 15) else { return }
            var screen: P1ScreenState?
            if let romData = try? Data(contentsOf: paths.importedROMPath),
               let state = try? Data(contentsOf: paths.v1StatePath) {
                screen = V1EmulatorEngine.peekScreen(romWords: V1EmulatorEngine.parseROM(romData), state: state)
            }
            gate.release()
            guard let screen, let self else { return }
            await MainActor.run {
                // Unpaused in the meantime: the live engine owns the
                // screen now.
                guard self.isPaused, self.engine == nil else { return }
                self.screenState = screen
            }
        }
    }

    /// Stops the engine and persists its state -- stop() itself blocks
    /// until the stepping thread has actually exited, which saveState()
    /// depends on to read the core's state without a concurrent writer
    /// (see both methods' own doc comments on V1EmulatorEngine).
    func stopEngine() {
        startGeneration += 1  // invalidates any startEngine() catch-up still in flight
        loadCancel?.cancel()
        loadCancel = nil
        // Without this, backgrounding (or swiping away) while a catch-up
        // was still running left isLoading stuck on true forever -- and
        // resumeIfNeeded() refuses to start while it's set, so this Tama
        // stayed frozen on its last frame until the app was force-quit.
        isLoading = false
        isFastForwarding = false
        guard let engine else { return }
        engine.stop()
        if let data = engine.saveState() {
            let paths = SavePaths(device: selectedDevice)
            try? paths.ensureDirectoriesExist()
            if (try? data.write(to: paths.v1StatePath, options: .atomic)) != nil {
                // Time spent fast-forwarding put this Tama's clock ahead
                // of real time by that much, so the save counts as caught
                // up to that far in the future -- the next time away is
                // shortened by it rather than the clock staying ahead.
                paths.lastSavedAt = Date().addingTimeInterval(engine.fastForwardExtraSeconds - owedAtLiveStart)
                // See PlayViewModel.stopEngine(): at most hourly, and
                // still inside the gate.
                paths.makeBackup(reason: .automatic)
            }
        }
        self.engine = nil
        if holdsGate {
            holdsGate = false
            EngineGate.gate(for: selectedDevice).release()
        }
    }

    /// stopEngine() is what writes this family's save, so a backup of
    /// "right now" is a stop, a snapshot, and a restart.
    func backupNow() {
        guard engine != nil else {
            SavePaths(device: selectedDevice).makeBackup(reason: .manual)
            return
        }
        stopEngine()
        SavePaths(device: selectedDevice).makeBackup(reason: .manual)
        startEngine()
    }

    /// Restart: like taking the battery out and back in. First-gen toys
    /// keep everything in RAM, so the game starts over from the
    /// beginning. Stops (which saves), backs that save up so Backups can
    /// undo this, then drops the CPU/RAM snapshot and boots fresh.
    func restartTama() {
        stopEngine()
        let paths = SavePaths(device: selectedDevice)
        paths.makeBackup(reason: .beforeRestart)
        try? FileManager.default.removeItem(at: paths.v1StatePath)
        if isPaused {
            isPaused = false
            DevicePauseState.setPaused(false, for: selectedDevice)
        }
        startEngine(discardingGap: true)
    }

    func restoreBackup(_ backup: SaveBackup) throws {
        stopEngine()
        try SavePaths(device: selectedDevice).restore(backup)
        // Same as PlayViewModel: restoring implies playing it.
        if isPaused {
            isPaused = false
            DevicePauseState.setPaused(false, for: selectedDevice)
        }
        startEngine()
    }

    func pressButton(_ button: InputController.Button) {
        engine?.input.press(button)
    }

    func releaseButton(_ button: InputController.Button) {
        engine?.input.release(button)
    }

    /// Tap-an-icon shortcut; see V1IconProfile.tappableMenuLights.
    func openMenuIcon(light: Int) {
        guard let count = V1IconProfile.tappableMenuLights(for: selectedDevice.id) else { return }
        engine?.openMenuIcon(light: light, count: count)
    }

    // MARK: - Screenshot / video

    /// The screen as a picture, at the size it's drawn in the gallery.
    func screenshot() -> CGImage? {
        renderP1Snapshot(state: screenState, deviceID: selectedDevice.id)
    }

    /// Catch-up (if there's a saved state and real time has passed since
    /// it) runs off the main thread, same reason as PlayViewModel's own
    /// startEngine(): it can take real wall-clock time (bounded by
    /// catchUpWallClockBudget), and nothing should wait on it inside the
    /// UI's own call stack.
    ///
    /// `discardingGap` is for unpausing: "frozen while paused" means none
    /// of the paused time counts as time away. The stamp is moved inside
    /// the gate, not before it, so a catch-up that was interrupted by the
    /// pause and is still writing its own progress can't overwrite it.
    private func startEngine(discardingGap: Bool = false) {
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
        NotificationScheduler.requestAuthorizationIfNeeded()

        Task.detached(priority: .userInitiated) { [weak self] in
            // The TamaLib core is a single set of C globals, so nothing
            // else may be using it while this runs -- not a background
            // refresh pass, and not an earlier catch-up that was swiped
            // away from and hasn't wound down yet. See EngineGate.
            let holdsGate = gate.acquire(timeout: 15)
            @Sendable func releaseGate() { if holdsGate { gate.release() } }
            guard !cancel.isCancelled else { releaseGate(); return }

            if discardingGap { paths.markSyncedNow() }

            // Read only now, inside the gate: whoever held it a moment ago
            // may have just written a newer state and lastSavedAt.
            var state = try? Data(contentsOf: paths.v1StatePath)
            var caughtUpTo = paths.lastSavedAt ?? Date()
            var madeProgress = false
            if let loaded = state {
                let words = V1EmulatorEngine.parseROM(romData)
                var current = loaded
                // Keep going in budget-sized passes until it's really
                // caught up (or this page is no longer the one on screen)
                // rather than going live with a clock that's still behind.
                while !cancel.isCancelled {
                    let owed = Date().timeIntervalSince(caughtUpTo)
                    guard owed > 0.5 else { break }
                    let result = V1EmulatorEngine.catchUp(
                        romWords: words,
                        from: current,
                        backlogSeconds: owed,
                        wallClockBudget: Self.catchUpWallClockBudget,
                        shouldAbort: { cancel.isCancelled }
                    )
                    // No progress at all means the core couldn't load this
                    // state -- retrying would just spin.
                    guard result.advancedSeconds > 0 else { break }
                    current = result.state
                    caughtUpTo = caughtUpTo.addingTimeInterval(result.advancedSeconds)
                    madeProgress = true
                }
                state = current
            }

            // Persists the catch-up itself, not just the live session that
            // follows it -- so being superseded right here, or the app
            // being killed mid-play, doesn't throw the work away.
            func persistProgress() {
                guard madeProgress, let state else { return }
                if (try? state.write(to: paths.v1StatePath, options: .atomic)) != nil {
                    paths.lastSavedAt = caughtUpTo
                }
            }

            guard !cancel.isCancelled, let self else {
                persistProgress()
                releaseGate()
                return
            }
            persistProgress()
            let stateToLoad = state
            let stateCaughtUpTo = caughtUpTo
            let didCatchUp = madeProgress
            await MainActor.run {
                guard self.startGeneration == generation else { releaseGate(); return }
                let newEngine = V1EmulatorEngine(onFrame: { [weak self] state in
                    self?.screenState = state
                    self?.hasShownFrame = true
                }, onCallDetected: {
                    NotificationScheduler.fireCallingNotification(device: device)
                })
                guard newEngine.start(romData: romData, savedState: stateToLoad) else {
                    releaseGate()
                    self.errorMessage = "Couldn't start this Tama's emulator core."
                    self.isLoading = false
                    return
                }
                // A saved state that can't be advanced at all (see the
                // loop above) has nothing meaningful owed -- only carry a
                // shortfall for a state that was actually being caught up.
                // Negative when the last session's fast-forwarding left
                // the clock ahead and not enough real time has passed
                // since to use that up -- still carried, so it isn't
                // forgotten. Capped so a phone whose own clock was set
                // back can't leave this Tama "ahead" by days.
                let owed = max(-3600, Date().timeIntervalSince(stateCaughtUpTo))
                self.owedAtLiveStart = (stateToLoad == nil || (owed > 0.5 && !didCatchUp)) ? 0 : owed
                self.holdsGate = holdsGate
                self.errorMessage = nil
                self.isLoading = false
                self.engine = newEngine
            }
        }
    }
}

extension V1PlayViewModel: ScreenRecordable {
    var audioFormat: AVAudioFormat? { engine?.audioFormat }

    func installRecordingTap(format: AVAudioFormat, bufferSize: AVAudioFrameCount, block: @escaping AVAudioNodeTapBlock) {
        engine?.installRecordingTap(format: format, bufferSize: bufferSize, block: block)
    }

    func removeRecordingTap() {
        engine?.removeRecordingTap()
    }

    func recordingFrame(side: CGFloat) -> CGImage? {
        if let cached = recordingFrameCache, cached.state == screenState { return cached.image }
        guard let image = renderP1Snapshot(state: screenState, deviceID: selectedDevice.id) else { return nil }
        recordingFrameCache = (screenState, image)
        return image
    }
}
