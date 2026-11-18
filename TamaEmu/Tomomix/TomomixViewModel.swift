import Foundation
import Observation
import os

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
    /// Placeholder for animations: a short line under the tomomix.
    private(set) var caption: String?
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
    private var held: Set<InputController.Button> = []
    private let beeper = TomoBeeper()

    init() {
        if let save = Self.load() {
            brain = save.brain
            timeOffset = save.timeOffset
            pausedAt = save.pausedAt
            muted = save.muted
            paused = save.pausedAt != nil
        } else {
            brain = TomoBrain(now: Date())
            timeOffset = 0
            pausedAt = nil
            muted = false
            paused = false
        }
    }

    var simNow: Date { simTime(at: Date()) }

    func simTime(at date: Date) -> Date { pausedAt ?? date.addingTimeInterval(timeOffset) }

    // MARK: - Running

    func start() {
        guard loop == nil else { return }
        lastTick = Date()
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
        gameTask?.cancel()
        gameTask = nil
        if case .game = screen { screen = .main }
        beeper.stop()
        save()
    }

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        if !paused, speed != 1 { timeOffset += dt * (speed - 1) }
        let events = brain.advance(to: simNow)
        handle(events)
        beeper.idleTick()
        if let until = captionUntil, now >= until { caption = nil; captionUntil = nil }
        if case .game = screen, !brain.canPlay { endGameEarly() }
        if !brain.canCare, screen != .main { screen = .main; cursor = nil }
        if !events.isEmpty || now.timeIntervalSince(lastSave) > 30 { save() }
    }

    private func handle(_ events: [TomoBrain.Event]) {
        for event in events {
            switch event {
            case .born: say("Born!"); beep(.fanfare)
            case .evolved(_, let to): say("Grew into \(to.label)!"); beep(.fanfare)
            case .callStarted: beep(.call)
            case .gotSick: say("Feeling sick…")
            case .becameOld: say("Getting old")
            case .departed: beep(.fanfare); screen = .main; cursor = nil
            default: break
            }
        }
    }

    // MARK: - Buttons (§2)

    func press(_ button: InputController.Button) {
        held.insert(button)
        if held.contains(.a) && held.contains(.c) {
            comboAC()
            return
        }
        beep(.click)
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

    func tapIcon(_ icon: Icon) {
        guard icon != .attention, case .main = screen, brain.canCare else { return }
        beep(.click)
        cursor = icon
        open(icon)
    }

    func tapFood(snack: Bool) {
        guard case .food = screen else { return }
        beep(.click)
        screen = .food(choice: snack ? 1 : 0)
        giveFood(snack: snack)
    }

    func tapLights(on: Bool) {
        guard case .lights = screen else { return }
        beep(.click)
        brain.setLights(on: on)
        screen = .main
        save()
    }

    /// Follow Me: tap the left or right half of the screen (§6).
    func tapGameSide(right: Bool) {
        guard case .game = screen else { return }
        beep(.click)
        gameInput(right: right)
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
            if brain.canPlay { startGame() } else { say("Doesn't want to play") }
        case .medicine:
            switch brain.giveMedicine() {
            case .notSick: say("Not sick")
            case .needsMore: say("One more dose…")
            case .cured: say("Cured!")
            }
        case .clean:
            say(brain.clean() ? "All clean!" : "Nothing to clean")
        case .discipline:
            say(brain.scold() == .scolded ? "Scolded!" : "Huh?")
        case .attention:
            break
        }
        save()
    }

    private func giveFood(snack: Bool) {
        let result = snack ? brain.feedSnack() : brain.feedMeal()
        let bites = brain.character.params.bites
        say(result == .ate ? (snack ? "Snack! " : "Meal! ") + String(repeating: "nom ", count: bites) : "No thanks")
        screen = .main
        save()
    }

    func newStar() {
        gameTask?.cancel()
        brain = TomoBrain(now: simNow)
        screen = .main
        cursor = nil
        caption = nil
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

    func togglePause() {
        if paused {
            timeOffset = (pausedAt ?? Date()).timeIntervalSince(Date())
            pausedAt = nil
        } else {
            pausedAt = simNow
        }
        paused.toggle()
        lastTick = Date()
        save()
    }

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

    private struct SaveFile: Codable {
        var brain: TomoBrain
        var timeOffset: TimeInterval
        var pausedAt: Date?
        var muted: Bool
    }

    private static var saveURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tomomix", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tomomix.json")
    }

    private static func load() -> SaveFile? {
        guard let data = try? Data(contentsOf: saveURL) else { return nil }
        return try? JSONDecoder().decode(SaveFile.self, from: data)
    }

    func save() {
        lastSave = Date()
        let file = SaveFile(brain: brain, timeOffset: timeOffset, pausedAt: pausedAt, muted: muted)
        if let data = try? JSONEncoder().encode(file) {
            try? data.write(to: Self.saveURL, options: .atomic)
        }
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
