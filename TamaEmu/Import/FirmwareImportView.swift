import SwiftUI
import TamaCore
import UniformTypeIdentifiers

/// Lets the user pick their own ROM dump. Never bundles firmware, and never
/// uploads it anywhere — it's copied straight into the app's own sandbox.
///
/// Device identity is asked for AFTER the file is picked, not before: ROM
/// size narrows the real device down to a short list (several devices share
/// the same size, so it can't fully identify one — see the comment at the
/// top of device.c), then DeviceDetector looks inside the file to pick the
/// exact one. Only when that isn't certain is the user asked, with the best
/// guess pre-selected.
struct FirmwareImportView: View {
    let devices: [TamaDevice]
    var onImported: (TamaDevice, URL) -> Void

    @State private var showingPicker = false
    @State private var errorMessage: String?
    @State private var pendingImport: PendingImport?
    @State private var pendingOverwrite: PendingOverwrite?

    private struct PendingImport {
        let url: URL
        let candidates: [TamaDevice]
        var selected: TamaDevice
        /// The first candidate is a real best guess from the file's
        /// contents, not just the first device of that size.
        let hasGuess: Bool
    }

    private struct PendingOverwrite {
        let url: URL
        let device: TamaDevice
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Import a ROM dump (.bin) from a Tamagotchi device you own. Firmware is never bundled with this app and never leaves your device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let pending = pendingImport {
                Text(pending.hasGuess
                     ? "This looks like a \(pending.candidates[0].title), but this version isn't one the app knows for sure. Please check it's right."
                     : "This file's size matches more than one device. Which one is it?")
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
        .confirmationDialog(
            "You already have a Tama for \(pendingOverwrite?.device.title ?? "")",
            isPresented: Binding(get: { pendingOverwrite != nil }, set: { if !$0 { cancelOverwrite() } }),
            titleVisibility: .visible
        ) {
            Button("Replace it", role: .destructive) { confirmOverwrite() }
            Button("Cancel", role: .cancel) { cancelOverwrite() }
        } message: {
            Text("Importing here replaces its current save data. This can't be undone.")
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
        // Size narrows it down; the file's contents usually settle it (see
        // DeviceDetector). Only read the file when size alone isn't enough.
        let sizeMatches = DeviceDetector.candidates(forFileSize: size, in: devices)
        let rom = sizeMatches.count > 1 ? try? Data(contentsOf: url, options: .mappedIfSafe) : nil
        let detection = DeviceDetector.detect(size: size, rom: rom, in: devices)
        let candidates = detection.candidates
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
            // The list is ordered best guess first.
            pendingImport = PendingImport(url: url, candidates: candidates, selected: candidates[0],
                                          hasGuess: rom != nil && candidates[0].family == .ctama)
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
        // Several real Tamas can be owned at once now, each keyed by
        // device.id — don't silently clobber an existing one's save data
        // just because the ambiguous-size picker (or a re-import) landed
        // on an already-owned model. Access stays open until confirmed or
        // cancelled, same as the ambiguous-device picker above.
        if ActiveDeviceLookup.hasImportedROM(device) {
            pendingOverwrite = PendingOverwrite(url: url, device: device)
            errorMessage = nil
            return
        }
        performImport(url: url, device: device)
    }

    private func confirmOverwrite() {
        guard let pending = pendingOverwrite else { return }
        pendingOverwrite = nil
        performImport(url: pending.url, device: pending.device)
    }

    private func cancelOverwrite() {
        pendingOverwrite?.url.stopAccessingSecurityScopedResource()
        pendingOverwrite = nil
    }

    private func performImport(url: URL, device: TamaDevice) {
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
