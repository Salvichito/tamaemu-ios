import SwiftUI
import TamaCore

/// One gallery page for a Tamagotchi Meets / On (T18Emu) Tama: its 128x128
/// color screen in the same frame the color Tamas use, and the A/B/C
/// buttons. Same gestures as every page: tap the screen to pause, hold it
/// to fast-forward (Premium).
struct T18PageView: View {
    let viewModel: T18PlayViewModel

    @Environment(PurchaseManager.self) private var purchases
    /// This Tama's theme; the screen glows only when it's Ambient.
    @AppStorage private var themeRaw: String?
    @State private var showingPaywall = false
    @State private var holdTask: Task<Void, Never>?
    @State private var heldForPaywall = false

    private static let holdThreshold: Duration = .milliseconds(180)

    init(viewModel: T18PlayViewModel) {
        self.viewModel = viewModel
        _themeRaw = AppStorage(AppSettings.Keys.theme(for: viewModel.selectedDevice))
    }

    private var ambientBackgroundEnabled: Bool {
        let device = viewModel.selectedDevice
        return AppTheme.stored(themeRaw, for: device)
            .effective(isPremium: purchases.isPremium, device: device) == .ambient
    }

    var body: some View {
        pageContent
            .sheet(isPresented: $showingPaywall) {
                PaywallView()
            }
    }

    @ViewBuilder
    private var screen: some View {
        if ambientBackgroundEnabled {
            T18LiveLCD(viewModel: viewModel, glow: true)
        } else {
            T18LiveLCD(viewModel: viewModel, glow: false)
                .glassScreenFrame(cornerRadius: T18LiveLCD.width * LCDView.cornerRadiusRatio)
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
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in beginPress() }
                    .onEnded { _ in endPress() }
            )

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

/// The live screen on its own, so a new picture re-renders only this view
/// and not the glass buttons next to it (see TamaPageView's LiveLCD).
private struct T18LiveLCD: View {
    let viewModel: T18PlayViewModel
    let glow: Bool

    static let width: CGFloat = 280

    var body: some View {
        if glow {
            LCDView(image: viewModel.screenImage)
                .frame(maxWidth: Self.width)
                .screenGlow(color: viewModel.glowColor)
        } else {
            LCDView(image: viewModel.screenImage)
                .frame(maxWidth: Self.width)
        }
    }
}
