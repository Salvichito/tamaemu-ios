import AVFoundation
import CoreGraphics
import Foundation
import Observation
import SwiftUI
import TamaCore

/// Owns exactly one Tama's engine lifecycle. One instance per owned device,
/// cached for the gallery's lifetime by GalleryViewModel — device identity
/// is fixed for this instance's whole life; there is no more
/// `switchToDevice`, because "switching" is now just which gallery page is
/// selected.
@MainActor
@Observable
final class PlayViewModel {
    let selectedDevice: TamaDevice
    private(set) var lcdImage: CGImage?
    /// The screen's ambient glow color, recomputed only when `lcdImage`
    /// itself changes rather than on every SwiftUI re-render — this used to
    /// live inline in ScreenGlow's view body, which re-ran (and rebuilt a
    /// whole Core Image pipeline) on every unrelated state change, such as
    /// `isPaused` or `isLoading` toggling, even while the frame was
    /// unchanged.
    private(set) var lcdGlowColor: Color = .white
    private(set) var errorMessage: String?
    /// True while an engine load (catch-up included) is in flight off the
    /// main thread — the screen already shows the last known frame during
    /// this (see startEngine()), but it isn't live/interactive yet.
    private(set) var isLoading = false
    /// Mirrors DevicePauseState, cached here so SwiftUI observes changes —
    /// a paused Tama is excluded from catch-up and, if it happens to be the
    /// visible page right now, its engine is stopped immediately so the
    /// screen visibly freezes.
    private(set) var isPaused: Bool
    /// The last translation of the LCD, shown as a floating bubble above
    /// the screen (TamaPageView) until it's dismissed — tapped away,
    /// auto-timed-out, or replaced by a new one.
    private(set) var translatedText: String?
    /// Bumped every time `translatedText` is assigned a fresh result,
    /// including a repeat of the exact same text — TamaPageView keys its
    /// 5-second auto-dismiss timer on this rather than on `translatedText`
    /// itself, so retranslating an unchanged screen still restarts the
    /// countdown instead of silently keeping the old one running.
    private(set) var translationID: UUID?
    private(set) var isTranslating = false

    private var engine: EmulatorEngine?
    private var displayTimer: Timer?
    /// Bumped by stopEngine() and every startEngine() call — a load that
    /// finishes after being superseded (stopped, paused, restarted again)
    /// checks this before applying its result, so it discards itself
    /// instead of resurrecting a stale engine.
    private var startGeneration = 0

    /// Does NOT start the engine — construction is cheap and side-effect
    /// free (just a cached widget snapshot, if any) so the gallery can
    /// create a PlayViewModel for every owned device up front without
    /// spinning up N live engines. Only `resumeIfNeeded()`, called by the
    /// gallery exactly when a page actually becomes visible, starts it.
    init(device: TamaDevice) {
        selectedDevice = device
        isPaused = DevicePauseState.isPaused(device)
        // Shows the last real frame instantly instead of a black screen
        // once this page becomes visible, stale by however long it's been
        // since this Tama was last live, but immediately tells the user
        // their Tama is there rather than leaving them guessing.
        setLCDImage(WidgetSharedState.loadLastFrameImage(for: device))
    }

    /// The one place `lcdImage` is ever assigned — keeps `lcdGlowColor` in
    /// lockstep with it, computed exactly as often as the frame actually
    /// changes instead of on every view re-render.
    private func setLCDImage(_ image: CGImage?) {
        lcdImage = image
        lcdGlowColor = image?.vividGlowColor() ?? .white
    }

    /// Deletes one device's ROM/save data and any pause flag outright — the
    /// caller (GalleryViewModel) is responsible for stopping this device's
    /// engine first, since this is a plain disk operation with no engine
    /// awareness of its own.
    static func removeDeviceData(_ device: TamaDevice) {
        SavePaths(device: device).deleteAll()
        DevicePauseState.clear(device)
    }

    /// Tapping the LCD. Can only ever be called on the page currently on
    /// screen (nothing else has a way to trigger it), so it's safe to
    /// directly stop/restart this instance's own engine rather than asking
    /// the gallery whether this page is "the visible one."
    func togglePause() {
        isPaused.toggle()
        DevicePauseState.setPaused(isPaused, for: selectedDevice)
        if isPaused {
            stopEngine()
        } else {
            // "Frozen while paused" is literal: no time should be counted
            // as having passed during the pause, so pin the clock to right
            // now before bringing the engine back — otherwise catch-up
            // would measure the entire paused interval as a backlog to
            // fast-forward through, the opposite of what pausing means.
            SavePaths(device: selectedDevice).lastSavedAt = Date()
            startEngine()
        }
    }

    /// Stops the emulator thread and audio entirely, after persisting
    /// state. Call when this page stops being visible (swiped away) or on
    /// scenePhase == .background for whichever page is currently visible.
    func stopEngine() {
        startGeneration += 1  // invalidates any startEngine() load still in flight
        displayTimer?.invalidate()
        displayTimer = nil
        // stop() must come first: it blocks until the emulator thread has
        // actually exited, which save() and renderCurrentFrame() both
        // depend on to safely read the Emu struct without a concurrent
        // writer.
        engine?.stop()
        if let engine, let image = LCDImageBuilder.makeImage(
            from: engine.renderCurrentFrame(), width: 128, height: 128
        ) {
            WidgetSharedState.publish(image: image, device: selectedDevice)
        }
        engine?.save()
        engine = nil
    }

    /// Call when this page becomes visible (swiped to) or on
    /// scenePhase == .active for whichever page is currently visible.
    /// A no-op if already running.
    func resumeIfNeeded() {
        guard engine == nil, !isPaused else { return }
        startEngine()
    }

    func pressButton(_ button: InputController.Button) {
        engine?.input.press(button)
    }

    func releaseButton(_ button: InputController.Button) {
        engine?.input.release(button)
    }

    /// Pass-throughs to the live engine's audio for ScreenRecorder. Both
    /// are no-ops without a running engine — a page that's paused or
    /// mid-load has no audio to tap, so the record button never offers
    /// video in that state (see TamaGalleryView).
    var audioFormat: AVAudioFormat? { engine?.audioFormat }

    func installRecordingTap(format: AVAudioFormat, bufferSize: AVAudioFrameCount, block: @escaping AVAudioNodeTapBlock) {
        engine?.installRecordingTap(format: format, bufferSize: bufferSize, block: block)
    }

    func removeRecordingTap() {
        engine?.removeRecordingTap()
    }

    /// Re-applies speed/stay-awake to the running engine right after a
    /// Settings change — these take effect immediately, no restart needed.
    func refreshSettings() {
        engine?.applySettings()
    }

    /// Soft reset: same ROM/flash/RAM, CPU state and clock back to the
    /// firmware's own boot vector. Distinct from removeDeviceData, which
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

    /// Path to this device's live flash/save image, if any exists yet —
    /// for the Settings screen's export action (disabled otherwise).
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

    /// Overwrites this device's live flash image with an imported `.sav`
    /// file and discards its CPU/RAM snapshot, so the next load boots
    /// fresh from that flash content — mirrors the Android port's own
    /// save-import (replace flash, drop state, reload).
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
        // Replacing the save implies resuming play with it, regardless of
        // whatever pause state this Tama was in before.
        if isPaused {
            isPaused = false
            DevicePauseState.setPaused(false, for: selectedDevice)
        }
        paths.lastSavedAt = Date()
        startEngine()
    }

    private func beginDisplayTimer() {
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            // Timer's closure type is nonisolated/Sendable as far as the
            // compiler knows, but this timer is always created from — and
            // therefore always fires on — the main actor's run loop, so
            // this assumption is safe, not just convenient.
            MainActor.assumeIsolated {
                guard let self, let frame = self.engine?.latestFrame() else { return }
                self.setLCDImage(LCDImageBuilder.makeImage(from: frame, width: 128, height: 128))
            }
        }
    }

    /// Loading an engine runs catch-up synchronously inside its init() —
    /// and real-device throughput turned out to be far below what a
    /// previous fixed, blocking budget assumed (measured ~12x real time on
    /// an actual phone, not the ~230x Simulator figure the budget was
    /// originally sized against). No fixed synchronous budget can both
    /// keep launch instant AND make real progress at that throughput, so
    /// this runs entirely off the main thread instead of inside
    /// PlayViewModel's (and ultimately the UI's) call stack — the catch-up
    /// pass can take however long it actually needs without the app ever
    /// appearing to hang. A larger per-attempt budget is safe now that
    /// nothing is waiting on it.
    private nonisolated static let catchUpWallClockBudget: TimeInterval = 10.0

    private func startEngine() {
        stopEngine()
        startGeneration += 1
        let generation = startGeneration
        isLoading = true
        let device = selectedDevice
        let paths = SavePaths(device: device)
        let isPausedNow = isPaused
        NotificationScheduler.requestAuthorizationIfNeeded()

        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result {
                try EmulatorEngine(
                    device: device,
                    savePaths: paths,
                    catchUpWallClockBudget: Self.catchUpWallClockBudget,
                    isPaused: isPausedNow,
                    // This engine's catch-up pass runs because the player
                    // just opened (or unpaused) the app — any call it
                    // detects is about to be visible on screen within
                    // moments, so a notification for it would just be
                    // noise. A call during live play afterwards still
                    // notifies normally (see checkCallDetection).
                    notifyOnCatchUpCalls: false,
                    onCallDetected: {
                        NotificationScheduler.fireCallingNotification(deviceTitle: device.title)
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
                        // paused, restarted) — this engine never started
                        // running, so just persist whatever catch-up
                        // progress it made and let it go.
                        newEngine.save()
                        return
                    }
                    if let image {
                        WidgetSharedState.publish(image: image, device: device)
                        // Shows the real post-catch-up frame the instant
                        // loading ends, rather than leaving the stale
                        // cached snapshot on screen until the display timer
                        // happens to notice a pixel change.
                        self.setLCDImage(image)
                    }
                    newEngine.start()
                    self.engine = newEngine
                    self.errorMessage = nil
                    self.isLoading = false
                    self.beginDisplayTimer()
                }
            case .failure(let error):
                await MainActor.run {
                    guard self.startGeneration == generation else { return }
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    // MARK: - Translation

    /// One-shot: grabs whatever's on the LCD right now and translates it
    /// once. Tapping the button again while a translation is already in
    /// flight is a no-op rather than queuing a second request.
    @available(iOS 27.0, *)
    func translateNow() {
        guard !isTranslating, let lcdImage else { return }
        runTranslation(on: lcdImage)
    }

    /// .detached, not a plain Task — a plain Task created from this
    /// MainActor-isolated method would inherit MainActor, and a
    /// translator's actual network/model call runs synchronously on
    /// whatever thread calls it, which would freeze the whole app's UI for
    /// the duration (confirmed on-device while prototyping this).
    /// Detaching keeps that work off the main thread; only the property
    /// writes below hop back.
    @available(iOS 27.0, *)
    private func runTranslation(on image: CGImage) {
        isTranslating = true
        let cloudAPIKey = AppSettings.liveTranslationUsesCloud ? KeychainStore.read() : nil
        Task.detached { [weak self] in
            let text: String?
            if let cloudAPIKey, !cloudAPIKey.isEmpty {
                text = await CloudTranslator.translate(image, apiKey: cloudAPIKey)
            } else {
                text = await ScreenTranslator.translate(image)
            }
            guard let self else { return }
            await MainActor.run {
                self.isTranslating = false
                self.translatedText = text
                self.translationID = text != nil ? UUID() : nil
            }
        }
    }

    func dismissTranslation() {
        translatedText = nil
        translationID = nil
    }
}
