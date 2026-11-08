import SwiftUI

/// One gallery page for a P1-era (TamaLib) Tama. Deliberately minimal next
/// to TamaPageView: no pause (no save/resume for this core yet), no
/// translation bubble, no loading overlay (there's no catch-up pass to
/// wait on -- starting the core is effectively instant).
struct V1PageView: View {
    let viewModel: V1PlayViewModel
    let ambientBackgroundEnabled: Bool

    var body: some View {
        VStack(spacing: 16) {
            P1ScreenView(state: viewModel.screenState)
                .frame(maxWidth: 280)

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
