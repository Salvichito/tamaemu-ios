import SwiftUI
import TamaCore
import UniformTypeIdentifiers

/// Lets the user pick their own ROM dump. Never bundles firmware, and never
/// uploads it anywhere — it's copied straight into the app's own sandbox.
struct FirmwareImportView: View {
    @Binding var selectedDevice: TamaDevice
    let devices: [TamaDevice]
    var onImported: (URL) -> Void

    @State private var showingPicker = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 12) {
            Text("No firmware loaded")
                .font(.headline)
            Text("Import a ROM dump (.bin) from a Tamagotchi device you own. Firmware is never bundled with this app and never leaves your device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Picker("Device", selection: $selectedDevice) {
                ForEach(devices) { device in
                    Text(device.title).tag(device)
                }
            }
            .pickerStyle(.menu)

            Button("Import firmware (.bin)") { showingPicker = true }
                .buttonStyle(.borderedProminent)

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .fileImporter(isPresented: $showingPicker, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url):
                importFile(at: url)
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    private func importFile(at url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            errorMessage = "Could not access the selected file."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let paths = SavePaths(device: selectedDevice)
            try paths.ensureDirectoriesExist()
            let destination = paths.importedROMPath
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            errorMessage = nil
            onImported(destination)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
