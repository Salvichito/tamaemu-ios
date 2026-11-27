import Foundation
import SwiftUI
import TamaCore

/// User-adjustable preferences that affect playback, independent of any one
/// device's save data. Backed by UserDefaults.standard (app-only — nothing
/// here needs to be visible to the widget extension, unlike
/// WidgetSharedState's App Group defaults).
///
/// Plain static accessors, not an @Observable object: these are read from
/// the emulator thread (speed/stay-awake applied at engine start) and the
/// real-time audio render callback (volume), the same informal
/// cross-thread read pattern EmulatorEngine/AudioOutput already use for the
/// core's own tone state. SwiftUI reads/writes them via @AppStorage using
/// the same key strings, so the Settings UI and engine always agree.
enum AppSettings {
    enum Keys {
        static let volume = "settings.volume"
        static let hapticsEnabled = "settings.hapticsEnabled"
        static let catchUpCapHours = "settings.catchUpCapHours"
        static let appearanceMode = "settings.appearanceMode"
        static let sharpPixels = "settings.sharpPixels"
        static let ignoreSilentSwitch = "settings.ignoreSilentSwitch"
        static let pauseOtherAudio = "settings.pauseOtherAudio"
        static let ambientBackgroundEnabled = "settings.ambientBackgroundEnabled"
        static let reminderNotificationsEnabled = "settings.reminderNotificationsEnabled"
        static let reminderIntervalHours = "settings.reminderIntervalHours"
        /// Whether live translation uses a cloud AI (KeychainStore) instead
        /// of the on-device model. The key itself is never stored here —
        /// UserDefaults is not a safe place for a secret — only this
        /// boolean choice.
        static let liveTranslationUsesCloud = "settings.liveTranslationUsesCloud"

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
        /// AppTheme raw value — that device's play-screen backdrop when
        /// there's no Ambient Background (see ThemeBackground).
        static func theme(for device: TamaDevice) -> String {
            "settings.theme.\(device.id)"
        }
    }

    /// `.system` leaves `.preferredColorScheme` unset so the app follows
    /// the OS's own light/dark switch.
    enum AppearanceMode: String, CaseIterable, Identifiable {
        case system, light, dark

        var id: String { rawValue }

        var label: String {
            switch self {
            case .system: "Automatic"
            case .light: "Light"
            case .dark: "Dark"
            }
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    /// Matches the core's own game-clock ladder (`periph_speed_step`), so
    /// "faster"/"slower" in Settings always lands on a value the firmware
    /// itself steps between.
    static let speedLadder = [1, 2, 5, 10, 30, 60, 120, 300, 600]
    static let catchUpCapOptions: [Double] = [0, 1, 6, 24]
    static let reminderIntervalOptions: [Double] = [4, 8, 12, 24]

    /// Read from PlayViewModel (not SwiftUI) when deciding which
    /// translator to call, so it needs a plain accessor alongside the
    /// @AppStorage binding SettingsView itself uses.
    static var liveTranslationUsesCloud: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.liveTranslationUsesCloud) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.liveTranslationUsesCloud) }
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

    /// What the Tamas' sound actually plays at: the volume setting, or
    /// nothing while one runs in the background for the Apple Watch.
    static var playbackVolume: Double {
        WatchRemote.silenced ? 0 : volume
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

    static var sharpPixels: Bool {
        get { UserDefaults.standard.object(forKey: Keys.sharpPixels) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.sharpPixels) }
    }

    static var appearanceMode: AppearanceMode {
        get {
            (UserDefaults.standard.string(forKey: Keys.appearanceMode)).flatMap(AppearanceMode.init) ?? .system
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Keys.appearanceMode) }
    }

    /// The old app-wide Ambient Background switch (on by default). It has
    /// no control any more — Ambient is now a per-Tama theme — and is only
    /// read as color Tamas' default theme (AppTheme.defaultTheme), so
    /// someone who had switched it off keeps their gradients.
    static var ambientBackgroundEnabled: Bool {
        UserDefaults.standard.object(forKey: Keys.ambientBackgroundEnabled) as? Bool ?? true
    }

    /// One-time move from the app-wide switch to the Ambient theme. With
    /// the switch on, a color Tama's stored theme was hidden behind the
    /// glow — so it becomes Ambient, keeping what the user actually saw.
    /// Tamas with no stored theme need nothing (see defaultTheme).
    static func migrateAmbientToTheme() {
        let defaults = UserDefaults.standard
        let doneKey = "settings.ambientMigratedToTheme"
        guard !defaults.bool(forKey: doneKey) else { return }
        if ambientBackgroundEnabled {
            for device in DeviceCatalog.all() where AppTheme.supportsAmbient(device) {
                let key = Keys.theme(for: device)
                if defaults.string(forKey: key) != nil {
                    defaults.set(AppTheme.ambient.rawValue, forKey: key)
                }
            }
        }
        defaults.set(true, forKey: doneKey)
    }

    /// Off by default: this is a state-blind fallback (see
    /// ReminderNotificationScheduler) — it doesn't know whether the Tama
    /// actually needs anything, just that the app hasn't been opened in a
    /// while, so it's opt-in rather than nagging everyone out of the box.
    static var reminderNotificationsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.reminderNotificationsEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.reminderNotificationsEnabled) }
    }

    static var reminderIntervalHours: Double {
        get {
            let stored = UserDefaults.standard.object(forKey: Keys.reminderIntervalHours) as? Double ?? 8
            return reminderIntervalOptions.contains(stored) ? stored : 8
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.reminderIntervalHours) }
    }

    /// Off by default: the Tama respects the phone's silent switch.
    /// Settings shows this inverted, as "Respect Silent Mode" (on by
    /// default); the stored key keeps its original meaning so existing
    /// installs carry their choice over untouched.
    static var ignoreSilentSwitch: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.ignoreSilentSwitch) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.ignoreSilentSwitch) }
    }

    /// Off by default: the Tama's sound plays over music, podcasts and
    /// the like. On, opening the app pauses them, and leaving it lets
    /// them resume.
    static var pauseOtherAudio: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.pauseOtherAudio) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.pauseOtherAudio) }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
