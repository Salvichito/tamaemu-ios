import Foundation
import TamaCore

/// Which devices currently have imported firmware — shared between the
/// gallery (foreground) and the BGAppRefreshTask handler (background), so
/// both agree on which save data to catch up and publish.
enum ActiveDeviceLookup {
    static func hasImportedROM(_ device: TamaDevice) -> Bool {
        FileManager.default.fileExists(atPath: SavePaths(device: device).importedROMPath.path)
    }

    /// Every device the player currently owns (has imported firmware for) —
    /// the gallery's page list, and the set the background refresh pass and
    /// the widget's device picker both draw from.
    static func allImported() -> [TamaDevice] {
        DeviceCatalog.all().filter(hasImportedROM)
    }
}
