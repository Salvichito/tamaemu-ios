import SwiftUI

/// One gallery page for a Tama-Go/Tamagotchi Friends (T7Emu) Tama. Mirrors
/// V1PageView's shape -- deliberately minimal next to TamaPageView: no
/// pause, no translation bubble, just the screen, buttons and a catch-up
/// overlay for resuming after time away.
struct T7PageView: View {
    let viewModel: T7PlayViewModel
    let ambientBackgroundEnabled: Bool

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                T7ScreenView(state: viewModel.screenState)
                    .frame(maxWidth: 280)

                if viewModel.isLoading {
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
            .disabled(viewModel.isLoading)
            .opacity(viewModel.isLoading ? 0.4 : 1)

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
}
