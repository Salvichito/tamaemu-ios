import Foundation

/// Everything about one tomomix's life, and the rules that move it forward.
/// Pure logic: no UI, no clock of its own. The caller says "it's now
/// time T" and the brain plays every minute up to T, so catching up after
/// the app was closed for hours is the same code as staying open.
///
/// Rules live in Docs/Tomomix/Rulebook.md (§ numbers below point there).
/// All timers count **awake minutes** unless stated otherwise.
struct TomoBrain: Codable, Sendable {
    enum Phase: String, Codable, Sendable {
        /// The fallen star pulsing on the ground (§3).
        case star
        case alive
        /// The fixed star in the night sky (§12).
        case departed
    }

    enum DepartureCause: String, Codable, Sendable {
        case neglect, sickness, critical, oldAge
    }

    enum CallKind: String, Sendable { case hunger, happiness, bedtime, misbehavior, critical }

    /// Things that happened while the brain moved forward, for the screen
    /// (animations, beeps) and later for notifications.
    enum Event: Equatable, Sendable {
        case born
        case evolved(from: TomoCharacter, to: TomoCharacter)
        case callStarted(CallKind)
        case careMistake
        case disciplineMistake
        case pooped
        case gotSick
        case becameOld
        case fellAsleep
        case wokeUp
        case departed(DepartureCause)
    }

    // MARK: - State

    var rng: TomoRandom
    /// Simulated time the brain has played up to. Moves in whole minutes.
    private(set) var clock: Date
    private(set) var phase: Phase = .star
    private(set) var bornAt: Date
    private(set) var character: TomoCharacter = .baby
    private(set) var departureCause: DepartureCause?

    private(set) var ageYears = 0
    private(set) var weight = 5
    /// 0-4 each (§4).
    private(set) var hunger = 0
    private(set) var happiness = 0
    /// 0-100 in steps of 10 (§8).
    private(set) var discipline = 0
    /// The two hidden counts growth depends on (§11).
    private(set) var careMistakes = 0
    private(set) var disciplineMistakes = 0

    private(set) var hungerInterval = 3
    private(set) var happyInterval = 4
    private(set) var hungerCountdown = 1
    private(set) var happyCountdown = 2
    /// Minutes left to answer a hunger/happiness call; nil when no call (§7).
    private(set) var careDeadline: Int?
    /// Meter drops left before the next misbehavior; nil for the Baby (§8).
    private(set) var misbehaviorCountdown: Int?
    private(set) var misbehaving = false
    private(set) var disciplineDeadline: Int?

    private(set) var poop = 0
    private(set) var poopCountdown = TomoRules.firstPoop
    private(set) var healthyLeft: Double = 45
    private(set) var sick = false
    private(set) var dosesGiven = 0
    private(set) var sicknessesThisForm = 0
    private(set) var sickMinutes = 0
    /// Minutes until the end, while in critical condition (§12).
    private(set) var criticalLeft: Int?
    private(set) var emptyMinutes = 0

    /// Until the next stage, or for an adult until it's old.
    private(set) var lifetimeLeft = 60
    private(set) var isOld = false
    private(set) var oldAgeMistakes = 0

    private(set) var asleep = false
    private(set) var lightsOn = true
    /// Baby only: awake minutes until its nap, then minutes of nap left.
    private(set) var napCountdown: Int?
    private(set) var napLeft: Int?
    private(set) var bedtimeMinutes = 0
    private(set) var bedtimeMistakeCounted = false

    // MARK: - Starting a life

    /// A new shooting star, landing at `now`. It's born 30 seconds later.
    init(now: Date, seed: UInt64 = UInt64.random(in: .min ... .max)) {
        rng = TomoRandom(state: seed)
        clock = now
        bornAt = now.addingTimeInterval(TomoRules.starPulseSeconds)
    }

    /// When the fallen star becomes the Baby.
    var birthTime: Date { bornAt }

    private mutating func beBorn(events: inout [Event]) {
        let p = TomoCharacter.baby.params
        phase = .alive
        character = .baby
        ageYears = 0
        weight = p.weight.lowerBound
        hunger = 0
        happiness = 0
        discipline = 0
        hungerInterval = p.hunger
        happyInterval = p.happy
        // §3 classic first intervals: hunger runs out right away.
        hungerCountdown = 1
        happyCountdown = 2
        healthyLeft = Double(p.healthy)
        lifetimeLeft = p.lifetime
        napCountdown = TomoRules.babyNapAfter
        poopCountdown = TomoRules.firstPoop
        lightsOn = true
        events.append(.born)
        // §3: it's born with both meters empty, so it calls right away
        // instead of waiting for the first drop a minute later.
        careDeadline = TomoRules.careDeadline
        events.append(.callStarted(.hunger))
    }

    // MARK: - Moving time forward

    /// Plays every whole minute up to `target`. Returns what happened.
    @discardableResult
    mutating func advance(to target: Date, calendar: Calendar = .current) -> [Event] {
        var events: [Event] = []
        if phase == .star {
            guard target >= bornAt else { return events }
            clock = bornAt
            beBorn(events: &events)
        }
        while phase == .alive, target.timeIntervalSince(clock) >= 60 {
            clock.addTimeInterval(60)
            stepMinute(calendar: calendar, events: &events)
        }
        return events
    }

    private mutating func stepMinute(calendar: Calendar, events: inout [Event]) {
        // Critical condition: nothing else happens, and it ends (§12).
        if let left = criticalLeft {
            criticalLeft = left - 1
            if left - 1 <= 0 { depart(.critical, events: &events) }
            return
        }

        if character.stage != .baby {
            let night = isSleepTime(clock, calendar: calendar)
            if night && !asleep { fallAsleep(events: &events) }
            if !night && asleep { wakeUp(events: &events) }
        }

        if asleep {
            sleepMinute(events: &events)
        } else {
            awakeMinute(events: &events)
        }
    }

    func isSleepTime(_ date: Date, calendar: Calendar = .current) -> Bool {
        let p = character.params
        guard let wake = p.wake, let sleep = p.sleep else { return false }
        let hour = calendar.component(.hour, from: date)
        return sleep > wake ? (hour >= sleep || hour < wake) : (hour >= sleep && hour < wake)
    }

    private mutating func fallAsleep(events: inout [Event]) {
        asleep = true
        bedtimeMinutes = 0
        bedtimeMistakeCounted = false
        events.append(.fellAsleep)
        if lightsOn { events.append(.callStarted(.bedtime)) }
    }

    private mutating func wakeUp(events: inout [Event]) {
        asleep = false
        napLeft = nil
        lightsOn = true                                    // §9
        ageYears += TomoRules.yearsPerWake                 // §9
        if isOld {
            // §12: each interval becomes ¾ of the last, never below 10.
            hungerInterval = max(TomoRules.oldAgeIntervalFloor, hungerInterval - hungerInterval / 4)
            happyInterval = max(TomoRules.oldAgeIntervalFloor, happyInterval - happyInterval / 4)
        }
        events.append(.wokeUp)
    }

    private mutating func sleepMinute(events: inout [Event]) {
        if let left = napLeft {
            // The Baby's nap (§3). No bedtime rules for a 5-minute nap.
            if left <= 1 { wakeUp(events: &events) } else { napLeft = left - 1 }
            return
        }
        // §7: lights left on after bedtime.
        if lightsOn {
            bedtimeMinutes += 1
            if bedtimeMinutes >= TomoRules.bedtimeDeadline && !bedtimeMistakeCounted {
                bedtimeMistakeCounted = true
                addCareMistake(events: &events)
            }
        }
    }

    /// One awake minute, in the classic order (research §12).
    private mutating func awakeMinute(events: inout [Event]) {
        // 1. Baby nap.
        if let left = napCountdown {
            if left <= 1 {
                napCountdown = nil
                napLeft = TomoRules.babyNapLength
                asleep = true
                events.append(.fellAsleep)
                return
            }
            napCountdown = left - 1
        }

        // 2-3. Hunger and happiness drop on their own wobbly timers (§4).
        hungerCountdown -= 1
        if hungerCountdown <= 0 {
            hungerCountdown = rng.wobble(hungerInterval)
            dropMeter(isHunger: true, events: &events)
        }
        happyCountdown -= 1
        if happyCountdown <= 0 {
            happyCountdown = rng.wobble(happyInterval)
            dropMeter(isHunger: false, events: &events)
        }

        // 4. Deadlines (§7, §8).
        if let left = careDeadline {
            if hunger > 0 && happiness > 0 {
                careDeadline = nil
            } else if left <= 1 {
                careDeadline = nil
                addCareMistake(events: &events)
                if phase != .alive { return }
            } else {
                careDeadline = left - 1
            }
        }
        if misbehaving, let left = disciplineDeadline {
            if left <= 1 {
                misbehaving = false
                disciplineDeadline = nil
                disciplineMistakes = min(TomoRules.mistakeCap, disciplineMistakes + 1)
                events.append(.disciplineMistake)
            } else {
                disciplineDeadline = left - 1
            }
        }

        // 5. Poop (§10).
        poopCountdown -= 1
        if poopCountdown <= 0 {
            poopCountdown = character == .baby ? TomoRules.babyPoopEvery : TomoRules.poopEvery
            if poop < TomoRules.maxPoop {
                poop += 1
                events.append(.pooped)
            }
        }

        // 6. An empty meter for too long (§12).
        if hunger == 0 || happiness == 0 {
            emptyMinutes += 1
            if emptyMinutes >= TomoRules.emptyMeterDeath {
                depart(.neglect, events: &events)
                return
            }
        } else {
            emptyMinutes = 0
        }

        // 7. Sickness (§10, §12).
        if sick {
            sickMinutes += 1
            if sickMinutes >= TomoRules.untreatedSicknessDeath {
                depart(.sickness, events: &events)
                return
            }
        } else {
            healthyLeft -= 1 + TomoRules.poopSicknessSpeedup * Double(poop)
            if healthyLeft <= 0 {
                getSick(events: &events)
                if criticalLeft != nil { return }
            }
        }

        // 8. Growing up, or getting old (§11, §12).
        lifetimeLeft -= 1
        if lifetimeLeft <= 0 {
            if character.stage == .adult {
                if !isOld {
                    isOld = true
                    events.append(.becameOld)
                }
            } else {
                evolve(events: &events)
            }
        }
    }

    private mutating func dropMeter(isHunger: Bool, events: inout [Event]) {
        let before = isHunger ? hunger : happiness
        if before > 0 {
            if isHunger { hunger -= 1 } else { happiness -= 1 }
            if before - 1 > 0 {
                // §8: only drops that don't empty a meter count toward
                // misbehavior (research DS06).
                countMisbehaviorDrop(events: &events)
                return
            }
        }
        // Meter is empty: open a call if one isn't already open (§7).
        if careDeadline == nil {
            careDeadline = TomoRules.careDeadline
            events.append(.callStarted(isHunger ? .hunger : .happiness))
        }
    }

    private mutating func countMisbehaviorDrop(events: inout [Event]) {
        guard var left = misbehaviorCountdown, !misbehaving, discipline < 100 else { return }
        left -= 1
        if left <= 0 {
            misbehaving = true
            disciplineDeadline = TomoRules.disciplineDeadline
            events.append(.callStarted(.misbehavior))
            left = rng.int(in: misbehaviorRange)
        }
        misbehaviorCountdown = left
    }

    private var misbehaviorRange: ClosedRange<Int> {
        character.stage == .adult ? TomoRules.adultMisbehavior : TomoRules.childTeenMisbehavior
    }

    private mutating func addCareMistake(events: inout [Event]) {
        careMistakes = min(TomoRules.mistakeCap, careMistakes + 1)
        events.append(.careMistake)
        if isOld {
            oldAgeMistakes += 1
            if oldAgeMistakes >= TomoRules.oldAgeMistakesDeath {
                depart(.oldAge, events: &events)
            }
        }
    }

    private mutating func getSick(events: inout [Event]) {
        sick = true
        dosesGiven = 0
        sickMinutes = 0
        sicknessesThisForm += 1
        events.append(.gotSick)
        if sicknessesThisForm >= TomoRules.sicknessesBeforeCritical {
            criticalLeft = TomoRules.criticalMinutes
            events.append(.callStarted(.critical))
        }
    }

    private mutating func evolve(events: inout [Event]) {
        let from = character
        let next: TomoCharacter
        switch from.stage {
        case .baby: next = TomoRules.child(careMistakes: careMistakes)
        case .child: next = TomoRules.teen(careMistakes: careMistakes)
        case .teen: next = TomoRules.adult(careMistakes: careMistakes, disciplineMistakes: disciplineMistakes)
        case .adult: return
        }
        let p = next.params
        character = next
        // §4: timers keep their time left; the new intervals apply from
        // the next restart.
        hungerInterval = p.hunger
        happyInterval = p.happy
        weight = min(max(weight, p.weight.lowerBound), p.weight.upperBound)
        discipline = TomoRules.startingDiscipline(for: next, disciplineMistakes: disciplineMistakes)
        lifetimeLeft = p.lifetime
        sicknessesThisForm = 0                              // §10
        if !sick { healthyLeft = Double(p.healthy) }
        napCountdown = nil
        if misbehaviorCountdown == nil || from.stage == .teen {
            misbehaviorCountdown = rng.int(in: misbehaviorRange)
        }
        events.append(.evolved(from: from, to: next))
    }

    private mutating func depart(_ cause: DepartureCause, events: inout [Event]) {
        phase = .departed
        departureCause = cause
        criticalLeft = nil
        careDeadline = nil
        misbehaving = false
        events.append(.departed(cause))
    }

    // MARK: - What the screen shows

    /// The attention icon (§2, §7, §8). Unlike the classic toy, it stays
    /// lit while a meter is empty, even after the 14 minutes run out (§7).
    var attention: Bool {
        guard phase == .alive else { return false }
        return careDeadline != nil || misbehaving || criticalLeft != nil
            || (asleep && lightsOn && napLeft == nil)
            || (!asleep && (hunger == 0 || happiness == 0))
    }

    /// Care actions are possible: alive, not in critical condition.
    var canCare: Bool { phase == .alive && criticalLeft == nil }

    var canPlay: Bool { canCare && !asleep && !sick && !misbehaving }

    // MARK: - Care actions

    enum FoodResult: Equatable, Sendable { case ate, refused }

    /// §5. Refuses when full, sick, asleep or misbehaving.
    mutating func feedMeal() -> FoodResult {
        guard canCare, !asleep, !sick, !misbehaving, hunger < TomoRules.maxLevel else { return .refused }
        hunger += 1
        weight = clampWeight(weight + 1)
        careAnswered()
        return .ate
    }

    /// §5. A snack at full happiness is still eaten, but brings sickness
    /// closer.
    mutating func feedSnack() -> FoodResult {
        guard canCare, !asleep, !sick, !misbehaving else { return .refused }
        if happiness >= TomoRules.maxLevel {
            healthyLeft -= TomoRules.snackSicknessPenalty
        } else {
            happiness += 1
        }
        weight = clampWeight(weight + 2)
        careAnswered()
        return .ate
    }

    mutating func setLights(on: Bool) {
        guard phase == .alive else { return }
        lightsOn = on
    }

    enum MedicineResult: Equatable, Sendable { case notSick, needsMore, cured }

    /// §10. Some characters need 2 or 3 doses.
    mutating func giveMedicine() -> MedicineResult {
        guard canCare, !asleep else { return .notSick }
        guard sick else { return .notSick }
        dosesGiven += 1
        guard dosesGiven >= character.params.doses else { return .needsMore }
        sick = false
        dosesGiven = 0
        sickMinutes = 0
        healthyLeft = Double(character.params.healthy)
        return .cured
    }

    /// §10. Removes all poop.
    mutating func clean() -> Bool {
        guard canCare, !asleep, poop > 0 else { return false }
        poop = 0
        return true
    }

    enum DisciplineResult: Equatable, Sendable { case scolded, noEffect }

    /// §8. Only works during misbehavior.
    mutating func scold() -> DisciplineResult {
        guard canCare, !asleep, misbehaving else { return .noEffect }
        misbehaving = false
        disciplineDeadline = nil
        discipline = min(100, discipline + TomoRules.disciplineStep)
        return .scolded
    }

    /// §6. A finished game (not quit). Returns the happiness steps given.
    @discardableResult
    mutating func finishGame(score: Int) -> Int {
        guard canPlay else { return 0 }
        let reward = TomoRules.gameReward(score: score)
        happiness = min(TomoRules.maxLevel, happiness + reward)
        weight = clampWeight(weight - 1)
        careAnswered()
        return reward
    }

    private func clampWeight(_ value: Int) -> Int {
        let range = character.params.weight
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// One step is enough to answer a call (§7).
    private mutating func careAnswered() {
        if hunger > 0 && happiness > 0 { careDeadline = nil }
    }
}
