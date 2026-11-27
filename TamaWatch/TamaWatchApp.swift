import SwiftUI

/// Tomomix on Apple Watch: a remote for the Tama on the phone. The Tama
/// keeps living on the iPhone; this shows its screen and sends A/B/C.
@main
struct TamaWatchApp: App {
    @State private var link = WatchLink()

    var body: some Scene {
        WindowGroup {
            WatchScreenView()
                .environment(link)
        }
    }
}
