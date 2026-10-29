import SwiftUI
import TamaCore
import UniformTypeIdentifiers

/// Lets the user pick their own ROM dump. Never bundles firmware, and never
/// uploads it anywhere — it's copied straight into the app's own sandbox.
///
/// Device identity is asked for AFTER the file is picked, not before: ROM
/// size narrows the real device down to a short list (several devices share
/// the same size, so it can't fully identify one — see the comment at the
/// top of device.c), and only that short list is shown, pre-selected to its
/// first match, matching how the original emulator's own import flow works.
struct FirmwareImportView: View {
    let devices: [TamaDevice]
    var onImported: (TamaDevice, URL) -> Void

    @State private var showingPicker = false
    @State private var errorMessage: String?
    @State private var pendingImport: PendingImport?

    private struct PendingImport {
        let url: URL
        let candidates: [TamaDevice]
        var selected: TamaDevice
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("No firmware loaded")
                .font(.headline)
            Text("Import a ROM dump (.bin) from a Tamagotchi device you own. Firmware is never bundled with this app and never leaves your device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let pending = pendingImport {
                Text("This file's size matches more than one device. Which one is it?")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Picker("Device", selection: Binding(
                    get: { pendingImport?.selected ?? pending.selected },
                    set: { pendingImport?.selected = $0 }
                )) {
                    ForEach(pending.candidates) { device in
                        Text(device.title).tag(device)
                    }
                }
                .pickerStyle(.menu)
                Button("Use this device") { confirmImport() }
                    .buttonStyle(.borderedProminent)
                Button("Cancel") { cancelImport() }
                    .font(.footnote)
            } else {
                Button("Import firmware (.bin)") { showingPicker = true }
                    .buttonStyle(.borderedProminent)
            }

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
                handlePicked(url)
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    private func handlePicked(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            errorMessage = "Could not access the selected file."
            return
        }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            url.stopAccessingSecurityScopedResource()
            errorMessage = "Could not read the selected file."
            return
        }
        let candidates = devices.filter { $0.romSize == size }
        errorMessage = nil
        switch candidates.count {
        case 0:
            url.stopAccessingSecurityScopedResource()
            let supportedSizes = Set(devices.map(\.romSize)).sorted()
                .map { "\($0 / (1024 * 1024)) MB" }
                .joined(separator: ", ")
            errorMessage = "This file is \(size) bytes, which doesn't match any supported device (expected one of: \(supportedSizes)). Make sure this is the right ROM dump."
        case 1:
            // Access stays open — importFile(url:device:) closes it.
            importFile(url: url, device: candidates[0])
        default:
            // Ambiguous: several devices share this ROM size. Access stays
            // open until the user confirms or cancels.
            pendingImport = PendingImport(url: url, candidates: candidates, selected: candidates[0])
        }
    }

    private func confirmImport() {
        guard let pending = pendingImport else { return }
        importFile(url: pending.url, device: pending.selected)
    }

    private func cancelImport() {
        pendingImport?.url.stopAccessingSecurityScopedResource()
        pendingImport = nil
    }

    private func importFile(url: URL, device: TamaDevice) {
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let paths = SavePaths(device: device)
            try paths.ensureDirectoriesExist()
            let destination = paths.importedROMPath
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            errorMessage = nil
            pendingImport = nil
            onImported(device, destination)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
