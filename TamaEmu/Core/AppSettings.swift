import Foundation

/// User-adjustable preferences that affect playback, independent of any one
/// device's save data. Backed by UserDefaults.standard (app-only — nothing
/// here needs to be visible to the widget extension, unlike
/// WidgetSharedState's App Group defaults).
///
/// Plain static accessors, not an @Observable object: these are read from
/// the emulator thread (speed/stay-awake applied at engine start) and the
/// real-time audio render callback (mute/volume), the same informal
/// cross-thread read pattern EmulatorEngine/AudioOutput already use for the
/// core's own tone state. SwiftUI reads/writes them via @AppStorage using
/// the same key strings, so the Settings UI and engine always agree.
enum AppSettings {
    enum Keys {
        static let muted = "settings.muted"
        static let volume = "settings.volume"
        static let hapticsEnabled = "settings.hapticsEnabled"
        static let speedMultiplier = "settings.speedMultiplier"
        static let stayAwake = "settings.stayAwake"
        static let catchUpCapHours = "settings.catchUpCapHours"
        static let buttonColorIndex = "settings.buttonColorIndex"
        static let accentColorIndex = "settings.accentColorIndex"
        static let sharpPixels = "settings.sharpPixels"
    }

    /// Matches the core's own game-clock ladder (`periph_speed_step`), so
    /// "faster"/"slower" in Settings always lands on a value the firmware
    /// itself steps between.
    static let speedLadder = [1, 2, 5, 10, 30, 60, 120, 300, 600]
    static let catchUpCapOptions: [Double] = [0, 1, 6, 24]

    static var muted: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.muted) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.muted) }
    }

    /// Double, not Float — @AppStorage only binds to Double directly, and
    /// the Settings UI needs a live binding to this same key.
    static var volume: Double {
        get {
            let stored = UserDefaults.standard.object(forKey: Keys.volume) as? Double
            return (stored ?? 0.6).clamped(to: 0...1)
        }
        set { UserDefaults.standard.set(newValue.clamped(to: 0...1), forKey: Keys.volume) }
    }

    static var hapticsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Keys.hapticsEnabled) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.hapticsEnabled) }
    }

    static var speedMultiplier: Int {
        get {
            let stored = UserDefaults.standard.object(forKey: Keys.speedMultiplier) as? Int ?? 1
            return speedLadder.contains(stored) ? stored : 1
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.speedMultiplier) }
    }

    static var stayAwake: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.stayAwake) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.stayAwake) }
    }

    /// How much real elapsed time a single catch-up pass will attempt to
    /// age through, in hours. 0 means "don't catch up at all" (the Tama
    /// stays frozen until this is raised), matching the off position of
    /// the Android port's own catch-up multiplier.
    static var catchUpCapHours: Double {
        get {
            let stored = UserDefaults.standard.object(forKey: Keys.catchUpCapHours) as? Double ?? 24
            return catchUpCapOptions.contains(stored) ? stored : 24
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.catchUpCapHours) }
    }

    static let buttonColorCount = 6
    static var buttonColorIndex: Int {
        get { (UserDefaults.standard.object(forKey: Keys.buttonColorIndex) as? Int ?? 0) % buttonColorCount }
        set { UserDefaults.standard.set(newValue % buttonColorCount, forKey: Keys.buttonColorIndex) }
    }

    static let accentColorCount = 6
    static var accentColorIndex: Int {
        get { (UserDefaults.standard.object(forKey: Keys.accentColorIndex) as? Int ?? 0) % accentColorCount }
        set { UserDefaults.standard.set(newValue % accentColorCount, forKey: Keys.accentColorIndex) }
    }

    static var sharpPixels: Bool {
        get { UserDefaults.standard.object(forKey: Keys.sharpPixels) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.sharpPixels) }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
