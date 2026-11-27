import AVFoundation
import CoreGraphics
import Foundation
import Observation
import SwiftUI
import TamaCore

/// Owns one Tamagotchi Meets / On (T18Emu) Tama's engine lifecycle. Same
/// shape as T7PlayViewModel (one per owned device, cached by
/// GalleryViewModel, construction cheap and side-effect free), with this
/// family's two save files: the game's own flash save and the session.
@MainActor
@Observable
final class T18PlayViewModel: SaveBackupHost {
    let selectedDevice: TamaDevice
    private(set) var screenState: T18ScreenState = .blank
    /// The screen as an image, rebuilt once per new picture.
    private(set) var screenImage: CGImage?
    /// The screen's most vivid color, for the Ambient theme's glow.
    private(set) var glowColor: Color = .white
    private(set) var errorMessage: String?
    private(set) var isLoading = false
    private(set) var isPaused: Bool
    private(set) var isFastForwarding = false
    private var hasShownFrame = false

    @ObservationIgnored private var lastWidgetFrame = Date.distantPast
    private var engine: T18EmulatorEngine?
    /// The last video frame drawn, reused while the screen hasn't changed.
    @ObservationIgnored private var recordingFrameCache: (state: T18ScreenState, image: CGImage)?
    private var startGeneration = 0
    private var loadCancel: CancelFlag?
    private var holdsGate = false
    /// See T7PlayViewModel.liveStartCaughtUpTo.
    private var liveStartCaughtUpTo: Date?

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

    /// Tapping the screen, or Pause/Resume in the ⋯ menu.
    func togglePause() {
        isPaused.toggle()
        DevicePauseState.setPaused(isPaused, for: selectedDevice)
        if isPaused {
            stopEngine()
        } else {
            // Nothing is owed for the time paused, and the clock stays
            // where it was (Sync Clock to Now is the manual catch-up).
            startEngine(discardingGap: true)
        }
    }

    /// ⋯ "Set Points…". Applied between frames; while paused, kept until
    /// play resumes.
    func setPoints(_ value: Int) {
        if let engine {
            engine.setPoints(value)
        } else {
            pointsAwaitingEngine = value
        }
    }
    private var pointsAwaitingEngine: Int?

    /// ⋯ "Sync Clock to Now": the toy's clock jumps to the real time and
    /// nothing ages in between.
    func syncClockToNow() {
        guard engine != nil, !isPaused else { return }
        stopEngine()
        startEngine(discardingGap: true, syncClock: true)
    }

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

    private func show(_ state: T18ScreenState) {
        guard state != screenState || screenImage == nil else { return }
        screenState = state
        screenImage = state.makeImage()
        glowColor = screenImage?.vividGlowColor() ?? .white
        hasShownFrame = true
    }

    private func showSavedScreenIfNeeded() {
        guard !hasShownFrame else { return }
        hasShownFrame = true
        let paths = SavePaths(device: selectedDevice)
        let gate = EngineGate.gate(for: selectedDevice)
        Task.detached(priority: .userInitiated) { [weak self] in
            guard gate.acquire(timeout: 15) else { return }
            var screen: T18ScreenState?
            if let romData = try? Data(contentsOf: paths.importedROMPath),
               let state = try? Data(contentsOf: paths.t18StatePath) {
                let flash = try? Data(contentsOf: paths.t18FlashPath)
                screen = T18EmulatorEngine.peekScreen(romData: romData, flashData: flash, state: state)
            }
            gate.release()
            guard let screen, let self else { return }
            await MainActor.run {
                guard self.isPaused, self.engine == nil else { return }
                self.show(screen)
                self.publishWidgetFrame()
            }
        }
    }

    /// Stops the engine and saves both files (stop() joins the stepping
    /// thread first, so the core is quiet while it's read).
    func stopEngine() {
        startGeneration += 1
        loadCancel?.cancel()
        loadCancel = nil
        isLoading = false
        isFastForwarding = false
        guard let engine else { return }
        engine.stop()
        publishWidgetFrame()
        let paths = SavePaths(device: selectedDevice)
        try? paths.ensureDirectoriesExist()
        // Flash first: it's the game's own save, the part that matters most.
        if let flash = engine.saveFlash() {
            try? flash.write(to: paths.t18FlashPath, options: .atomic)
        }
        if let state = engine.saveState(),
           (try? state.write(to: paths.t18StatePath, options: .atomic)) != nil {
            let now = Date()
            let caughtUpTo = liveStartCaughtUpTo?.addingTimeInterval(engine.liveSecondsAdvanced) ?? now
            paths.lastSavedAt = min(caughtUpTo, now.addingTimeInterval(engine.fastForwardExtraSeconds))
        }
        engine.release()
        paths.makeBackup(reason: .automatic)
        self.engine = nil
        if holdsGate {
            holdsGate = false
            EngineGate.gate(for: selectedDevice).release()
        }
    }

    // MARK: - Export / import

    func prepareExportURL() -> URL? {
        let wasRunning = engine != nil
        if wasRunning { stopEngine() }
        defer { if wasRunning { startEngine() } }
        let paths = SavePaths(device: selectedDevice)
        guard let flash = try? Data(contentsOf: paths.t18FlashPath) else { return nil }
        let state = try? Data(contentsOf: paths.t18StatePath)
        let file = T18SaveFile.encode(deviceID: selectedDevice.id, flash: flash, state: state)

        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("SaveExport", isDirectory: true)
        try? fm.removeItem(at: folder)
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
        let name = "\(selectedDevice.title) \(stamp)".replacingOccurrences(of: "/", with: "-")
        let url = folder.appendingPathComponent(name).appendingPathExtension(T18SaveFile.fileExtension)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try file.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    func importSave(from url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let save = try T18SaveFile.decode(try Data(contentsOf: url))
        guard save.deviceID == selectedDevice.id else {
            let from = DeviceCatalog.find(name: save.deviceID)?.title ?? "another device"
            throw T18SaveFile.Failure("This save is from \(from), not \(selectedDevice.title).")
        }
        stopEngine()
        unpauseQuietly()
        defer { startEngine() }
        let paths = SavePaths(device: selectedDevice)
        try paths.ensureDirectoriesExist()
        paths.makeBackup(reason: .beforeImport)
        try save.flash.write(to: paths.t18FlashPath, options: .atomic)
        if let state = save.state {
            try state.write(to: paths.t18StatePath, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: paths.t18StatePath)
        }
        paths.markSyncedNow()
    }

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
        unpauseQuietly()
        startEngine()
    }

    /// Restart: like taking the toy's battery out. The game's flash save is
    /// kept and the session dropped, so it boots to CONTINUE / RESET ALL.
    /// Backed up first, so Backups can undo it.
    func restartTama() {
        stopEngine()
        let paths = SavePaths(device: selectedDevice)
        paths.makeBackup(reason: .beforeRestart)
        try? FileManager.default.removeItem(at: paths.t18StatePath)
        unpauseQuietly()
        startEngine(discardingGap: true)
    }

    private func unpauseQuietly() {
        guard isPaused else { return }
        isPaused = false
        DevicePauseState.setPaused(false, for: selectedDevice)
    }

    // MARK: - Widget, screenshot

    func publishWidgetFrame() {
        lastWidgetFrame = Date()
        guard hasShownFrame, let image = screenImage else { return }
        WidgetSharedState.publish(image: image, device: selectedDevice)
    }

    private func publishWidgetFrameIfDue() {
        if Date().timeIntervalSince(lastWidgetFrame) > TomomixViewModel.widgetFrameInterval { publishWidgetFrame() }
    }

    /// Same render as the color Tamas' screenshot button.
    func screenshot() -> CGImage? { renderLCDSnapshot(image: screenImage, side: 512) }

    func pressButton(_ button: InputController.Button) {
        engine?.input.press(button)
    }

    func releaseButton(_ button: InputController.Button) {
        engine?.input.release(button)
    }

    private func startEngine(discardingGap: Bool = false, syncClock: Bool = false) {
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
            let holdsGate = gate.acquire(timeout: 15)
            @Sendable func releaseGate() { if holdsGate { gate.release() } }
            guard !cancel.isCancelled else { releaseGate(); return }

            if discardingGap { paths.markSyncedNow() }

            var state = try? Data(contentsOf: paths.t18StatePath)
            var flash = try? Data(contentsOf: paths.t18FlashPath)
            var caughtUpTo = paths.lastSavedAt ?? Date()
            var madeProgress = false
            if let loaded = state {
                var current = loaded
                while !cancel.isCancelled {
                    let owed = Date().timeIntervalSince(caughtUpTo)
                    guard owed > 0.5 else { break }
                    let result = T18EmulatorEngine.catchUp(
                        romData: romData,
                        flashData: flash,
                        from: current,
                        backlogSeconds: owed,
                        wallClockBudget: Self.catchUpWallClockBudget,
                        shouldAbort: { cancel.isCancelled }
                    )
                    guard result.advancedSeconds > 0 else { break }
                    current = result.state
                    flash = result.flash
                    caughtUpTo = caughtUpTo.addingTimeInterval(result.advancedSeconds)
                    madeProgress = true
                }
                state = current
            }

            func persistProgress() {
                guard madeProgress, let state else { return }
                if let flash { try? flash.write(to: paths.t18FlashPath, options: .atomic) }
                if (try? state.write(to: paths.t18StatePath, options: .atomic)) != nil {
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
            let flashToLoad = flash
            let stateCaughtUpTo = caughtUpTo
            let didCatchUp = madeProgress
            await MainActor.run {
                guard self.startGeneration == generation else { releaseGate(); return }
                let newEngine = T18EmulatorEngine(onFrame: { [weak self] state in
                    self?.show(state)
                    self?.publishWidgetFrameIfDue()
                }, onCallDetected: {
                    NotificationScheduler.fireCallingNotification(device: device)
                })
                guard newEngine.start(
                    romData: romData, flashData: flashToLoad, stateData: stateToLoad,
                    setClockTo: syncClock ? Date() : nil
                ) else {
                    releaseGate()
                    self.errorMessage = "Couldn't start this Tama's emulator core."
                    self.isLoading = false
                    return
                }
                let stillBehind = Date().timeIntervalSince(stateCaughtUpTo) > 0.5
                self.liveStartCaughtUpTo = (stateToLoad == nil || (stillBehind && !didCatchUp)) ? Date() : stateCaughtUpTo
                self.holdsGate = holdsGate
                self.errorMessage = nil
                self.isLoading = false
                if let points = self.pointsAwaitingEngine {
                    newEngine.setPoints(points)
                    self.pointsAwaitingEngine = nil
                }
                self.engine = newEngine
            }
        }
    }
}

/// The one-file export format for a Meets/On save: the game's flash save
/// plus, optionally, the session. Layout (little-endian):
///   "TAMAT18S", version (1 byte), device id length (1 byte) + UTF-8 id,
///   flash length (4 bytes) + bytes, state length (4 bytes, 0 = none) + bytes.
enum T18SaveFile {
    static let fileExtension = "t18save"
    private static let magic = Array("TAMAT18S".utf8)
    private static let version: UInt8 = 1

    struct Contents {
        var deviceID: String
        var flash: Data
        var state: Data?
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func encode(deviceID: String, flash: Data, state: Data?) -> Data {
        var out = Data(magic)
        out.append(version)
        let id = Data(deviceID.utf8.prefix(255))
        out.append(UInt8(id.count))
        out.append(id)
        func appendLength(_ n: Int) {
            var v = UInt32(n).littleEndian
            out.append(Data(bytes: &v, count: 4))
        }
        appendLength(flash.count)
        out.append(flash)
        appendLength(state?.count ?? 0)
        if let state { out.append(state) }
        return out
    }

    static func decode(_ data: Data) throws -> Contents {
        let bytes = [UInt8](data)
        let notASave = Failure("This isn't a Tamagotchi Meets or On save file.")
        var i = 0
        func take(_ n: Int) throws -> ArraySlice<UInt8> {
            guard n >= 0, i + n <= bytes.count else { throw notASave }
            defer { i += n }
            return bytes[i..<(i + n)]
        }
        func length() throws -> Int {
            let b = try take(4)
            return b.reversed().reduce(0) { $0 << 8 | Int($1) }
        }
        guard Array(try take(magic.count)) == magic else { throw notASave }
        guard try take(1).first == version else {
            throw Failure("This save was made by a newer version of the app.")
        }
        let idLength = Int(try take(1).first!)
        guard let deviceID = String(bytes: try take(idLength), encoding: .utf8) else { throw notASave }
        let flash = Data(try take(try length()))
        guard !flash.isEmpty else { throw notASave }
        let stateLength = try length()
        let state = stateLength > 0 ? Data(try take(stateLength)) : nil
        return Contents(deviceID: deviceID, flash: flash, state: state)
    }
}

extension T18PlayViewModel: ScreenRecordable {
    var audioFormat: AVAudioFormat? { engine?.audioFormat }

    func installRecordingTap(format: AVAudioFormat, bufferSize: AVAudioFrameCount, block: @escaping AVAudioNodeTapBlock) {
        engine?.installRecordingTap(format: format, bufferSize: bufferSize, block: block)
    }

    func removeRecordingTap() {
        engine?.removeRecordingTap()
    }

    func recordingFrame(side: CGFloat) -> CGImage? {
        guard screenImage != nil else { return nil }
        if let cached = recordingFrameCache, cached.state == screenState { return cached.image }
        let image = renderLCDSnapshot(image: screenImage, side: side)
        if let image { recordingFrameCache = (screenState, image) }
        return image
    }
}
