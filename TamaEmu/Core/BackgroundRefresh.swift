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
        // iOS signals "your time is up" by cancelling this task. The
        // catch-up loops below are plain synchronous code that would never
        // notice on their own, so the handler flips a flag they poll.
        // Stopping promptly matters: a pass that overruns gets the whole
        // app suspended mid-save (or killed), which is exactly what used
        // to leave a Tama's clock hours behind -- the frozen pass resumed
        // whenever the app was next opened and saved as if no time had
        // passed in between.
        let expired = CancelFlag()
        await withTaskCancellationHandler {
            runPass(shouldAbort: { expired.isCancelled || isAppActive })
        } onCancel: {
            expired.cancel()
        }
    }

    private static func runPass(shouldAbort: @escaping () -> Bool) {
        let owned = ActiveDeviceLookup.allImported().filter { !DevicePauseState.isPaused($0) }
        guard !owned.isEmpty else { return }
        let ordered = BackgroundRefreshCursor.ordered(owned)

        // No UI is blocked here, unlike the foreground launch path, so this
        // can afford to catch up far more of the gap per wake-up — but now
        // the ~30s-ish BGAppRefreshTask ceiling has to be shared across
        // however many owned, unpaused Tamas need a pass. Each device gets
        // an even share of whatever is left (leaving slack under the real
        // ceiling), so a Tama that finishes early hands its unused time to
        // the ones after it; the cursor above is what keeps that fair
        // across repeated wake-ups.
        let passStart = DispatchTime.now().uptimeNanoseconds
        let totalBudget: TimeInterval = 25.0

        for (index, device) in ordered.enumerated() {
            // The player may have opened the app while this task was
            // queued or mid-run. If so, the foreground launch path's own
            // catch-up is the one that should run — it knows to stay
            // silent since the player is already looking at the screen,
            // unlike this headless pass, which exists specifically to
            // warn them *before* they do.
            guard !shouldAbort() else { return }
            let spent = Double(DispatchTime.now().uptimeNanoseconds - passStart) / 1_000_000_000
            let budget = (totalBudget - spent) / Double(ordered.count - index)
            guard budget > 0.25 else { return }

            // Skip (rather than wait for) a Tama something else is using
            // right now — that can only be the foreground, which will
            // catch it up itself. See EngineGate.
            let gate = EngineGate.gate(for: device)
            guard gate.acquire(timeout: 0.5) else { continue }
            refresh(device, budget: budget, shouldAbort: shouldAbort)
            gate.release()

            BackgroundRefreshCursor.recordStoppedAfter(device)
        }
    }

    /// One Tama's headless catch-up + save. Caller holds its EngineGate.
    private static func refresh(_ device: TamaDevice, budget: TimeInterval, shouldAbort: @escaping () -> Bool) {
        let paths = SavePaths(device: device)
        let notifyCall = {
            guard !isAppActive else { return }
            NotificationScheduler.fireCallingNotification(deviceTitle: device.title)
            // A real heads-up just went out — no need for the dumb
            // "it's been a while" reminder on top of it.
            ReminderNotificationScheduler.cancel()
        }

        switch device.family {
        case .ctama:
            guard let engine = try? EmulatorEngine(
                device: device,
                savePaths: paths,
                catchUpWallClockBudget: budget,
                shouldAbort: shouldAbort,
                onCallDetected: notifyCall
            ) else { return }
            // init() already ran its catch-up pass. Publish + save, then
            // let `engine` deallocate — it was never start()ed, so there's
            // no thread to stop and no concurrent writer for save() to
            // worry about, same as the foreground path's precondition.
            // save() records how far the pass really got, so a pass cut
            // short here (budget, expiry, the app being opened) leaves the
            // rest owed rather than forgotten.
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
                  let savedState = try? Data(contentsOf: paths.v1StatePath),
                  let caughtUpTo = paths.lastSavedAt else { return }
            let owed = Date().timeIntervalSince(caughtUpTo)
            guard owed > 1 else { return }
            let result = V1EmulatorEngine.catchUp(
                romWords: V1EmulatorEngine.parseROM(romData),
                from: savedState,
                backlogSeconds: owed,
                wallClockBudget: budget,
                shouldAbort: shouldAbort,
                onCallDetected: notifyCall
            )
            guard result.advancedSeconds > 0 else { return }
            try? paths.ensureDirectoriesExist()
            // Forward by exactly what was emulated — never "now". Stamping
            // "now" here is what made a P1's clock fall behind for good
            // whenever a pass ran out of time before closing the gap.
            if (try? result.state.write(to: paths.v1StatePath, options: .atomic)) != nil {
                paths.lastSavedAt = caughtUpTo.addingTimeInterval(result.advancedSeconds)
            }

        case .t7:
            // No widget image and no call-detection notification yet,
            // same reasoning as .v1 above for the image, plus T7's
            // 10 icons have no confirmed "needs attention" equivalent
            // yet either (see T7EmulatorEngine's own doc comment) --
            // catch-up alone still runs so the Tama isn't frozen in
            // time the next time its page is opened.
            guard let romData = try? Data(contentsOf: paths.importedROMPath),
                  let savedState = try? Data(contentsOf: paths.t7StatePath),
                  let caughtUpTo = paths.lastSavedAt else { return }
            let savedEeprom = try? Data(contentsOf: paths.t7EepromPath)
            let owed = Date().timeIntervalSince(caughtUpTo)
            guard owed > 1 else { return }
            let result = T7EmulatorEngine.catchUp(
                romData: romData,
                eepromData: savedEeprom,
                from: savedState,
                backlogSeconds: owed,
                wallClockBudget: budget,
                shouldAbort: shouldAbort
            )
            guard result.advancedSeconds > 0 else { return }
            try? paths.ensureDirectoriesExist()
            if (try? result.state.write(to: paths.t7StatePath, options: .atomic)) != nil {
                paths.lastSavedAt = caughtUpTo.addingTimeInterval(result.advancedSeconds)
            }
            if let eeprom = result.eeprom {
                try? eeprom.write(to: paths.t7EepromPath, options: .atomic)
            }
        }
    }
}

/// A thread-safe "stop what you're doing" flag for a catch-up pass running
/// off the main thread. Catch-up loops poll it between batches of steps,
/// so a pass that's been superseded (page swiped away, app backgrounded,
/// the background task's time ran out) stops within milliseconds instead
/// of grinding on for the rest of its budget.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}

/// Makes sure only one thing at a time is loading, advancing, or saving a
/// given Tama's state: a foreground load/catch-up, the live engine, or a
/// headless BackgroundRefresh pass. Without it those could overlap -- e.g.
/// a background pass still mid-flight when the app is opened, or a
/// catch-up that was swiped away from but hadn't noticed yet -- and
/// whichever finished last would overwrite the other's save with an older
/// one. For the V1 and T7 families it's worse than a lost save: those
/// cores keep their state in C globals, so two users at once corrupt each
/// other's CPU state outright -- hence one gate per *family* there, but
/// one per device for CTama (each of its engines owns its own memory).
///
/// A plain semaphore rather than a lock on purpose: ownership is handed
/// from the background load task to the live engine and released later
/// from the main thread, which a thread-bound lock doesn't allow.
final class EngineGate: @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var gates: [String: EngineGate] = [:]

    static func gate(for device: TamaDevice) -> EngineGate {
        let key: String
        switch device.family {
        case .ctama: key = "ctama." + device.id
        case .v1: key = "v1"
        case .t7: key = "t7"
        }
        registryLock.lock(); defer { registryLock.unlock() }
        if let existing = gates[key] { return existing }
        let gate = EngineGate()
        gates[key] = gate
        return gate
    }

    private let semaphore = DispatchSemaphore(value: 1)

    /// False if the gate is still held by someone else after `timeout`.
    func acquire(timeout: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + timeout) == .success
    }

    func release() {
        semaphore.signal()
    }
}
