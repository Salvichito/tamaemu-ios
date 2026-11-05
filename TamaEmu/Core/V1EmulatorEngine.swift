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

    private(set) var onFrame: ((P1ScreenState) -> Void)?

    private lazy var audioOutput = AudioOutput(
        toneProvider: {
            (ios_hal_tone_on(), Float(ios_hal_tone_freq_dhz()) / 10)
        },
        volumeProvider: {
            Float(AppSettings.volume)
        }
    )

    init(onFrame: @escaping (P1ScreenState) -> Void) {
        self.onFrame = onFrame
    }

    /// romData is a raw P1 ROM dump: 12-bit words stored as big-endian
    /// byte pairs (confirmed against a real TamagotchiP1.bin -- see the
    /// integration-research memory). Returns false if the core failed to
    /// start.
    @discardableResult
    func start(romData: Data) -> Bool {
        guard thread == nil else { return true }

        var words = [UInt16]()
        words.reserveCapacity(romData.count / 2)
        var iterator = romData.makeIterator()
        while let hi = iterator.next(), let lo = iterator.next() {
            words.append((UInt16(hi) << 8) | UInt16(lo))
        }

        let started = words.withUnsafeBufferPointer { buf in
            ios_hal_start(buf.baseAddress, UInt32(buf.count))
        }
        guard started == 0 else { return false }

        lastButtonMask = 0
        stopLock.lock(); shouldStop = false; stopLock.unlock()
        let t = Thread { [weak self] in self?.runLoop() }
        t.name = "V1EmulatorEngine"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
        audioOutput.start()
        return true
    }

    func stop() {
        guard thread != nil else { return }
        stopLock.lock(); shouldStop = true; stopLock.unlock()
        thread = nil
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

            let now = Date()
            guard now.timeIntervalSince(lastPublish) >= 1.0 / 30.0 else { continue }
            lastPublish = now

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

            let state = P1ScreenState(bits: bits, icons: icons)
            let callback = onFrame
            DispatchQueue.main.async {
                callback?(state)
            }
        }
    }
}
