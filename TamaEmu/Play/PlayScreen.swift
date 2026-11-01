import SwiftUI

struct PlayScreen: View {
    @State private var viewModel = PlayViewModel()
    @State private var showingSettings = false
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(AppSettings.Keys.accentColorIndex) private var accentColorIndex = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ZStack {
                    LCDView(image: viewModel.lcdImage)
                        .frame(maxWidth: 280)

                    if viewModel.isLoading {
                        VStack(spacing: 6) {
                            ProgressView()
                            Text("Catching up…")
                                .font(.caption2)
                                .foregroundStyle(.white)
                        }
                        .padding(10)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }

                if viewModel.hasFirmware {
                    Text(viewModel.selectedDevice.title)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ButtonPad(
                        onPress: { viewModel.pressButton($0) },
                        onRelease: { viewModel.releaseButton($0) }
                    )
                    .disabled(viewModel.isLoading)
                    .opacity(viewModel.isLoading ? 0.4 : 1)
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
            .navigationTitle("")
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
