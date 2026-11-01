import BackgroundTasks
import Foundation
import TamaCore

/// Runs on whatever schedule iOS grants a BGAppRefreshTask — no guarantee
/// of cadence, just "sometime, probably minutes to longer from now". Does
/// the same catch-up + call-check + publish the foreground path does, but
/// headless: never calls EmulatorEngine.start(), so there's no dedicated
/// thread and no audio engine spun up — just init()'s one-shot catch-up.
enum BackgroundRefresh {
    static let taskID = "com.fluorescente.TamaEmu.refresh"

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
            let paths = SavePaths(device: device)
            guard let engine = try? EmulatorEngine(
                device: device,
                savePaths: paths,
                catchUpWallClockBudget: perDeviceBudget,
                onCallDetected: {
                    NotificationScheduler.fireCallingNotification(deviceTitle: device.title)
                }
            ) else {
                BackgroundRefreshCursor.recordStoppedAfter(device)
                continue
            }
            // init() already ran its catch-up pass. Publish + save, then
            // let `engine` deallocate — it was never start()ed, so there's
            // no thread to stop and no concurrent writer for save() to
            // worry about, same as the foreground path's precondition.
            if let image = LCDImageBuilder.makeImage(from: engine.renderCurrentFrame(), width: 128, height: 128) {
                WidgetSharedState.publish(image: image, device: device)
            }
            engine.save()
            BackgroundRefreshCursor.recordStoppedAfter(device)
        }
    }
}
