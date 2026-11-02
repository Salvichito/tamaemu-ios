import SwiftUI

@main
struct TamaEmuApp: App {
    init() {
        NotificationScheduler.configure()
        BackgroundRefresh.observeAppState()
    }

    var body: some Scene {
        WindowGroup {
            TamaGalleryView()
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.taskID)) {
            await BackgroundRefresh.run()
            BackgroundRefresh.scheduleNext()
        }
    }
}
