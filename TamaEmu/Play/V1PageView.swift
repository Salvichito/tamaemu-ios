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
    @State private var shakeDetector = ShakeDetector()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppSettings.Keys.hapticsEnabled) private var hapticsEnabled = true

    private static let holdThreshold: Duration = .milliseconds(180)

    var body: some View {
        pageContent
            // Tapping the "shell" -- anywhere on the page that isn't the
            // screen or a button -- taps the toy's tap sensor (Angel,
            // Morino, Umino). The screen and buttons sit on top and keep
            // their own touches.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if V1IconProfile.hasTapSensor(viewModel.selectedDevice.id) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { viewModel.tapSensor() }
                }
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView()
            }
            // Shake the phone = tap the toy's shell (Angel, Morino, Umino).
            // The motion sensor runs only while this page is live and the
            // app is in front.
            .onChange(of: listensForShake, initial: true) { _, listen in
                if listen {
                    shakeDetector.start { viewModel.tapSensor() }
                } else {
                    shakeDetector.stop()
                }
            }
            .onDisappear { shakeDetector.stop() }
            .sensoryFeedback(trigger: viewModel.sensorTaps) { _, _ in
                hapticsEnabled ? .impact(weight: .medium) : nil
            }
    }

    private var pageContent: some View {
        VStack(spacing: 16) {
            ZStack {
                P1ScreenView(
                    state: viewModel.screenState,
                    deviceID: viewModel.selectedDevice.id,
                    onButton: buttonsDisabled ? nil : { button, down in
                        if down { viewModel.pressButton(button) } else { viewModel.releaseButton(button) }
                    },
                    onIconTap: buttonsDisabled ? nil : { viewModel.openMenuIcon(light: $0) }
                )
                .frame(maxWidth: 280)
                .glassScreenFrame(cornerRadius: P1ScreenView.cornerRadius, glare: true)
                .modifier(ShellWobble(taps: viewModel.sensorTaps))
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
            .overlay {
                // Tap to pause / hold to fast-forward. On a model whose
                // icons take touches (Yasashii, tappable P1 icons), only
                // the middle band around the pixels takes it, so pressing
                // an icon doesn't also pause the Tama.
                GeometryReader { geo in
                    let side = min(geo.size.width, geo.size.height)
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: side, height: hasScreenButtons ? side * 0.5 : side)
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
                onRelease: { viewModel.releaseButton($0) },
                buttons: V1IconProfile.padButtons(for: viewModel.selectedDevice.id)
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

    private var listensForShake: Bool {
        V1IconProfile.hasTapSensor(viewModel.selectedDevice.id) && viewModel.isLive && scenePhase == .active
    }

    /// Icons that take touches (Yasashii's care buttons, or tappable
    /// menu icons): pause/fast-forward then only listens to the middle band.
    private var hasScreenButtons: Bool {
        let id = viewModel.selectedDevice.id
        return V1IconProfile.forDevice(id).hasButtons || V1IconProfile.tappableMenuLights(for: id) != nil
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

/// A quick side-to-side wobble of the screen each time the shell is
/// tapped, so a shake visibly "lands".
private struct ShellWobble: ViewModifier {
    let taps: Int
    @State private var offset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .onChange(of: taps) {
                Task { @MainActor in
                    for x in [6.0, -5.0, 3.0, -2.0, 0.0] {
                        withAnimation(.easeInOut(duration: 0.05)) { offset = x }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                }
            }
    }
}
