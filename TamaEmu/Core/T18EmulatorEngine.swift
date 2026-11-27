import AVFoundation
import CoreGraphics
import CT18Emu
import Foundation

/// A Tamagotchi Meets / On (T18Emu) screen: the 128x128 color picture the
/// game last finished, and how bright its light was. `seq` goes up with
/// every new picture, so equal screens compare cheaply.
struct T18ScreenState: Equatable {
    var pixels: [UInt16] // RGB565, row-major
    var backlight: Int // 0...255; 0 = the toy switched its screen off
    var seq: UInt32

    static let side = Int(IOS_T18_LCD_WIDTH)
    static let blank = T18ScreenState(pixels: Array(repeating: 0, count: side * side), backlight: 0, seq: 0)

    static func == (a: T18ScreenState, b: T18ScreenState) -> Bool {
        a.seq == b.seq && a.backlight == b.backlight
    }

    /// The picture as a 128x128 image, dimmed by the backlight like the
    /// real screen (dark when the toy has switched it off).
    func makeImage() -> CGImage? {
        let side = Self.side
        // The game's own light levels: full is about 127 of 255. Below that
        // the screen dims; at 0 it's off and shows black.
        let light = backlight <= 0 ? 0.0 : min(1.0, 0.25 + 0.75 * Double(backlight) / 127.0)
        var rgba = [UInt8](repeating: 255, count: side * side * 4)
        let scale = Int(light * 256)
        for i in 0..<(side * side) {
            let v = Int(pixels[i])
            let r = ((v >> 11) & 0x1F) * 255 / 31
            let g = ((v >> 5) & 0x3F) * 255 / 63
            let b = (v & 0x1F) * 255 / 31
            rgba[i * 4] = UInt8(r * scale >> 8)
            rgba[i * 4 + 1] = UInt8(g * scale >> 8)
            rgba[i * 4 + 2] = UInt8(b * scale >> 8)
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

/// Driver for the T18Emu core (Tamagotchi Meets / On): steps it at a real
/// 60 Hz cadence, forwards button input and plays its buzzer. Same shape
/// as T7EmulatorEngine. The core keeps its memory in C globals, so there
/// is one per process: callers hold this family's EngineGate.
///
/// Unlike the other families, the game writes its own save into its flash
/// (like the real toy), so a save is two files: the written flash sectors
/// (the game's save, what survives a "battery change") and the session
/// (CPU, chip and SRAM, to resume mid-moment).
final class T18EmulatorEngine {
    let input = InputController()

    private var thread: Thread?
    private let stopLock = NSLock()
    private var shouldStop = false
    private let stoppedSemaphore = DispatchSemaphore(value: 0)

    private(set) var onFrame: ((T18ScreenState) -> Void)?
    private(set) var onCallDetected: (() -> Void)?

    /// Emulated 1/60 s frames the live loop stepped since start(). Written
    /// only by the stepping thread; read only after stop().
    private var liveFramesStepped: UInt64 = 0
    var liveSecondsAdvanced: TimeInterval { Double(liveFramesStepped) / 60 }

    private var fastForward = false
    private var fastForwardExtraFrames: UInt64 = 0
    var fastForwardExtraSeconds: TimeInterval { Double(fastForwardExtraFrames) / 60 }

    func setFastForward(_ on: Bool) {
        stopLock.lock(); fastForward = on; stopLock.unlock()
    }

    private let pointsLock = NSLock()
    private var pendingPoints: Int?
    /// Gotchi Points (the game's Param block, +0x20). Applied by the
    /// stepping thread between frames. Safe from any thread.
    func setPoints(_ value: Int) {
        pointsLock.lock(); pendingPoints = max(0, min(65535, value)); pointsLock.unlock()
    }

    /// The core's own 1 ms sound timeline (ios_t18_compat.c), rendered as a
    /// square wave: menu beeps are ~32 ms and melody notes ~40 ms, too short
    /// for a per-frame poll. toneProvider only says whether anything is
    /// playing, so the audio engine can sleep while the Tama is quiet.
    private lazy var audioOutput = AudioOutput(
        toneProvider: { (ios_t18_sound_busy(), 0) },
        volumeProvider: { Float(AppSettings.playbackVolume) },
        pcmProvider: { out, count, restarted in
            if restarted { ios_t18_sound_skip_to(T18EmulatorEngine.audioTargetSamples) }
            _ = ios_t18_sound_pull(out, UInt32(count), T18EmulatorEngine.audioTargetSamples)
        }
    )
    private static let audioTargetSamples: UInt32 = 1920
    private var audioCapturing = false

    var audioFormat: AVAudioFormat { audioOutput.outputFormat }

    func installRecordingTap(format: AVAudioFormat, bufferSize: AVAudioFrameCount, block: @escaping AVAudioNodeTapBlock) {
        audioOutput.installRecordingTap(format: format, bufferSize: bufferSize, block: block)
    }

    func removeRecordingTap() {
        audioOutput.removeRecordingTap()
    }

    init(onFrame: @escaping (T18ScreenState) -> Void, onCallDetected: (() -> Void)? = nil) {
        self.onFrame = onFrame
        self.onCallDetected = onCallDetected
    }

    /// romData: the user's 8 MB Meets/On firmware. flashData: the game's
    /// own save (written sectors); stateData: the session. With no session
    /// the game boots from its flash save, like the toy after a battery
    /// change (CONTINUE / RESET ALL), and the battery clock is set to now.
    /// `setClockTo` jumps a resumed session's clock (Sync Clock to Now).
    @discardableResult
    func start(romData: Data, flashData: Data?, stateData: Data?, setClockTo clockTime: Date? = nil) -> Bool {
        guard thread == nil else { return true }
        guard Self.boot(romData: romData, flashData: flashData, stateData: stateData) else { return false }
        if let clockTime { Self.setClock(clockTime) }

        // Sound only for live play: catch-up runs without it, faster.
        ios_t18_sound_live(true, UInt32(audioOutput.outputFormat.sampleRate.rounded()))
        audioCapturing = true

        liveFramesStepped = 0
        fastForwardExtraFrames = 0
        stopLock.lock(); shouldStop = false; fastForward = false; stopLock.unlock()
        let t = Thread { [weak self] in
            self?.runLoop()
            self?.stoppedSemaphore.signal()
        }
        t.name = "T18EmulatorEngine"
        t.qualityOfService = .userInitiated
        thread = t
        // Before the thread: audioOutput is lazy, see T7EmulatorEngine.
        audioOutput.start()
        t.start()
        return true
    }

    /// Starts the core and loads a save into it. Caller holds the gate.
    fileprivate static func boot(romData: Data, flashData: Data?, stateData: Data?) -> Bool {
        let started = romData.withUnsafeBytes { raw in
            ios_t18_start(raw.bindMemory(to: UInt8.self).baseAddress, UInt32(romData.count))
        }
        guard started else { return false }
        if let flashData {
            _ = flashData.withUnsafeBytes { raw in
                ios_t18_flash_load(raw.bindMemory(to: UInt8.self).baseAddress, UInt32(flashData.count))
            }
        }
        var resumed = false
        if let stateData {
            resumed = stateData.withUnsafeBytes { raw in
                ios_t18_load_state(raw.bindMemory(to: UInt8.self).baseAddress, UInt32(stateData.count))
            }
        }
        // A cold boot: the battery clock is part of the session, so it
        // starts at the real time (the toy's own setup screen still asks).
        if !resumed { setClock(Date()) }
        return true
    }

    fileprivate static func setClock(_ date: Date) {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        ios_t18_set_time(
            Int32(c.year ?? 2026), Int32(c.month ?? 1), Int32(c.day ?? 1),
            Int32(c.hour ?? 0), Int32(c.minute ?? 0), Int32(c.second ?? 0)
        )
    }

    /// What a saved Tama's screen was showing, without running it (a
    /// paused Tama, the widget). The caller holds this family's gate.
    static func peekScreen(romData: Data, flashData: Data?, state: Data) -> T18ScreenState? {
        guard boot(romData: romData, flashData: flashData, stateData: state) else { return nil }
        defer { ios_t18_stop() }
        return currentScreen()
    }

    fileprivate static func currentScreen() -> T18ScreenState {
        var pixels = [UInt16](repeating: 0, count: T18ScreenState.side * T18ScreenState.side)
        let seq = pixels.withUnsafeMutableBufferPointer { ios_t18_get_frame($0.baseAddress) }
        return T18ScreenState(pixels: pixels, backlight: Int(ios_t18_backlight()), seq: seq)
    }

    fileprivate static func saveStateNow() -> Data? {
        let needed = ios_t18_save_state(nil, 0)
        guard needed > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(needed))
        let written = buffer.withUnsafeMutableBufferPointer { ios_t18_save_state($0.baseAddress, UInt32($0.count)) }
        return written > 0 ? Data(buffer[0..<Int(written)]) : nil
    }

    fileprivate static func saveFlashNow() -> Data? {
        let needed = ios_t18_flash_save(nil, 0)
        guard needed > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(needed))
        let written = buffer.withUnsafeMutableBufferPointer { ios_t18_flash_save($0.baseAddress, UInt32($0.count)) }
        return written > 0 ? Data(buffer[0..<Int(written)]) : nil
    }

    /// Only after stop(), which joins the stepping thread.
    func saveState() -> Data? { Self.saveStateNow() }
    func saveFlash() -> Data? { Self.saveFlashNow() }

    func stop() {
        guard thread != nil else { return }
        stopLock.lock(); shouldStop = true; stopLock.unlock()
        thread = nil
        stoppedSemaphore.wait()
        audioOutput.stop()
        // Not shut down here: saving still needs the core. Call release().
    }

    /// Shuts the core down. Call after stop() and after saving.
    func release() {
        ios_t18_sound_live(false, 0)
        ios_t18_stop()
    }

    private func runLoop() {
        let frameNanos: UInt64 = 1_000_000_000 / 60
        var nextDeadlineNanos = DispatchTime.now().uptimeNanoseconds + frameNanos
        var lastMask: UInt8 = 0
        var lastSeq: UInt32 = .max
        var lastBacklight = -1
        var lastAttention: Bool?
        var pixels = [UInt16](repeating: 0, count: T18ScreenState.side * T18ScreenState.side)

        while true {
            stopLock.lock(); let stop = shouldStop; let fast = fastForward; stopLock.unlock()
            if stop { break }

            let mask = input.currentMask()
            if mask != lastMask {
                // InputController's bits (A=0, B=1, C=2) are the core's.
                ios_t18_set_buttons(Int32(mask))
                lastMask = mask
            }
            pointsLock.lock(); let points = pendingPoints; pendingPoints = nil; pointsLock.unlock()
            if let points { _ = ios_t18_set_points(Int32(points)) }

            ios_t18_run_us(16_667)
            liveFramesStepped += 1
            if fast {
                ios_t18_run_us(16_667)
                liveFramesStepped += 1
                fastForwardExtraFrames += 1
            }
            audioOutput.tick(buttonsDown: mask != 0)
            let wantAudio = audioOutput.isEngineWanted && !fast
            if wantAudio != audioCapturing {
                ios_t18_sound_capture(wantAudio)
                audioCapturing = wantAudio
            }

            // A call: twice a second is plenty (it stays on for minutes).
            if liveFramesStepped % 30 == 0 {
                let attention = ios_t18_attention()
                if let last = lastAttention, attention, !last { onCallDetected?() }
                lastAttention = attention
            }

            // Only hand the UI a new picture, or a change of light.
            let seq = ios_t18_get_frame(nil)
            let backlight = Int(ios_t18_backlight())
            if seq != lastSeq || backlight != lastBacklight {
                lastSeq = seq
                lastBacklight = backlight
                _ = pixels.withUnsafeMutableBufferPointer { ios_t18_get_frame($0.baseAddress) }
                let state = T18ScreenState(pixels: pixels, backlight: backlight, seq: seq)
                let callback = onFrame
                DispatchQueue.main.async { callback?(state) }
            }

            let nowNanos = DispatchTime.now().uptimeNanoseconds
            nextDeadlineNanos += frameNanos
            if nextDeadlineNanos > nowNanos {
                Thread.sleep(forTimeInterval: Double(nextDeadlineNanos - nowNanos) / 1_000_000_000)
            } else if nowNanos - nextDeadlineNanos > 250_000_000 {
                nextDeadlineNanos = nowNanos + frameNanos
            }
        }
    }
}

extension T18EmulatorEngine {
    /// Advances a saved Tama by up to `backlogSeconds` of emulated time
    /// (time the app was closed) within `wallClockBudget` real seconds.
    /// Same contract as T7EmulatorEngine.catchUp. Cheap while the toy has
    /// switched itself off (most of the time away): the core then only
    /// wakes for the game's once-a-minute alarm.
    static func catchUp(
        romData: Data,
        flashData: Data?,
        from stateData: Data,
        backlogSeconds: TimeInterval,
        wallClockBudget: TimeInterval,
        shouldAbort: (() -> Bool)? = nil,
        onCallDetected: (() -> Void)? = nil
    ) -> (state: Data, flash: Data?, advancedSeconds: TimeInterval) {
        guard backlogSeconds >= 0.1 else { return (stateData, flashData, 0) }
        guard boot(romData: romData, flashData: flashData, stateData: stateData) else { return (stateData, flashData, 0) }
        defer { ios_t18_stop() }

        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, wallClockBudget) * 1_000_000_000)
        // In 0.5 s steps; a leftover fraction stays owed for next time.
        let stepMicros: UInt32 = 500_000
        let steps = Int(backlogSeconds * 2)
        var done = 0
        var lastAttention: Bool?
        while done < steps {
            ios_t18_run_us(stepMicros)
            done += 1
            if onCallDetected != nil {
                let attention = ios_t18_attention()
                if let last = lastAttention, attention, !last { onCallDetected?() }
                lastAttention = attention
            }
            if done % 8 == 0, DispatchTime.now().uptimeNanoseconds >= deadline || shouldAbort?() == true {
                break
            }
        }
        guard let state = saveStateNow() else { return (stateData, flashData, 0) }
        return (state, saveFlashNow() ?? flashData, Double(done) / 2)
    }
}
