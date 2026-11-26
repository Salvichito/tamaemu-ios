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

    /// With Ambient Background on, the screen glows into the blurred
    /// backdrop; otherwise it sits in a glass bezel over the theme.
    @ViewBuilder
    private var screen: some View {
        if ambientBackgroundEnabled {
            LiveLCD(viewModel: viewModel, glow: true)
        } else {
            LiveLCD(viewModel: viewModel, glow: false)
                .glassScreenFrame(cornerRadius: LiveLCD.width * LCDView.cornerRadiusRatio)
        }
    }

    private var pageContent: some View {
        VStack(spacing: 16) {
            ZStack {
                screen
                    .overlay(alignment: .topTrailing) {
                        if viewModel.isFastForwarding && !viewModel.isPaused {
                            FastForwardIndicator()
                        }
                    }

                if viewModel.isPaused {
                    PausedBadge()
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
                    TranslationBubble(text: translatedText, isError: viewModel.translationIsError) {
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

            if let peerName = viewModel.linkPeerName {
                Label("Connected to \(peerName)", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.green.opacity(0.85), in: Capsule())
                    .transition(.opacity)
            }

            ButtonPad(
                onPress: { viewModel.pressButton($0) },
                onRelease: { viewModel.releaseButton($0) }
            )
            .disabled(viewModel.isLoading || viewModel.isPaused)

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

/// The live screen, split out so the per-frame `lcdImage`/`lcdGlowColor`
/// reads re-render only this view. Read inline in the page body, every LCD
/// frame change also re-rendered the A/B/C buttons next to it, and their
/// Liquid Glass visibly flickered from being rebuilt that often.
private struct LiveLCD: View {
    let viewModel: PlayViewModel
    let glow: Bool

    static let width: CGFloat = 280

    var body: some View {
        if glow {
            LCDView(image: viewModel.lcdImage)
                .frame(maxWidth: Self.width)
                .screenGlow(color: viewModel.lcdGlowColor)
        } else {
            LCDView(image: viewModel.lcdImage)
                .frame(maxWidth: Self.width)
        }
    }
}

/// The "Paused" square shown over the screen while a Tama is paused.
/// Same look as Tomomix's, shared by every model's page.
struct PausedBadge: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "pause.circle.fill").font(.system(size: 34))
            Text("Paused").font(.tomo(.footnote))
        }
        .foregroundStyle(.white)
        .frame(width: 96, height: 96)                    // a square
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Tap to resume")
    }
}

/// Small "»" chip shown in the screen's top-right corner while
/// fast-forwarding. Kept tiny and off-center so the animations stay
/// visible. Shared by every model's page.
struct FastForwardIndicator: View {
    var body: some View {
        Image(systemName: "forward.fill")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.black.opacity(0.45), in: Capsule())
            .padding(6)
            .allowsHitTesting(false)
            .accessibilityLabel("Fast-forwarding")
    }
}
