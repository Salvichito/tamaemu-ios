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
    }

    private let minHoldMs: Int64 = 60
    private let gapMs: Int64 = 25
    private let maxQueued = 2

    private let lock = NSLock()
    private var held: UInt8 = 0
    private var holdUntilMs: [Int64] = [0, 0, 0]
    private var queued: [Int] = [0, 0, 0]

    /// Call once when a button is physically pressed down.
    func press(_ button: Button) {
        lock.lock(); defer { lock.unlock() }
        let now = Self.nowMs()
        let i = button.rawValue
        if holdUntilMs[i] > now {
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
    /// the mask the firmware should currently see (bit0=A bit1=B bit2=C).
    func currentMask() -> UInt8 {
        lock.lock(); defer { lock.unlock() }
        let now = Self.nowMs()
        var mask = held
        for i in 0..<3 {
            if holdUntilMs[i] > now {
                mask |= UInt8(1 << i)
            } else if queued[i] > 0 && now >= holdUntilMs[i] + gapMs {
                queued[i] -= 1
                holdUntilMs[i] = now + minHoldMs
                mask |= UInt8(1 << i)
            }
        }
        return mask
    }

    private static func nowMs() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }
}
