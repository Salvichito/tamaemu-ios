import Foundation
import TamaCore

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
        static let catchUpCapHours = "settings.catchUpCapHours"
        static let buttonColorIndex = "settings.buttonColorIndex"
        static let accentColorIndex = "settings.accentColorIndex"
        static let sharpPixels = "settings.sharpPixels"
        static let ignoreSilentSwitch = "settings.ignoreSilentSwitch"

        /// Per-device keys — speed and stay-awake are the two settings that
        /// already have a per-instance home on the C Emu struct (rtc_mult,
        /// stay_awake), so their storage is keyed per device too, mirroring
        /// SavePaths' lastSavedAt.<id> pattern.
        static func speedMultiplier(for device: TamaDevice) -> String {
            "settings.speedMultiplier.\(device.id)"
        }
        static func stayAwake(for device: TamaDevice) -> String {
            "settings.stayAwake.\(device.id)"
        }
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

    static func speedMultiplier(for device: TamaDevice) -> Int {
        let stored = UserDefaults.standard.object(forKey: Keys.speedMultiplier(for: device)) as? Int ?? 1
        return speedLadder.contains(stored) ? stored : 1
    }

    static func setSpeedMultiplier(_ value: Int, for device: TamaDevice) {
        UserDefaults.standard.set(value, forKey: Keys.speedMultiplier(for: device))
    }

    /// On by default: a real Tamagotchi's screen goes black to save its
    /// own battery, but that's pointless to reproduce here — the host
    /// device already has its own screen-sleep, and the blanked emulated
    /// panel just looked like a bug (e.g. right after relaunch).
    static func stayAwake(for device: TamaDevice) -> Bool {
        UserDefaults.standard.object(forKey: Keys.stayAwake(for: device)) as? Bool ?? true
    }

    static func setStayAwake(_ value: Bool, for device: TamaDevice) {
        UserDefaults.standard.set(value, forKey: Keys.stayAwake(for: device))
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

    /// Off by default: the Tama stays a "toy" that respects the phone's
    /// silent switch, matching the original product default. On, it plays
    /// through the ring/silent switch — the AVAudioSession category this
    /// drives also means it'll duck/pause other audio apps while active,
    /// same as any game that offers this option.
    static var ignoreSilentSwitch: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.ignoreSilentSwitch) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.ignoreSilentSwitch) }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
