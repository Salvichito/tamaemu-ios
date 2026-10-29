import CTama
import Foundation
import TamaCore

enum EmulatorError: Error, LocalizedError {
    case unknownDevice(String)
    case romTooLarge(got: Int, max: Int)

    var errorDescription: String? {
        switch self {
        case .unknownDevice(let id):
            return "Unknown device '\(id)'."
        case .romTooLarge(let got, let max):
            return "Firmware is \(got) bytes, larger than this device's \(max)-byte ROM."
        }
    }
}

/// Identifies this core/port's save format to state_load/state_save. Bump
/// this if the Emu struct's meaning changes in a way its own size check
/// wouldn't catch.
private let buildID = "tamaemu-ios-mvp-1"

/// Owns one running Tamagotchi core: a dedicated 60Hz thread stepping the
/// CPU, a thread-safe framebuffer handoff, and save/flash persistence.
final class EmulatorEngine {
    let device: TamaDevice
    let input = InputController()
    private let savePaths: SavePaths
    private let emu: UnsafeMutablePointer<Emu>
    private let frameStore: FrameStore

    private var thread: Thread?
    private let stopLock = NSLock()
    private var shouldStop = false
    private let stoppedSemaphore = DispatchSemaphore(value: 0)

    private let callDetector = CallDetector()
    /// Set by whoever owns this engine to be told when the Tamagotchi
    /// starts calling for attention (M9c wires this to a local
    /// notification). May be called from the emulator thread or from
    /// init()'s catch-up pass — never assume a particular thread.
    var onCallDetected: (() -> Void)?

    private lazy var audioOutput = AudioOutput { [weak self] in
        guard let self else { return (false, 0) }
        return (self.emu.pointee.tone_on != 0, self.emu.pointee.tone_freq)
    }

    init(device: TamaDevice, savePaths: SavePaths) throws {
        guard let profile = device_find(device.id) else {
            throw EmulatorError.unknownDevice(device.id)
        }
        self.device = device
        self.savePaths = savePaths
        self.frameStore = FrameStore(width: Int(PANEL_W), height: Int(PANEL_H))

        // Don't assume the caller already created these — state_save/the
        // flash-image write would otherwise fail silently (missing
        // directory) the first time a device is driven without going
        // through the import flow.
        try? savePaths.ensureDirectoriesExist()

        let e = UnsafeMutablePointer<Emu>.allocate(capacity: 1)
        memset(e, 0, MemoryLayout<Emu>.stride)
        e.pointee.dev = profile.pointee

        let romSize = Int(profile.pointee.rom_size)
        let romBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: romSize)
        romBuffer.initialize(repeating: 0xFF, count: romSize)

        // The live flash image (if any) carries whatever the firmware has
        // saved into it; the pristine import is only the fallback.
        let sourceURL = FileManager.default.fileExists(atPath: savePaths.liveFlashPath.path)
            ? savePaths.liveFlashPath
            : savePaths.importedROMPath
        let romData = try Data(contentsOf: sourceURL)
        guard romData.count <= romSize else {
            romBuffer.deallocate()
            e.deallocate()
            throw EmulatorError.romTooLarge(got: romData.count, max: romSize)
        }
        romData.withUnsafeBytes { raw in
            if let base = raw.bindMemory(to: UInt8.self).baseAddress {
                romBuffer.update(from: base, count: romData.count)
            }
        }
        e.pointee.rom = romBuffer
        self.emu = e

        var why = [CChar](repeating: 0, count: 256)
        let result = savePaths.stateBasePath.path.withCString { base in
            buildID.withCString { bid in
                state_load(e, base, bid, &why, why.count)
            }
        }
        if result == STATE_LOADED {
            if let lastSavedAt = savePaths.lastSavedAt {
                catchUp(seconds: Date().timeIntervalSince(lastSavedAt))
            }
        } else {
            cpu_reset(e)
        }
    }

    deinit {
        if let rom = emu.pointee.rom {
            rom.deallocate()
        }
        emu.deallocate()
    }

    func start() {
        guard thread == nil else { return }
        stopLock.lock(); shouldStop = false; stopLock.unlock()
        let t = Thread { [weak self] in self?.runLoop() }
        t.name = "EmulatorEngine"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        audioOutput.start()
    }

    /// Signals the emulator thread to stop and blocks until it actually has
    /// — `save()` reads the whole Emu struct, so it must never run while
    /// the thread could still be concurrently stepping it. The 1s timeout
    /// is only a safety net against a true hang; the thread normally exits
    /// within one frame.
    func stop() {
        guard thread != nil else { return }
        stopLock.lock(); shouldStop = true; stopLock.unlock()
        _ = stoppedSemaphore.wait(timeout: .now() + 1.0)
        thread = nil
        audioOutput.stop()
    }

    /// Persists the full snapshot and, if the firmware has written to its
    /// flash, the live flash image too. Call only after stop() has
    /// returned — never while the emulator thread might still be running.
    func save() {
        var why = [CChar](repeating: 0, count: 256)
        let saved = savePaths.stateBasePath.path.withCString { base in
            buildID.withCString { bid in
                state_save(emu, base, bid, &why, why.count)
            }
        }
        if saved != 0 {
            savePaths.lastSavedAt = Date()
        }
        if emu.pointee.flash_dirty, let rom = emu.pointee.rom {
            let romSize = Int(emu.pointee.dev.rom_size)
            let data = Data(bytes: rom, count: romSize)
            try? data.write(to: savePaths.liveFlashPath, options: .atomic)
            emu.pointee.flash_dirty = false
        }
    }

    func latestFrame() -> [UInt32]? {
        frameStore.readIfChanged()
    }

    /// Call once right after every `cpu_step`, from any loop (normal
    /// real-time or catch-up) — the melody edge that signals a call can
    /// happen at any point in either.
    private func checkCallDetection() {
        let detected = callDetector.checkToneEdge(
            toneOn: emu.pointee.tone_on != 0,
            toneFreq: emu.pointee.tone_freq,
            emuSecs: emu.pointee.emu_secs
        )
        if detected {
            onCallDetected?()
        }
    }

    /// Fast-forwards simulated time with no real-time pacing, to catch up
    /// on real time that passed while nothing was running (app closed,
    /// between background wake-ups) — mirrors the Android port's own
    /// catch-up behavior: capped at 24h of simulated time, same as theirs.
    /// Also capped on wall-clock compute time (checked periodically, not
    /// every step, since that would dominate the cost of catching up
    /// millions of instructions) since BGAppRefreshTask has a strict
    /// execution budget — stopping early here just means less of the gap
    /// got caught up, not a crash or lost progress.
    private func catchUp(seconds: TimeInterval, wallClockBudget: TimeInterval = 5.0) {
        let cappedSeconds = min(max(seconds, 0), 24 * 3600)
        guard cappedSeconds > 0 else { return }
        let targetSecs = emu.pointee.emu_secs + cappedSeconds
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(wallClockBudget * 1_000_000_000)
        var stepsSinceDeadlineCheck = 0
        while emu.pointee.emu_secs < targetSecs && !emu.pointee.stopped {
            let before = emu.pointee.cycles
            cpu_step(emu)
            let delta = UInt32(truncatingIfNeeded: emu.pointee.cycles &- before)
            periph_tick(emu, delta)
            checkCallDetection()
            stepsSinceDeadlineCheck += 1
            if stepsSinceDeadlineCheck >= 4096 {
                stepsSinceDeadlineCheck = 0
                if DispatchTime.now().uptimeNanoseconds >= deadline { break }
            }
        }
    }

    private func runLoop() {
        let frameNanos: UInt64 = 1_000_000_000 / 60
        var nextDeadlineNanos = DispatchTime.now().uptimeNanoseconds + frameNanos
        var pixels = [UInt32](repeating: 0xFF000000, count: Int(PANEL_W) * Int(PANEL_H))
        var w: Int32 = 0
        var h: Int32 = 0

        while true {
            stopLock.lock(); let stop = shouldStop; stopLock.unlock()
            if stop { break }

            let targetSecs = emu.pointee.emu_secs + (1.0 / 60.0)
            while emu.pointee.emu_secs < targetSecs && !emu.pointee.stopped {
                let before = emu.pointee.cycles
                cpu_step(emu)
                let delta = UInt32(truncatingIfNeeded: emu.pointee.cycles &- before)
                periph_tick(emu, delta)
                checkCallDetection()
            }
            periph_buttons(emu, input.currentMask())

            pixels.withUnsafeMutableBufferPointer { buf in
                lcd_render(emu, buf.baseAddress, &w, &h)
            }
            frameStore.write(pixels)

            let nowNanos = DispatchTime.now().uptimeNanoseconds
            if nextDeadlineNanos > nowNanos {
                Thread.sleep(forTimeInterval: Double(nextDeadlineNanos - nowNanos) / 1_000_000_000)
            } else {
                nextDeadlineNanos = nowNanos
            }
            nextDeadlineNanos += frameNanos
        }
        stoppedSemaphore.signal()
    }
}
