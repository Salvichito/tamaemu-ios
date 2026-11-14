import SwiftUI

/// One gallery page for a P1-era (TamaLib) Tama. Same as TamaPageView
/// minus the translation bubble: tapping the screen toggles pause, holding
/// it down fast-forwards at 2x for as long as the hold lasts -- see that
/// view's own comments for why the gesture is built the way it is.
struct V1PageView: View {
    let viewModel: V1PlayViewModel
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
                P1ScreenView(state: viewModel.screenState)
                    .frame(maxWidth: 280)

                if viewModel.isPaused {
                    badge(systemImage: "pause.circle.fill", text: "Paused — tap to resume")
                } else if viewModel.isFastForwarding {
                    badge(systemImage: "forward.fill", text: "2× speed")
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
