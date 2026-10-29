import Foundation

/// Detects the Tamagotchi's "calling for attention" melody: a two-note
/// sequence (roughly 1396 Hz then 1174 Hz, within 0.5s of each other) on
/// the piezo tone. Ported from the Android reference's melody-edge check
/// in `native-emu.c`. That reference also cross-checks a per-device PC
/// "counter" hook, but only to pick which string to log — it does not
/// gate whether a call is raised, so it's not ported here.
final class CallDetector {
    private enum Step {
        case waitingForFirstNote
        case waitingForSecondNote(since: Double)
    }

    private let firstNoteRange: ClosedRange<Float> = 1330...1460
    private let secondNoteRange: ClosedRange<Float> = 1120...1230
    private let secondNoteWindow: Double = 0.5
    /// Matches the Android reference's call_raise() debounce: don't
    /// re-raise the same still-ongoing, unanswered call every time its
    /// melody loops.
    private let debounce: Double = 2.0

    private var step: Step = .waitingForFirstNote
    private var toneWasOn = false
    private var lastRaisedAt: Double?

    /// Call once per emulated step with the current tone state. Returns
    /// true exactly when a *new* call should be raised.
    func checkToneEdge(toneOn: Bool, toneFreq: Float, emuSecs: Double) -> Bool {
        defer { toneWasOn = toneOn }
        guard toneOn, !toneWasOn else { return false }

        switch step {
        case .waitingForFirstNote:
            if firstNoteRange.contains(toneFreq) {
                step = .waitingForSecondNote(since: emuSecs)
            }
            return false

        case .waitingForSecondNote(let since):
            if emuSecs - since >= secondNoteWindow {
                // Timed out — matches the Android reference exactly: this
                // resets to waiting for a first note, it does not try to
                // treat the current (timed-out) edge as a fresh first note.
                step = .waitingForFirstNote
                return false
            }
            guard secondNoteRange.contains(toneFreq) else {
                return false // still within the window, wrong note — keep waiting
            }
            step = .waitingForFirstNote
            if let lastRaisedAt, emuSecs - lastRaisedAt < debounce {
                return false
            }
            lastRaisedAt = emuSecs
            return true
        }
    }
}
