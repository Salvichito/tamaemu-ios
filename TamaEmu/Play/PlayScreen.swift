import SwiftUI

struct PlayScreen: View {
    @State private var viewModel = PlayViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 16) {
            Text("TamaEmu")
                .font(.title.bold())
            LCDView(image: viewModel.lcdImage)
                .frame(maxWidth: 280)
                .border(Color.gray)

            if viewModel.hasFirmware {
                Text("Running: \(viewModel.selectedDevice.title)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ButtonPad(
                    onPress: { viewModel.pressButton($0) },
                    onRelease: { viewModel.releaseButton($0) }
                )
            } else {
                FirmwareImportView(
                    selectedDevice: $viewModel.selectedDevice,
                    devices: viewModel.devices,
                    onImported: { url in
                        viewModel.firmwareImported(for: viewModel.selectedDevice, at: url)
                    }
                )
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .padding()
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                viewModel.stopEngine()
            case .active:
                viewModel.resumeIfNeeded()
            default:
                break
            }
        }
    }
}

#Preview {
    PlayScreen()
}
