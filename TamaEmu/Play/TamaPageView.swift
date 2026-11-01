import SwiftUI
import TamaCore

/// One gallery page: a single Tama's LCD + buttons, with its own overflow
/// menu (pause, settings, delete). Tapping the LCD toggles pause — this can
/// only ever be called on the page currently on screen, so PlayViewModel's
/// togglePause() is safe to act on its own engine directly.
struct TamaPageView: View {
    let viewModel: PlayViewModel
    var onDelete: () -> Void
    var onDeviceImported: (TamaDevice) -> Void

    @State private var showingSettings = false
    @State private var showingDeleteConfirm = false

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                LCDView(image: viewModel.lcdImage)
                    .frame(maxWidth: 280)

                if viewModel.isPaused {
                    VStack(spacing: 6) {
                        Image(systemName: "pause.circle.fill")
                            .font(.title2)
                        Text("Paused — tap to resume")
                            .font(.caption2)
                    }
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else if viewModel.isLoading {
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
            // On the whole stack, not just LCDView — otherwise tapping
            // directly on the "Paused — tap to resume" badge itself (the
            // single most likely place to tap) is swallowed by the badge's
            // own opaque background instead of reaching the gesture below it.
            .contentShape(Rectangle())
            .onTapGesture { viewModel.togglePause() }

            Text(viewModel.selectedDevice.title)
                .font(.footnote)
                .foregroundStyle(.secondary)

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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        viewModel.togglePause()
                    } label: {
                        Label(
                            viewModel.isPaused ? "Resume" : "Pause",
                            systemImage: viewModel.isPaused ? "play.fill" : "pause.fill"
                        )
                    }
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings for \(viewModel.selectedDevice.title)", systemImage: "gearshape")
                    }
                    Button(role: .destructive) {
                        showingDeleteConfirm = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(
                device: viewModel.selectedDevice,
                viewModel: viewModel,
                onDelete: onDelete,
                onDeviceImported: onDeviceImported
            )
        }
        .confirmationDialog(
            "Delete \(viewModel.selectedDevice.title)?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes its firmware and save data from this device. It can be re-imported later, but progress will be lost.")
        }
    }
}
