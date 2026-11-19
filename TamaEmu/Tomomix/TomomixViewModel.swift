import Foundation
import Observation
import os
import UserNotifications

/// Drives one tomomix on screen: moves the brain forward with the clock,
/// turns A/B/C presses and taps into care actions, runs the Follow Me game,
/// and saves. Prototype: placeholder visuals, plus debug time controls.
@MainActor
@Observable
final class TomomixViewModel {
    /// The 7 care icons, in A order (§2), then the attention icon.
    enum Icon: Int, CaseIterable {
        case food, light, game, medicine, clean, status, discipline, attention
        static let selectable: [Icon] = [.food, .light, .game, .medicine, .clean, .status, .discipline]
    }

    enum Screen: Equatable {
        case main
        case food(choice: Int)      // 0 meal, 1 snack
        case lights(choice: Int)    // 0 on, 1 off
        case status
        case game(GameState)
    }

    struct GameState: Equatable {
        enum Step: Equatable {
            case showing(index: Int)    // tomomix shows sequence[index]
            case input(index: Int)      // waiting for the player's sequence[index]
            case result(score: Int, reward: Int)
        }
        /// true = right, false = left. Grows by one each round (§6).
        var sequence: [Bool]
        var round: Int
        var step: Step
        /// Direction currently lit on screen (shown or just pressed).
        var lit: Bool?
    }

    private(set) var brain: TomoBrain
    private(set) var screen: Screen = .main
    /// Highlighted care icon; nil = none (§2).
    private(set) var cursor: Icon?
    /// A short line under the tomomix, for things with no animation.
    private(set) var caption: String?
    /// The animation playing now, if any (Animations.md §4).
    private(set) var moment: TomoMoment?
    private(set) var muted: Bool
    private(set) var paused: Bool
    /// Prototype only: how many simulated seconds pass per real second.
    var speed: Double = 1

    /// Simulated time = real time + offset (debug skips push it ahead).
    private var timeOffset: TimeInterval
    private var pausedAt: Date?
    private var captionUntil: Date?
    private var lastTick = Date()
    private var lastSave = Date()
    private var loop: Task<Void, Never>?
    private var gameTask: Task<Void, Never>?
    /// After eating (or refusing), the food menu comes back with the same
    /// choice selected once the animation ends or is skipped. Leaving the
    /// menu clears it, so opening Food again starts on Meal.
    private var foodChoiceAfterMoment: Int?
    private var held: Set<InputController.Button> = []
    private let beeper = TomoBeeper()

    init() {
        if let save = TomomixStore.load() {
            brain = save.brain
            timeOffset = save.timeOffset
            pausedAt = save.pausedAt
            muted = save.muted
            paused = save.pausedAt != nil
            frozenAt = save.pausedAt != nil ? Date() : nil
        } else {
            brain = TomoBrain(now: Date().addingTimeInterval(TomoRules.birthIntroSeconds))
            timeOffset = 0
            pausedAt = nil
            muted = false
            paused = false
            moment = TomoMoment(.birthIntro)
        }
    }

    /// The moment still playing at `date`, if any.
    func activeMoment(at date: Date) -> TomoMoment? {
        guard let moment, !moment.isOver(at: date) else { return nil }
        return moment
    }

    private func play(_ kind: TomoMoment.Kind) {
        moment = TomoMoment(kind)
        caption = nil
        captionUntil = nil
    }

    var simNow: Date { simTime(at: Date()) }

    func simTime(at date: Date) -> Date { pausedAt ?? date.addingTimeInterval(timeOffset) }

    // MARK: - Running

    /// True while this page is on screen and its clock runs.
    private(set) var isRunning = false

    func start() {
        guard loop == nil else { return }
        isRunning = true
        lastTick = Date()
        // On screen, it beeps for itself: no notifications needed.
        TomomixNotifications.cancel()
        NotificationScheduler.requestAuthorizationIfNeeded()
        beeper.start()
        tick()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                self?.tick()
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        isRunning = false
        gameTask?.cancel()
        gameTask = nil
        if case .game = screen { screen = .main }
        beeper.stop()
        save()
        // Off screen (another page, or the app closed): tell the phone
        // when it will call next, so iOS can notify without the app
        // having to run in the background.
        TomomixNotifications.schedule(for: saveFile)
    }

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        if !paused, speed != 1 { timeOffset += dt * (speed - 1) }
        let before = brain.clock
        let events = brain.advance(to: simNow)
        // Only animate what happened just now, not a long catch-up after
        // the app was closed (or a debug skip).
        handle(events, live: brain.clock.timeIntervalSince(before) <= 180)
        if !paused, let m = moment, m.isOver(at: now) { endMoment() }
        beeper.idleTick()
        if let until = captionUntil, now >= until { caption = nil; captionUntil = nil }
        if case .game = screen, !brain.canPlay { endGameEarly() }
        if !brain.canCare, screen != .main { screen = .main; cursor = nil }
        if !events.isEmpty || now.timeIntervalSince(lastSave) > 30 { save() }
    }

    private func handle(_ events: [TomoBrain.Event], live: Bool) {
        for event in events {
            switch event {
            case .born:
                if live { play(.burst) }
                beep(.fanfare)
            case .evolved(let from, let to):
                foodChoiceAfterMoment = nil
                if live { play(.evolve(from: from, to: to)) }
                beep(.fanfare)
            case .pooped:
                if live, moment == nil { play(.poop) }
            case .callStarted:
                if live { beep(.call) }
            case .becameOld:
                say("Getting old")
            case .departed:
                foodChoiceAfterMoment = nil
                gameTask?.cancel()
                screen = .main
                cursor = nil
                if live { play(.depart(brain.character)) }
                beep(.fanfare)
            default:
                break
            }
        }
    }

    // MARK: - Buttons (§2)

    func press(_ button: InputController.Button) {
        held.insert(button)
        guard !paused else { return }
        if held.contains(.a) && held.contains(.c) {
            comboAC()
            return
        }
        beep(.click)
        if foodChoiceAfterMoment != nil, activeMoment(at: Date()) != nil {
            // Eating: C leaves the food menu, A or B skip back to it.
            if button == .c { foodChoiceAfterMoment = nil }
            endMoment()
            return
        }
        switch button {
        case .a: pressA()
        case .b: pressB()
        case .c: pressC()
        default: break
        }
    }

    func release(_ button: InputController.Button) {
        held.remove(button)
    }

    private func comboAC() {
        if brain.phase == .departed {
            newStar()
        } else if case .main = screen {
            muted.toggle()                                 // §2: sound on/off
            say(muted ? "Sound off" : "Sound on")
            save()
        }
    }

    private func pressA() {
        switch screen {
        case .main:
            guard brain.canCare, !isStarOrDeparted else { return }
            let list = Icon.selectable
            if let current = cursor, let i = list.firstIndex(of: current) {
                cursor = list[(i + 1) % list.count]
            } else {
                cursor = list[0]
            }
        case .food(let c): screen = .food(choice: 1 - c)
        case .lights(let c): screen = .lights(choice: 1 - c)
        case .status: screen = .main
        case .game: gameInput(right: false)
        }
    }

    private func pressB() {
        switch screen {
        case .main:
            if let cursor { open(cursor) }
        case .food(let c): giveFood(snack: c == 1)
        case .lights(let c): brain.setLights(on: c == 0); screen = .main; save()
        case .status: screen = .main
        case .game: gameInput(right: true)
        }
    }

    private func pressC() {
        switch screen {
        case .main: cursor = nil
        case .game: quitGame()
        default: screen = .main
        }
    }

    // MARK: - Taps (§2 hidden shortcuts)

    /// Tapping an icon opens it. Tapping the icon whose screen is already
    /// open closes it again; tapping a different one jumps straight there.
    func tapIcon(_ icon: Icon) {
        guard !paused, icon != .attention, brain.canCare else { return }
        foodChoiceAfterMoment = nil
        if let open = openIcon {
            beep(.click)
            if open == icon {
                if case .game = screen { quitGame() } else { screen = .main }
                return
            }
            if case .game = screen { return }   // finish or quit the game first
            screen = .main
        } else {
            beep(.click)
        }
        cursor = icon
        open(icon)
    }

    /// Which icon the current screen belongs to; nil on the main screen.
    private var openIcon: Icon? {
        switch screen {
        case .main: return nil
        case .food: return .food
        case .lights: return .light
        case .status: return .status
        case .game: return .game
        }
    }

    func tapFood(snack: Bool) {
        guard !paused, case .food = screen else { return }
        beep(.click)
        screen = .food(choice: snack ? 1 : 0)
        giveFood(snack: snack)
    }

    func tapLights(on: Bool) {
        guard !paused, case .lights = screen else { return }
        beep(.click)
        brain.setLights(on: on)
        screen = .main
        save()
    }

    /// Follow Me: tap the left or right half of the screen (§6).
    func tapGameSide(right: Bool) {
        guard !paused, case .game = screen else { return }
        beep(.click)
        gameInput(right: right)
    }

    /// Tap on the screen itself (not an icon or menu item): skips what's
    /// playing or closes what can be closed, so players can move on
    /// quickly (§2). Never skips a real wait (the star's 30 seconds) or
    /// the game's sequence.
    func tapScreen() {
        if paused {
            togglePause()          // tap to resume, like the other Tamas
            return
        }
        if activeMoment(at: Date()) != nil {
            endMoment()
            return
        }
        if caption != nil {
            caption = nil
            captionUntil = nil
            return
        }
        switch screen {
        case .status, .food, .lights:
            screen = .main
        case .game(let g):
            if case .result = g.step { screen = .main }
        case .main:
            break
        }
    }

    // MARK: - Care actions

    private var isStarOrDeparted: Bool { brain.phase != .alive }

    private func open(_ icon: Icon) {
        guard brain.canCare else { return }
        if brain.asleep, icon != .light, icon != .status { say("Shh… sleeping"); return }   // §2
        switch icon {
        case .food: screen = .food(choice: 0)
        case .light: screen = .lights(choice: brain.lightsOn ? 1 : 0)
        case .status: screen = .status
        case .game:
            if brain.canPlay { startGame() } else { play(.refuse) }
        case .medicine:
            switch brain.giveMedicine() {
            case .notSick: say("Not sick")
            case .needsMore: play(.medicine(cured: false))
            case .cured: play(.medicine(cured: true))
            }
        case .clean:
            // The sweep plays even with nothing to clean: it's fun to
            // watch (§10).
            let poop = brain.poop
            _ = brain.clean()
            play(.clean(poop: poop))
        case .discipline:
            if brain.scold() == .scolded { play(.scold) } else { say("Huh?") }
        case .attention:
            break
        }
        save()
    }

    private func giveFood(snack: Bool) {
        let result = snack ? brain.feedSnack() : brain.feedMeal()
        if result == .ate {
            play(.eat(snack: snack, bites: brain.character.params.bites))
        } else {
            play(.refuse)
        }
        // The scene shows the eating; the menu comes back afterwards.
        screen = .main
        foodChoiceAfterMoment = snack ? 1 : 0
        save()
    }

    /// The animation finished or was skipped.
    private func endMoment() {
        moment = nil
        if let choice = foodChoiceAfterMoment {
            foodChoiceAfterMoment = nil
            if brain.canCare, !brain.asleep, screen == .main { screen = .food(choice: choice) }
        }
    }

    func newStar() {
        gameTask?.cancel()
        foodChoiceAfterMoment = nil
        // It lands after the intro, so the 30-second pulse is all there (§3).
        brain = TomoBrain(now: simNow.addingTimeInterval(TomoRules.birthIntroSeconds))
        screen = .main
        cursor = nil
        play(.birthIntro)
        save()
    }

    // MARK: - Follow Me (§6)

    private func startGame() {
        var rng = SystemRandomNumberGenerator()
        screen = .game(GameState(sequence: [Bool.random(using: &rng)], round: 1, step: .showing(index: 0), lit: nil))
        runShowing()
    }

    /// Plays the sequence for this round, then waits for input.
    private func runShowing() {
        gameTask?.cancel()
        gameTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, case .game(var g) = self.screen else { return }
            for i in g.sequence.indices {
                if Task.isCancelled { return }
                g.step = .showing(index: i)
                g.lit = g.sequence[i]
                self.screen = .game(g)
                self.beep(g.sequence[i] ? .right : .left)
                try? await Task.sleep(for: .milliseconds(550))
                g.lit = nil
                self.screen = .game(g)
                try? await Task.sleep(for: .milliseconds(200))
            }
            if Task.isCancelled { return }
            g.step = .input(index: 0)
            self.screen = .game(g)
            self.armIdleTimeout()
        }
    }

    /// §6: no press for 5 seconds counts as a wrong direction.
    private func armIdleTimeout() {
        gameTask?.cancel()
        gameTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(TomoRules.gameIdleSeconds))
            if Task.isCancelled { return }
            self?.gameOver()
        }
    }

    private func gameInput(right: Bool) {
        guard case .game(var g) = screen else { return }
        switch g.step {
        case .input(let index):
            g.lit = right
            beep(right ? .right : .left)
            if g.sequence[index] != right {
                screen = .game(g)
                gameOver()
                return
            }
            if index + 1 < g.sequence.count {
                g.step = .input(index: index + 1)
                screen = .game(g)
                armIdleTimeout()
            } else if g.round == TomoRules.gameRounds {
                screen = .game(g)
                finishGame(score: TomoRules.gameRounds)
            } else {
                // Round complete: add one direction and show it again.
                g.round += 1
                g.sequence.append(Bool.random())
                g.step = .showing(index: 0)
                screen = .game(g)
                runShowing()
            }
        case .result:
            screen = .main
        case .showing:
            break
        }
    }

    /// A wrong direction (or timeout) ends the game: score = rounds completed.
    private func gameOver() {
        guard case .game(let g) = screen else { return }
        finishGame(score: g.round - 1)
    }

    private func finishGame(score: Int) {
        gameTask?.cancel()
        guard case .game(var g) = screen else { return }
        let reward = brain.finishGame(score: score)
        g.step = .result(score: score, reward: reward)
        g.lit = nil
        screen = .game(g)
        beep(score == TomoRules.gameRounds ? .fanfare : .click)
        save()
        // The result closes by itself after a moment (§6); a tap or a
        // button closes it sooner.
        gameTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(TomoRules.gameResultSeconds))
            guard !Task.isCancelled, let self, case .game(let g) = self.screen, case .result = g.step else { return }
            self.screen = .main
        }
    }

    /// C during the game: no reward, no weight (§6).
    private func quitGame() {
        gameTask?.cancel()
        screen = .main
    }

    private func endGameEarly() {
        gameTask?.cancel()
        screen = .main
    }

    // MARK: - Prototype tools

    func skipAhead(minutes: Double) {
        if paused { pausedAt = pausedAt?.addingTimeInterval(minutes * 60) } else { timeOffset += minutes * 60 }
        tick()
    }

    /// Pause freezes everything (§16): the clock, the tomomix mid-pose,
    /// any animation. Care is blocked until it resumes.
    func togglePause() {
        if paused {
            timeOffset = (pausedAt ?? Date()).timeIntervalSince(Date())
            pausedAt = nil
            // Pick the animation up exactly where it stopped.
            if let m = moment, let frozen = frozenAt {
                moment = TomoMoment(m.kind, at: m.start.addingTimeInterval(Date().timeIntervalSince(frozen)))
            }
            frozenAt = nil
        } else {
            pausedAt = simNow
            frozenAt = Date()
            gameTask?.cancel()
            if case .game = screen { screen = .main }
        }
        paused.toggle()
        lastTick = Date()
        save()
    }

    /// Real time the screen froze at while paused; the scene draws this
    /// instant instead of the clock, so nothing moves.
    private(set) var frozenAt: Date?

    // MARK: - Feedback

    private func say(_ text: String) {
        caption = text
        captionUntil = Date().addingTimeInterval(2)
    }

    private func beep(_ sound: TomoBeeper.Sound) {
        guard !muted else { return }
        beeper.play(sound)
    }

    // MARK: - Saving

    func save() {
        lastSave = Date()
        TomomixStore.write(saveFile)
    }

    private var saveFile: TomomixStore.SaveFile {
        TomomixStore.SaveFile(brain: brain, timeOffset: timeOffset, pausedAt: pausedAt, muted: muted)
    }
}

// MARK: - Gallery lifecycle

extension TomomixViewModel {
    /// The gallery shows this page: run the clock and the scene.
    func resumeIfNeeded() { start() }
    /// The page left the screen or the app went to the background.
    func stopEngine() { stop() }
}

/// The tomomix's save file, readable without a view model, so the
/// gallery can tell whether one exists and the background refresh can
/// move it forward while the app is closed.
enum TomomixStore {
    struct SaveFile: Codable {
        var brain: TomoBrain
        var timeOffset: TimeInterval
        var pausedAt: Date?
        var muted: Bool
    }

    static var saveURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tomomix", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tomomix.json")
    }

    static var exists: Bool { FileManager.default.fileExists(atPath: saveURL.path) }

    static func load() -> SaveFile? {
        guard let data = try? Data(contentsOf: saveURL) else { return nil }
        return try? JSONDecoder().decode(SaveFile.self, from: data)
    }

    static func write(_ file: SaveFile) {
        if let data = try? JSONEncoder().encode(file) {
            try? data.write(to: saveURL, options: .atomic)
        }
    }

    static func remove() {
        try? FileManager.default.removeItem(at: saveURL)
    }

    /// Set when the player deletes their tomomix, so it isn't recreated
    /// on the next launch just because no ROM is imported.
    static var removedByPlayer: Bool {
        get { UserDefaults.standard.bool(forKey: "tomomix.removedByPlayer") }
        set { UserDefaults.standard.set(newValue, forKey: "tomomix.removedByPlayer") }
    }

    /// Background refresh: plays the minutes since the last save and
    /// saves. Returns true when the tomomix started calling meanwhile.
    static func catchUp(now: Date = Date()) -> Bool {
        guard var file = load(), file.pausedAt == nil else { return false }
        let events = file.brain.advance(to: now.addingTimeInterval(file.timeOffset))
        write(file)
        return events.contains { if case .callStarted = $0 { return true } else { return false } }
    }
}

/// Tomomix's notifications. Its rules have no randomness the player can't
/// replay (the random generator is saved with it), so with no one caring
/// for it, the app can work out exactly when it will call next. When its
/// page leaves the screen, those calls are handed to iOS as timed
/// notifications, which iOS delivers on its own: no background running,
/// no battery cost. They're cancelled as soon as the page is back.
enum TomomixNotifications {
    private static let prefix = "tomomix-call-"
    /// How far ahead to look, and at most how many to hand over (iOS
    /// keeps 64 pending per app, shared with the other Tamas' reminders).
    private static let lookAheadMinutes = 48 * 60
    private static let maxScheduled = 20

    static func schedule(for file: TomomixStore.SaveFile, now: Date = Date()) {
        cancel()
        guard file.pausedAt == nil else { return }
        var brain = file.brain
        let simNow = now.addingTimeInterval(file.timeOffset)
        brain.advance(to: simNow)

        var calls: [(Date, TomoBrain.CallKind)] = []
        var minute = 1
        while minute <= lookAheadMinutes, calls.count < maxScheduled, brain.phase != .departed {
            for event in brain.advance(to: simNow.addingTimeInterval(Double(minute) * 60)) {
                if case .callStarted(let kind) = event {
                    // Back from the tomomix's clock to the phone's.
                    calls.append((brain.clock.addingTimeInterval(-file.timeOffset), kind))
                }
            }
            minute += 1
        }

        let center = UNUserNotificationCenter.current()
        // Each kind takes its messages in turn, from a random start, so
        // the same one never shows twice in a row.
        var turn = [TomoBrain.CallKind: Int]()
        let start = Int.random(in: 0..<6)
        for (index, call) in calls.enumerated() {
            let wait = call.0.timeIntervalSince(now)
            guard wait >= 1 else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Tomomix"
            let n = turn[call.1, default: start]
            turn[call.1] = n + 1
            content.body = message(for: call.1, turn: n)
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false)
            center.add(UNNotificationRequest(identifier: "\(prefix)\(index)", content: content, trigger: trigger))
        }
    }

    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: (0..<maxScheduled).map { "\(prefix)\($0)" }
        )
    }

    /// Varied wording, so it doesn't read like an alarm clock (§16).
    private static func message(for kind: TomoBrain.CallKind, turn: Int) -> String {
        let options: [String]
        switch kind {
        case .hunger:
            options = ["Your tomomix is hungry.", "A little tummy is rumbling.", "Your tomomix is calling: food, please!"]
        case .happiness:
            options = ["Your tomomix wants some company.", "Your tomomix is feeling a bit lonely.", "Your tomomix is calling for you."]
        case .bedtime:
            options = ["Your tomomix fell asleep with the light on.", "Bedtime! Your tomomix needs the light off."]
        case .misbehavior:
            options = ["Your tomomix is calling for you.", "Your tomomix wants your attention."]
        case .critical:
            options = ["Your tomomix is very sick and needs you now."]
        }
        return options[turn % options.count]
    }
}

/// Placeholder beeps for the prototype, through the app's own square-wave
/// synth (AudioOutput), at the app's volume setting.
final class TomoBeeper: @unchecked Sendable {
    enum Sound { case click, call, left, right, fanfare }

    /// (frequency, start, end) in uptime nanoseconds.
    private let notes = OSAllocatedUnfairLock<[(Float, UInt64, UInt64)]>(initialState: [])
    private lazy var output = AudioOutput(
        toneProvider: { [weak self] in self?.current() ?? (false, 0) },
        volumeProvider: { Float(AppSettings.volume) }
    )

    func start() { output.start() }
    func stop() { output.stop() }
    /// Lets the audio engine go idle once nothing has played for a while.
    func idleTick() { output.tick(buttonsDown: false) }

    func play(_ sound: Sound) {
        let pattern: [(Float, Double)]   // (Hz, seconds); 0 Hz = rest
        switch sound {
        case .click: pattern = [(2093, 0.04)]
        case .call: pattern = [(1397, 0.12), (0, 0.06), (1175, 0.12), (0, 0.06), (1397, 0.12)]
        case .left: pattern = [(784, 0.3)]
        case .right: pattern = [(1175, 0.3)]
        case .fanfare: pattern = [(1047, 0.1), (1319, 0.1), (1568, 0.1), (2093, 0.2)]
        }
        var t = DispatchTime.now().uptimeNanoseconds
        var scheduled: [(Float, UInt64, UInt64)] = []
        for (hz, secs) in pattern {
            let end = t + UInt64(secs * 1_000_000_000)
            if hz > 0 { scheduled.append((hz, t, end)) }
            t = end
        }
        notes.withLock { $0 = scheduled }
        output.tick(buttonsDown: true)   // wake the audio engine right away
    }

    private func current() -> (on: Bool, freq: Float) {
        let now = DispatchTime.now().uptimeNanoseconds
        return notes.withLock { list in
            if let note = list.first(where: { now >= $0.1 && now < $0.2 }) { return (true, note.0) }
            return (false, 0)
        }
    }
}
