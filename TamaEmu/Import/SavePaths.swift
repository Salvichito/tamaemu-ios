import Foundation
import TamaCore

/// Where one device's firmware and save data live on disk, inside
/// Application Support (not Documents — see the project plan for why).
struct SavePaths {
    let device: TamaDevice

    private static var rootDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("TamaEmu", isDirectory: true)
    }

    private var romsDir: URL { Self.rootDirectory.appendingPathComponent("roms", isDirectory: true) }
    private var savesDir: URL { Self.rootDirectory.appendingPathComponent("saves", isDirectory: true) }

    /// The pristine firmware dump as imported by the user. Never overwritten
    /// once imported.
    var importedROMPath: URL { romsDir.appendingPathComponent("\(device.id).bin") }

    /// The live flash/NOR image, including any in-game saved data the
    /// firmware itself has written. Rewritten whenever the core's
    /// `flash_dirty` flag is set.
    var liveFlashPath: URL { savesDir.appendingPathComponent("\(device.id).sav") }

    /// Base path for the full CPU/RAM/clock snapshot. `state_load`/
    /// `state_save` append ".state"/".lock" themselves.
    var stateBasePath: URL { savesDir.appendingPathComponent(device.id) }

    func ensureDirectoriesExist() throws {
        try FileManager.default.createDirectory(at: romsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: savesDir, withIntermediateDirectories: true)
    }
}
