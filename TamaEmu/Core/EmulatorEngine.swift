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

    /// How many seconds of real elapsed time catch-up has NOT yet applied
    /// to `emu_secs` — set once, right after `init()`'s catch-up pass, and
    /// unchanged for the rest of this engine's life (normal real-time play
    /// keeps `emu_secs` and wall-clock moving in lockstep, so it neither
    /// grows nor shrinks on its own). `save()` subtracts this from `Date()`
    /// when recording `lastSavedAt`, so a catch-up pass that couldn't
    /// finish (wall-clock budget, or a deliberately low catch-up cap)
    /// doesn't get forgotten — the shortfall carries into the next catch-up
    /// attempt instead of silently vanishing.
    private var catchUpBacklog: TimeInterval = 0

    /// Real seconds lost to a large (>250ms) frame overrun during live
    /// play — e.g. a genuine stall, not routine scheduling jitter — that
    /// `runLoop()` deliberately did NOT correct for in the moment (see its
    /// own comment for why). Written only from the emulator thread, read
    /// only from `save()` after `stop()` has joined that thread, so there's
    /// no concurrent access despite no lock guarding it.
    private var liveDriftBacklog: TimeInterval = 0

    private let callDetector = CallDetector()
    /// Set by whoever owns this engine to be told when the Tamagotchi
    /// starts calling for attention (M9c wires this to a local
    /// notification). May be called from the emulator thread or from
    /// init()'s catch-up pass — never assume a particular thread.
    var onCallDetected: (() -> Void)?

    /// Whether a call detected during init()'s catch-up pass should still
    /// invoke `onCallDetected`. BackgroundRefresh wants this (it's the only
    /// chance to notify the player *before* they open the app). The
    /// foreground launch path (PlayViewModel) does not: that catch-up pass
    /// runs because the player just opened the app, so by the time it
    /// could fire, they're already looking at the live screen — a
    /// notification at that point is pure noise, not a heads-up. A call
    /// detected live, during `runLoop()`, always notifies regardless of
    /// this flag — that's a real-time event, not a backlog replay.
    private let notifyOnCatchUpCalls: Bool

    private lazy var audioOutput = AudioOutput(
        toneProvider: { [weak self] in
            guard let self else { return (false, 0) }
            return (self.emu.pointee.tone_on != 0, self.emu.pointee.tone_freq)
        },
        settingsProvider: {
            (AppSettings.muted, Float(AppSettings.volume))
        }
    )

    /// `onCallDetected` must be supplied here, not assigned after — init()
    /// itself may run a catch-up pass that detects a call, and a handler
    /// attached only after init() returns would silently miss it.
    ///
    /// `catchUpWallClockBudget` runs synchronously inside this init(), on
    /// whatever thread constructs it — every real caller (PlayViewModel's
    /// startEngine(), BackgroundRefresh) now does that off the main
    /// thread specifically so this can take however long it actually
    /// needs without the UI appearing to hang. The small 1.0s default
    /// here only matters if some future caller constructs this directly
    /// on a thread that *does* need to stay responsive. Any gap too large
    /// to fully catch up in the given budget isn't lost either way (see
    /// catchUpBacklog) — it's picked up gradually over the next attempt.
    init(
        device: TamaDevice,
        savePaths: SavePaths,
        catchUpWallClockBudget: TimeInterval = 1.0,
        isPaused: Bool = false,
        notifyOnCatchUpCalls: Bool = true,
        onCallDetected: (() -> Void)? = nil
    ) throws {
        guard let profile = device_find(device.id) else {
            throw EmulatorError.unknownDevice(device.id)
        }
        self.device = device
        self.savePaths = savePaths
        self.frameStore = FrameStore(width: Int(PANEL_W), height: Int(PANEL_H))
        self.notifyOnCatchUpCalls = notifyOnCatchUpCalls
        self.onCallDetected = onCallDetected

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
            // A paused Tama's clock is frozen on purpose — PlayViewModel
            // keeps lastSavedAt pinned to "now" on every save while paused
            // (see stopEngine()), so there's never a backlog to apply here;
            // skipping the call outright is just the explicit version of
            // that same intent, in case something else ever sets a stale
            // lastSavedAt while paused.
            if !isPaused, let lastSavedAt = savePaths.lastSavedAt {
                catchUp(seconds: Date().timeIntervalSince(lastSavedAt), wallClockBudget: catchUpWallClockBudget)
            }
        } else {
            cpu_reset(e)
        }
        applySettings()
    }

    /// Pushes the live-adjustable settings (speed, stay-awake) onto the
    /// running core. Safe to call any time — these are plain struct fields
    /// the core reads every tick, not something requiring a restart, and
    /// Android's own equivalent settings take effect immediately too.
    func applySettings() {
        emu.pointee.rtc_mult = Int32(AppSettings.speedMultiplier(for: device))
        emu.pointee.stay_awake = AppSettings.stayAwake(for: device)
        // Guarded on `thread != nil`, not called unconditionally: this is
        // also called from init() for headless engines (BackgroundRefresh)
        // that never call start() — touching `audioOutput` there would
        // force-construct an AVAudioEngine that's never otherwise needed,
        // against the whole point of that path staying lightweight.
        if thread != nil {
            audioOutput.applySessionCategory()
        }
    }

    /// Soft reset: same ROM/flash/RAM, just CPU state and the program
    /// counter reset to the firmware's reset vector — "battery out and
    /// in", not a wipe. Only safe to call while the dedicated thread is
    /// stopped (same precondition as save()).
    func resetCPU() {
        cpu_reset(emu)
    }

    /// Jumps the firmware's own RTC registers straight to a wall-clock
    /// time. This is a JUMP, unlike catch-up (which steps every emulated
    /// second) — matches the Android port's own setClock exactly, writing
    /// through periph_write8 (not a raw ioram poke) so any side effects
    /// periph.c attaches to these addresses still run; in practice none do
    /// for the RTC seconds/minutes/hours registers, confirmed by reading
    /// periph_write8's own dispatch.
    @discardableResult
    func setClock(hour: Int, minute: Int, second: Int) -> Bool {
        guard (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else {
            return false
        }
        func bcd(_ v: Int) -> UInt8 { UInt8((v / 10) << 4 | (v % 10)) }
        periph_write8(emu, 0x301910, bcd(second))
        periph_write8(emu, 0x301914, bcd(minute))
        periph_write8(emu, 0x301918, bcd(hour))
        return true
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
            savePaths.lastSavedAt = Date().addingTimeInterval(-(catchUpBacklog + liveDriftBacklog))
            // Folded into lastSavedAt above — zero it so a second save()
            // on this same (still-running) engine instance, e.g. from
            // restartTama()/prepareExportURL(), doesn't subtract it again.
            liveDriftBacklog = 0
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

    /// Renders the current frame synchronously, for one-off uses (e.g.
    /// publishing to the widget right after init()'s catch-up pass, before
    /// the dedicated thread has rendered anything into FrameStore yet).
    /// Safe to call before start() (nothing else is touching `emu` yet)
    /// or after stop() has joined (same reasoning as save()).
    func renderCurrentFrame() -> [UInt32] {
        var pixels = [UInt32](repeating: 0xFF000000, count: Int(PANEL_W) * Int(PANEL_H))
        var w: Int32 = 0
        var h: Int32 = 0
        pixels.withUnsafeMutableBufferPointer { buf in
            lcd_render(emu, buf.baseAddress, &w, &h)
        }
        return pixels
    }

    /// Call once right after every `cpu_step`, from any loop (normal
    /// real-time or catch-up) — the melody edge that signals a call can
    /// happen at any point in either. `duringCatchUp` controls whether a
    /// detection here is allowed to notify — see `notifyOnCatchUpCalls`.
    private func checkCallDetection(duringCatchUp: Bool = false) {
        let detected = callDetector.checkToneEdge(
            toneOn: emu.pointee.tone_on != 0,
            toneFreq: emu.pointee.tone_freq,
            emuSecs: emu.pointee.emu_secs
        )
        if detected && (!duringCatchUp || notifyOnCatchUpCalls) {
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
        let requestedSeconds = max(seconds, 0)
        let capSeconds = AppSettings.catchUpCapHours * 3600
        let cappedSeconds = min(requestedSeconds, capSeconds)
        guard cappedSeconds > 0 else {
            // Nothing attempted this pass — e.g. catch-up is turned off, or
            // there's genuinely nothing to catch up. Whatever gap exists
            // stays owed in full, rather than being reset to zero.
            catchUpBacklog = requestedSeconds
            return
        }
        let startSecs = emu.pointee.emu_secs
        let targetSecs = startSecs + cappedSeconds
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(wallClockBudget * 1_000_000_000)
        var stepsSinceDeadlineCheck = 0
        while emu.pointee.emu_secs < targetSecs && !emu.pointee.stopped {
            let before = emu.pointee.cycles
            cpu_step(emu)
            let delta = UInt32(truncatingIfNeeded: emu.pointee.cycles &- before)
            periph_tick(emu, delta)
            checkCallDetection(duringCatchUp: true)
            stepsSinceDeadlineCheck += 1
            if stepsSinceDeadlineCheck >= 4096 {
                stepsSinceDeadlineCheck = 0
                if DispatchTime.now().uptimeNanoseconds >= deadline { break }
            }
        }
        let actuallyAdvanced = emu.pointee.emu_secs - startSecs
        catchUpBacklog = max(0, requestedSeconds - actuallyAdvanced)

        // A long, unpaced catch-up can run millions of steps in one go —
        // far more than normal real-time play ever does between saves —
        // so a rare core edge case (wild jump, bad decode) is far more
        // likely to actually fire here. `stop()` sets `emu.pointee.stopped`
        // permanently (cleared only by cpu_reset), and runLoop() gates its
        // own stepping on that same flag, so leaving it set would freeze
        // the engine — and whatever was on screen at the moment it died —
        // forever. Recovering here, the same way a corrupt/missing save
        // already falls back to cpu_reset() in init(), costs the Tama's
        // exact position but is far better than a permanently dead screen.
        if emu.pointee.stopped {
            cpu_reset(emu)
        }
    }

    private func runLoop() {
        let frameNanos: UInt64 = 1_000_000_000 / 60
        var nextDeadlineNanos = DispatchTime.now().uptimeNanoseconds + frameNanos
        var pixels = [UInt32](repeating: 0xFF000000, count: Int(PANEL_W) * Int(PANEL_H))
        var w: Int32 = 0
        var h: Int32 = 0

        // Accumulated across iterations, matching the Android port's own
        // `t_ziel` — NOT recomputed fresh from emu_secs each time. Its own
        // comment explains why that distinction matters: if a single frame
        // overshoots (see the cycle ceiling below), recomputing from the
        // new, already-overshot emu_secs would just keep that excess
        // forever; accumulating means the next frame's target is
        // unaffected by the overshoot, so the loop simply skips stepping
        // until real time catches back up to where emu_secs already is —
        // paying the excess back instead of banking it.
        var targetSecs = emu.pointee.emu_secs

        while true {
            stopLock.lock(); let stop = shouldStop; stopLock.unlock()
            if stop { break }

            targetSecs += 1.0 / 60.0
            // Mirrors the Android port's own "notbremse" (emergency brake).
            // The firmware's clock isn't constant — e.g. entering its
            // low-power sleep mode mid-frame drops OSC3's ~20MHz down to
            // OSC1's 32.768kHz watch crystal. rtc_tick() computes
            // emu_secs += cycles/hz, so the moment hz collapses, every
            // further cycle in that same frame suddenly represents a much
            // bigger slice of emu_secs — without a ceiling, a handful of
            // cycles right at that transition can masquerade as many
            // real seconds of simulated time. That hits idle animation
            // specifically hard, since sleep/wake cycling is exactly what
            // happens while idling. Capping cycles-per-frame at roughly
            // what full speed would need, plus slack for legitimately
            // catching up a small lag, bounds how bad one transition can
            // be — identical in spirit to upstream's own fix for this.
            let mclk = emu.pointee.cmu.mclk_hz > 0 ? emu.pointee.cmu.mclk_hz : emu.pointee.dev.osc3_hz
            let cycleCeiling = emu.pointee.cycles &+ UInt64(mclk / 60.0) &+ 100_000
            while emu.pointee.emu_secs < targetSecs && emu.pointee.cycles < cycleCeiling && !emu.pointee.stopped {
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
                // Overran this frame's budget. A small overrun is normal
                // scheduling jitter and self-corrects for free — the next
                // iteration just starts immediately with no sleep, same as
                // Android tolerates below its own tuned 250ms threshold.
                // Only count anything bigger as real drift (Doze-equivalent
                // suspension, thermal throttling, a genuine stall) for the
                // next session-boundary catch-up pass to absorb instead of
                // correcting it live.
                let overrun = Double(nowNanos - nextDeadlineNanos) / 1_000_000_000
                if overrun > 0.25 {
                    liveDriftBacklog += overrun
                }
                nextDeadlineNanos = nowNanos
            }
            nextDeadlineNanos += frameNanos
        }
        stoppedSemaphore.signal()
    }
}
