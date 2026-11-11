import SwiftUI
import TamaCore

/// One gallery page: a single Tama's LCD + buttons. The overflow menu
/// (pause, settings, delete) lives on the enclosing NavigationStack in
/// TamaGalleryView, not here — a `.toolbar` defined per page would attach to
/// every page the page-style TabView keeps alive for swiping, and right
/// after launch (before the TabView settles on its initial selection) that
/// could show two pages' toolbars — and so two overflow buttons — at once.
/// Tapping the LCD toggles pause; holding it down fast-forwards at 2x for
/// as long as the hold lasts. Both can only ever happen on the page
/// currently on screen, so PlayViewModel's togglePause()/beginFastForward()/
/// endFastForward() are safe to act on its own engine directly.
struct TamaPageView: View {
    let viewModel: PlayViewModel
    let ambientBackgroundEnabled: Bool

    @Environment(PurchaseManager.self) private var purchases
    @State private var showingPaywall = false

    /// Set once a press has been held long enough to count as "hold" rather
    /// than "tap" — nil while no finger is down. Distinguishing the two
    /// needs a delay before committing to fast-forward, since a tap starts
    /// out looking identical to the first moment of a hold.
    @State private var holdTask: Task<Void, Never>?

    /// Set when a hold was long enough to fire but got turned into a
    /// paywall prompt instead of fast-forward (free tier) — endPress()
    /// checks this so releasing the hold doesn't also toggle pause, which
    /// would otherwise happen since isFastForwarding never went true.
    @State private var heldForPaywall = false

    /// How long a press must be held before it counts as "hold" instead of
    /// "tap" — long enough that a normal tap-to-pause never triggers it,
    /// short enough that fast-forward still feels immediate.
    private static let holdThreshold: Duration = .milliseconds(180)

    var body: some View {
        pageContent
            .sheet(isPresented: $showingPaywall) {
                PaywallView()
            }
    }

    private var pageContent: some View {
        VStack(spacing: 16) {
            ZStack {
                LCDView(image: viewModel.lcdImage)
                    .frame(maxWidth: 280)
                    .screenGlow(color: viewModel.lcdGlowColor)

                if viewModel.isPaused {
                    VStack(spacing: 6) {
                        Image(systemName: "pause.circle.fill")
                            .font(.title2)
                        Text("Paused — tap to resume")
                            .font(.caption2)
                    }
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else if viewModel.isFastForwarding {
                    VStack(spacing: 6) {
                        Image(systemName: "forward.fill")
                            .font(.title2)
                        Text("2× speed")
                            .font(.caption2)
                    }
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else if viewModel.isLoading {
                    VStack(spacing: 6) {
                        ProgressView()
                            .tint(.white)
                        Text("Catching up…")
                            .font(.caption2)
                    }
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            // On the whole stack, not just LCDView — otherwise tapping
            // directly on the "Paused — tap to resume" badge itself (the
            // single most likely place to tap) is swallowed by the badge's
            // own opaque background instead of reaching the gesture below it.
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in beginPress() }
                    .onEnded { _ in endPress() }
            )
            // Floats above the LCD's own frame (overlay, not layout) so it
            // never shifts the title/ButtonPad position while visible.
            .overlay(alignment: .top) {
                if let translatedText = viewModel.translatedText {
                    TranslationBubble(text: translatedText) {
                        viewModel.dismissTranslation()
                    }
                    .offset(y: -64)
                    .task(id: viewModel.translationID) {
                        try? await Task.sleep(for: .seconds(5))
                        viewModel.dismissTranslation()
                    }
                    .transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
                    .zIndex(1)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.translatedText)

            if ambientBackgroundEnabled {
                Text(viewModel.selectedDevice.title)
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .foregroundStyle(.black.opacity(0.25))
            } else {
                Text(viewModel.selectedDevice.title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ButtonPad(
                onPress: { viewModel.pressButton($0) },
                onRelease: { viewModel.releaseButton($0) }
            )
            .disabled(viewModel.isLoading || viewModel.isPaused)
            .opacity(viewModel.isLoading || viewModel.isPaused ? 0.4 : 1)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .padding()
    }

    /// Finger down. Idempotent — SwiftUI's DragGesture re-fires onChanged
    /// on every touch update, not just the first — so this only schedules
    /// the hold check once per press. Skipped entirely while paused: there's
    /// no running engine for fast-forward to speed up, so a hold there
    /// should behave exactly like a tap (handled by endPress below).
    private func beginPress() {
        guard holdTask == nil, !viewModel.isPaused else { return }
        holdTask = Task {
            try? await Task.sleep(for: Self.holdThreshold)
            guard !Task.isCancelled else { return }
            guard purchases.isPremium else {
                heldForPaywall = true
                showingPaywall = true
                return
            }
            viewModel.beginFastForward()
        }
    }

    /// Finger up (or the gesture otherwise ends). If the hold timer above
    /// already fired, this was a hold — end fast-forward. A hold that
    /// surfaced the paywall instead (free tier) isn't a tap either, so it
    /// skips the pause toggle too. Otherwise it was a plain tap — toggle
    /// pause, same as before this gesture existed.
    private func endPress() {
        let wasFastForwarding = viewModel.isFastForwarding
        let wasHeldForPaywall = heldForPaywall
        heldForPaywall = false
        holdTask?.cancel()
        holdTask = nil
        if wasFastForwarding {
            viewModel.endFastForward()
        } else if !wasHeldForPaywall {
            viewModel.togglePause()
        }
    }
}
