import SwiftUI

struct PlayScreen: View {
    @State private var viewModel = PlayViewModel()
    @State private var showingSettings = false
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(AppSettings.Keys.accentColorIndex) private var accentColorIndex = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                LCDView(image: viewModel.lcdImage)
                    .frame(maxWidth: 280)
                    .border(Color(.separator))

                if viewModel.hasFirmware {
                    HStack(spacing: 8) {
                        Text("Running: \(viewModel.selectedDevice.title)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Not right? Switch device") { viewModel.resetFirmware() }
                            .font(.footnote)
                    }
                    ButtonPad(
                        onPress: { viewModel.pressButton($0) },
                        onRelease: { viewModel.releaseButton($0) }
                    )
                } else {
                    FirmwareImportView(
                        devices: viewModel.devices,
                        onImported: { device, url in
                            viewModel.firmwareImported(for: device, at: url)
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
            .navigationTitle("TamaEmu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(viewModel: viewModel)
            }
        }
        .tint(TamaPalette.accentColor(at: accentColorIndex))
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                viewModel.stopEngine()
                BackgroundRefresh.scheduleNext()
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
