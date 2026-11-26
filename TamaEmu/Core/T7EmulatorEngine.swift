import AVFoundation
import CT7Emu
import CTamaLib // icon_nav.c, the tap-an-icon shortcut shared with first-gen
import Foundation

/// A Tama-Go / Tamagotchi Friends (T7Emu) screen snapshot: 48x31 pixels at
/// 4 grayscale levels, plus 10 fixed status icons. Row-major, matching
/// `ios_t7_get_frame`'s layout (see ios_t7.h for the confirmed icon order).
struct T7ScreenState: Equatable {
    var pixels: [UInt8] // 0...3 per pixel
    var icons: [UInt8] // 0...3 per icon

    static let blank = T7ScreenState(
        pixels: Array(repeating: 0, count: Int(IOS_T7_LCD_WIDTH * IOS_T7_LCD_HEIGHT)),
        icons: Array(repeating: 0, count: Int(IOS_T7_ICON_COUNT))
    )

    func pixel(_ x: Int, _ y: Int) -> UInt8 { pixels[y * Int(IOS_T7_LCD_WIDTH) + x] }
}

/// Driver for the T7Emu core: steps it at a real 60Hz cadence, forwards
/// button input, and plays its buzzer tone. Simpler than both this app's
/// other two engines' run loops: unlike CTama, the core's clock never
/// changes rate (no sleep-mode oscillator switch to guard against), and
/// unlike TamaLib, the core doesn't pace itself internally (no
/// sleep_until to fight for fast-forward/catch-up) -- `ios_t7_step_frame()`
/// already advances exactly one 60Hz frame's worth of cycles and fires the
/// video IRQ/NMI at the right point internally, so this loop only needs to
/// call it once per real 1/60s tick.
///
/// Calls: `onCallDetected` fires when the attention ("bell") icon lights
/// up -- see ios_t7_attention_on for how sure that mapping is.
final class T7EmulatorEngine {
    let input = InputController()

    private var thread: Thread?
    private let stopLock = NSLock()
    private var shouldStop = false
    private var lastButtonMask: UInt8 = 0
    private let stoppedSemaphore = DispatchSemaphore(value: 0)

    private(set) var onFrame: ((T7ScreenState) -> Void)?
    /// Invoked (from the stepping thread) once per off->on edge of the
    /// attention icon -- same contract as V1EmulatorEngine.onCallDetected.
    private(set) var onCallDetected: (() -> Void)?

    /// How many 1/60s frames the live loop has actually stepped since
    /// start() -- i.e. how much emulated time really passed, as opposed
    /// to how much real time did (a stalled or suspended loop steps
    /// fewer). Written only by the stepping thread; read only after
    /// stop() has joined it.
    private var liveFramesStepped: UInt64 = 0
    /// Emulated seconds advanced by live play so far. Only meaningful
    /// after stop().
    var liveSecondsAdvanced: TimeInterval { Double(liveFramesStepped) / 60 }

    /// Hold-to-fast-forward: two emulated frames per real 1/60 s tick.
    /// Read by the stepping thread under stopLock.
    private var fastForward = false
    /// Frames stepped beyond real time while fast-forwarding -- the Tama's
    /// clock is ahead of real time by this much. Same role as
    /// V1EmulatorEngine.fastForwardExtraSeconds. Only meaningful after stop().
    private var fastForwardExtraFrames: UInt64 = 0
    var fastForwardExtraSeconds: TimeInterval { Double(fastForwardExtraFrames) / 60 }

    func setFastForward(_ on: Bool) {
        stopLock.lock(); fastForward = on; stopLock.unlock()
    }

    /// Plays the core's own sound stream (t7_sound.c's timer + DAC
    /// emulation, rendered as a clean square wave), not the tone-polling
    /// the other two cores use: these toys change notes faster than a
    /// 60 Hz poll can follow. toneProvider is only "is anything playing",
    /// which lets the audio engine sleep when the Tama is quiet.
    private lazy var audioOutput = AudioOutput(
        toneProvider: {
            (ios_t7_sound_busy(), 0)
        },
        volumeProvider: {
            Float(AppSettings.volume)
        },
        pcmProvider: { out, count, restarted in
            if restarted { ios_t7_sound_skip_to(T7EmulatorEngine.audioTargetSamples) }
            _ = ios_t7_sound_pull(out, UInt32(count), T7EmulatorEngine.audioTargetSamples)
        }
    )
    /// Audio kept buffered between the emulator (which delivers 1/60 s at a
    /// time) and the speaker: ~40 ms at 48 kHz. The core's pull stretches
    /// or squeezes playback by a few percent to hold this level.
    private static let audioTargetSamples: UInt32 = 1920
    private var audioCapturing = false

    /// For ScreenRecorder -- same pass-throughs the other engines have.
    var audioFormat: AVAudioFormat { audioOutput.outputFormat }

    func installRecordingTap(format: AVAudioFormat, bufferSize: AVAudioFrameCount, block: @escaping AVAudioNodeTapBlock) {
        audioOutput.installRecordingTap(format: format, bufferSize: bufferSize, block: block)
    }

    func removeRecordingTap() {
        audioOutput.removeRecordingTap()
    }

    /// Tap-an-icon shortcut (icon_nav.c, same one the first-gen engine
    /// uses): the stepping thread presses the buttons for the user until
    /// `light` is selected, then opens it. A steps through icons 0-8 on
    /// both toys (measured headless 2026-11-25). Any press of the user's
    /// own cancels it. Safe from any thread.
    func openMenuIcon(light: Int) {
        guard (0..<Self.menuIconCount).contains(light) else { return }
        navLock.lock(); pendingNav = UInt8(light); navLock.unlock()
    }
    static let menuIconCount = 9
    private let navLock = NSLock()
    private var pendingNav: UInt8?
    /// Stepping thread only (start() resets it before the thread exists).
    private var nav = icon_nav_t()

    /// Gotchi Figure (Tama-Go): plugs `figure` (a figure's flash dump, see
    /// FigureLibrary) in, or unplugs with nil. Like on the real toy, a
    /// swap takes the old figure off first and waits a moment before the
    /// new one goes on (Paramix waits 2.5 s too). Applied by the stepping
    /// thread between frames. Safe from any thread.
    func setFigure(_ figure: Data?) {
        figureLock.lock(); pendingFigure = .some(figure); figureLock.unlock()
    }
    private let figureLock = NSLock()
    /// .some(nil) = unplug. Read and cleared by the stepping thread.
    private var pendingFigure: Data??
    /// Stepping thread only: a figure waiting to go on, and the frame it may.
    private var figureToInsert: (data: Data, atFrame: UInt64)?
    private static let figureSwapFrames: UInt64 = 150

    init(onFrame: @escaping (T7ScreenState) -> Void, onCallDetected: (() -> Void)? = nil) {
        self.onFrame = onFrame
        self.onCallDetected = onCallDetected
    }

    /// romData is a raw Tama-Go (640 KB) or Tamagotchi Friends (768 KB)
    /// flash dump. eepromData/stateData, if given, are loaded right after
    /// the core boots fresh from romData, before any stepping -- eeprom
    /// first, so the CPU/RAM state (which may be mid-read of the EEPROM)
    /// resumes with the right data already in place. Returns false if the
    /// core failed to start.
    @discardableResult
    func start(romData: Data, eepromData: Data? = nil, stateData: Data? = nil, figure: Data? = nil, setClockTo clockTime: Date? = nil) -> Bool {
        guard thread == nil else { return true }

        let started = romData.withUnsafeBytes { raw in
            ios_t7_start(raw.bindMemory(to: UInt8.self).baseAddress, UInt32(romData.count))
        }
        guard started else { return false }
        // Sound hardware on before load_state, so the save's sound-timer
        // phase is restored (see ios_t7.h). Live play only: catch-up runs
        // without it, much faster.
        ios_t7_sound_live(true, UInt32(audioOutput.outputFormat.sampleRate.rounded()))
        audioCapturing = true

        if let eepromData {
            _ = eepromData.withUnsafeBytes { raw in
                ios_t7_eeprom_load(raw.bindMemory(to: UInt8.self).baseAddress, UInt32(eepromData.count))
            }
        }
        if let stateData {
            _ = stateData.withUnsafeBytes { raw in
                ios_t7_load_state(raw.bindMemory(to: UInt8.self).baseAddress, UInt32(stateData.count))
            }
            // Only on top of a loaded save: a fresh boot is still in its
            // own clock-setting screen.
            if let clockTime {
                let now = Calendar.current.dateComponents([.hour, .minute, .second], from: clockTime)
                _ = ios_t7_set_clock(Int32(now.hour ?? 0), Int32(now.minute ?? 0), Int32(now.second ?? 0))
            }
        }

        // Already plugged in when the save resumes, as on the real toy:
        // no "figure arrived" scene each time the app opens.
        if let figure { Self.insertFigure(figure) }
        figureToInsert = nil
        figureLock.lock(); pendingFigure = nil; figureLock.unlock()

        lastButtonMask = 0
        liveFramesStepped = 0
        nav = icon_nav_t()
        navLock.lock(); pendingNav = nil; navLock.unlock()
        fastForwardExtraFrames = 0
        stopLock.lock(); shouldStop = false; fastForward = false; stopLock.unlock()
        let t = Thread { [weak self] in
            self?.runLoop()
            self?.stoppedSemaphore.signal()
        }
        t.name = "T7EmulatorEngine"
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

    /// What a saved Tama's screen was showing, without running it -- for a
    /// paused Tama, which has no live engine (same role as
    /// V1EmulatorEngine.peekScreen). The caller must hold this family's
    /// EngineGate: there is only one T7 core in the process.
    static func peekScreen(romData: Data, eepromData: Data?, state: Data) -> T7ScreenState? {
        let started = romData.withUnsafeBytes { raw in
            ios_t7_start(raw.bindMemory(to: UInt8.self).baseAddress, UInt32(romData.count))
        }
        guard started else { return nil }
        defer { ios_t7_stop() }
        if let eepromData {
            _ = eepromData.withUnsafeBytes { raw in
                ios_t7_eeprom_load(raw.bindMemory(to: UInt8.self).baseAddress, UInt32(eepromData.count))
            }
        }
        let loaded = state.withUnsafeBytes { raw in
            ios_t7_load_state(raw.bindMemory(to: UInt8.self).baseAddress, UInt32(state.count))
        }
        guard loaded else { return nil }
        var pixels = [UInt8](repeating: 0, count: Int(IOS_T7_LCD_WIDTH * IOS_T7_LCD_HEIGHT))
        var icons = [UInt8](repeating: 0, count: Int(IOS_T7_ICON_COUNT))
        pixels.withUnsafeMutableBufferPointer { p in
            icons.withUnsafeMutableBufferPointer { i in
                ios_t7_get_frame(p.baseAddress, i.baseAddress)
            }
        }
        return T7ScreenState(pixels: pixels, icons: icons)
    }

    /// Snapshots of the live core's CPU/RAM/DRAM/bank state and its
    /// separate emulated EEPROM (game save) -- only safe to call after
    /// stop(), which blocks until the stepping thread has actually
    /// exited, same reasoning as V1EmulatorEngine's saveState().
    func saveState() -> Data? {
        let needed = ios_t7_save_state(nil, 0)
        var buffer = [UInt8](repeating: 0, count: Int(needed))
        let written = buffer.withUnsafeMutableBufferPointer { buf in
            ios_t7_save_state(buf.baseAddress, UInt32(buf.count))
        }
        guard written > 0 else { return nil }
        return Data(buffer[0..<Int(written)])
    }

    func saveEeprom() -> Data? {
        let needed = ios_t7_eeprom_save(nil, 0)
        guard needed > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(needed))
        let written = buffer.withUnsafeMutableBufferPointer { buf in
            ios_t7_eeprom_save(buf.baseAddress, UInt32(buf.count))
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
        // The core is NOT shut down here: saveState()/saveEeprom() still
        // need it alive (t7_serialize_state returns 0 once released, which
        // silently dropped every save and made each resume a cold boot).
        // Call release() after saving.
    }

    /// Shuts the core down. Call after stop() and after saving.
    func release() {
        ios_t7_stop()
    }

    private func runLoop() {
        let frameNanos: UInt64 = 1_000_000_000 / 60
        var nextDeadlineNanos = DispatchTime.now().uptimeNanoseconds + frameNanos
        var pixels = [UInt8](repeating: 0, count: Int(IOS_T7_LCD_WIDTH * IOS_T7_LCD_HEIGHT))
        var icons = [UInt8](repeating: 0, count: Int(IOS_T7_ICON_COUNT))
        var lastPixels: [UInt8] = []
        var lastIcons: [UInt8] = []
        // nil until the first frame: a call already on when the engine
        // starts doesn't fire again, a new one does (as in V1EmulatorEngine).
        var lastAttentionOn: Bool?

        while true {
            stopLock.lock(); let stop = shouldStop; let fast = fastForward; stopLock.unlock()
            if stop { break }

            var mask = input.currentMask()
            // Tap-an-icon shortcut: while it runs it drives the buttons
            // itself, timed by emulated frames and reading last frame's
            // icons, until the user presses anything.
            let emulatedMicros = UInt32(truncatingIfNeeded: liveFramesStepped &* 16_667)
            navLock.lock(); let request = pendingNav; pendingNav = nil; navLock.unlock()
            if let request { icon_nav_start(&nav, request, UInt8(Self.menuIconCount), emulatedMicros) }
            if icon_nav_active(&nav) {
                if mask != 0 {
                    icon_nav_cancel(&nav)
                } else {
                    var lights: UInt16 = 0
                    for i in 0..<icons.count where icons[i] != 0 { lights |= UInt16(1 << i) }
                    mask = icon_nav_tick(&nav, emulatedMicros, lights)
                }
            }
            if mask != lastButtonMask {
                let changed = mask ^ lastButtonMask
                // InputController's bit order (A=0, B=1, C=2) matches
                // ios_t7_set_button's own (T7_BTN_A/B/C's left-to-right
                // physical layout) -- no remapping needed.
                for bit in 0..<3 where (changed & (1 << bit)) != 0 {
                    ios_t7_set_button(Int32(bit), (mask & (1 << bit)) != 0)
                }
                lastButtonMask = mask
            }

            figureLock.lock(); let figureRequest = pendingFigure; pendingFigure = nil; figureLock.unlock()
            if let figureRequest {
                ios_t7_figure_remove()
                figureToInsert = figureRequest.map { ($0, liveFramesStepped + Self.figureSwapFrames) }
            }
            if let waiting = figureToInsert, liveFramesStepped >= waiting.atFrame {
                Self.insertFigure(waiting.data)
                figureToInsert = nil
            }

            _ = ios_t7_step_frame()
            liveFramesStepped += 1
            if fast {
                _ = ios_t7_step_frame()
                liveFramesStepped += 1
                fastForwardExtraFrames += 1
            }
            audioOutput.tick(buttonsDown: mask != 0)
            // No samples while the audio engine sleeps: they would pile up
            // and play late when it wakes. None while fast-forwarding
            // either: twice the audio per tick can't be played at the
            // right pitch, so it's muted instead of garbled.
            let wantAudio = audioOutput.isEngineWanted && !fast
            if wantAudio != audioCapturing {
                ios_t7_sound_capture(wantAudio)
                audioCapturing = wantAudio
            }

            pixels.withUnsafeMutableBufferPointer { p in
                icons.withUnsafeMutableBufferPointer { i in
                    ios_t7_get_frame(p.baseAddress, i.baseAddress)
                }
            }
            let attentionOn = icons[9] != 0
            if let last = lastAttentionOn, attentionOn, !last {
                onCallDetected?()
            }
            lastAttentionOn = attentionOn

            // Only hand a frame to the UI when it differs from the last one:
            // most frames are identical, and each publish redraws the whole
            // screen bitmap on the main thread (same fix as the color
            // models' FrameStore).
            if pixels != lastPixels || icons != lastIcons {
                lastPixels = pixels
                lastIcons = icons
                let state = T7ScreenState(pixels: pixels, icons: icons)
                let callback = onFrame
                DispatchQueue.main.async {
                    callback?(state)
                }
            }

            let nowNanos = DispatchTime.now().uptimeNanoseconds
            nextDeadlineNanos += frameNanos
            if nextDeadlineNanos > nowNanos {
                Thread.sleep(forTimeInterval: Double(nextDeadlineNanos - nowNanos) / 1_000_000_000)
            } else if nowNanos - nextDeadlineNanos > 250_000_000 {
                // Overran badly (background suspension, a real stall) --
                // same 250ms tolerance CTama's own engine uses. Re-sync the
                // deadline to now instead of trying to catch up live frame
                // by frame; catchUp(_:) below is what absorbs real time
                // spent away, not this loop.
                nextDeadlineNanos = nowNanos + frameNanos
            }
        }
    }
}

extension T7EmulatorEngine {
    /// Only between start and stepping, or on the stepping thread.
    fileprivate static func insertFigure(_ figure: Data) {
        _ = figure.withUnsafeBytes { raw in
            ios_t7_figure_insert(raw.bindMemory(to: UInt8.self).baseAddress, UInt32(figure.count))
        }
    }

    /// Advances a saved state by up to `backlogSeconds` of emulated time
    /// (time the app was closed), within `wallClockBudget` real seconds --
    /// same contract as the other two engines' own catch-up. Simpler than
    /// both: `ios_t7_step_frame()` already runs unpaced (nothing to fake a
    /// clock for, unlike TamaLib), so this just calls it back-to-back as
    /// fast as the budget allows, same shape as CTama's own catchUp(seconds:).
    /// Returns the state+EEPROM to actually resume from -- unchanged if
    /// there was nothing to catch up, or as far as it got if the budget
    /// ran out first. EEPROM is returned alongside state (not just state)
    /// because the catch-up itself can write new save data (stat changes,
    /// growth) that needs persisting too, not only CPU/RAM progress.
    ///
    /// `advancedSeconds` is how much emulated time it actually got
    /// through -- callers move `lastSavedAt` forward by exactly that, so
    /// whatever the budget didn't reach stays owed instead of being
    /// forgotten (see V1EmulatorEngine.catchUp's own doc comment).
    /// `shouldAbort` is polled between batches of frames.
    static func catchUp(
        romData: Data,
        eepromData: Data?,
        from stateData: Data,
        figure: Data? = nil,
        backlogSeconds: TimeInterval,
        wallClockBudget: TimeInterval,
        shouldAbort: (() -> Bool)? = nil,
        onCallDetected: (() -> Void)? = nil
    ) -> (state: Data, eeprom: Data?, advancedSeconds: TimeInterval) {
        guard backlogSeconds >= 1.0 / 60 else { return (stateData, eepromData, 0) }

        let started = romData.withUnsafeBytes { raw in
            ios_t7_start(raw.bindMemory(to: UInt8.self).baseAddress, UInt32(romData.count))
        }
        guard started else { return (stateData, eepromData, 0) }
        defer { ios_t7_stop() }

        if let eepromData {
            _ = eepromData.withUnsafeBytes { raw in
                ios_t7_eeprom_load(raw.bindMemory(to: UInt8.self).baseAddress, UInt32(eepromData.count))
            }
        }
        let loaded = stateData.withUnsafeBytes { raw in
            ios_t7_load_state(raw.bindMemory(to: UInt8.self).baseAddress, UInt32(stateData.count))
        }
        guard loaded else { return (stateData, eepromData, 0) }
        // Time away passes with the figure still plugged in.
        if let figure { insertFigure(figure) }

        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, wallClockBudget) * 1_000_000_000)
        // Rounded down: a leftover fraction of a frame stays owed and is
        // picked up next time, rather than being rounded away each pass.
        let targetFrames = Int(backlogSeconds * 60)
        var frame = 0
        var lastAttentionOn: Bool?
        while frame < targetFrames {
            _ = ios_t7_step_frame()
            frame += 1
            // A call stays lit for minutes, so twice a second can't miss one.
            if onCallDetected != nil, frame % 30 == 0 {
                let attentionOn = ios_t7_attention_on()
                if let last = lastAttentionOn, attentionOn, !last {
                    onCallDetected?()
                }
                lastAttentionOn = attentionOn
            }
            if frame % 16 == 0,
               DispatchTime.now().uptimeNanoseconds >= deadline || shouldAbort?() == true {
                break
            }
        }

        let neededState = ios_t7_save_state(nil, 0)
        var stateBuffer = [UInt8](repeating: 0, count: Int(neededState))
        let writtenState = stateBuffer.withUnsafeMutableBufferPointer { buf in
            ios_t7_save_state(buf.baseAddress, UInt32(buf.count))
        }
        guard writtenState > 0 else { return (stateData, eepromData, 0) }

        let neededEeprom = ios_t7_eeprom_save(nil, 0)
        var eepromBuffer = [UInt8](repeating: 0, count: Int(neededEeprom))
        let writtenEeprom = eepromBuffer.withUnsafeMutableBufferPointer { buf in
            ios_t7_eeprom_save(buf.baseAddress, UInt32(buf.count))
        }

        return (
            Data(stateBuffer[0..<Int(writtenState)]),
            writtenEeprom > 0 ? Data(eepromBuffer[0..<Int(writtenEeprom)]) : eepromData,
            Double(frame) / 60
        )
    }
}
