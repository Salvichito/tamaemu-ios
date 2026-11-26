import AVFoundation
import CTamaLib
import Foundation
import TamaCore

/// A P1-era (TamaLib) screen snapshot: 32x16 1-bit pixels plus 8 fixed
/// status icons. Row-major, matching `ios_hal_get_frame`'s layout.
struct P1ScreenState: Equatable {
    var bits: [Bool]
    var icons: [Bool]
    /// Yasashii only: its six lit care buttons, IOS_HAL_LAMP_* bits
    /// (meal, happiness, affection, toilet, lights, status). 0 elsewhere.
    var lamps: UInt8 = 0

    static let blank = P1ScreenState(
        bits: Array(repeating: false, count: 32 * 16),
        icons: Array(repeating: false, count: 8)
    )

    func pixel(_ x: Int, _ y: Int) -> Bool { bits[y * 32 + x] }
}

/// Driver for the TamaLib core: steps it continuously, forwards button
/// input, and plays its buzzer tone. Save/pause are still separate later
/// steps (see the integration-research memory). TamaLib's own
/// `tamalib_step()` already paces itself to the real chip's speed via its
/// HAL's `sleep_until`, so this just needs to call it continuously on a
/// background thread -- no 60Hz frame loop of its own like the existing
/// S1C33 engine needs.
final class V1EmulatorEngine {
    let input = InputController()

    private var thread: Thread?
    private let stopLock = NSLock()
    private var shouldStop = false
    private var lastButtonMask: UInt8 = 0
    /// cpu_init() (via ios_hal_start) only stores the raw pointer it's
    /// given -- g_program -- and dereferences it on every single
    /// instruction fetch for as long as the core runs; it never copies the
    /// ROM into its own buffer. So whatever array backs that pointer has
    /// to outlive the whole run, not just the ios_hal_start() call that
    /// hands the pointer over. Keeping it here (rather than as a local in
    /// start()) is what gives it that lifetime -- without this, Swift
    /// frees the parsed-words buffer the moment start() returns, and the
    /// stepping thread spends the rest of the session reading freed heap
    /// memory as "ROM," corrupting execution the moment something else's
    /// allocation reuses that block: exactly the random freezes/resets
    /// reported after actual gameplay (not reproduced by short smoke
    /// tests, since the block often isn't reused that quickly).
    private var romWords: [UInt16] = []
    /// Signaled right as runLoop() returns -- stop() waits on this so a
    /// save() called right after it is guaranteed the stepping thread is
    /// no longer touching the core's state (ios_hal_save_state() has no
    /// locking of its own against it).
    private let stoppedSemaphore = DispatchSemaphore(value: 0)

    private(set) var onFrame: ((P1ScreenState) -> Void)?
    /// Set by whoever owns this engine to be told when the Tama starts
    /// calling for attention -- mirrors CTama's EmulatorEngine.onCallDetected,
    /// but driven by TamaLib's own icon bit 7 ("attention"), which the core
    /// already lights up on its own, rather than a melody-tone heuristic.
    private(set) var onCallDetected: (() -> Void)?
    /// nil until the first frame is read -- lets runLoop() tell "icon was
    /// already on when this engine started" (not a new call, don't fire)
    /// apart from "icon just turned on" (a real new edge).
    private var lastAttentionOn: Bool?
    private var lampCalls = LampCallTracker()

    private lazy var audioOutput = AudioOutput(
        toneProvider: {
            (ios_hal_tone_on(), Float(ios_hal_tone_freq_dhz()) / 10)
        },
        volumeProvider: {
            Float(AppSettings.volume)
        }
    )

    /// Hold-to-fast-forward bookkeeping. While it's on, the Tama's own
    /// clock runs ahead of real time by (multiplier - 1) seconds for every
    /// real second held -- `fastForwardExtraSeconds` is that running
    /// total, which whoever saves this engine's state must add to the
    /// save's "caught up to" stamp (see V1PlayViewModel.stopEngine()).
    /// Main thread only.
    private static let fastForwardMultiplier: UInt8 = 2
    private var fastForwardBeganAt: DispatchTime?
    private(set) var fastForwardExtraSeconds: TimeInterval = 0

    /// Twice real speed while on. Only meaningful on a running engine.
    func setFastForward(_ on: Bool) {
        guard thread != nil else { return }
        if on {
            guard fastForwardBeganAt == nil else { return }
            fastForwardBeganAt = .now()
            ios_hal_set_speed(Self.fastForwardMultiplier)
        } else {
            guard let began = fastForwardBeganAt else { return }
            ios_hal_set_speed(1)
            fastForwardBeganAt = nil
            let held = Double(DispatchTime.now().uptimeNanoseconds - began.uptimeNanoseconds) / 1_000_000_000
            fastForwardExtraSeconds += held * Double(Self.fastForwardMultiplier - 1)
        }
    }

    /// Tap-an-icon shortcut (icon_nav.c): the stepping thread presses the
    /// buttons for the user until `light` is selected, then opens it.
    /// `count` is how many lights A cycles through. Any press of the
    /// user's own cancels it. Safe from any thread.
    func openMenuIcon(light: Int, count: Int) {
        guard (0..<count).contains(light) else { return }
        navLock.lock(); pendingNav = (UInt8(light), UInt8(count)); navLock.unlock()
    }
    private let navLock = NSLock()
    private var pendingNav: (light: UInt8, count: UInt8)?
    /// Stepping thread only (start() resets it before the thread exists).
    private var nav = icon_nav_t()

    /// For ScreenRecorder -- same pass-throughs the CTama engine has.
    var audioFormat: AVAudioFormat { audioOutput.outputFormat }

    func installRecordingTap(format: AVAudioFormat, bufferSize: AVAudioFrameCount, block: @escaping AVAudioNodeTapBlock) {
        audioOutput.installRecordingTap(format: format, bufferSize: bufferSize, block: block)
    }

    func removeRecordingTap() {
        audioOutput.removeRecordingTap()
    }

    init(onFrame: @escaping (P1ScreenState) -> Void, onCallDetected: (() -> Void)? = nil) {
        self.onFrame = onFrame
        self.onCallDetected = onCallDetected
    }

    /// romData is a raw P1 ROM dump: 12-bit words stored as big-endian
    /// byte pairs (confirmed against a real TamagotchiP1.bin -- see the
    /// integration-research memory). savedState, if given, is applied
    /// right after the core boots fresh from romData, before any
    /// stepping -- see ios_hal_load_state's own doc comment for what it
    /// restores and why that's safe to do between those two points.
    /// Returns false if the core failed to start.
    @discardableResult
    func start(romData: Data, savedState: Data? = nil, setClockTo clockTime: Date? = nil) -> Bool {
        guard thread == nil else { return true }

        romWords = Self.parseROM(romData)
        let model = V1EmulatorEngine.model(for: romWords)
        // See InputController.setTiming: Tamaotch drops taps under ~0.15 s
        // and taps closer than ~0.3 s apart, so hold each 0.2 s and space
        // them 0.3 s (quick taps queue up instead of being lost). The
        // Yasashii is slower still (measured headless 2026-11-25, status
        // button, 20 tries each: 0/20 at 60 ms, 5/20 at 100 ms, 18/20 at
        // 150 ms, 16-20/20 from 250 ms), so it gets 0.25 s -- now only for
        // cancel; the rest wait for the toy's own beep (below).
        switch model {
        case IOS_HAL_MODEL_TAMAOTCH:
            input.setTiming(minimumHoldMs: 200, minimumGapMs: 300)
        case IOS_HAL_MODEL_YASASHII:
            // Every button but cancel is held until the toy beeps (see
            // InputController.setAckHold): fixed holds lost ~15-20% of
            // presses on awake saves (measured headless 2026-11-25), the
            // beep rule ~0-1%. Cancel never beeps, so it keeps 0.25 s.
            input.setTiming(minimumHoldMs: 250, minimumGapMs: 300)
            input.setAckHold(buttons: [.a, .b, .tap, .k10, .k11, .k12, .k13], floorMs: 150, capMs: 600)
        default:
            // The tap sensor (Angel, Morino, Umino) is a one-shot press,
            // held 0.2 s so a toy busy animating still sees it.
            input.setTiming(minimumHoldMs: 60, minimumGapMs: 25, holdOverrides: [.tap: 200])
        }
        if model != IOS_HAL_MODEL_YASASHII {
            input.setAckHold(buttons: [], floorMs: 0, capMs: 0)
        }
        let started = romWords.withUnsafeBufferPointer { buf in
            ios_hal_start(buf.baseAddress, UInt32(buf.count), model)
        }
        guard started == 0 else { return false }

        if let savedState {
            _ = savedState.withUnsafeBytes { raw in
                ios_hal_load_state(raw.bindMemory(to: UInt8.self).baseAddress, UInt32(savedState.count))
            }
            // ⋯ "Sync Clock to Now": the clock jumps to the given time (the
            // pet lives none of the time in between). Only on top of a loaded save: a fresh boot is
            // still in its own clock-setting screen. The core refuses for
            // Digimon and for a clock that was never set.
            if let clockTime {
                let now = Calendar.current.dateComponents([.hour, .minute, .second], from: clockTime)
                _ = ios_hal_set_clock(Int32(now.hour ?? 0), Int32(now.minute ?? 0), Int32(now.second ?? 0))
            }
        }

        lastButtonMask = 0
        nav = icon_nav_t()
        navLock.lock(); pendingNav = nil; navLock.unlock()
        fastForwardBeganAt = nil
        fastForwardExtraSeconds = 0
        stopLock.lock(); shouldStop = false; stopLock.unlock()
        let t = Thread { [weak self] in
            self?.runLoop()
            self?.stoppedSemaphore.signal()
        }
        t.name = "V1EmulatorEngine"
        t.qualityOfService = .userInitiated
        thread = t
        // Before the thread, not after: `audioOutput` is a lazy var and
        // the thread's run loop calls audioOutput.tick() straight away.
        // Started the other way round, both threads raced to create it,
        // each got its own copy, and the one that was started here was
        // the one thrown away — no sound at all.
        audioOutput.start()
        t.start()
        return true
    }

    /// A snapshot of the live core's full state -- CPU, RAM, display,
    /// buzzer, and its own elapsed clock -- for resuming later via
    /// start(romData:savedState:). Only safe to call after stop(), which
    /// blocks until the stepping thread has actually exited -- see
    /// stoppedSemaphore's own doc comment.
    func saveState() -> Data? {
        let size = Int(ios_hal_state_size())
        var buffer = [UInt8](repeating: 0, count: size)
        let written = buffer.withUnsafeMutableBufferPointer { buf in
            ios_hal_save_state(buf.baseAddress, UInt32(buf.count))
        }
        guard written > 0 else { return nil }
        return Data(buffer[0..<Int(written)])
    }

    func stop() {
        guard thread != nil else { return }
        // Back to normal speed first, so the time spent fast-forwarding
        // is fully counted before anyone reads fastForwardExtraSeconds.
        setFastForward(false)
        stopLock.lock(); shouldStop = true; stopLock.unlock()
        thread = nil
        stoppedSemaphore.wait()
        audioOutput.stop()
        ios_hal_stop()
    }

    /// Instructions run per pass of runLoop (a power of two dividing 64,
    /// so the audio tick below still lands every 64 instructions).
    private static let stepsPerPass: UInt32 = 32

    private func runLoop() {
        var bitsBuf = [UInt8](repeating: 0, count: 64)
        var lastPublish = Date.distantPast
        var lastToneOn = false
        var audioTickCounter: UInt32 = 0

        while true {
            stopLock.lock(); let stop = shouldStop; stopLock.unlock()
            if stop { break }

            // A small batch per pass, not one instruction: everything below
            // (locks, Date(), the input check) cost far more than the
            // instruction itself. The P1 runs ~5k instructions a second, but
            // the Yasashii switches its chip to the fast OSC3 clock for
            // animations and runs up to ~170k (measured headless
            // 2026-11-25) -- one-at-a-time from Swift couldn't keep up on a
            // phone, so it slowed to a crawl whenever it got busy (the
            // toilet-cleaning animation). 32 instructions is ~6 ms at the
            // slow clock, well under the shortest press the firmware is shown.
            ios_hal_step_many(Self.stepsPerPass)

            // A new beep is the firmware's "got it" for a held press
            // (InputController.setAckHold; a no-op unless a press waits).
            let toneNow = ios_hal_tone_on()
            if toneNow && !lastToneOn { input.acknowledge() }
            lastToneOn = toneNow

            // Forwarded every step, not just on the throttled publish tick
            // below -- hw_set_button() is a cheap, idempotent CPU-pin write
            // (see hw.c), so there's no cost reason to hold a fresh press
            // back. ios_hal_step() advances only one instruction and paces
            // itself to the real chip's speed internally (sleep_until), so
            // this loop iterates far more often than 30Hz; gating button
            // forwarding on the same 1/30s check the screen publish uses
            // below meant a press could sit unseen by the chip for up to
            // ~33ms for no reason -- the actual cause of P1/P2 feeling
            // laggy, not the CTama engine's frame ordering (that engine
            // doesn't even run this device; see DeviceCatalog's .v1 family).
            var mask = input.currentMask()
            // Tap-an-icon shortcut: while it runs it drives the buttons
            // itself, timed by the core's own clock, until the user
            // presses anything.
            navLock.lock(); let request = pendingNav; pendingNav = nil; navLock.unlock()
            if let request { icon_nav_start(&nav, request.light, request.count, ios_hal_elapsed_us()) }
            if icon_nav_active(&nav) {
                if mask != 0 {
                    icon_nav_cancel(&nav)
                } else {
                    var lights: UInt16 = 0
                    for i in 0..<8 where ios_hal_get_icon(UInt8(i)) { lights |= UInt16(1 << i) }
                    mask = icon_nav_tick(&nav, ios_hal_elapsed_us(), lights)
                }
            }
            let changed = mask ^ lastButtonMask
            if changed != 0 {
                // InputController's bit order (A=0, B=1, C=2, then the
                // tap and K10-K13 pins) already matches ios_hal_set_button's
                // own -- no remapping needed. The HAL ignores 4-7 on every
                // model but the Yasashii.
                for bit in 0..<8 where (changed & (1 << bit)) != 0 {
                    ios_hal_set_button(Int32(bit), (mask & (1 << bit)) != 0)
                }
                lastButtonMask = mask
            }
            // This loop runs once per emulated instruction, far more often
            // than the sound engine needs to hear from it.
            audioTickCounter &+= Self.stepsPerPass
            if audioTickCounter & 63 == 0 {
                audioOutput.tick(buttonsDown: mask != 0)
            }

            let now = Date()
            guard now.timeIntervalSince(lastPublish) >= 1.0 / 30.0 else { continue }
            lastPublish = now

            var iconsByte: UInt8 = 0
            bitsBuf.withUnsafeMutableBufferPointer { buf in
                ios_hal_get_frame(buf.baseAddress, &iconsByte)
            }

            var bits = [Bool](repeating: false, count: 32 * 16)
            for i in 0..<(32 * 16) {
                bits[i] = (bitsBuf[i / 8] & (0x80 >> (i % 8))) != 0
            }
            var icons = [Bool](repeating: false, count: 8)
            for i in 0..<8 {
                icons[i] = (iconsByte & (1 << i)) != 0
            }

            // Index 7 is the "attention" icon -- TamaLib already lights it
            // up on its own when the Tama needs care, no melody-matching
            // needed. Firing on every false->true edge, not merely "is it
            // on", so a call that's been sitting on since before this
            // engine even started doesn't immediately fire (lastAttentionOn
            // starts nil, so the very first read only primes it) while a
            // real new call still does, live, the same instant it starts.
            // The Yasashii has no attention icon: it blinks the care
            // button it wants instead (lamps stay 0 on every other model).
            let lamps = ios_hal_get_lamps()
            let attentionOn = icons[7] || lampCalls.isCalling(lamps: lamps, nowUs: ios_hal_elapsed_us())
            if let last = lastAttentionOn, attentionOn && !last {
                onCallDetected?()
            }
            lastAttentionOn = attentionOn

            let state = P1ScreenState(bits: bits, icons: icons, lamps: lamps)
            let callback = onFrame
            DispatchQueue.main.async {
                callback?(state)
            }
        }
    }
}

extension V1EmulatorEngine {
    /// Advances a saved state by up to `backlogSeconds` of emulated time
    /// (time the app was closed), within `wallClockBudget` real seconds
    /// -- same shape as the CTama engine's own catch-up-on-resume, just
    /// built on fast-forward instead of an unpaced step loop. Returns the
    /// state to actually resume from: unchanged if there was nothing to
    /// catch up, or as far as it got if the budget ran out first (same
    /// "catches up as much as it can, not guaranteed to finish" contract
    /// the CTama family already has).
    ///
    /// Static, and runs its own start/stop cycles directly against the
    /// HAL rather than through an instance -- there's no live runLoop at
    /// this point to race with, and a single fast-forward pass can't
    /// cover more than ~71 minutes of emulated time regardless of budget
    /// (ios_hal_elapsed_us's own 32-bit microsecond range), so this
    /// chunks the backlog into repeated, fresh-epoch hops, saving and
    /// reloading state between them -- the overnight-gap case this
    /// exists for needs exactly that, not a single pass.
    /// `onCallDetected`, if given, is invoked once per false->true edge of
    /// TamaLib's own "attention" icon (bit 7) encountered anywhere along the
    /// replay -- not just whatever the icon happens to read at the very
    /// end -- mirroring EmulatorEngine's own `checkCallDetection(duringCatchUp:)`.
    /// Pass nil for a plain foreground resume (the player is about to look
    /// at the live screen regardless, same reasoning PlayViewModel's own
    /// CTama catch-up uses); pass a real closure only for a headless pass
    /// that exists specifically to warn the player before they open the
    /// app (BackgroundRefresh).
    ///
    /// Returns how many emulated seconds it actually advanced alongside
    /// the new state -- measured from the core's own clock, not assumed
    /// from what was asked for. Callers must move this Tama's
    /// `lastSavedAt` forward by exactly that much and no more: every
    /// caller used to stamp it "now" regardless, so whenever the budget
    /// ran out first (a long night on a real phone, or a background pass
    /// sharing ~25s between several Tamas at background CPU priority) the
    /// part that hadn't been emulated yet was silently forgotten and the
    /// clock stayed that far behind for good. `shouldAbort` is polled
    /// between batches of steps; returning true stops the pass early.
    static func catchUp(
        romWords: [UInt16],
        from state: Data,
        backlogSeconds: TimeInterval,
        wallClockBudget: TimeInterval,
        shouldAbort: (() -> Bool)? = nil,
        onCallDetected: (() -> Void)? = nil
    ) -> (state: Data, advancedSeconds: TimeInterval) {
        guard backlogSeconds > 0 else { return (state, 0) }

        // Well inside the ~71 minutes one hop can represent (see above).
        let hopSeconds: TimeInterval = 600
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, wallClockBudget) * 1_000_000_000)
        var advancedUs: UInt64 = 0
        var currentState = state
        var outOfTime = false
        // Persists across hops (each hop tears down and reloads the HAL
        // session), same reason the live engine's own lastAttentionOn
        // isn't reset per-call -- nil until the first read primes it, so a
        // call already sitting on in the loaded save doesn't itself count
        // as a new edge.
        var lastAttentionOn: Bool?
        var lampCalls = LampCallTracker()

        while !outOfTime {
            let remaining = backlogSeconds - Double(advancedUs) / 1_000_000
            // Less than one instruction's worth left -- done.
            guard remaining > 0.001 else { break }
            let hop = min(remaining, hopSeconds)

            let started = romWords.withUnsafeBufferPointer { buf in
                ios_hal_start(buf.baseAddress, UInt32(buf.count), V1EmulatorEngine.model(for: romWords))
            }
            guard started == 0 else { break }

            let loaded = currentState.withUnsafeBytes { raw in
                ios_hal_load_state(raw.bindMemory(to: UInt8.self).baseAddress, UInt32(currentState.count))
            }
            guard loaded else {
                ios_hal_stop()
                break
            }

            let startUs = ios_hal_elapsed_us()
            let targetDeltaUs = UInt32(hop * 1_000_000)
            var batchesSinceCheck = 0
            ios_hal_set_fast_forward(true)
            // Stepped in small batches inside C rather than one call per
            // instruction from here -- the per-call overhead was several
            // times the cost of the instruction itself. A batch is ~5ms of
            // emulated time, so overshooting the target by part of one is
            // harmless: what actually ran is measured below, not assumed.
            while (ios_hal_elapsed_us() &- startUs) < targetDeltaUs {
                ios_hal_step_many(32)
                if onCallDetected != nil {
                    // The attention icon stays lit for as long as the Tama
                    // is calling, far longer than one batch, so sampling it
                    // per batch can't miss a call.
                    let attentionOn = ios_hal_get_icon(7)
                        || lampCalls.isCalling(lamps: ios_hal_get_lamps(), nowUs: ios_hal_elapsed_us())
                    if let last = lastAttentionOn, attentionOn && !last {
                        onCallDetected?()
                    }
                    lastAttentionOn = attentionOn
                }
                batchesSinceCheck += 1
                if batchesSinceCheck >= 64 {
                    batchesSinceCheck = 0
                    if DispatchTime.now().uptimeNanoseconds >= deadline || shouldAbort?() == true {
                        outOfTime = true
                        break
                    }
                }
            }
            let hopAdvancedUs = ios_hal_elapsed_us() &- startUs
            ios_hal_set_fast_forward(false)

            let size = Int(ios_hal_state_size())
            var buffer = [UInt8](repeating: 0, count: size)
            let written = buffer.withUnsafeMutableBufferPointer { buf in
                ios_hal_save_state(buf.baseAddress, UInt32(buf.count))
            }
            ios_hal_stop()
            guard written > 0 else { break }

            currentState = Data(buffer[0..<Int(written)])
            advancedUs += UInt64(hopAdvancedUs)
        }

        return (currentState, Double(advancedUs) / 1_000_000)
    }

    /// The screen a saved state was showing, without running it -- for a
    /// paused Tama, which has no live engine to publish frames. Boots the
    /// core, loads the state, reads the display and tears it down again,
    /// so the caller must hold the V1 EngineGate, same as catchUp().
    static func peekScreen(romWords: [UInt16], state: Data) -> P1ScreenState? {
        let started = romWords.withUnsafeBufferPointer { buf in
            ios_hal_start(buf.baseAddress, UInt32(buf.count), V1EmulatorEngine.model(for: romWords))
        }
        guard started == 0 else { return nil }
        defer { ios_hal_stop() }
        let loaded = state.withUnsafeBytes { raw in
            ios_hal_load_state(raw.bindMemory(to: UInt8.self).baseAddress, UInt32(state.count))
        }
        guard loaded else { return nil }

        var bitsBuf = [UInt8](repeating: 0, count: 64)
        var iconsByte: UInt8 = 0
        bitsBuf.withUnsafeMutableBufferPointer { buf in
            ios_hal_get_frame(buf.baseAddress, &iconsByte)
        }
        return P1ScreenState(
            bits: (0..<(32 * 16)).map { (bitsBuf[$0 / 8] & (0x80 >> ($0 % 8))) != 0 },
            icons: (0..<8).map { (iconsByte & (1 << $0)) != 0 },
            lamps: ios_hal_get_lamps()
        )
    }

    /// Which toy a ROM is, for the hardware the ROM alone doesn't describe
    /// (LCD wiring and orientation, how keys and beeps reach the chip) --
    /// see IOS_HAL_MODEL_* in ios_hal.h. Decided from the ROM's own content,
    /// not from the TamaDevice, so every path that boots the core (live,
    /// catch-up, peek) agrees without having to be told. An unknown dump
    /// gets the plain P1 wiring, which is what this core always used.
    static func model(for romWords: [UInt16]) -> Int32 {
        let bytes = romWords.lazy.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        switch DeviceCatalog.v1DeviceID(forROM: bytes) {
        case "umino": return IOS_HAL_MODEL_ICON_PER_SEGMENT
        case "genjintch": return IOS_HAL_MODEL_GENJINTCH
        case "tamaotch": return IOS_HAL_MODEL_TAMAOTCH
        case "mothra": return IOS_HAL_MODEL_MOTHRA
        case "yasashii": return IOS_HAL_MODEL_YASASHII
        case "digimon-v1", "digimon-v2", "digimon-v3": return IOS_HAL_MODEL_DIGIMON
        default: return IOS_HAL_MODEL_P1
        }
    }

    /// romData parsing, factored out of start(romData:) so catchUp(_:)
    /// (a static function with no instance to call that on) can reuse it.
    static func parseROM(_ romData: Data) -> [UInt16] {
        var words = [UInt16]()
        words.reserveCapacity(romData.count / 2)
        var iterator = romData.makeIterator()
        while let hi = iterator.next(), let lo = iterator.next() {
            words.append((UInt16(hi) << 8) | UInt16(lo))
        }
        return words
    }
}

/// Turns the Yasashii's blinking care-button lamps into one steady
/// "calling" signal, the way the attention icon works on other models:
/// "calling" means some lamp was lit within the last 5 emulated seconds.
/// Measured headless 2026-11-24 over an emulated hour: the meal/happiness
/// lamps blink about twice a second with gaps up to ~1.5 s, and the lights
/// lamp blinks only every ~2 s. The old 1.5 s window counted each lights
/// blink as a new call (~70 alerts an hour); 5 s gives ~4, one per real
/// call. Times are the core's own clock (ios_hal_elapsed_us), compared
/// with wrapping subtraction.
struct LampCallTracker {
    private var lastLitUs: UInt32?

    mutating func isCalling(lamps: UInt8, nowUs: UInt32) -> Bool {
        if lamps != 0 {
            lastLitUs = nowUs
            return true
        }
        guard let lastLitUs else { return false }
        return nowUs &- lastLitUs < 5_000_000
    }
}

