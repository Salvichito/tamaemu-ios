import Foundation

// Tomomix: the built-in original pet. Every number in this file comes from
// Docs/Tomomix/Rulebook.md -- section numbers (§) point there. Change the
// rulebook first, then this file.

/// The 17 living characters (§1). The fallen star and the departed ending
/// are life stages, not characters.
enum TomoCharacter: String, Codable, CaseIterable, Sendable {
    case baby
    case childGood, childBad
    case teenExcellent, teenGood, teenBad
    case adult1A, adult1B, adult1C, adult1D
    case adult2A, adult2B, adult2C, adult2D
    case adult3A, adult3B, adult3C, adult3D

    enum Stage: Sendable { case baby, child, teen, adult }

    var stage: Stage {
        switch self {
        case .baby: return .baby
        case .childGood, .childBad: return .child
        case .teenExcellent, .teenGood, .teenBad: return .teen
        default: return .adult
        }
    }

    /// Short label for placeholder art and the debug panel.
    var label: String {
        switch self {
        case .baby: return "Baby"
        case .childGood: return "Good Child"
        case .childBad: return "Bad Child"
        case .teenExcellent: return "Excellent Teen"
        case .teenGood: return "Good Teen"
        case .teenBad: return "Bad Teen"
        case .adult1A: return "1A"
        case .adult1B: return "1B"
        case .adult1C: return "1C"
        case .adult1D: return "1D"
        case .adult2A: return "2A"
        case .adult2B: return "2B"
        case .adult2C: return "2C"
        case .adult2D: return "2D"
        case .adult3A: return "3A"
        case .adult3B: return "3B"
        case .adult3C: return "3C"
        case .adult3D: return "3D"
        }
    }

    /// The character's numbers (§14).
    var params: TomoParams {
        switch self {
        case .baby:
            return TomoParams(wake: nil, sleep: nil, hunger: 3, happy: 4, weight: 5...5, doses: 2, healthy: 45, lifetime: 60, bites: 4)
        case .childGood, .childBad:
            return TomoParams(wake: 9, sleep: 20, hunger: 50, happy: 60, weight: 10...99, doses: 2, healthy: 990, lifetime: 1380, bites: 4)
        case .teenExcellent:
            return TomoParams(wake: 9, sleep: 21, hunger: 75, happy: 85, weight: 20...99, doses: 2, healthy: 1656, lifetime: 2220, bites: 2)
        case .teenGood:
            return TomoParams(wake: 9, sleep: 21, hunger: 75, happy: 85, weight: 20...99, doses: 2, healthy: 1158, lifetime: 1800, bites: 2)
        case .teenBad:
            return TomoParams(wake: 9, sleep: 21, hunger: 75, happy: 85, weight: 20...99, doses: 2, healthy: 660, lifetime: 1380, bites: 4)
        case .adult1A:
            return TomoParams(wake: 9, sleep: 22, hunger: 81, happy: 91, weight: 30...99, doses: 1, healthy: 3900, lifetime: 4095, bites: 2)
        case .adult1B:
            return TomoParams(wake: 9, sleep: 22, hunger: 81, happy: 91, weight: 30...99, doses: 1, healthy: 2808, lifetime: 3120, bites: 2)
        case .adult1C, .adult1D:
            return TomoParams(wake: 11, sleep: 23, hunger: 55, happy: 65, weight: 30...99, doses: 1, healthy: 2592, lifetime: 2880, bites: 2)
        case .adult2A:
            return TomoParams(wake: 9, sleep: 22, hunger: 70, happy: 80, weight: 25...99, doses: 2, healthy: 2535, lifetime: 2828, bites: 2)
        case .adult2B:
            return TomoParams(wake: 9, sleep: 22, hunger: 70, happy: 80, weight: 25...99, doses: 2, healthy: 1989, lifetime: 2340, bites: 2)
        case .adult2C:
            return TomoParams(wake: 10, sleep: 22, hunger: 57, happy: 67, weight: 20...99, doses: 2, healthy: 1476, lifetime: 1830, bites: 2)
        case .adult2D:
            return TomoParams(wake: 10, sleep: 22, hunger: 50, happy: 57, weight: 25...99, doses: 2, healthy: 1626, lifetime: 2160, bites: 2)
        case .adult3A, .adult3B:
            return TomoParams(wake: 9, sleep: 22, hunger: 60, happy: 70, weight: 20...99, doses: 2, healthy: 1170, lifetime: 1560, bites: 2)
        case .adult3C:
            return TomoParams(wake: 9, sleep: 22, hunger: 60, happy: 70, weight: 10...99, doses: 3, healthy: 360, lifetime: 780, bites: 4)
        case .adult3D:
            return TomoParams(wake: 10, sleep: 22, hunger: 45, happy: 50, weight: 20...99, doses: 2, healthy: 660, lifetime: 1440, bites: 2)
        }
    }
}

struct TomoParams: Sendable {
    /// Wake-up and bedtime hours, local time. nil for the Baby, which only
    /// naps (§3).
    let wake: Int?
    let sleep: Int?
    /// Minutes between hunger / happiness drops, before the ±20% wobble (§4).
    let hunger: Int
    let happy: Int
    let weight: ClosedRange<Int>
    let doses: Int
    /// Healthy timer, awake minutes (§10).
    let healthy: Int
    /// Awake minutes until it grows up, or for an adult until it's old (§12).
    let lifetime: Int
    /// Eating animation length (§14).
    let bites: Int
}

/// Fixed numbers from the rulebook that aren't per character.
enum TomoRules {
    static let starPulseSeconds: TimeInterval = 30            // §3
    /// Sky + shooting star + close-up before the pulse (Animations.md §5).
    static let birthIntroSeconds: TimeInterval = 5
    static let maxLevel = 4                                    // §4: empty + 4 steps
    static let disciplineStep = 10                             // §8: 10 scolds fill it
    static let timerWobble = 0.2                               // §4
    static let babyNapAfter = 40                               // §3
    static let babyNapLength = 5                               // §3
    static let careDeadline = 14                               // §7
    static let bedtimeDeadline = 60                            // §7
    static let disciplineDeadline = 14                         // §8
    static let childTeenMisbehavior = 5...7                    // §8
    static let adultMisbehavior = 6...8                        // §8
    static let firstPoop = 15                                  // §10
    static let babyPoopEvery = 25                              // §10
    static let poopEvery = 180                                 // §10
    static let maxPoop = 8                                     // §10
    static let poopSicknessSpeedup = 0.25                      // §10, per poop
    static let snackSicknessPenalty = 15.0                     // §5
    static let sicknessesBeforeCritical = 3                    // §10
    static let criticalMinutes = 10                            // §12
    static let emptyMeterDeath = 720                           // §12
    static let untreatedSicknessDeath = 350                    // §12
    static let oldAgeMistakesDeath = 5                         // §12
    static let oldAgeIntervalFloor = 10                        // §12
    static let mistakeCap = 15                                 // §11
    static let yearsPerWake = 3                                // §9
    static let gameRounds = 5                                  // §6
    static let gameIdleSeconds: TimeInterval = 5               // §6
    static let gameResultSeconds: TimeInterval = 2.5           // §6

    /// §6 results: happiness steps for a score of 0-5.
    static func gameReward(score: Int) -> Int {
        switch score {
        case 5: return 3
        case 3...4: return 2
        case 1...2: return 1
        default: return 0
        }
    }

    /// §6: weight a finished game takes off, 2 per round completed
    /// (a perfect game, 10). Never below the character's minimum.
    static let gameWeightPerRound = 2

    /// §11: Baby → Child.
    static func child(careMistakes c: Int) -> TomoCharacter {
        c == 0 ? .childGood : .childBad
    }

    /// §11: Child → Teen, and the adult tier, share the same bands.
    static func tier(careMistakes c: Int) -> Int {
        switch c {
        case 0...2: return 1
        case 3...5: return 2
        default: return 3
        }
    }

    static func teen(careMistakes c: Int) -> TomoCharacter {
        [.teenExcellent, .teenGood, .teenBad][tier(careMistakes: c) - 1]
    }

    /// §11: Teen → Adult. Tier from care mistakes, type from discipline.
    static func adult(careMistakes c: Int, disciplineMistakes d: Int) -> TomoCharacter {
        let type: Int
        switch d {
        case 0: type = 0
        case 1: type = 1
        case 2...3: type = 2
        default: type = 3
        }
        let table: [[TomoCharacter]] = [
            [.adult1A, .adult1B, .adult1C, .adult1D],
            [.adult2A, .adult2B, .adult2C, .adult2D],
            [.adult3A, .adult3B, .adult3C, .adult3D],
        ]
        return table[tier(careMistakes: c) - 1][type]
    }

    /// §8: discipline meter (0-100) a character starts with when it
    /// evolves into it.
    static func startingDiscipline(for character: TomoCharacter, disciplineMistakes d: Int) -> Int {
        switch character.stage {
        case .baby, .child: return 0
        case .teen: return d <= 2 ? 50 : 0
        case .adult:
            switch character {
            case .adult1A, .adult2A, .adult3A: return 100
            case .adult1B, .adult2B, .adult3B: return 80
            case .adult1C, .adult2C, .adult3C: return 20
            default: return 0
            }
        }
    }
}

/// Small seeded random generator (SplitMix64). Its whole state is one
/// number saved with the tomomix, so catching up after the app was closed
/// rolls exactly the same dice as staying open would have (§16).
struct TomoRandom: Codable, Sendable {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0..<1.
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }

    /// `minutes` ±20%, never below 1 (§4).
    mutating func wobble(_ minutes: Int) -> Int {
        let factor = 1 + (unit() * 2 - 1) * TomoRules.timerWobble
        return max(1, Int((Double(minutes) * factor).rounded()))
    }
}
