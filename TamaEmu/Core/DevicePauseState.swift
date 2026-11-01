import Foundation
import TamaCore

/// Whether a device's clock is frozen — excluded from catch-up until
/// manually unpaused. Purely a "stop time for this pet until I come back"
/// toggle, not a performance optimization (a non-visible gallery page is
/// already dormant for free). Mirrors SavePaths' lastSavedAt key pattern.
enum DevicePauseState {
    static func isPaused(_ device: TamaDevice) -> Bool {
        UserDefaults.standard.bool(forKey: key(device))
    }

    static func setPaused(_ paused: Bool, for device: TamaDevice) {
        UserDefaults.standard.set(paused, forKey: key(device))
    }

    static func clear(_ device: TamaDevice) {
        UserDefaults.standard.removeObject(forKey: key(device))
    }

    private static func key(_ device: TamaDevice) -> String { "paused.\(device.id)" }
}
