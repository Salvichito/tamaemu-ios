import SwiftUI

/// One gallery page for a Tama-Go/Tamagotchi Friends (T7Emu) Tama. Same
/// shape as V1PageView: tapping the screen toggles pause, holding it down
/// fast-forwards at 2x for as long as the hold lasts (Premium, like the
/// other models). No translation bubble.
struct T7PageView: View {
    let viewModel: T7PlayViewModel
    let ambientBackgroundEnabled: Bool

    @Environment(PurchaseManager.self) private var purchases
    @State private var showingPaywall = false
    @State private var holdTask: Task<Void, Never>?
    @State private var heldForPaywall = false

    private static let holdThreshold: Duration = .milliseconds(180)

    var body: some View {
        pageContent
            .sheet(isPresented: $showingPaywall) {
                PaywallView()
            }
    }

    private func badge(systemImage: String, text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.title2)
            Text(text)
                .font(.caption2)
        }
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var pageContent: some View {
        VStack(spacing: 16) {
            ZStack {
                T7ScreenView(
                    state: viewModel.screenState,
                    isFriends: viewModel.selectedDevice.id == "tamagotchi-friends",
                    onIconTap: buttonsDisabled ? nil : { viewModel.openMenuIcon(light: $0) }
                )
                    .frame(maxWidth: 280)
                    .glassScreenFrame(cornerRadius: T7ScreenView.cornerRadius, glare: true)
                    .overlay(alignment: .topTrailing) {
                        if viewModel.isFastForwarding && !viewModel.isPaused {
                            FastForwardIndicator()
                        }
                    }

                if viewModel.isPaused {
                    badge(systemImage: "pause.circle.fill", text: "Paused — tap to resume")
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
            .overlay {
                // Tap to pause / hold to fast-forward, same gesture as
                // V1PageView (see TamaPageView for why it's built this
                // way). Only the pixel band takes it: the icons above and
                // below are tappable shortcuts.
                GeometryReader { geo in
                    let side = min(geo.size.width, geo.size.height)
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: side, height: side * 0.6)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { _ in beginPress() }
                                .onEnded { _ in endPress() }
                        )
                }
            }

            if ambientBackgroundEnabled {
                Text(viewModel.selectedDevice.title)
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.3))
            } else {
                Text(viewModel.selectedDevice.title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ButtonPad(
                onPress: { viewModel.pressButton($0) },
                onRelease: { viewModel.releaseButton($0) }
            )
            .disabled(buttonsDisabled)

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

    private var buttonsDisabled: Bool { viewModel.isLoading || viewModel.isPaused }

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
