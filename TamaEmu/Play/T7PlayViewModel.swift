import AVFoundation
import CoreGraphics
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
    /// Mirrors DevicePauseState, same as V1PlayViewModel's own: a paused
    /// Tama has no live engine and is skipped by catch-up, so no time
    /// passes for it until it's unpaused.
    private(set) var isPaused: Bool
    /// True while the screen is held down. Never persisted.
    private(set) var isFastForwarding = false
    /// Whether `screenState` has ever been given a real frame -- see
    /// V1PlayViewModel's own.
    private var hasShownFrame = false

    /// When the widget's picture was last refreshed (see publishWidgetFrame).
    @ObservationIgnored private var lastWidgetFrame = Date.distantPast
    private var engine: T7EmulatorEngine?
    /// Who this Tama is connected to (NearbyLinkSession), for the badge on
    /// its page -- nil when not connected.
    private(set) var linkPeerName: String?
    /// Kept here, not only on the engine: the engine is rebuilt every time
    /// the page comes back, and the connection should survive that.
    private var linkPort: LinkPort?
    /// The last video frame drawn, reused while the screen hasn't changed.
    private var recordingFrameCache: (state: T7ScreenState, image: CGImage)?
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

    /// Gotchi Figures (Tama-Go only): the imported ones, and which one is
    /// plugged in (nil = none). Stays plugged in across app launches.
    private(set) var figures: [TamaFigure] = []
    private(set) var pluggedFigureID: String?

    init(device: TamaDevice) {
        selectedDevice = device
        isPaused = DevicePauseState.isPaused(device)
        if device.id == "tamago" {
            figures = FigureLibrary.all()
            pluggedFigureID = FigureLibrary.pluggedID(for: device)
        }
    }

    var supportsFigures: Bool { selectedDevice.id == "tamago" }
    var pluggedFigure: TamaFigure? { figures.first { $0.id == pluggedFigureID } }

    /// Plugs a figure in (nil unplugs). A running Tama sees it right away.
    func plugIn(_ figure: TamaFigure?) {
        guard figure?.id != pluggedFigureID else { return }
        pluggedFigureID = figure?.id
        FigureLibrary.setPluggedID(figure?.id, for: selectedDevice)
        engine?.setFigure(figure.flatMap { FigureLibrary.data(for: $0) })
    }

    @discardableResult
    func importFigure(from url: URL) throws -> TamaFigure {
        let figure = try FigureLibrary.importFile(at: url)
        figures = FigureLibrary.all()
        // Re-importing the plugged one: the Tama gets the new copy.
        if figure.id == pluggedFigureID { engine?.setFigure(FigureLibrary.data(for: figure)) }
        return figure
    }

    func deleteFigure(_ figure: TamaFigure) {
        if figure.id == pluggedFigureID { plugIn(nil) }
        FigureLibrary.delete(figure)
        figures = FigureLibrary.all()
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

    /// Tapping the screen, or Pause/Resume in the ⋯ menu -- see
    /// V1PlayViewModel.togglePause().
    func togglePause() {
        isPaused.toggle()
        DevicePauseState.setPaused(isPaused, for: selectedDevice)
        if isPaused {
            stopEngine()
        } else {
            // Nothing is owed for the time spent paused, and the clock is
            // left where it was: players keep some Tamas on a deliberate
            // offset. "Sync Clock to Now" (⋯) is the manual catch-up.
            startEngine(discardingGap: true)
        }
    }

    /// ⋯ "Sync Clock to Now": the clock jumps to the real time and nothing
    /// ages in between: a quick stop and restart with the clock set on the
    /// way back in. Never automatic (not on unpause).
    func syncClockToNow() {
        guard engine != nil, !isPaused else { return }
        stopEngine()
        startEngine(discardingGap: true, syncClock: true)
    }

    /// Holding the screen down. A no-op without a running engine.
    /// Plugs this Tama-Go's infrared into a connection to another one, or
    /// unplugs it (nil). Same as PlayViewModel.setLink.
    func setLink(port: LinkPort?, peerName: String?) {
        linkPort = port
        linkPeerName = port == nil ? nil : peerName
        engine?.setLinkPort(port)
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

    /// See V1PlayViewModel.showSavedScreenIfNeeded().
    private func showSavedScreenIfNeeded() {
        guard !hasShownFrame else { return }
        hasShownFrame = true
        let paths = SavePaths(device: selectedDevice)
        let gate = EngineGate.gate(for: selectedDevice)
        Task.detached(priority: .userInitiated) { [weak self] in
            guard gate.acquire(timeout: 15) else { return }
            var screen: T7ScreenState?
            if let romData = try? Data(contentsOf: paths.importedROMPath),
               let state = try? Data(contentsOf: paths.t7StatePath) {
                let eeprom = try? Data(contentsOf: paths.t7EepromPath)
                screen = T7EmulatorEngine.peekScreen(romData: romData, eepromData: eeprom, state: state)
            }
            gate.release()
            guard let screen, let self else { return }
            await MainActor.run {
                guard self.isPaused, self.engine == nil else { return }
                self.screenState = screen
                // A paused Tama's widget shows this frozen screen too.
                self.publishWidgetFrame()
            }
        }
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
        isFastForwarding = false
        guard let engine else { return }
        engine.stop()
        publishWidgetFrame()
        let paths = SavePaths(device: selectedDevice)
        try? paths.ensureDirectoriesExist()
        if let state = engine.saveState(),
           (try? state.write(to: paths.t7StatePath, options: .atomic)) != nil {
            let now = Date()
            let caughtUpTo = liveStartCaughtUpTo?.addingTimeInterval(engine.liveSecondsAdvanced) ?? now
            // Fast-forwarding put the Tama's clock ahead of real time by
            // that much, so the save counts as caught up that far into the
            // future and the next time away is shortened by it (same as
            // V1PlayViewModel). Never further than that: a live loop
            // can't otherwise get ahead of real time.
            paths.lastSavedAt = min(caughtUpTo, now.addingTimeInterval(engine.fastForwardExtraSeconds))
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

    // MARK: - Export / import

    /// A copy of this Tama's save as one file, for the system's "save to
    /// Files" sheet (never the live files: that sheet moves what it's
    /// given, see PlayViewModel.prepareExportURL). Stops the engine first
    /// so the export is current to this moment, then starts it again.
    func prepareExportURL() -> URL? {
        let wasRunning = engine != nil
        if wasRunning { stopEngine() }
        defer { if wasRunning { startEngine() } }
        let paths = SavePaths(device: selectedDevice)
        guard let eeprom = try? Data(contentsOf: paths.t7EepromPath) else { return nil }
        let state = try? Data(contentsOf: paths.t7StatePath)
        let file = T7SaveFile.encode(deviceID: selectedDevice.id, eeprom: eeprom, state: state)

        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("SaveExport", isDirectory: true)
        try? fm.removeItem(at: folder)
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
        let name = "\(selectedDevice.title) \(stamp)".replacingOccurrences(of: "/", with: "-")
        let url = folder.appendingPathComponent(name).appendingPathExtension(T7SaveFile.fileExtension)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try file.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Replaces this Tama's save with an exported one. The current save is
    /// backed up first, so an import can be undone from Backups. The Tama
    /// resumes exactly where the file left it, with no time owed (same as
    /// restoring a backup).
    func importSave(from url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        // Read and check the whole file before touching anything.
        let save = try T7SaveFile.decode(try Data(contentsOf: url))
        guard save.deviceID == selectedDevice.id else {
            let from = DeviceCatalog.find(name: save.deviceID)?.title ?? "another device"
            throw T7SaveFile.Failure("This save is from \(from), not \(selectedDevice.title).")
        }
        // Stopped before writing: stopping saves, and that save would
        // otherwise land on top of the imported files.
        stopEngine()
        unpauseQuietly()
        defer { startEngine() }
        let paths = SavePaths(device: selectedDevice)
        try paths.ensureDirectoriesExist()
        paths.makeBackup(reason: .beforeImport)
        try save.eeprom.write(to: paths.t7EepromPath, options: .atomic)
        if let state = save.state {
            try state.write(to: paths.t7StatePath, options: .atomic)
        } else {
            // A game save on its own: boots fresh from it, like a real toy
            // after a battery change.
            try? FileManager.default.removeItem(at: paths.t7StatePath)
        }
        paths.markSyncedNow()
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
        // Same as V1PlayViewModel: restoring implies playing it.
        unpauseQuietly()
        startEngine()
    }

    /// Restart: like the toy's reset button. The game save (EEPROM) is
    /// kept; the CPU/RAM snapshot is dropped so it boots fresh from that
    /// save -- the same thing importing a save without a snapshot does.
    /// What's there is backed up first, so Backups can undo this.
    func restartTama() {
        stopEngine()
        let paths = SavePaths(device: selectedDevice)
        paths.makeBackup(reason: .beforeRestart)
        try? FileManager.default.removeItem(at: paths.t7StatePath)
        unpauseQuietly()
        startEngine(discardingGap: true)
    }

    private func unpauseQuietly() {
        guard isPaused else { return }
        isPaused = false
        DevicePauseState.setPaused(false, for: selectedDevice)
    }

    var isFriends: Bool { selectedDevice.id == "tamagotchi-friends" }

    // MARK: - Widget

    /// Hands the home-screen widget this Tama's screen as it looks right
    /// now: the same picture as a screenshot, at a smaller size. Called
    /// when the page stops, and every couple of minutes while it plays
    /// (same pace as Tomomix's).
    func publishWidgetFrame() {
        lastWidgetFrame = Date()
        guard hasShownFrame, let image = widgetImage() else { return }
        WidgetSharedState.publish(image: image, device: selectedDevice)
    }

    private func widgetImage() -> CGImage? {
        renderT7Snapshot(state: screenState, isFriends: isFriends, scale: 2)
    }

    private func publishWidgetFrameIfDue() {
        if Date().timeIntervalSince(lastWidgetFrame) > TomomixViewModel.widgetFrameInterval { publishWidgetFrame() }
    }

    // MARK: - Screenshot / video

    /// The screen as a picture, at the size it's drawn in the gallery.
    func screenshot() -> CGImage? {
        renderT7Snapshot(state: screenState, isFriends: isFriends)
    }

    /// Tap-an-icon shortcut; see T7EmulatorEngine.openMenuIcon.
    func openMenuIcon(light: Int) {
        engine?.openMenuIcon(light: light)
    }

    func pressButton(_ button: InputController.Button) {
        engine?.input.press(button)
    }

    func releaseButton(_ button: InputController.Button) {
        engine?.input.release(button)
    }

    /// `discardingGap` is for unpausing: the time spent paused is not
    /// owed (see V1PlayViewModel.startEngine(discardingGap:)).
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

        let figureData = FigureLibrary.pluggedFigureData(for: device)

        Task.detached(priority: .userInitiated) { [weak self] in
            // Same shape as V1PlayViewModel.startEngine() -- see its
            // comments for why each step is where it is.
            let holdsGate = gate.acquire(timeout: 15)
            @Sendable func releaseGate() { if holdsGate { gate.release() } }
            guard !cancel.isCancelled else { releaseGate(); return }

            // Inside the gate, same reason as V1PlayViewModel's.
            if discardingGap { paths.markSyncedNow() }

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
                        figure: figureData,
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
                    self?.hasShownFrame = true
                    self?.publishWidgetFrameIfDue()
                }, onCallDetected: {
                    NotificationScheduler.fireCallingNotification(device: device)
                })
                guard newEngine.start(
                    romData: romData, eepromData: eepromToLoad, stateData: stateToLoad,
                    figure: figureData, setClockTo: syncClock ? Date() : nil
                ) else {
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
                newEngine.setLinkPort(self.linkPort)
                self.engine = newEngine
            }
        }
    }
}

/// The one-file export format for a Tama-Go/Tamagotchi Friends save: the
/// emulated EEPROM (the game save itself) plus, optionally, the CPU/RAM
/// snapshot that resumes play mid-moment. Layout (little-endian):
///   "TAMAT7SV", version (1 byte), device id length (1 byte) + UTF-8 id,
///   EEPROM length (4 bytes) + bytes, state length (4 bytes, 0 = none) + bytes.
enum T7SaveFile {
    static let fileExtension = "t7save"
    private static let magic = Array("TAMAT7SV".utf8)
    private static let version: UInt8 = 1

    struct Contents {
        var deviceID: String
        var eeprom: Data
        var state: Data?
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func encode(deviceID: String, eeprom: Data, state: Data?) -> Data {
        var out = Data(magic)
        out.append(version)
        let id = Data(deviceID.utf8.prefix(255))
        out.append(UInt8(id.count))
        out.append(id)
        func appendLength(_ n: Int) {
            var v = UInt32(n).littleEndian
            out.append(Data(bytes: &v, count: 4))
        }
        appendLength(eeprom.count)
        out.append(eeprom)
        appendLength(state?.count ?? 0)
        if let state { out.append(state) }
        return out
    }

    static func decode(_ data: Data) throws -> Contents {
        let bytes = [UInt8](data)
        let notASave = Failure("This isn't a Tama-Go or Tamagotchi Friends save file.")
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
        let eeprom = Data(try take(try length()))
        guard !eeprom.isEmpty else { throw notASave }
        let stateLength = try length()
        let state = stateLength > 0 ? Data(try take(stateLength)) : nil
        return Contents(deviceID: deviceID, eeprom: eeprom, state: state)
    }
}

extension T7PlayViewModel: ScreenRecordable {
    var audioFormat: AVAudioFormat? { engine?.audioFormat }

    func installRecordingTap(format: AVAudioFormat, bufferSize: AVAudioFrameCount, block: @escaping AVAudioNodeTapBlock) {
        engine?.installRecordingTap(format: format, bufferSize: bufferSize, block: block)
    }

    func removeRecordingTap() {
        engine?.removeRecordingTap()
    }

    func recordingFrame(side: CGFloat) -> CGImage? {
        if let cached = recordingFrameCache, cached.state == screenState { return cached.image }
        guard let image = screenshot() else { return nil }
        recordingFrameCache = (screenState, image)
        return image
    }
}

// MARK: - Gotchi Figures

/// A Tama-Go figure the user imported: their own dump of a figure's flash
/// chip (nothing is bundled). Files live in Application Support, shared
/// by every Tama-Go.
struct TamaFigure: Identifiable, Hashable {
    let id: String // file name without extension
    let name: String
    let isFullDump: Bool
    let url: URL
}

enum FigureLibrary {
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TamaEmu/figures", isDirectory: true)
    }

    /// A single-figure dump is ~340 KB; a full dump with the figure's own
    /// extras is 4 MB.
    private static let fullDumpThreshold = 1024 * 1024
    private static let maxSize = 16 * 1024 * 1024

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func all() -> [TamaFigure] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.filter { $0.pathExtension == "bin" }.map { url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let id = url.deletingPathExtension().lastPathComponent
            let full = size > fullDumpThreshold
            return TamaFigure(id: id, name: displayName(id: id, full: full), isFullDump: full, url: url)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func data(for figure: TamaFigure) -> Data? {
        try? Data(contentsOf: figure.url)
    }

    /// Checks the file is a figure dump (the game looks for AA 55 at
    /// byte 1, as the real Tama-Go does), then copies it in. Importing the
    /// same figure again replaces it.
    static func importFile(at url: URL) throws -> TamaFigure {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        var data = try Data(contentsOf: url)
        let notAFigure = Failure(message: "This isn't a Tama-Go figure dump.")
        guard data.count >= 3, data.count <= maxSize,
              data[data.startIndex + 1] == 0xAA, data[data.startIndex + 2] == 0x55 else { throw notAFigure }
        // Some dumping tools add a text trailer ("DONE") past the 4 MB chip.
        let chip = 4 * 1024 * 1024
        if data.count > chip, data.count <= chip + 16 { data = data.prefix(chip) }

        let full = data.count > fullDumpThreshold
        var base = cleanName(url.deletingPathExtension().lastPathComponent)
        if base.isEmpty { base = "Figure \(data.count > 0x13 ? Int(data[data.startIndex + 0x13]) : 0)" }
        let id = full ? "\(base) (full)" : base
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appendingPathComponent(id.replacingOccurrences(of: "/", with: "-")).appendingPathExtension("bin")
        try data.write(to: dest, options: .atomic)
        return TamaFigure(id: dest.deletingPathExtension().lastPathComponent, name: displayName(id: id, full: full), isFullDump: full, url: dest)
    }

    static func delete(_ figure: TamaFigure) {
        try? FileManager.default.removeItem(at: figure.url)
    }

    /// "(03)_Tama-Go_Mametchi" or "Tama-Go_Mametchi_Figure" -> "Mametchi".
    private static func cleanName(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "_", with: " ")
        s = s.replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)^tama-?go\s*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)\s*figure$"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func displayName(id: String, full: Bool) -> String { id }

    // Which figure each Tama-Go has plugged in.
    private static func key(_ device: TamaDevice) -> String { "figure.plugged.\(device.id)" }

    static func pluggedID(for device: TamaDevice) -> String? {
        UserDefaults.standard.string(forKey: key(device))
    }

    static func setPluggedID(_ id: String?, for device: TamaDevice) {
        UserDefaults.standard.set(id, forKey: key(device))
    }

    /// The plugged-in figure's dump, or nil (none, or its file is gone).
    static func pluggedFigureData(for device: TamaDevice) -> Data? {
        guard device.id == "tamago", let id = pluggedID(for: device) else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(id).appendingPathExtension("bin"))
    }
}
