import Foundation

/// The "infrared window" between one running Tama and whatever carries its
/// signal to another Tama (today: NearbyLinkSession). The emulator thread
/// sits on one side, the network on the other, so all state is behind a
/// lock.
///
/// What travels through is the core's own link traffic, unchanged: for the
/// Plus Color that is a run of 4-byte "the light was on for this long,
/// after this long a pause" events.
///
/// ## Why the two Tamas step together while they talk
///
/// That signal is nothing but timing. The receiving Tama plays each step
/// back the moment the previous one ends, so a piece that arrives late
/// stretches a pause and makes the whole packet unreadable; and the Tamas
/// give up if an answer takes much more than a twelfth of a second. A
/// real wireless link is neither steady nor that fast, so no amount of
/// buffering satisfies both.
///
/// The way out is that these are emulated Tamas, so their sense of time
/// is ours to control. While a conversation is going on, the two advance
/// frame by frame *together*:
///
/// - each sends one message per frame of its own time (1/60 s), holding
///   whatever it transmitted in that frame, even if that is nothing;
/// - each plays exactly one of the other's frames per frame of its own,
///   and holds still if the next one hasn't arrived;
/// - neither runs more than a few frames ahead of what the other has
///   confirmed playing.
///
/// Measured in the Tamas' own time the delay between them is therefore
/// always the same few frames, however slow or uneven the network is. A
/// slow link doesn't garble anything; it just makes both Tamas run a
/// little slower for the couple of seconds the exchange takes.
///
/// Outside a conversation nothing is sent at all and the Tama runs
/// normally, so staying paired costs no speed and no radio traffic.
final class LinkPort: @unchecked Sendable {
    private let lock = NSLock()
    private var sendHandler: (@Sendable (Data) -> Void)?

    /// True from the first transmitted event (either side) until both
    /// have been silent for a while.
    private var talking = false
    /// The other Tama's frames, not yet played.
    private var waiting: [Data] = []
    /// Frames sent / frames the other side has confirmed playing.
    private var sent: UInt32 = 0
    private var confirmedByPeer: UInt32 = 0
    /// Frames of the other side's played (or discarded) here, and the
    /// last count we told it.
    private var played: UInt32 = 0
    private var playedReported: UInt32 = 0
    /// Frames in a row with nothing transmitted in either direction, as
    /// seen here and as last reported by the other side.
    private var quietFrames = 0
    private var peerQuietFrames = 0
    private var playedEventsThisFrame = false

    /// How many frames one Tama may run ahead of what the other has
    /// confirmed. Three frames is 50 ms of Tama time each way, inside what
    /// the firmware tolerates; the link runs at full speed as long as a
    /// message and its confirmation make the round trip in about that
    /// long, and proportionally slower beyond.
    private static let window: UInt32 = 3
    /// Silence, in frames, after which the conversation counts as over (2
    /// s; the Tamas resend about once a second while they are trying).
    private static let quietToStop = 120

    private enum Kind: UInt8 { case frame = 1, confirm = 2, done = 3 }

    enum Step {
        /// Run this frame; hand the core these bytes first (may be empty).
        case run(Data)
        /// The other Tama isn't ready for us to go on. Hold still and ask
        /// again shortly.
        case wait
    }

    /// Where outgoing messages go. Set once, by the session that owns
    /// this port, before the port is handed to an engine.
    func setSendHandler(_ handler: (@Sendable (Data) -> Void)?) {
        lock.lock(); sendHandler = handler; lock.unlock()
    }

    // MARK: - Emulator thread

    /// At the start of each frame.
    func nextStep() -> Step {
        lock.lock()
        guard talking else { lock.unlock(); return .run(Data()) }
        if sent &- confirmedByPeer >= Self.window || waiting.isEmpty {
            let confirm = confirmationIfNeeded()
            let handler = sendHandler
            lock.unlock()
            if let confirm { handler?(confirm) }
            return .wait
        }
        let events = waiting.removeFirst()
        played &+= 1
        playedEventsThisFrame = !events.isEmpty
        lock.unlock()
        return .run(events)
    }

    /// At the end of each frame, with what this Tama transmitted during
    /// it (usually nothing).
    func finishFrame(_ events: Data) {
        lock.lock()
        if !talking {
            guard !events.isEmpty else { lock.unlock(); return }
            startTalking()
        }
        if events.isEmpty && !playedEventsThisFrame {
            quietFrames += 1
        } else {
            quietFrames = 0
        }
        playedEventsThisFrame = false
        var message: Data
        if quietFrames >= Self.quietToStop && peerQuietFrames >= Self.quietToStop - 20 {
            stopTalking()
            message = Data([Kind.done.rawValue])
        } else {
            message = Data([Kind.frame.rawValue])
            appendCount(played, to: &message)
            message.append(UInt8(min(quietFrames, 255)))
            message.append(events)
            sent &+= 1
            playedReported = played
        }
        let handler = sendHandler
        lock.unlock()
        handler?(message)
    }

    /// Waited as long as is reasonable (the other Tama was paused, closed
    /// or lost). Drop the conversation and run normally again.
    func giveUpWaiting() {
        lock.lock()
        stopTalking()
        let handler = sendHandler
        lock.unlock()
        handler?(Data([Kind.done.rawValue]))
    }

    // MARK: - Network side

    /// A message from the other Tama arrived.
    func receive(_ message: Data) {
        guard let first = message.first, let kind = Kind(rawValue: first) else { return }
        let body = message.dropFirst()
        var reply: Data?
        lock.lock()
        switch kind {
        case .frame:
            guard body.count >= 5 else { break }
            noteConfirmed(readCount(body))
            peerQuietFrames = Int(body[body.startIndex + 4])
            let events = Data(body.dropFirst(5))
            if !talking && events.isEmpty {
                // Left over from a conversation that has already ended
                // here. Count it so the sender isn't left waiting on it.
                played &+= 1
                reply = confirmationIfNeeded()
            } else {
                if !talking { startTalking() }
                waiting.append(events)
            }
        case .confirm:
            guard body.count >= 4 else { break }
            noteConfirmed(readCount(body))
        case .done:
            stopTalking()
        }
        let handler = sendHandler
        lock.unlock()
        if let reply { handler?(reply) }
    }

    // MARK: - Helpers (call with the lock held)

    private func startTalking() {
        talking = true
        quietFrames = 0
        peerQuietFrames = 0
        playedEventsThisFrame = false
    }

    private func stopTalking() {
        talking = false
        // Nothing is owed in either direction any more.
        played &+= UInt32(waiting.count)
        waiting.removeAll()
        confirmedByPeer = sent
    }

    private func noteConfirmed(_ count: UInt32) {
        // Counts only ever go up; an older message arriving late must not
        // take one back. (Wrap-around would need 800 days of talking.)
        if count > confirmedByPeer && count <= sent { confirmedByPeer = count }
    }

    private func confirmationIfNeeded() -> Data? {
        guard played != playedReported else { return nil }
        playedReported = played
        var message = Data([Kind.confirm.rawValue])
        appendCount(played, to: &message)
        return message
    }

    private func appendCount(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private func readCount(_ body: Data) -> UInt32 {
        let i = body.startIndex
        return UInt32(body[i]) | UInt32(body[i + 1]) << 8 | UInt32(body[i + 2]) << 16 | UInt32(body[i + 3]) << 24
    }
}
