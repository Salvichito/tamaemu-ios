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
    /// cover every ROM except the Tamaotch and Yasashii; the Tamaotch (measured headless
    /// 2026-11-24, with its program timer at the right speed) drops presses
    /// under ~0.15 s and presses that follow the last one within ~0.3 s;
    /// V1EmulatorEngine raises both for that model before it starts.
    private var minHoldMs: Int64 = 60
    private var gapMs: Int64 = 25
    /// Per-button minimum hold that overrides minHoldMs (see setTiming).
    private var holdOverrideMs: [Button: Int64] = [:]
    func setTiming(minimumHoldMs: Int64, minimumGapMs: Int64, holdOverrides: [Button: Int64] = [:]) {
        lock.lock(); defer { lock.unlock() }
        minHoldMs = minimumHoldMs
        gapMs = minimumGapMs
        holdOverrideMs = holdOverrides
    }
    private func minHold(_ i: Int) -> Int64 {
        Button(rawValue: i).flatMap { holdOverrideMs[$0] } ?? minHoldMs
    }
    private let maxQueued = 2

    /// "Hold until it beeps" buttons (Yasashii only, see V1EmulatorEngine):
    /// instead of a fixed minimum, the press is held until the firmware
    /// beeps to say it took it (acknowledge()), at least ackFloorMs and at
    /// most ackCapMs. Measured headless 2026-11-25: awake, the Yasashii
    /// can take anywhere from ~0.15 s to ~1 s to beep depending on where
    /// in its own cycle the press lands, so any fixed hold short enough to
    /// feel like a tap lost some presses.
    private var ackButtons: UInt8 = 0
    private var ackFloorMs: Int64 = 0
    private var ackCapMs: Int64 = 0
    private var ackStartMs = [Int64](repeating: 0, count: Button.allCases.count)
    private var awaitingAck: UInt8 = 0
    func setAckHold(buttons: Set<Button>, floorMs: Int64, capMs: Int64) {
        lock.lock(); defer { lock.unlock() }
        ackButtons = buttons.reduce(0) { $0 | UInt8(1 << $1.rawValue) }
        ackFloorMs = floorMs
        ackCapMs = capMs
        awaitingAck = 0
    }
    /// The firmware just started a beep: every press still waiting for one
    /// ends at its floor (or now, if that's already past).
    func acknowledge() {
        lock.lock(); defer { lock.unlock() }
        guard awaitingAck != 0 else { return }
        let now = Self.nowMs()
        for i in 0..<Button.allCases.count where (awaitingAck & (1 << i)) != 0 {
            holdUntilMs[i] = max(ackStartMs[i] + ackFloorMs, now)
        }
        awaitingAck = 0
    }
    /// Starts the firmware-side hold of button i at `now`.
    private func beginHold(_ i: Int, now: Int64) {
        if (ackButtons & (1 << i)) != 0 {
            holdUntilMs[i] = now + ackCapMs
            ackStartMs[i] = now
            awaitingAck |= UInt8(1 << i)
        } else {
            holdUntilMs[i] = now + minHold(i)
        }
    }

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
            beginHold(i, now: now)
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
            } else if queued[i] > 0 && (mask & (1 << i)) == 0 && (lastMask & (1 << i)) == 0
                        && now >= upAtMs[i] + gapMs {
                // lastMask: the firmware must have seen this button go up
                // (which is what sets upAtMs) before a queued tap starts.
                // Without it, a queued tap began the instant the previous
                // hold ended, so the firmware saw one unbroken press --
                // found 2026-11-25 from a log: four quick taps on the
                // Yasashii happiness button became one 5.5 s hold, which
                // the toy ignored.
                queued[i] -= 1
                beginHold(i, now: now)
                mask |= UInt8(1 << i)
            }
        }
        let wentUp = lastMask & ~mask
        awaitingAck &= mask
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
