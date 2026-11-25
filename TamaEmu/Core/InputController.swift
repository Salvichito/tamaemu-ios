import Foundation

/// Debounces on-screen button presses against the emulated firmware's own
/// polling rate. The firmware polls buttons only every few ms to ~200ms
/// depending on screen, so a press/release shorter than one poll interval
/// can be dropped, and two taps closer together than that can fuse into one
/// long press as the firmware sees it. Mirrors the Android port's proven
/// mitigation: hold each press for a minimum duration, and queue (rather
/// than merge) a follow-up tap that arrives while still holding the last one.
final class InputController: @unchecked Sendable {
    enum Button: Int, CaseIterable {
        case a = 0, b = 1, c = 2
        /// First-gen (TamaLib) core only: the tap-sensor pin and the
        /// K10-K13 pins, same numbering as ios_hal_set_button. Only the
        /// Yasashii has buttons on these (lights, then toilet, affection,
        /// happiness, meal); the other engines never receive them.
        case tap = 3, k10 = 4, k11 = 5, k12 = 6, k13 = 7
    }

    /// Shortest press the firmware is shown however quick the tap, and the
    /// shortest release it sees between two taps of the same button. 60/25 ms
    /// cover every ROM except the Tamaotch, which (measured headless
    /// 2026-11-24, with its program timer at the right speed) drops presses
    /// under ~0.15 s and presses that follow the last one within ~0.3 s;
    /// V1EmulatorEngine raises both for that model before it starts.
    private var minHoldMs: Int64 = 60
    private var gapMs: Int64 = 25
    func setTiming(minimumHoldMs: Int64, minimumGapMs: Int64) {
        lock.lock(); defer { lock.unlock() }
        minHoldMs = minimumHoldMs
        gapMs = minimumGapMs
    }
    private let maxQueued = 2

    private let lock = NSLock()
    private var held: UInt8 = 0
    private var holdUntilMs = [Int64](repeating: 0, count: Button.allCases.count)
    private var queued = [Int](repeating: 0, count: Button.allCases.count)
    /// When the firmware last saw each button go up, for gapMs.
    private var upAtMs = [Int64](repeating: 0, count: Button.allCases.count)
    private var lastMask: UInt8 = 0

    /// Call once when a button is physically pressed down.
    func press(_ button: Button) {
        lock.lock(); defer { lock.unlock() }
        let now = Self.nowMs()
        let i = button.rawValue
        if holdUntilMs[i] > now || now < upAtMs[i] + gapMs {
            queued[i] = min(queued[i] + 1, maxQueued)
        } else {
            held |= UInt8(1 << i)
            holdUntilMs[i] = now + minHoldMs
        }
    }

    /// Call once when a button is physically released.
    func release(_ button: Button) {
        lock.lock(); defer { lock.unlock() }
        held &= ~UInt8(1 << button.rawValue)
    }

    /// Called every emulated frame, right alongside periph_tick, to compute
    /// the mask the firmware should currently see (bit0=A bit1=B bit2=C,
    /// bits 3-7 the extra first-gen pins above).
    func currentMask() -> UInt8 {
        lock.lock(); defer { lock.unlock() }
        let now = Self.nowMs()
        var mask = held
        for i in 0..<Button.allCases.count {
            if holdUntilMs[i] > now {
                mask |= UInt8(1 << i)
            } else if queued[i] > 0 && (mask & (1 << i)) == 0 && now >= upAtMs[i] + gapMs {
                queued[i] -= 1
                holdUntilMs[i] = now + minHoldMs
                mask |= UInt8(1 << i)
            }
        }
        let wentUp = lastMask & ~mask
        if wentUp != 0 {
            for i in 0..<Button.allCases.count where (wentUp & (1 << i)) != 0 {
                upAtMs[i] = now
            }
        }
        lastMask = mask
        return mask
    }

    private static func nowMs() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }
}
