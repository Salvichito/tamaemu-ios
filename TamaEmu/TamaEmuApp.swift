import SwiftUI

@main
struct TamaEmuApp: App {
    init() {
        NotificationScheduler.configure()
    }

    var body: some Scene {
        WindowGroup {
            PlayScreen()
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.taskID)) {
            await BackgroundRefresh.run()
            BackgroundRefresh.scheduleNext()
        }
    }
}
