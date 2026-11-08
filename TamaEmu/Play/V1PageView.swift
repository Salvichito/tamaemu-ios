import SwiftUI

/// One gallery page for a P1-era (TamaLib) Tama. Deliberately minimal next
/// to TamaPageView: no pause, no translation bubble -- just the screen,
/// buttons and a catch-up overlay for resuming after time away.
struct V1PageView: View {
    let viewModel: V1PlayViewModel
    let ambientBackgroundEnabled: Bool

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                P1ScreenView(state: viewModel.screenState)
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
