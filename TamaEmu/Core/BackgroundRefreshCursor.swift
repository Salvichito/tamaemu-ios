import Foundation
import TamaCore

/// Persisted round-robin starting point for BackgroundRefresh's multi-device
/// pass. The ~30s OS budget is split evenly across however many owned Tamas
/// need a catch-up this run, so none individually gets much time — rotating
/// who goes *first* each run means a slow device doesn't eat the whole
/// budget and starve the same later devices on every single wake-up; over
/// repeated wake-ups, every owned Tama eventually gets priority.
enum BackgroundRefreshCursor {
    private static let key = "backgroundRefresh.cursor"

    static func ordered(_ devices: [TamaDevice]) -> [TamaDevice] {
        guard !devices.isEmpty else { return [] }
        let lastID = UserDefaults.standard.string(forKey: key)
        let startIndex = devices.firstIndex(where: { $0.id == lastID })
            .map { ($0 + 1) % devices.count } ?? 0
        return Array(devices[startIndex...] + devices[..<startIndex])
    }

    static func recordStoppedAfter(_ device: TamaDevice) {
        UserDefaults.standard.set(device.id, forKey: key)
    }
}
