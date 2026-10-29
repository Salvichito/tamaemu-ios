import Foundation
import TamaCore

/// Finds whichever device currently has imported firmware — shared between
/// PlayViewModel (foreground) and the BGAppRefreshTask handler (background),
/// so both agree on which save data to catch up and publish.
enum ActiveDeviceLookup {
    static let selectedDeviceIDKey = "selectedDeviceID"

    static func find() -> TamaDevice? {
        let remembered = UserDefaults.standard.string(forKey: selectedDeviceIDKey)
            .flatMap(DeviceCatalog.find(name:))
        if let remembered, hasImportedROM(remembered) {
            return remembered
        }
        return DeviceCatalog.all().first(where: hasImportedROM)
    }

    static func hasImportedROM(_ device: TamaDevice) -> Bool {
        FileManager.default.fileExists(atPath: SavePaths(device: device).importedROMPath.path)
    }
}
