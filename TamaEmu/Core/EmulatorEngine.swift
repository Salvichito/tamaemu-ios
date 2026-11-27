import AVFoundation
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

    /// Momentary speed-up while the player holds down on the Tama's
    /// screen — not persisted, not saved, leaves no trace once released.
    /// Guarded the same way stopLock guards shouldStop: set from the main
    /// thread (PlayViewModel), read every frame by runLoop() on the
    /// emulator thread.
    private let fastForwardLock = NSLock()
    private var fastForwardMultiplier: Double = 1.0

    /// 1.0 is normal speed; call with 1.0 again to return to it. A value
    /// above 1.0 advances game time faster than real time — the same
    /// mechanism catch-up already uses, just live and interactive instead
    /// of a one-shot pass. The piezo's own tone frequency is untouched, but
    /// notes play back faster, so sound speeds up right along with the
    /// animation — a deliberate fast-forward effect, not a bug.
    func setFastForward(_ multiplier: Double) {
        fastForwardLock.lock(); fastForwardMultiplier = multiplier; fastForwardLock.unlock()
    }

    private func currentFastForwardMultiplier() -> Double {
        fastForwardLock.lock(); defer { fastForwardLock.unlock() }
        return fastForwardMultiplier
    }

    // MARK: - Connecting to another Tama

    /// Set from the main thread (PlayViewModel), read once per frame by
    /// runLoop() on the emulator thread -- same pattern as fastForwardLock.
    private let linkLock = NSLock()
    private var requestedLinkPort: LinkPort?
    /// Emulator thread only (and stop()/deinit, once that thread is gone):
    /// the port the core's link is currently wired to.
    private var attachedLinkPort: LinkPort?

    /// Wires this Tama's infrared to `port` (nil unplugs it). Takes effect
    /// at the start of the next frame. Safe to call at any time, including
    /// before start().
    ///
    /// The core already has a complete model of the infrared hardware and
    /// a shared "bus" between Tamas (link.c); it is simply never given a
    /// partner unless this is called. Here the bus has two seats: seat 0
    /// is this Tama, seat 1 stands in for the remote one -- whatever this
    /// Tama sends lands in seat 1's inbox and is shipped out through the
    /// port, and whatever the port delivers is "sent" from seat 1 so it
    /// lands in this Tama's inbox. No sockets, no core changes.
    func setLinkPort(_ port: LinkPort?) {
        linkLock.lock(); requestedLinkPort = port; linkLock.unlock()
    }

    private func currentRequestedLinkPort() -> LinkPort? {
        linkLock.lock(); defer { linkLock.unlock() }
        return requestedLinkPort
    }

    /// Brings the core's link in step with what was last requested.
    private func syncLink(to port: LinkPort?) {
        guard port !== attachedLinkPort else { return }
        if let port {
            if emu.pointee.link == nil {
                let link = UnsafeMutablePointer<Link>.allocate(capacity: 1)
                memset(link, 0, MemoryLayout<Link>.size)
                emu.pointee.link = link
                emu.pointee.core_id = 0
            }
            // Also on a change of partner: nothing of the previous
            // conversation may leak into the new one.
            link_reset(emu.pointee.link)
            attachedLinkPort = port
        } else {
            detachLink()
        }
    }

    private func detachLink() {
        if let link = emu.pointee.link {
            emu.pointee.link = nil
            link.deallocate()
        }
        attachedLinkPort = nil
    }

    /// How long a Tama in the middle of a conversation will hold still for
    /// the other one before dropping it and carrying on alone. Long enough
    /// to ride out a bad wireless hiccup; a friend who paused or closed
    /// the app freezes this Tama for at most this long, once.
    private static let linkWaitLimitNanos: UInt64 = 500_000_000

    /// Before this frame's CPU stepping: take the other Tama's next frame
    /// and hand it to the core -- waiting for it if it hasn't arrived yet
    /// (see LinkPort for why the two step together). Returns false if a
    /// stop was requested while waiting.
    private func deliverLinkInput() -> Bool {
        guard let port = attachedLinkPort, let link = emu.pointee.link else { return true }
        let started = DispatchTime.now().uptimeNanoseconds
        while true {
            switch port.nextStep() {
            case .run(let data):
                for byte in data {
                    link_tx(link, 1, byte)
                }
                return true
            case .wait:
                stopLock.lock(); let stop = shouldStop; stopLock.unlock()
                if stop { return false }
                if DispatchTime.now().uptimeNanoseconds &- started > Self.linkWaitLimitNanos {
                    port.giveUpWaiting()
                    return true
                }
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
    }

    /// After this frame's CPU stepping: hand the port whatever this Tama
    /// transmitted (usually nothing; the port decides what, if anything,
    /// goes out). The core emits whole events only, so a frame's worth is
    /// always a whole number of them.
    private func collectLinkOutput() {
        guard let port = attachedLinkPort, let link = emu.pointee.link else { return }
        var out = Data()
        while true {
            let byte = link_rx(link, 1)
            if byte < 0 { break }
            out.append(UInt8(truncatingIfNeeded: byte))
        }
        port.finishFrame(out)
    }

    /// Where this Tama's clock stands against real time, as one fixed
    /// point: "when the core's own emulated-time counter (`emu_secs`) read
    /// `anchorEmuSecs`, the real wall-clock time was `anchorWall`". From
    /// that, the real moment the state is caught up to right now is always
    /// just `anchorWall + (emu_secs - anchorEmuSecs)` (see
    /// `stateWallTime`), and the time still owed is "now" minus that.
    ///
    /// This replaces separately tallying up every way time could be lost
    /// (a catch-up pass cut short by its budget, a stalled frame, a
    /// background pass that iOS suspended half-way and resumed hours
    /// later). Each of those tallies was a place to get it wrong, and
    /// several did: a pass computed its target from the time it *started*,
    /// so anything that delayed its save -- most of all iOS freezing the
    /// process mid-pass -- was recorded as "already caught up" and the
    /// Tama's clock fell behind by exactly that long. Deriving it from how
    /// far the core actually advanced can't drift that way: whatever
    /// didn't get emulated simply stays owed.
    private var anchorWall: Date
    private var anchorEmuSecs: Double

    /// The real wall-clock moment this state is caught up to.
    private var stateWallTime: Date {
        anchorWall.addingTimeInterval(emu.pointee.emu_secs - anchorEmuSecs)
    }

    /// Real seconds this Tama is still behind right now. Only meaningful
    /// while the emulator thread isn't running (it reads `emu`).
    private var owedSeconds: TimeInterval {
        max(0, Date().timeIntervalSince(stateWallTime))
    }

    /// Declares the Tama's clock correct as of this instant -- nothing
    /// owed. For anything that deliberately breaks the timeline: the
    /// player setting the clock, a restart, a recovery reset.
    private func reanchorToNow() {
        anchorWall = Date()
        anchorEmuSecs = emu.pointee.emu_secs
    }

    /// Whether another budgeted catch-up pass would make progress --
    /// PlayViewModel keeps running passes (continueCatchUp) while this
    /// page stays visible, rather than leaving the rest for the next time
    /// this engine is loaded. False when catch-up is switched off in
    /// Settings: the gap then just stays owed (as it always has) instead
    /// of being retried in a loop that can never shrink it.
    var canContinueCatchUp: Bool {
        owedSeconds > 0.5 && AppSettings.catchUpCapHours > 0
    }

    /// Polled between batches of steps during catch-up; returning true
    /// stops the pass early. Whatever it didn't reach stays owed.
    private let shouldAbort: (() -> Bool)?

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
        volumeProvider: {
            Float(AppSettings.playbackVolume)
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
    /// anchorWall) — it's picked up gradually over the next attempt.
    init(
        device: TamaDevice,
        savePaths: SavePaths,
        catchUpWallClockBudget: TimeInterval = 1.0,
        isPaused: Bool = false,
        notifyOnCatchUpCalls: Bool = true,
        shouldAbort: (() -> Bool)? = nil,
        onCallDetected: (() -> Void)? = nil
    ) throws {
        guard let profile = device_find(device.id) else {
            throw EmulatorError.unknownDevice(device.id)
        }
        self.device = device
        self.savePaths = savePaths
        self.frameStore = FrameStore(width: Int(PANEL_W), height: Int(PANEL_H))
        self.notifyOnCatchUpCalls = notifyOnCatchUpCalls
        self.shouldAbort = shouldAbort
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
        let now = Date()
        anchorEmuSecs = e.pointee.emu_secs
        if result == STATE_LOADED {
            // A paused Tama's clock is frozen on purpose: nothing is owed
            // for the time it sat paused, so it's simply current as of now.
            // Clamped to "now" either way -- a state can legitimately be a
            // little ahead of real time (tap-and-hold fast-forward), which
            // is carried as-is so the next stretch away absorbs it, but
            // anything further ahead than that is a changed device clock,
            // not something to wait out.
            let caughtUpTo = isPaused ? now : (savePaths.wallTime(forEmuSecs: e.pointee.emu_secs) ?? now)
            anchorWall = caughtUpTo.timeIntervalSince(now) > 3600 ? now : caughtUpTo
            if !isPaused {
                catchUp(wallClockBudget: catchUpWallClockBudget)
            }
        } else {
            anchorWall = now
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
    }

    /// Soft reset: same ROM/flash/RAM, just CPU state and the program
    /// counter reset to the firmware's reset vector — "battery out and
    /// in", not a wipe. Only safe to call while the dedicated thread is
    /// stopped (same precondition as save()).
    func resetCPU() {
        cpu_reset(emu)
        reanchorToNow()
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
        // The player just told us what time it is -- whatever was still
        // owed from before is moot, and replaying it on the next resume
        // would push the clock they just set ahead by that much.
        reanchorToNow()
        return true
    }

    /// Byte offset into the raw `Emu` struct where each ROM we've mapped
    /// so far keeps its points/wallet total, as a plain little-endian
    /// 16-bit value. Found empirically, one device at a time, by diffing
    /// .state saves while earning/spending a known amount in-game and
    /// watching which byte moved by exactly that amount (confirmed twice
    /// per device, at different points totals, to rule out coincidence).
    /// Each entry is specific to that one ROM's own firmware layout —
    /// there's no reason to expect it to match another device, and it
    /// hasn't (each one really is different). Unlike `setClock`, this
    /// isn't a `periph_write8` call — it's a raw poke into plain working
    /// RAM, not a memory-mapped hardware register, so there's no
    /// dedicated write path to go through.
    ///
    /// The 2026-11-26 entries were found headless instead: set a guessed
    /// spot to 1234, open the status page that shows points, and narrow
    /// the guesses down until "1234G" appeared (P's: also seen going
    /// 300 → 800 when evolving gave +500). Each was checked to still show
    /// the new value after a minute of play. iD L and 4U+ keep a 32-bit
    /// total, so the upper half is cleared too (left alone it showed a
    /// garbled 8-digit number).
    private static let pointsField: [String: (offset: Int, bytes: Int)] = [
        "plus-color": (45792, 2),  // confirmed 750→760 after earning 10
        "id": (45920, 2),          // confirmed 650→680 after earning 30
        "4u-plain": (5220, 2),     // confirmed 260→280 after earning 20
        "id-melody": (45920, 2),   // same spot as the iD
        "idl": (46012, 4),
        "ps": (5224, 2),
        "4u": (4956, 4),           // 4U+
    ]

    /// Whether Set Points works on this model yet.
    static func supportsPoints(_ deviceID: String) -> Bool {
        pointsField[deviceID] != nil
    }

    /// Sets the points/wallet total for a device in `pointsField`; a
    /// no-op (returns `nil`) for anything not yet mapped there. Clamped
    /// to 0...65535 on 16-bit fields and 0...99999 (the 5 digits the UI
    /// allows) on 32-bit ones. Call only while the engine's thread is
    /// stopped (same precondition as `save()`).
    @discardableResult
    func setPoints(_ value: Int) -> Int? {
        guard let field = Self.pointsField[device.id] else { return nil }
        let ptr = UnsafeMutableRawPointer(emu).advanced(by: field.offset).assumingMemoryBound(to: UInt8.self)
        let clamped = max(0, min(field.bytes == 4 ? 99999 : 65535, value))
        for i in 0..<field.bytes {
            ptr[i] = UInt8((clamped >> (8 * i)) & 0xFF)
        }
        return clamped
    }

    deinit {
        if let link = emu.pointee.link {
            link.deallocate()
        }
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
        // .userInteractive tells the OS this thread can never be
        // deprioritized, keeping performance cores spun up for as long as
        // the app is open — but runLoop() already paces itself with its
        // own sleep-to-deadline timing, not scheduling priority, so it
        // doesn't need that. .userInitiated still keeps it ahead of
        // ordinary background work without pinning the CPU in a higher
        // power state for the whole session.
        //
        // .utility was tried here on real-device profiler data: it moved
        // ~86% of this thread's CPU time off performance cores and onto
        // efficiency cores (a real, measured power win on paper). But
        // on-device it visibly broke real-time pacing — the OS schedules
        // .utility threads loosely enough that this thread, which needs
        // to run on a precise 60Hz cadence (every emulated frame of game
        // logic depends on it), started missing its own deadlines and the
        // whole Tama visibly ran in slow motion. Confirmed by playing on
        // a real device, not simulator — reverted back to .userInitiated
        // for that reason. Don't retry .utility (or anything lower) here
        // without re-confirming smooth, real-time playback on-device, not
        // just checking the profiler's core-time numbers look better.
        t.qualityOfService = .userInitiated
        thread = t
        // Before the thread, not after: `audioOutput` is a lazy var and
        // the thread's run loop calls audioOutput.tick() straight away.
        // Started the other way round, both threads raced to create it,
        // each got its own copy, and the one that was started here was
        // the one thrown away — no sound at all.
        audioOutput.start()
        t.start()
    }

    /// Signals the emulator thread to stop and blocks until it actually has
    /// — `save()` reads the whole Emu struct, so it must never run while
    /// the thread could still be concurrently stepping it. The 1s timeout
    /// is only a safety net against a true hang; the thread normally exits
    /// within one frame.
    func stop() {
        guard thread != nil else { return }
        stopLock.lock(); shouldStop = true; stopLock.unlock()
        let exited = stoppedSemaphore.wait(timeout: .now() + 1.0) == .success
        thread = nil
        audioOutput.stop()
        // Unplugged before anything saves: the snapshot is a copy of the
        // whole core, and a pointer to this session's link has no business
        // in it. Only once the thread is really gone -- it is the one user.
        if exited { detachLink() }
    }

    /// Pass-throughs for ScreenRecorder — see AudioOutput's own doc
    /// comments for why tapping the mixer node is safe to do alongside
    /// normal playback and never touches the microphone.
    var audioFormat: AVAudioFormat { audioOutput.outputFormat }

    func installRecordingTap(format: AVAudioFormat, bufferSize: AVAudioFrameCount, block: @escaping AVAudioNodeTapBlock) {
        audioOutput.installRecordingTap(format: format, bufferSize: bufferSize, block: block)
    }

    func removeRecordingTap() {
        audioOutput.removeRecordingTap()
    }

    /// Read-only look at the Tama's flash image (firmware + everything it
    /// has stored, downloads included). Call only after stop() has
    /// returned.
    func readFlash<T>(_ body: (UnsafeBufferPointer<UInt8>) -> T) -> T {
        body(UnsafeBufferPointer(start: emu.pointee.rom, count: Int(emu.pointee.dev.rom_size)))
    }

    /// Lets `body` change the flash image in place -- the same bytes the
    /// firmware programs when it stores something itself -- and marks it
    /// to be written out by the next save(), which also re-stamps the
    /// snapshot so the two keep matching. The CPU/RAM state is untouched,
    /// so the Tama carries on exactly where it was. Call only after stop()
    /// has returned.
    func editFlash<T>(_ body: (UnsafeMutableBufferPointer<UInt8>) -> T) -> T {
        let result = body(UnsafeMutableBufferPointer(start: emu.pointee.rom, count: Int(emu.pointee.dev.rom_size)))
        emu.pointee.flash_dirty = true
        return result
    }

    /// Persists the full snapshot and, if the firmware has written to its
    /// flash, the live flash image too. Call only after stop() has
    /// returned — never while the emulator thread might still be running.
    func save() {
        // Flash first, snapshot second. The snapshot records a checksum of
        // the flash it belongs with and is refused on the next load if the
        // file on disk doesn't match (the Tama then restarts from its
        // flash). Two files can't be written in one indivisible step, so
        // if the app is killed between them, this order leaves the newest
        // flash with an older snapshot -- a restart that still has the
        // latest in-game save -- rather than the other way round.
        //
        // Also written whenever the file is simply missing, not only when
        // the firmware has changed it: with no file, the next load falls
        // back to the pristine firmware, which no snapshot matches.
        if let rom = emu.pointee.rom,
           emu.pointee.flash_dirty || !FileManager.default.fileExists(atPath: savePaths.liveFlashPath.path) {
            let romSize = Int(emu.pointee.dev.rom_size)
            let data = Data(bytes: rom, count: romSize)
            if (try? data.write(to: savePaths.liveFlashPath, options: .atomic)) != nil {
                emu.pointee.flash_dirty = false
            }
        }
        var why = [CChar](repeating: 0, count: 256)
        let saved = savePaths.stateBasePath.path.withCString { base in
            buildID.withCString { bid in
                state_save(emu, base, bid, &why, why.count)
            }
        }
        if saved != 0 {
            // Both describe the same thing -- the real moment this exact
            // state is caught up to -- derived from how far the core
            // actually ran, never from "now". The anchor is what the next
            // load trusts (see SavePaths.clockAnchor for why);
            // lastSavedAt is kept in step for anything still reading it.
            let caughtUpTo = stateWallTime
            savePaths.clockAnchor = SavePaths.ClockAnchor(emuSecs: emu.pointee.emu_secs, wall: caughtUpTo)
            savePaths.lastSavedAt = caughtUpTo
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

    /// Call after every batch of steps (each batch returns on a tone
    /// edge), from any loop (normal real-time or catch-up) — the melody
    /// edge that signals a call can happen at any point in either. `duringCatchUp` controls whether a
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
    private func catchUp(wallClockBudget: TimeInterval = 5.0) {
        // Whatever is owed right now, measured fresh -- not handed in by
        // the caller -- so there's no stale figure to go wrong. Anything
        // beyond the cap, or beyond what this pass's budget reaches, just
        // stays owed for the next pass.
        let cappedSeconds = min(owedSeconds, AppSettings.catchUpCapHours * 3600)
        guard cappedSeconds > 0 else { return }
        let startSecs = emu.pointee.emu_secs
        let targetSecs = startSecs + cappedSeconds
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(wallClockBudget * 1_000_000_000)
        // Most of a long gap is spent halted (device asleep, nothing to
        // do), where cpu_step would otherwise pace itself at a fixed 16
        // cycles per call — fine for live play, but during an unpaced
        // catch-up that per-call overhead (not actual work) dominates,
        // and scales with the device's own clock speed. The 4096 here
        // strides through halted time in bigger jumps instead — runLoop()
        // keeps calling plain cpu_step(), so live play is untouched.
        //
        // The stepping itself runs in batches inside C (cpu_run_catchup)
        // rather than one Swift→C round trip per instruction. It hands
        // back control on every tone on/off edge, so checking the melody
        // after each return sees exactly the transitions a per-step check
        // would — primed once up front for a tone already sounding in the
        // loaded state.
        checkCallDetection(duringCatchUp: true)
        while emu.pointee.emu_secs < targetSecs && !emu.pointee.stopped {
            _ = cpu_run_catchup(emu, targetSecs, 4096, 4096)
            checkCallDetection(duringCatchUp: true)
            if DispatchTime.now().uptimeNanoseconds >= deadline { break }
            if shouldAbort?() == true { break }
        }

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
            reanchorToNow()
        }
    }

    /// Runs another budgeted pass against whatever is still owed after a
    /// previous pass ran out of wall-clock time — call only before
    /// `start()`, never once the live thread is running (both touch `emu`
    /// with no synchronization between them).
    func continueCatchUp(wallClockBudget: TimeInterval) {
        catchUp(wallClockBudget: wallClockBudget)
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

            let fastForward = currentFastForwardMultiplier()
            targetSecs += (1.0 / 60.0) * fastForward
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
            // Scaled by the same fastForward factor as targetSecs above, so
            // a frame fast-forwarding at 2x is actually allowed to run
            // roughly twice the cycles needed to catch its target up within
            // this one real frame, instead of being throttled back down to
            // normal speed by a ceiling sized for 1x.
            let cycleCeiling = emu.pointee.cycles &+ UInt64(mclk / 60.0 * fastForward) &+ 100_000
            // Applied before this frame's cpu_step calls, not after — a
            // press/release that lands anywhere in the current real-time
            // frame is live for the whole of this frame's CPU stepping, so
            // the firmware's interrupt handler can see it immediately
            // instead of only starting next frame. That shaves a full
            // wasted frame (~16ms) off perceived input lag for free: it
            // changes nothing about btn_mask's value or when the ITC edge
            // fires relative to wall-clock time, only how many of this
            // frame's instructions get to react to it.
            periph_buttons(emu, input.currentMask())
            syncLink(to: currentRequestedLinkPort())
            if !deliverLinkInput() { break }
            // The stepping runs in batches inside C (cpu_run_frame), not
            // one instruction at a time from here: per-instruction
            // bookkeeping in Swift cost more than the emulation itself in
            // Debug builds and made slower devices miss the 60Hz deadline
            // (everything in slow motion). It hands back control on every
            // tone on/off edge, so the melody check after each return sees
            // exactly the transitions a per-step check would.
            while emu.pointee.emu_secs < targetSecs && emu.pointee.cycles < cycleCeiling && !emu.pointee.stopped {
                cpu_run_frame(emu, targetSecs, cycleCeiling)
                checkCallDetection()
            }
            collectLinkOutput()
            audioOutput.tick(buttonsDown: input.currentMask() != 0)

            pixels.withUnsafeMutableBufferPointer { buf in
                lcd_render(emu, buf.baseAddress, &w, &h)
            }
            frameStore.write(pixels)

            let nowNanos = DispatchTime.now().uptimeNanoseconds
            if nextDeadlineNanos > nowNanos {
                Thread.sleep(forTimeInterval: Double(nextDeadlineNanos - nowNanos) / 1_000_000_000)
            } else {
                // Overran this frame's budget — the next iteration just
                // starts immediately with no sleep. Deliberately NOT
                // corrected live by running extra cycles (that visibly
                // speeds up animation; see the fixed 1/60 increment
                // above). The real time lost here, however small or large,
                // isn't lost track of: save() works out where this state
                // stands from how far emu_secs actually advanced (see
                // anchorWall), so the shortfall is simply still owed at
                // the next session-boundary catch-up.
                nextDeadlineNanos = nowNanos
            }
            nextDeadlineNanos += frameNanos
        }
        stoppedSemaphore.signal()
    }
}
