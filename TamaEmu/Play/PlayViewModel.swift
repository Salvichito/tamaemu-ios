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
final class PlayViewModel: SaveBackupHost {
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
    /// The bubble is showing a failure reason, not a translation.
    private(set) var translationIsError = false
    /// Whether the live engine is currently running at the
    /// tap-and-hold fast-forward speed — purely a UI flag for the badge
    /// TamaPageView shows while held. Never persisted: losing the engine
    /// (background, swipe away) always comes back at normal speed.
    private(set) var isFastForwarding = false

    /// Who this Tama is currently connected to (NearbyLinkSession), for
    /// the badge on its page -- nil when not connected.
    private(set) var linkPeerName: String?
    /// Kept here rather than only on the engine: the engine is rebuilt
    /// every time this page comes back on screen, and the connection
    /// should survive that.
    private var linkPort: LinkPort?

    private var engine: EmulatorEngine?
    private var displayTimer: Timer?
    /// Bumped by stopEngine() and every startEngine() call — a load that
    /// finishes after being superseded (stopped, paused, restarted again)
    /// checks this before applying its result, so it discards itself
    /// instead of resurrecting a stale engine.
    private var startGeneration = 0
    /// Tells the in-flight load (if any) to stop its catch-up pass right
    /// away rather than run out its budget — set alongside every
    /// startGeneration bump that supersedes it.
    private var loadCancel: CancelFlag?
    /// Whether the live engine currently holds this device's EngineGate
    /// (handed over by the load task that built it) — released once it has
    /// been stopped and saved.
    private var holdsGate = false

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
            SavePaths(device: selectedDevice).markSyncedNow()
            // ...but the Tama's own clock should still show the real time,
            // not the moment it was paused. Jumping it (like "Sync Clock to
            // Now") moves only the clock — nothing ages in between.
            startEngine(syncClockToNow: true)
        }
    }

    /// Stops the emulator thread and audio entirely, after persisting
    /// state. Call when this page stops being visible (swiped away) or on
    /// scenePhase == .background for whichever page is currently visible.
    func stopEngine() {
        startGeneration += 1  // invalidates any startEngine() load still in flight
        loadCancel?.cancel()
        loadCancel = nil
        displayTimer?.invalidate()
        displayTimer = nil
        isFastForwarding = false
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
        if let engine {
            engine.save()
            // Rides along with a save that was happening anyway -- at most
            // once an hour (see SavePaths.automaticBackupInterval), and
            // still inside the gate so nothing else can be half-way
            // through writing these files.
            SavePaths(device: selectedDevice).makeBackup(reason: .automatic)
        }
        engine = nil
        if holdsGate {
            holdsGate = false
            EngineGate.gate(for: selectedDevice).release()
        }
    }

    /// Call when this page becomes visible (swiped to) or on
    /// scenePhase == .active for whichever page is currently visible.
    /// A no-op if already running.
    func resumeIfNeeded() {
        guard engine == nil, !isPaused else { return }
        startEngine()
    }

    /// Plugs this Tama's infrared into a connection to another Tama, or
    /// unplugs it (nil). Takes effect right away if the Tama is running,
    /// otherwise the next time it starts.
    func setLink(port: LinkPort?, peerName: String?) {
        linkPort = port
        linkPeerName = port == nil ? nil : peerName
        engine?.setLinkPort(port)
    }

    /// Tap-and-hold on the Tama's screen. A no-op while paused or loading
    /// — there's no running engine to speed up — or if already held.
    func beginFastForward() {
        guard !isPaused, !isFastForwarding, engine != nil else { return }
        isFastForwarding = true
        engine?.setFastForward(2.0)
    }

    /// Releasing the hold. Always safe to call, even if beginFastForward()
    /// above was skipped (e.g. the hold started while paused) — it's a
    /// no-op whenever isFastForwarding is already false.
    func endFastForward() {
        guard isFastForwarding else { return }
        isFastForwarding = false
        engine?.setFastForward(1.0)
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
        let paths = SavePaths(device: selectedDevice)
        pauseEngine { engine in
            // A restart loses the Tama's exact position and clock for
            // good -- keep a way back to the moment just before it.
            engine.save()
            paths.makeBackup(reason: .beforeRestart)
            engine.resetCPU()
        }
    }

    /// Runs an arbitrary action on the stopped engine (e.g. `setClock`)
    /// between stop and save/restart, for Settings actions that need
    /// direct engine access without exposing `engine` itself.
    func restartTamaClock(_ action: (EmulatorEngine) -> Void) {
        guard engine != nil else { return }
        pauseEngine(action)
    }

    /// Path to this device's live flash/save image, if any exists yet.
    private var liveSaveURL: URL? {
        let path = SavePaths(device: selectedDevice).liveFlashPath
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    /// Whether Settings' export action has anything to export -- a running
    /// engine always does (prepareExportURL() flushes it to disk first).
    var canExportSave: Bool {
        engine != nil || liveSaveURL != nil
    }

    /// A *copy* of the save file, for the system's "save to Files" sheet.
    ///
    /// Never hand that sheet the live file itself: it moves whatever it's
    /// given out of the app. That is what this used to do, and it left the
    /// Tama without its save file on disk -- so the next time it was
    /// loaded (swiping away and back, reopening the app) it fell back to
    /// the untouched firmware and started over. Only "sometimes", because
    /// the file reappeared on its own whenever the firmware happened to
    /// write a new in-game save before then.
    ///
    /// Briefly stops and restarts the engine around `save()` so the export
    /// reflects state current to the moment of export, not just the last
    /// backgrounding -- `save()` itself isn't safe to call while the
    /// emulator thread might still be stepping (see `EmulatorEngine.save`).
    func prepareExportURL() -> URL? {
        if engine != nil { pauseEngine() }
        guard let live = liveSaveURL else { return nil }
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("SaveExport", isDirectory: true)
        try? fm.removeItem(at: folder)
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
        let name = "\(selectedDevice.title) \(stamp)".replacingOccurrences(of: "/", with: "-")
        let copy = folder.appendingPathComponent(name).appendingPathExtension("sav")
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.copyItem(at: live, to: copy)
            return copy
        } catch {
            return nil
        }
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
        // Read the whole file before touching anything, so a file that
        // can't be read leaves the current Tama exactly as it was.
        let imported = try Data(contentsOf: url)
        // The engine has to be fully stopped *before* the file is
        // replaced: stopping saves, and a save made afterwards could write
        // the old Tama's data straight back over the imported file.
        stopEngine()
        let paths = SavePaths(device: selectedDevice)
        try paths.ensureDirectoriesExist()
        paths.makeBackup(reason: .beforeImport)
        try imported.write(to: paths.liveFlashPath, options: .atomic)
        paths.deleteStateOnly()
        // Replacing the save implies resuming play with it, regardless of
        // whatever pause state this Tama was in before.
        if isPaused {
            isPaused = false
            DevicePauseState.setPaused(false, for: selectedDevice)
        }
        paths.markSyncedNow()
        startEngine()
    }

    // MARK: - Downloads (DLC)

    /// Whether this kind of Tama has download slots at all.
    var supportsDownloads: Bool {
        DownloadStore.isSupported(deviceID: selectedDevice.id)
    }

    /// Downloads go straight into the running Tama's memory so it doesn't
    /// have to restart, which needs it loaded -- not paused, not still
    /// loading.
    var canChangeDownloads: Bool { engine != nil }

    /// Every download slot on this Tama and what's in it.
    func downloadCategories() -> [DownloadCategory] {
        let id = selectedDevice.id
        if engine != nil {
            var result: [DownloadCategory] = []
            pauseEngine { engine in
                result = engine.readFlash { DownloadStore.categories(deviceID: id, image: $0) }
            }
            return result
        }
        // Paused (or not loaded yet): what's on disk is current, since
        // stopping saves.
        let paths = SavePaths(device: selectedDevice)
        let url = liveSaveURL ?? paths.importedROMPath
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        return data.withUnsafeBytes {
            DownloadStore.categories(deviceID: id, image: $0.bindMemory(to: UInt8.self))
        }
    }

    /// Installs download files (.jpg/.bin) picked by the user. Each file
    /// gets its own result; one bad file doesn't stop the others.
    func installDownloads(from urls: [URL]) -> [DownloadInstallResult] {
        guard engine != nil else { return [] }
        // Copy everything into the app first: the picked files are only
        // readable through their security scope, and the installer opens
        // them by plain path.
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("DownloadImport", isDirectory: true)
        try? fm.removeItem(at: folder)
        defer { try? fm.removeItem(at: folder) }
        var local: [URL] = []
        var unreadable: [DownloadInstallResult] = []
        for (i, url) in urls.enumerated() {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let dir = folder.appendingPathComponent(String(i), isDirectory: true)
            let copy = dir.appendingPathComponent(url.lastPathComponent)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try fm.copyItem(at: url, to: copy)
                local.append(copy)
            } catch {
                unreadable.append(DownloadInstallResult(
                    fileName: url.lastPathComponent, itemName: "", categoryLabel: nil,
                    failure: "The file couldn't be read."
                ))
            }
        }
        guard !local.isEmpty else { return unreadable }

        let id = selectedDevice.id
        let paths = SavePaths(device: selectedDevice)
        var results: [DownloadInstallResult] = []
        pauseEngine { engine in
            // A way back to exactly how the Tama was before this.
            engine.save()
            paths.makeBackup(reason: .beforeDownloads)
            results = engine.editFlash { DownloadStore.install(deviceID: id, image: $0, files: local) }
        }
        return results + unreadable
    }

    /// Erases one download slot. Returns false if nothing was changed.
    @discardableResult
    func removeDownload(_ slot: DownloadSlot) -> Bool {
        guard engine != nil else { return false }
        let id = selectedDevice.id
        let paths = SavePaths(device: selectedDevice)
        var removed = false
        pauseEngine { engine in
            engine.save()
            paths.makeBackup(reason: .beforeDownloads)
            removed = engine.editFlash {
                DownloadStore.free(deviceID: id, image: $0, kind: slot.kind, index: slot.index)
            }
        }
        return removed
    }

    // MARK: - Backups

    func backupNow() {
        if engine != nil { pauseEngine() }
        SavePaths(device: selectedDevice).makeBackup(reason: .manual)
    }

    func restoreBackup(_ backup: SaveBackup) throws {
        stopEngine()
        try SavePaths(device: selectedDevice).restore(backup)
        // The backup's own last screen, straight away, rather than the
        // replaced Tama's lingering until the engine has loaded.
        setLCDImage(WidgetSharedState.loadLastFrameImage(for: selectedDevice))
        // Same as importing a save: restoring implies playing it.
        if isPaused {
            isPaused = false
            DevicePauseState.setPaused(false, for: selectedDevice)
        }
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

    private func startEngine(syncClockToNow: Bool = false) {
        stopEngine()
        startGeneration += 1
        let generation = startGeneration
        isLoading = true
        let device = selectedDevice
        let paths = SavePaths(device: device)
        let isPausedNow = isPaused
        let cancel = CancelFlag()
        loadCancel = cancel
        let gate = EngineGate.gate(for: device)
        NotificationScheduler.requestAuthorizationIfNeeded()

        Task.detached(priority: .userInitiated) { [weak self] in
            // Wait for anything else still touching this Tama's save — a
            // background refresh pass caught mid-flight by the app being
            // opened, or a previous load of this same page that was
            // superseded and is still saving its progress. Both stop
            // within moments once they notice, so this is normally
            // instant; the timeout only exists so a stuck holder can't
            // leave this page loading forever.
            let holdsGate = gate.acquire(timeout: 15)
            @Sendable func releaseGate() { if holdsGate { gate.release() } }

            guard !cancel.isCancelled else { releaseGate(); return }
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
                    shouldAbort: { cancel.isCancelled },
                    onCallDetected: {
                        NotificationScheduler.fireCallingNotification(device: device)
                    }
                )
            }
            switch result {
            case .success(let newEngine):
                // A single pass only gets catchUpWallClockBudget's worth of
                // compute, so a gap bigger than that leaves time still owed
                // (see EmulatorEngine.canContinueCatchUp) — keep running
                // further passes, still off the main thread, for as long as
                // this page is the one actually on screen. Without this, a
                // big gap used to only get chipped away at one visit at a
                // time, needing several swipes away and back to finish.
                while newEngine.canContinueCatchUp, !cancel.isCancelled {
                    newEngine.continueCatchUp(wallClockBudget: Self.catchUpWallClockBudget)
                }
                guard !cancel.isCancelled, let self else {
                    // Superseded while this was loading (stopped, paused,
                    // restarted) — this engine never started running, so
                    // just persist whatever catch-up progress it made and
                    // let it go. Still inside the gate, so whoever loads
                    // this Tama next sees this save, not a half-written one.
                    newEngine.save()
                    releaseGate()
                    return
                }
                if syncClockToNow {
                    // The engine's thread hasn't started yet, so writing the
                    // clock registers directly is safe here.
                    let now = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
                    newEngine.setClock(hour: now.hour ?? 0, minute: now.minute ?? 0, second: now.second ?? 0)
                }
                let image = LCDImageBuilder.makeImage(
                    from: newEngine.renderCurrentFrame(), width: 128, height: 128
                )
                await MainActor.run {
                    guard self.startGeneration == generation else {
                        newEngine.save()
                        releaseGate()
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
                    newEngine.setLinkPort(self.linkPort)
                    newEngine.start()
                    self.engine = newEngine
                    // The live engine keeps the gate from here; stopEngine()
                    // gives it back once the engine is stopped and saved.
                    self.holdsGate = holdsGate
                    self.errorMessage = nil
                    self.isLoading = false
                    self.beginDisplayTimer()
                }
            case .failure(let error):
                releaseGate()
                guard let self else { return }
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
            let isError: Bool
            if let cloudAPIKey, !cloudAPIKey.isEmpty {
                // A failed cloud request now says why in the bubble
                // (timed out, busy, bad key...) instead of the spinner
                // just stopping with nothing shown.
                switch await CloudTranslator.translate(image, apiKey: cloudAPIKey) {
                case .success(let translated):
                    text = translated
                    isError = false
                case .failure(let error):
                    text = error.message
                    isError = true
                }
            } else {
                text = await ScreenTranslator.translate(image)
                isError = false
            }
            guard let self else { return }
            await MainActor.run {
                self.isTranslating = false
                self.translatedText = text
                self.translationIsError = isError
                self.translationID = text != nil ? UUID() : nil
            }
        }
    }

    func dismissTranslation() {
        translatedText = nil
        translationID = nil
    }
}

extension PlayViewModel: ScreenRecordable {
    func recordingFrame(side: CGFloat) -> CGImage? {
        guard let lcdImage else { return nil }
        return renderLCDSnapshot(image: lcdImage, side: side)
    }
}
