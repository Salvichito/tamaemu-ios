import BackgroundTasks
import Foundation
import TamaCore
import UIKit

/// Runs on whatever schedule iOS grants a BGAppRefreshTask — no guarantee
/// of cadence, just "sometime, probably minutes to longer from now". Does
/// the same catch-up + call-check + publish the foreground path does, but
/// headless: never calls EmulatorEngine.start(), so there's no dedicated
/// thread and no audio engine spun up — just init()'s one-shot catch-up.
enum BackgroundRefresh {
    static let taskID = "com.fluorescente.TamaEmu.refresh"

    private static let activeLock = NSLock()
    private static var appIsActive = false

    /// Call once at app startup. `UIApplication.shared.applicationState`
    /// needs the main actor, but `run()`'s catch-up loop — and the
    /// `onCallDetected` closure it hands to EmulatorEngine, called from
    /// inside that loop — can't hop there without blocking a tight CPU
    /// loop, so foreground/background is tracked here instead, kept
    /// current by these two notifications and read with a plain lock from
    /// any thread.
    static func observeAppState() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            activeLock.lock(); appIsActive = true; activeLock.unlock()
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
            activeLock.lock(); appIsActive = false; activeLock.unlock()
        }
    }

    private static var isAppActive: Bool {
        activeLock.lock(); defer { activeLock.unlock() }
        return appIsActive
    }

    /// iOS only ever has one pending request per identifier — call this
    /// whenever backgrounding, and again after the task runs, so there's
    /// always one queued.
    static func scheduleNext() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func run() async {
        let owned = ActiveDeviceLookup.allImported().filter { !DevicePauseState.isPaused($0) }
        guard !owned.isEmpty else { return }
        let ordered = BackgroundRefreshCursor.ordered(owned)

        // No UI is blocked here, unlike the foreground launch path, so this
        // can afford to catch up far more of the gap per wake-up — but now
        // the ~30s-ish BGAppRefreshTask ceiling has to be shared across
        // however many owned, unpaused Tamas need a pass. Split evenly up
        // front (leaving slack under the real ceiling) rather than letting
        // whichever device runs first eat the whole budget; the cursor
        // above is what keeps that fair across repeated wake-ups, not this
        // one run's slicing.
        let totalBudget: TimeInterval = 25.0
        let perDeviceBudget = totalBudget / Double(ordered.count)

        for device in ordered {
            // The player may have opened the app while this task was
            // queued or mid-run. If so, the foreground launch path's own
            // catch-up is the one that should run — it knows to stay
            // silent since the player is already looking at the screen,
            // unlike this headless pass, which exists specifically to
            // warn them *before* they do.
            guard !isAppActive else { return }
            let paths = SavePaths(device: device)

            switch device.family {
            case .ctama:
                guard let engine = try? EmulatorEngine(
                    device: device,
                    savePaths: paths,
                    catchUpWallClockBudget: perDeviceBudget,
                    onCallDetected: {
                        guard !isAppActive else { return }
                        NotificationScheduler.fireCallingNotification(deviceTitle: device.title)
                        // A real heads-up just went out — no need for the dumb
                        // "it's been a while" reminder on top of it.
                        ReminderNotificationScheduler.cancel()
                    }
                ) else {
                    break
                }
                // init() already ran its catch-up pass. Publish + save, then
                // let `engine` deallocate — it was never start()ed, so there's
                // no thread to stop and no concurrent writer for save() to
                // worry about, same as the foreground path's precondition.
                if let image = LCDImageBuilder.makeImage(from: engine.renderCurrentFrame(), width: 128, height: 128) {
                    WidgetSharedState.publish(image: image, device: device)
                }
                engine.save()

            case .v1:
                // No widget image published here yet (unlike .ctama above)
                // -- rendering one needs the same icon/background artwork
                // P1ScreenView draws with, which lives in SwiftUI, not
                // something this headless pass can call into. Catch-up and
                // the call notification both work without it, so that's
                // just a gap, not a blocker.
                guard let romData = try? Data(contentsOf: paths.importedROMPath),
                      let savedState = try? Data(contentsOf: paths.v1StatePath) else {
                    break
                }
                let backlogSeconds = paths.lastSavedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0
                guard backlogSeconds > 1 else { break }
                let words = V1EmulatorEngine.parseROM(romData)
                let newState = V1EmulatorEngine.catchUp(
                    romWords: words,
                    from: savedState,
                    backlogSeconds: backlogSeconds,
                    wallClockBudget: perDeviceBudget,
                    onCallDetected: {
                        guard !isAppActive else { return }
                        NotificationScheduler.fireCallingNotification(deviceTitle: device.title)
                        ReminderNotificationScheduler.cancel()
                    }
                )
                try? paths.ensureDirectoriesExist()
                try? newState.write(to: paths.v1StatePath)
                paths.lastSavedAt = Date()

            case .t7:
                // No widget image and no call-detection notification yet,
                // same reasoning as .v1 above for the image, plus T7's
                // 10 icons have no confirmed "needs attention" equivalent
                // yet either (see T7EmulatorEngine's own doc comment) --
                // catch-up alone still runs so the Tama isn't frozen in
                // time the next time its page is opened.
                guard let romData = try? Data(contentsOf: paths.importedROMPath),
                      let savedState = try? Data(contentsOf: paths.t7StatePath) else {
                    break
                }
                let savedEeprom = try? Data(contentsOf: paths.t7EepromPath)
                let backlogSeconds = paths.lastSavedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0
                guard backlogSeconds > 1 else { break }
                let result = T7EmulatorEngine.catchUp(
                    romData: romData,
                    eepromData: savedEeprom,
                    from: savedState,
                    backlogSeconds: backlogSeconds,
                    wallClockBudget: perDeviceBudget
                )
                try? paths.ensureDirectoriesExist()
                try? result.state.write(to: paths.t7StatePath)
                if let eeprom = result.eeprom {
                    try? eeprom.write(to: paths.t7EepromPath)
                }
                paths.lastSavedAt = Date()
            }

            BackgroundRefreshCursor.recordStoppedAfter(device)
        }
    }
}
