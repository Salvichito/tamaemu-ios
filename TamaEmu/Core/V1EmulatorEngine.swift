import AVFoundation
import CTamaLib
import Foundation

/// A P1-era (TamaLib) screen snapshot: 32x16 1-bit pixels plus 8 fixed
/// status icons. Row-major, matching `ios_hal_get_frame`'s layout.
struct P1ScreenState {
    var bits: [Bool]
    var icons: [Bool]

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

    private lazy var audioOutput = AudioOutput(
        toneProvider: {
            (ios_hal_tone_on(), Float(ios_hal_tone_freq_dhz()) / 10)
        },
        volumeProvider: {
            Float(AppSettings.volume)
        }
    )

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
    func start(romData: Data, savedState: Data? = nil) -> Bool {
        guard thread == nil else { return true }

        romWords = Self.parseROM(romData)
        let started = romWords.withUnsafeBufferPointer { buf in
            ios_hal_start(buf.baseAddress, UInt32(buf.count))
        }
        guard started == 0 else { return false }

        if let savedState {
            _ = savedState.withUnsafeBytes { raw in
                ios_hal_load_state(raw.bindMemory(to: UInt8.self).baseAddress, UInt32(savedState.count))
            }
        }

        lastButtonMask = 0
        stopLock.lock(); shouldStop = false; stopLock.unlock()
        let t = Thread { [weak self] in
            self?.runLoop()
            self?.stoppedSemaphore.signal()
        }
        t.name = "V1EmulatorEngine"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
        audioOutput.start()
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
        stopLock.lock(); shouldStop = true; stopLock.unlock()
        thread = nil
        stoppedSemaphore.wait()
        audioOutput.stop()
        ios_hal_stop()
    }

    private func runLoop() {
        var bitsBuf = [UInt8](repeating: 0, count: 64)
        var lastPublish = Date.distantPast

        while true {
            stopLock.lock(); let stop = shouldStop; stopLock.unlock()
            if stop { break }

            ios_hal_step()

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
            let mask = input.currentMask()
            let changed = mask ^ lastButtonMask
            if changed != 0 {
                // InputController's bit order (A=0, B=1, C=2) already
                // matches ios_hal_set_button's own (0=A/left, 1=B/middle,
                // 2=C/right) -- no remapping needed.
                for bit in 0..<3 where (changed & (1 << bit)) != 0 {
                    ios_hal_set_button(Int32(bit), (mask & (1 << bit)) != 0)
                }
                lastButtonMask = mask
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
            let attentionOn = icons[7]
            if let last = lastAttentionOn, attentionOn && !last {
                onCallDetected?()
            }
            lastAttentionOn = attentionOn

            let state = P1ScreenState(bits: bits, icons: icons)
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
    static func catchUp(
        romWords: [UInt16],
        from state: Data,
        backlogSeconds: TimeInterval,
        wallClockBudget: TimeInterval,
        onCallDetected: (() -> Void)? = nil
    ) -> Data {
        guard backlogSeconds > 1 else { return state }

        let hopSeconds: TimeInterval = 50
        let deadline = Date().addingTimeInterval(wallClockBudget)
        var remaining = backlogSeconds
        var currentState = state
        // Persists across hops (each hop tears down and reloads the HAL
        // session), same reason the live engine's own lastAttentionOn
        // isn't reset per-call -- nil until the first read primes it, so a
        // call already sitting on in the loaded save doesn't itself count
        // as a new edge.
        var lastAttentionOn: Bool?

        while remaining > 1, Date() < deadline {
            let hop = min(remaining, hopSeconds)

            let started = romWords.withUnsafeBufferPointer { buf in
                ios_hal_start(buf.baseAddress, UInt32(buf.count))
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
            ios_hal_set_fast_forward(true)
            while (ios_hal_elapsed_us() &- startUs) < targetDeltaUs, Date() < deadline {
                ios_hal_step()
                if onCallDetected != nil {
                    let attentionOn = ios_hal_get_icon(7)
                    if let last = lastAttentionOn, attentionOn && !last {
                        onCallDetected?()
                    }
                    lastAttentionOn = attentionOn
                }
            }
            ios_hal_set_fast_forward(false)

            let size = Int(ios_hal_state_size())
            var buffer = [UInt8](repeating: 0, count: size)
            let written = buffer.withUnsafeMutableBufferPointer { buf in
                ios_hal_save_state(buf.baseAddress, UInt32(buf.count))
            }
            ios_hal_stop()
            guard written > 0 else { break }

            currentState = Data(buffer[0..<Int(written)])
            remaining -= hop
        }

        return currentState
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
