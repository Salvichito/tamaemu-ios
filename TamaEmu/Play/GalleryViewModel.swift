import Foundation
import Observation
import TamaCore

/// The handful of lifecycle calls GalleryViewModel needs to make without
/// caring which core backs a given device — everything else about
/// PlayViewModel/V1PlayViewModel stays concretely typed for their own
/// views to use.
@MainActor
private protocol EngineLifecycle: AnyObject {
    func resumeIfNeeded()
    func stopEngine()
}

extension PlayViewModel: EngineLifecycle {}
extension V1PlayViewModel: EngineLifecycle {}
extension T7PlayViewModel: EngineLifecycle {}

/// Owns the set of owned Tamas and one cached view-model per device —
/// PlayViewModel for CTama devices, V1PlayViewModel for TamaLib ones.
/// Construction of either is cheap and side-effect free (see their own
/// doc comments) — only this class's appear/disappear hooks actually
/// start or stop a device's engine, so exactly one is ever live at a time
/// no matter how many are owned.
@MainActor
@Observable
final class GalleryViewModel {
    private(set) var ownedDevices: [TamaDevice]
    var selectedPage: TamaDevice.ID?
    var showingImport = false
    var showingReorder = false

    private var viewModels: [TamaDevice.ID: PlayViewModel] = [:]
    private var v1ViewModels: [TamaDevice.ID: V1PlayViewModel] = [:]
    private var t7ViewModels: [TamaDevice.ID: T7PlayViewModel] = [:]

    init() {
        ownedDevices = Self.restoreOrder(of: ActiveDeviceLookup.allImported())
        selectedPage = ownedDevices.first?.id
        WidgetSharedState.publishOwnedDevices(ownedDevices)
        if let first = ownedDevices.first {
            pageDidAppear(first)
        }
    }

    /// Restores the player's last saved gallery order (so the first Tama
    /// they added keeps leading the gallery across relaunches instead of
    /// resetting to catalog order every time). Any device with no saved
    /// position — the very first launch, or one imported before this
    /// ordering existed — falls back to catalog order, after the ones we
    /// do have a position for.
    private static func restoreOrder(of devices: [TamaDevice]) -> [TamaDevice] {
        var remaining = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        var ordered = WidgetSharedState.ownedDeviceIDs().compactMap { remaining.removeValue(forKey: $0) }
        ordered.append(contentsOf: devices.filter { remaining[$0.id] != nil })
        return ordered
    }

    func viewModel(for device: TamaDevice) -> PlayViewModel {
        if let existing = viewModels[device.id] { return existing }
        let vm = PlayViewModel(device: device)
        viewModels[device.id] = vm
        return vm
    }

    func v1ViewModel(for device: TamaDevice) -> V1PlayViewModel {
        if let existing = v1ViewModels[device.id] { return existing }
        let vm = V1PlayViewModel(device: device)
        v1ViewModels[device.id] = vm
        return vm
    }

    func t7ViewModel(for device: TamaDevice) -> T7PlayViewModel {
        if let existing = t7ViewModels[device.id] { return existing }
        let vm = T7PlayViewModel(device: device)
        t7ViewModels[device.id] = vm
        return vm
    }

    /// Already-cached view-model for a device, regardless of family — for
    /// the lifecycle calls below, which don't need to know which kind it
    /// is, and shouldn't create one on demand the way the typed accessors
    /// above do.
    private func cachedEngine(for id: TamaDevice.ID) -> EngineLifecycle? {
        (viewModels[id] as EngineLifecycle?) ?? (v1ViewModels[id] as EngineLifecycle?) ?? (t7ViewModels[id] as EngineLifecycle?)
    }

    func device(withID id: TamaDevice.ID) -> TamaDevice? {
        ownedDevices.first { $0.id == id }
    }

    /// A page became the one on screen — bring its engine up if it isn't
    /// already (a no-op if it's already running, e.g. right after its own
    /// construction already started it).
    func pageDidAppear(_ device: TamaDevice) {
        switch device.family {
        case .ctama: viewModel(for: device).resumeIfNeeded()
        case .v1: v1ViewModel(for: device).resumeIfNeeded()
        case .t7: t7ViewModel(for: device).resumeIfNeeded()
        }
    }

    /// A page stopped being the one on screen — stop its engine, saving
    /// and publishing its last frame, same as backgrounding today.
    func pageDidDisappear(_ device: TamaDevice) {
        cachedEngine(for: device.id)?.stopEngine()
    }

    /// A device was just imported — either brand new, or an existing
    /// owned device whose ROM/save was just replaced via the overwrite
    /// confirmation in FirmwareImportView. Either way the files on disk
    /// just changed, so any cached view-model for it must be discarded
    /// (after stopping its engine, in case it was live) rather than kept
    /// around holding stale in-memory state.
    func deviceImported(_ device: TamaDevice) {
        cachedEngine(for: device.id)?.stopEngine()
        viewModels[device.id] = nil
        v1ViewModels[device.id] = nil
        t7ViewModels[device.id] = nil
        if !ownedDevices.contains(where: { $0.id == device.id }) {
            ownedDevices.append(device)
        }
        selectedPage = device.id
        WidgetSharedState.publishOwnedDevices(ownedDevices)
    }

    /// The player dragged a Tama to a new spot in the gallery — persist the
    /// new order so it survives relaunch and reaches the widget's picker.
    func moveDevices(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        ownedDevices.move(fromOffsets: offsets, toOffset: destination)
        WidgetSharedState.publishOwnedDevices(ownedDevices)
    }

    /// Removes a Tama entirely: stop its engine, delete its save data, and
    /// drop it from the gallery.
    func removeDevice(_ device: TamaDevice) {
        cachedEngine(for: device.id)?.stopEngine()
        switch device.family {
        case .ctama: PlayViewModel.removeDeviceData(device)
        case .v1: V1PlayViewModel.removeDeviceData(device)
        case .t7: T7PlayViewModel.removeDeviceData(device)
        }
        viewModels[device.id] = nil
        v1ViewModels[device.id] = nil
        t7ViewModels[device.id] = nil
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
