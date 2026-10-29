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
        guard let device = ActiveDeviceLookup.find() else { return }
        let paths = SavePaths(device: device)
        guard let engine = try? EmulatorEngine(device: device, savePaths: paths, onCallDetected: {
            NotificationScheduler.fireCallingNotification(deviceTitle: device.title)
        }) else { return }
        // init() already ran its catch-up pass. Publish + save, then let
        // `engine` deallocate — it was never start()ed, so there's no
        // thread to stop and no concurrent writer for save() to worry
        // about, same as the foreground path's precondition.
        if let image = LCDImageBuilder.makeImage(from: engine.renderCurrentFrame(), width: 128, height: 128) {
            WidgetSharedState.publish(image: image, deviceTitle: device.title)
        }
        engine.save()
    }
}
