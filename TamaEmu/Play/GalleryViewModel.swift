import Foundation
import Observation
import TamaCore

/// Owns the set of owned Tamas and one cached PlayViewModel per device.
/// Construction of a PlayViewModel is cheap and side-effect free (see its
/// own doc comment) — only this class's appear/disappear hooks actually
/// start or stop a device's engine, so exactly one is ever live at a time
/// no matter how many are owned.
@MainActor
@Observable
final class GalleryViewModel {
    private(set) var ownedDevices: [TamaDevice]
    var selectedPage: TamaDevice.ID?
    var showingImport = false

    private var viewModels: [TamaDevice.ID: PlayViewModel] = [:]

    init() {
        ownedDevices = ActiveDeviceLookup.allImported()
        selectedPage = ownedDevices.first?.id
        WidgetSharedState.publishOwnedDevices(ownedDevices)
        if let first = ownedDevices.first {
            pageDidAppear(first)
        }
    }

    func viewModel(for device: TamaDevice) -> PlayViewModel {
        if let existing = viewModels[device.id] { return existing }
        let vm = PlayViewModel(device: device)
        viewModels[device.id] = vm
        return vm
    }

    func device(withID id: TamaDevice.ID) -> TamaDevice? {
        ownedDevices.first { $0.id == id }
    }

    /// A page became the one on screen — bring its engine up if it isn't
    /// already (a no-op if it's already running, e.g. right after its own
    /// construction already started it).
    func pageDidAppear(_ device: TamaDevice) {
        viewModel(for: device).resumeIfNeeded()
    }

    /// A page stopped being the one on screen — stop its engine, saving
    /// and publishing its last frame, same as backgrounding today.
    func pageDidDisappear(_ device: TamaDevice) {
        viewModels[device.id]?.stopEngine()
    }

    /// A device was just imported — either brand new, or an existing
    /// owned device whose ROM/save was just replaced via the overwrite
    /// confirmation in FirmwareImportView. Either way the files on disk
    /// just changed, so any cached PlayViewModel for it must be discarded
    /// (after stopping its engine, in case it was live) rather than kept
    /// around holding stale in-memory state.
    func deviceImported(_ device: TamaDevice) {
        viewModels[device.id]?.stopEngine()
        viewModels[device.id] = nil
        if !ownedDevices.contains(where: { $0.id == device.id }) {
            ownedDevices.append(device)
        }
        selectedPage = device.id
        WidgetSharedState.publishOwnedDevices(ownedDevices)
    }

    /// Removes a Tama entirely: stop its engine, delete its save data, and
    /// drop it from the gallery.
    func removeDevice(_ device: TamaDevice) {
        viewModels[device.id]?.stopEngine()
        PlayViewModel.removeDeviceData(device)
        viewModels[device.id] = nil
        ownedDevices.removeAll { $0.id == device.id }
        WidgetSharedState.publishOwnedDevices(ownedDevices)
        if selectedPage == device.id {
            selectedPage = ownedDevices.first?.id
            if let newSelection = selectedPage, let newDevice = self.device(withID: newSelection) {
                pageDidAppear(newDevice)
            }
        }
    }
}
