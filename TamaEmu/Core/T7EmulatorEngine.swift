import AVFoundation
import CT7Emu
import Foundation

/// A Tama-Go / Tamagotchi Friends (T7Emu) screen snapshot: 48x31 pixels at
/// 4 grayscale levels, plus 10 fixed status icons. Row-major, matching
/// `ios_t7_get_frame`'s layout (see ios_t7.h for the confirmed icon order).
struct T7ScreenState {
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
/// No call-detection wiring yet (unlike the other two engines' onCallDetected):
/// T7Emu's 10 status icons don't have a confirmed "needs attention"
/// equivalent to TamaLib's icon 7 the way the P1 integration verified
/// against two independent sources -- better to ship nothing than guess.
final class T7EmulatorEngine {
    let input = InputController()

    private var thread: Thread?
    private let stopLock = NSLock()
    private var shouldStop = false
    private var lastButtonMask: UInt8 = 0
    private let stoppedSemaphore = DispatchSemaphore(value: 0)

    private(set) var onFrame: ((T7ScreenState) -> Void)?

    private lazy var audioOutput = AudioOutput(
        toneProvider: {
            (ios_t7_tone_on(), Float(ios_t7_tone_freq_hz()))
        },
        volumeProvider: {
            Float(AppSettings.volume)
        }
    )

    init(onFrame: @escaping (T7ScreenState) -> Void) {
        self.onFrame = onFrame
    }

    /// romData is a raw Tama-Go (640 KB) or Tamagotchi Friends (768 KB)
    /// flash dump. eepromData/stateData, if given, are loaded right after
    /// the core boots fresh from romData, before any stepping -- eeprom
    /// first, so the CPU/RAM state (which may be mid-read of the EEPROM)
    /// resumes with the right data already in place. Returns false if the
    /// core failed to start.
    @discardableResult
    func start(romData: Data, eepromData: Data? = nil, stateData: Data? = nil) -> Bool {
        guard thread == nil else { return true }

        let started = romData.withUnsafeBytes { raw in
            ios_t7_start(raw.bindMemory(to: UInt8.self).baseAddress, UInt32(romData.count))
        }
        guard started else { return false }

        if let eepromData {
            _ = eepromData.withUnsafeBytes { raw in
                ios_t7_eeprom_load(raw.bindMemory(to: UInt8.self).baseAddress, UInt32(eepromData.count))
            }
        }
        if let stateData {
            _ = stateData.withUnsafeBytes { raw in
                ios_t7_load_state(raw.bindMemory(to: UInt8.self).baseAddress, UInt32(stateData.count))
            }
        }

        lastButtonMask = 0
        stopLock.lock(); shouldStop = false; stopLock.unlock()
        let t = Thread { [weak self] in
            self?.runLoop()
            self?.stoppedSemaphore.signal()
        }
        t.name = "T7EmulatorEngine"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
        audioOutput.start()
        return true
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
        ios_t7_stop()
    }

    private func runLoop() {
        let frameNanos: UInt64 = 1_000_000_000 / 60
        var nextDeadlineNanos = DispatchTime.now().uptimeNanoseconds + frameNanos
        var pixels = [UInt8](repeating: 0, count: Int(IOS_T7_LCD_WIDTH * IOS_T7_LCD_HEIGHT))
        var icons = [UInt8](repeating: 0, count: Int(IOS_T7_ICON_COUNT))

        while true {
            stopLock.lock(); let stop = shouldStop; stopLock.unlock()
            if stop { break }

            let mask = input.currentMask()
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

            _ = ios_t7_step_frame()

            pixels.withUnsafeMutableBufferPointer { p in
                icons.withUnsafeMutableBufferPointer { i in
                    ios_t7_get_frame(p.baseAddress, i.baseAddress)
                }
            }
            let state = T7ScreenState(pixels: pixels, icons: icons)
            let callback = onFrame
            DispatchQueue.main.async {
                callback?(state)
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
    static func catchUp(
        romData: Data,
        eepromData: Data?,
        from stateData: Data,
        backlogSeconds: TimeInterval,
        wallClockBudget: TimeInterval
    ) -> (state: Data, eeprom: Data?) {
        guard backlogSeconds > 1 else { return (stateData, eepromData) }

        let started = romData.withUnsafeBytes { raw in
            ios_t7_start(raw.bindMemory(to: UInt8.self).baseAddress, UInt32(romData.count))
        }
        guard started else { return (stateData, eepromData) }
        defer { ios_t7_stop() }

        if let eepromData {
            _ = eepromData.withUnsafeBytes { raw in
                ios_t7_eeprom_load(raw.bindMemory(to: UInt8.self).baseAddress, UInt32(eepromData.count))
            }
        }
        let loaded = stateData.withUnsafeBytes { raw in
            ios_t7_load_state(raw.bindMemory(to: UInt8.self).baseAddress, UInt32(stateData.count))
        }
        guard loaded else { return (stateData, eepromData) }

        let deadline = Date().addingTimeInterval(wallClockBudget)
        let targetFrames = Int((backlogSeconds * 60).rounded())
        var frame = 0
        while frame < targetFrames, Date() < deadline {
            _ = ios_t7_step_frame()
            frame += 1
        }

        let neededState = ios_t7_save_state(nil, 0)
        var stateBuffer = [UInt8](repeating: 0, count: Int(neededState))
        let writtenState = stateBuffer.withUnsafeMutableBufferPointer { buf in
            ios_t7_save_state(buf.baseAddress, UInt32(buf.count))
        }
        guard writtenState > 0 else { return (stateData, eepromData) }

        let neededEeprom = ios_t7_eeprom_save(nil, 0)
        var eepromBuffer = [UInt8](repeating: 0, count: Int(neededEeprom))
        let writtenEeprom = eepromBuffer.withUnsafeMutableBufferPointer { buf in
            ios_t7_eeprom_save(buf.baseAddress, UInt32(buf.count))
        }

        return (
            Data(stateBuffer[0..<Int(writtenState)]),
            writtenEeprom > 0 ? Data(eepromBuffer[0..<Int(writtenEeprom)]) : eepromData
        )
    }
}
