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

    /// Real wall-clock time of the last successful save — not part of the
    /// `.state` snapshot itself (that only knows the emulator's own
    /// simulated clock). Used to compute how much real time to catch up on
    /// the next resume.
    var lastSavedAt: Date? {
        get { UserDefaults.standard.object(forKey: lastSavedAtKey) as? Date }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: lastSavedAtKey) }
    }

    private var lastSavedAtKey: String { "lastSavedAt.\(device.id)" }

    /// Base path for the full snapshot, with `state_save`'s own suffixes
    /// appended — mirrors the plain string concatenation `state_path()`
    /// does in state.c (no extra dot).
    private var stateFilePath: URL { stateBasePath.appendingPathExtension("state") }
    private var stateLockPath: URL { stateBasePath.appendingPathExtension("lock") }

    /// Removes every file this device's ROM/save data occupies, for when the
    /// wrong device was picked at import time and the data underneath it is
    /// simply wrong, not something worth keeping.
    func deleteAll() {
        for url in [importedROMPath, liveFlashPath, stateFilePath, stateLockPath] {
            try? FileManager.default.removeItem(at: url)
        }
        UserDefaults.standard.removeObject(forKey: lastSavedAtKey)
    }
}
