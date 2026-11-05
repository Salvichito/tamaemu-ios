import SwiftUI

@main
struct TamaEmuApp: App {
    init() {
        NotificationScheduler.configure()
        BackgroundRefresh.observeAppState()
        // The gallery's page dots run with backgroundDisplayMode(.never), so there's
        // no system scrim behind them — the default translucent-gray dot tint reads
        // fine on dark content but nearly disappears on a light background. .label
        // is a dynamic color, so this still adapts correctly per-page even though
        // TamaGalleryView can force light/dark via .preferredColorScheme.
        UIPageControl.appearance().pageIndicatorTintColor = UIColor.label.withAlphaComponent(0.2)
        UIPageControl.appearance().currentPageIndicatorTintColor = UIColor.label.withAlphaComponent(0.8)
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
