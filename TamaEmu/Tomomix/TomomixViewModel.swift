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
        /// The opening: a little tune while it hops for joy, before round 1.
        var intro = false
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
    /// The starry night before a star is caught: nothing happens until
    /// the player taps a shooting star (§3).
    private(set) var waitingForStar: Bool
    /// Outside on the grass instead of in the room. B (with no icon
    /// highlighted) goes in and out; it always sleeps inside.
    private(set) var outdoors: Bool
    /// Where the caught star hangs (fractions of the screen) while the
    /// player types their name; it falls from there.
    private(set) var caughtStar: CGPoint?
    /// When it was caught: it glides from there up to `starHover`.
    private(set) var caughtAt: Date?
    /// The tomomix's name; "" when the player skipped naming it, nil when
    /// they haven't been asked yet.
    private(set) var petName: String?
    /// A name question on screen, if any.
    enum Prompt { case playerName, petName }
    private(set) var prompt: Prompt?
    /// Prototype only: how many simulated seconds pass per real second.
    var speed: Double = 1
    /// Prototype only: show another character / hold one drawing. Only
    /// changes what's drawn, never the tomomix itself; not saved.
    var preview = TomoPreview()

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
    /// Ends the eating moment on time so the menu returns without a gap.
    private var momentEndTask: Task<Void, Never>?
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
            waitingForStar = save.waitingForStar ?? false
            petName = save.petName
            outdoors = save.outdoors ?? false
            // Older pauses and the old speed/skip tools left its clock off
            // the phone's time. Put it back in step without living or undoing
            // anything (a gap from the app being closed is still caught up).
            if pausedAt == nil, timeOffset != 0 {
                brain.shiftClock(by: -timeOffset)
                timeOffset = 0
            }
        } else {
            brain = TomoBrain(now: Date())
            timeOffset = 0
            pausedAt = nil
            muted = false
            paused = false
            waitingForStar = true
            petName = nil
            outdoors = true
        }
        #if DEBUG
        // Debug only: TOMO_DEBUG_CHAR=<character> shows that character.
        if let name = ProcessInfo.processInfo.environment["TOMO_DEBUG_CHAR"],
           let c = TomoCharacter(rawValue: name) { preview.character = c }
        #endif
    }

    // MARK: - Names and the first star (§3)

    /// The player's own name, shared by every tomomix they raise; "" when
    /// they skipped the question, nil when it was never asked.
    nonisolated static var playerName: String? {
        get { UserDefaults.standard.string(forKey: "tomomix.playerName") }
        set { UserDefaults.standard.set(newValue, forKey: "tomomix.playerName") }
    }

    static let maxNameLength = 10

    /// The player tapped a shooting star at `point` (fractions of the screen).
    /// A tap anywhere or any button, while waiting: catches the shooting
    /// star flying by (or one that only just left).
    func catchPassingStar() {
        guard waitingForStar, !paused, prompt == nil, caughtStar == nil else { return }
        let t = Date().timeIntervalSinceReferenceDate
        for lag in [0, 0.12, 0.24, 0.36] {
            guard let passing = TomoBirthScene.shootingStar(at: t - lag) else { continue }
            catchStar(at: TomoBirthScene.shootingStar(at: t)?.point ?? passing.point)
            return
        }
    }

    /// The ending's "tap again to shoot a new star" shows until then.
    private(set) var endingHintUntil: Date?

    /// After the cleaning swoosh, hop for joy (only when there was poop).
    private var happyAfterMoment = false

    /// When the player last pressed or tapped something; menus and the
    /// highlighted icon close by themselves after `idleClose` without input.
    private var lastInput = Date()
    static let idleClose: TimeInterval = 3

    func catchStar(at point: CGPoint) {
        guard waitingForStar, caughtStar == nil, !paused else { return }
        caughtStar = point
        caughtAt = Date()
        beep(.fanfare)
        if Self.playerName == nil {
            prompt = .playerName      // the star waits while they type
        } else {
            launchStar()
        }
    }

    func answerPlayerName(_ name: String?) {
        guard prompt == .playerName else { return }
        Self.playerName = Self.clean(name)
        prompt = nil
        launchStar()
    }

    func answerPetName(_ name: String?) {
        guard prompt == .petName else { return }
        petName = Self.clean(name)
        prompt = nil
        save()
    }

    /// Settings can rename either of them later.
    func rename(pet name: String) {
        petName = Self.clean(name)
        save()
    }

    func rename(player name: String) {
        Self.playerName = Self.clean(name)
    }

    func setMuted(_ value: Bool) {
        muted = value
        save()
    }

    private static func clean(_ name: String?) -> String {
        String((name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNameLength))
    }

    /// The name to show, or a stand-in.
    var displayName: String {
        if let petName, !petName.isEmpty { return petName }
        return "Tomomix"
    }

    /// The caught star falls: the birth intro, from the falling part on.
    private func launchStar() {
        waitingForStar = false
        outdoors = true                 // it's born where its star lands
        let fall = TomoRules.birthIntroSeconds - TomoBirthScene.fallStart
        brain = TomoBrain(now: simNow.addingTimeInterval(fall))
        moment = TomoMoment(.birthIntro, at: Date().addingTimeInterval(-TomoBirthScene.fallStart))
        caption = nil
        save()
    }

    /// A tap on the tomomix itself: a little surprised hop, only when it's
    /// fine (not asleep, sick, calling, misbehaving or about to need
    /// something). Returns false when the tap should do the usual thing.
    func tapPet() -> Bool {
        guard !paused, brain.phase == .alive, prompt == nil, screen == .main,
              activeMoment(at: Date()) == nil, caption == nil, isContent else { return false }
        play(.poke)
        beep(.click)
        return true
    }

    /// Nothing wrong and nothing about to be: no thought bubble either.
    var isContent: Bool {
        !brain.asleep && !brain.sick && !brain.needsCare
            && brain.hunger > 1 && brain.happiness > 1
    }

    /// The moment still playing at `date`, if any.
    func activeMoment(at date: Date) -> TomoMoment? {
        guard let moment else { return nil }
        // After eating, the food menu comes back: hold the last frame
        // until it does, so the normal pose never flashes in between.
        if moment.isOver(at: date), foodChoiceAfterMoment == nil { return nil }
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
        // Prototype tools' speed and skip live extra time, then the clock is
        // put back: the tomomix gets older, but the time of day stays real.
        var extra = pendingSkip
        pendingSkip = 0
        if !paused, speed != 1 { extra += dt * (speed - 1) }
        let before = brain.clock
        // The sky waits for the player: no clock until a star is caught.
        let events = waitingForStar ? [] : brain.advance(to: simNow.addingTimeInterval(extra))
        let lived = brain.clock.timeIntervalSince(before)
        if !waitingForStar, extra > 0 { brain.shiftClock(by: -extra) }
        // Only animate what happened just now, not a long catch-up after
        // the app was closed (or a debug skip).
        handle(events, live: lived <= 180)
        if !paused, let m = moment, m.isOver(at: now) { endMoment() }
        beeper.idleTick()
        if let until = captionUntil, now >= until { caption = nil; captionUntil = nil }
        if case .game = screen, !brain.canPlay { endGameEarly() }
        if !brain.canCare, screen != .main { screen = .main; cursor = nil }
        // Left alone: an open menu (food, light, status) closes and the
        // highlighted icon goes back to none. Games and animations wait.
        if moment == nil, prompt == nil, now.timeIntervalSince(lastInput) >= Self.idleClose {
            switch screen {
            case .food, .lights, .status: screen = .main; cursor = nil
            case .main where cursor != nil: cursor = nil
            default: break
            }
        }
        // Sleeping (or lights out) always happens in the room.
        if outdoors, brain.phase == .alive, brain.asleep || !brain.lightsOn { outdoors = false }
        // Born while the app was closed: ask its name once it's on screen.
        if brain.phase == .alive, petName == nil, prompt == nil, moment == nil { prompt = .petName }
        if !events.isEmpty || now.timeIntervalSince(lastSave) > 30 { save() }
    }

    private func handle(_ events: [TomoBrain.Event], live: Bool) {
        for event in events {
            switch event {
            case .born:
                outdoors = false                // stars always hatch into the room
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
                beep(.farewell)
            default:
                break
            }
        }
    }

    // MARK: - Buttons (§2)

    func press(_ button: InputController.Button) {
        held.insert(button)
        lastInput = Date()
        // Waiting for a star: any button catches the one flying by.
        if waitingForStar {
            catchPassingStar()
            return
        }
        guard !paused, prompt == nil, !waitingForStar else { return }
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
            if let cursor { open(cursor) } else { toggleOutdoors() }
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
        lastInput = Date()
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
        lastInput = Date()
        guard !paused, case .food = screen else { return }
        beep(.click)
        screen = .food(choice: snack ? 1 : 0)
        giveFood(snack: snack)
    }

    func tapLights(on: Bool) {
        lastInput = Date()
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
        lastInput = Date()
        if paused {
            togglePause()          // tap to resume, like the other Tamas
            return
        }
        if prompt != nil || waitingForStar { return }
        if activeMoment(at: Date()) != nil {
            endMoment()
            return
        }
        if caption != nil {
            caption = nil
            captionUntil = nil
            return
        }
        // The ending: a tap shows "tap again to shoot a new star" for 2
        // seconds; a second tap while it shows starts a new star.
        if brain.phase == .departed {
            if let until = endingHintUntil, Date() < until {
                endingHintUntil = nil
                newStar()
            } else {
                endingHintUntil = Date().addingTimeInterval(2)
            }
            return
        }
        switch screen {
        case .status, .food, .lights:
            screen = .main
        case .game(let g):
            if case .result = g.step { screen = .main }
        case .main:
            // Off the tomomix, on the main screen: out to the grass, or back in.
            cursor = nil
            toggleOutdoors()
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
            case .notSick: play(.refuse)          // "no", like refusing food
            case .needsMore:
                play(.medicine(cured: false))
                beep(.toot, after: TomoFrog.toot)
            case .cured:
                play(.medicine(cured: true))
                beep(.toot, after: TomoFrog.toot)          // the frog's toot…
                beep(.magic, after: TomoFrog.toot + 0.5)   // …the cure works…
                beep(.happy, after: TomoFrog.toot + 0.7)   // …and it hops for joy
            }
        case .clean:
            // The sweep plays even with nothing to clean: it's fun to
            // watch (§10).
            let poop = brain.poop
            _ = brain.clean()
            play(.clean(poop: poop))
            // Cleaned up: once the swoosh has gone, it hops for joy.
            if poop > 0 { happyAfterMoment = true }
        case .discipline:
            // Scolded for nothing: sad and confused, no words.
            if brain.scold() == .scolded { play(.scold); beep(.scary) } else { play(.confused) }
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
        // The scene shows the eating; the menu comes back afterwards,
        // right when the animation ends (not at the next clock tick).
        screen = .main
        foodChoiceAfterMoment = snack ? 1 : 0
        if let m = moment {
            momentEndTask?.cancel()
            momentEndTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(m.duration))
                guard !Task.isCancelled, let self, self.moment?.start == m.start, !self.paused else { return }
                self.endMoment()
            }
        }
        save()
    }

    /// B with no icon highlighted: out to the grass, or back inside.
    private func toggleOutdoors() {
        guard brain.phase == .alive, moment == nil || activeMoment(at: Date()) == nil else { return }
        if brain.asleep { say("Shh… sleeping"); return }
        if !brain.lightsOn { say("Lights are off"); return }
        outdoors.toggle()
        save()
    }

    /// The animation finished or was skipped.
    private func endMoment() {
        moment = nil
        lastInput = Date()            // a menu coming back gets its full time
        if happyAfterMoment {
            happyAfterMoment = false
            if brain.canCare, !brain.asleep {
                play(.happy)
                beep(.happy)
                return
            }
        }
        if let choice = foodChoiceAfterMoment {
            foodChoiceAfterMoment = nil
            if brain.canCare, !brain.asleep, screen == .main { screen = .food(choice: choice) }
        }
    }

    func newStar() {
        gameTask?.cancel()
        foodChoiceAfterMoment = nil
        // Back to the starry night: the next star is the player's to catch.
        brain = TomoBrain(now: simNow)
        waitingForStar = true
        caughtStar = nil
        caughtAt = nil
        petName = nil
        outdoors = true
        prompt = nil
        moment = nil
        caption = nil
        screen = .main
        cursor = nil
        save()
    }

    // MARK: - Follow Me (§6)

    private func startGame() {
        var rng = SystemRandomNumberGenerator()
        screen = .game(GameState(sequence: [Bool.random(using: &rng)], round: 1, step: .showing(index: 0), lit: nil, intro: true))
        beep(.gameStart)
        gameTask?.cancel()
        gameTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled, let self, case .game(var g) = self.screen else { return }
            g.intro = false
            self.screen = .game(g)
            self.runShowing()
        }
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
        // Perfect: the happy chime. Lost (no happiness won): the sad one.
        // Anything in between: a plain "okay" tune.
        beep(score == TomoRules.gameRounds ? .happy : reward > 0 ? .okay : .sad)
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

    /// Settings → Notifications changed. Off: drop any pending calls now.
    /// On: they're scheduled as usual the next time the page goes off screen.
    func refreshNotifications() {
        if !TomoCareSettings.notifications { TomomixNotifications.cancel() }
    }

    /// Prototype tools: live `minutes` right away (the clock stays real).
    func skipAhead(minutes: Double) {
        pendingSkip += minutes * 60
        tick()
    }

    private var pendingSkip: TimeInterval = 0

    /// Pause freezes everything (§16): the clock, the tomomix mid-pose,
    /// any animation. Care is blocked until it resumes.
    func togglePause() {
        if paused {
            // Back to the phone's real time (the sky, bedtime), but the paused
            // stretch never happened for the tomomix: it simply skips it.
            pausedAt = nil
            brain.skipPause(to: simNow)
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

    /// A sound a moment later (e.g. the happy chime once a cure has sunk in).
    private func beep(_ sound: TomoBeeper.Sound, after seconds: Double) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.beep(sound)
        }
    }

    // MARK: - Saving

    func save() {
        lastSave = Date()
        TomomixStore.write(saveFile)
    }

    private var saveFile: TomomixStore.SaveFile {
        TomomixStore.SaveFile(brain: brain, timeOffset: timeOffset, pausedAt: pausedAt, muted: muted,
                              waitingForStar: waitingForStar, petName: petName, outdoors: outdoors)
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
        /// Optional so saves from before these existed still load.
        var waitingForStar: Bool?
        var petName: String?
        var outdoors: Bool?
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
        guard var file = load(), file.pausedAt == nil, file.waitingForStar != true else { return false }
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
    /// iOS's notification calls wait on a system service that can be
    /// slow to answer (a freshly started phone or Simulator froze the
    /// screen on it), so they all run here, in order, off the main thread.
    private static let queue = DispatchQueue(label: "tomomix.notifications", qos: .utility)

    static func schedule(for file: TomomixStore.SaveFile, now: Date = Date()) {
        queue.async { scheduleNow(for: file, now: now) }
    }

    static func cancel() {
        queue.async { cancelNow() }
    }

    private static func scheduleNow(for file: TomomixStore.SaveFile, now: Date) {
        cancelNow()
        guard TomoCareSettings.notifications, file.pausedAt == nil, file.waitingForStar != true else { return }
        let pet = file.petName.flatMap { $0.isEmpty ? nil : $0 }
        let player = TomomixViewModel.playerName.flatMap { $0.isEmpty ? nil : $0 }
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
            content.title = pet ?? "Tomomix"
            let n = turn[call.1, default: start]
            turn[call.1] = n + 1
            content.body = message(for: call.1, turn: n, pet: pet, player: player)
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false)
            center.add(UNNotificationRequest(identifier: "\(prefix)\(index)", content: content, trigger: trigger))
        }
    }

    private static func cancelNow() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: (0..<maxScheduled).map { "\(prefix)\($0)" }
        )
    }

    /// Varied wording, so it doesn't read like an alarm clock (§16), with
    /// the tomomix's and the player's names when they gave them.
    static func message(for kind: TomoBrain.CallKind, turn: Int, pet: String?, player: String?) -> String {
        let it = pet ?? "Your tomomix"
        let you = player.map { ", \($0)" } ?? ""
        let options: [String]
        switch kind {
        case .hunger:
            options = ["\(it) is hungry\(you)!", "A little tummy is rumbling.", "\(it) is calling: food, please!"]
        case .happiness:
            options = ["\(it) wants some company\(you).", "\(it) is feeling a bit lonely.", "\(it) misses you\(you)."]
        case .bedtime:
            options = ["\(it) fell asleep with the light on.", "Bedtime\(you)! \(it) needs the light off."]
        case .misbehavior:
            options = ["\(it) is calling for you\(you).", "\(it) wants your attention."]
        case .critical:
            options = ["\(it) is very sick and needs you now\(you)."]
        }
        return options[turn % options.count]
    }
}

/// Placeholder beeps for the prototype, through the app's own square-wave
/// synth (AudioOutput), at the app's volume setting.
final class TomoBeeper: @unchecked Sendable {
    enum Sound { case click, call, left, right, fanfare, happy, sad, scary, magic, toot, farewell, gameStart, okay }

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
        // Bright little "ding-ding-diiing" going up.
        case .happy: pattern = [(1568, 0.08), (0, 0.03), (1976, 0.08), (0, 0.03), (2349, 0.08), (0, 0.03), (3136, 0.2)]
        // Two plain, pleasant notes: "not bad".
        case .okay: pattern = [(1319, 0.1), (0, 0.04), (1568, 0.2)]
        // Sliding down, "wah-wah-wahhh".
        case .sad: pattern = [(784, 0.16), (0, 0.04), (698, 0.16), (0, 0.04), (622, 0.16), (0, 0.04), (523, 0.4)]
        // A bouncy little "let's play!" tune.
        case .gameStart: pattern = [(1047, 0.09), (1319, 0.09), (1568, 0.09), (1319, 0.09), (2093, 0.12), (0, 0.05),
                                    (1568, 0.09), (2093, 0.25)]
        // The sad chime, slower and lower: for its ending.
        case .farewell: pattern = [(587, 0.24), (0, 0.06), (523, 0.24), (0, 0.06), (466, 0.24), (0, 0.06), (392, 0.6)]
        // Low and wobbly, "dun-dun-dunnn".
        case .scary: pattern = [(247, 0.16), (0, 0.05), (233, 0.16), (0, 0.05),
                                (220, 0.07), (208, 0.07), (220, 0.07), (208, 0.07), (196, 0.3)]
        // A silly low "pfrrrt" that wobbles down.
        case .toot: pattern = [(131, 0.05), (117, 0.05), (139, 0.05), (110, 0.05), (123, 0.05),
                               (98, 0.05), (110, 0.05), (87, 0.12)]
        // A quick sparkling run up, ending on a high shimmer.
        case .magic: pattern = [(1047, 0.045), (1319, 0.045), (1568, 0.045), (2093, 0.045), (2637, 0.045),
                                (3136, 0.045), (2637, 0.045), (3136, 0.045), (4186, 0.08), (3136, 0.06), (4186, 0.16)]
        }
        var t = DispatchTime.now().uptimeNanoseconds
        var scheduled: [(Float, UInt64, UInt64)] = []
        for (hz, secs) in pattern {
            let end = t + UInt64(secs * 1_000_000_000)
            if hz > 0 { scheduled.append((hz, t, end)) }
            t = end
        }
        notes.withLock { [scheduled] in $0 = scheduled }
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
