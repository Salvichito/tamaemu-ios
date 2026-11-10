import CTama

/// Which emulator core plays a device. Everything in this catalog used to
/// be `.ctama` implicitly; `.v1` (TamaLib, via TamaLibCore) is the first
/// device family that doesn't speak CTama's `DeviceProfile` C struct at
/// all, so it needs its own, non-`fileprivate` way to build a `TamaDevice`.
public enum TamaDeviceFamily: Hashable, Sendable {
    case ctama
    case v1
}

public struct TamaDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    /// Expected size, in bytes, of this device's ROM dump — the only thing
    /// about a `.bin` file we can check before the user tells us what it is.
    /// Several devices share the same size, so it narrows candidates rather
    /// than uniquely identifying one.
    public let romSize: Int
    public let family: TamaDeviceFamily

    fileprivate init(profile: UnsafePointer<DeviceProfile>) {
        id = String(cString: profile.pointee.name)
        title = String(cString: profile.pointee.title)
        romSize = Int(profile.pointee.rom_size)
        family = .ctama
    }

    fileprivate init(id: String, title: String, romSize: Int, family: TamaDeviceFamily) {
        self.id = id
        self.title = title
        self.romSize = romSize
        self.family = family
    }
}

/// Devices with no CTama `DeviceProfile` to read from, listed by hand. Kept
/// tiny and separate from device.c's table on purpose — these aren't
/// CTama devices at all, just entries this catalog also hands out.
private let v1Devices: [TamaDevice] = [
    // id stays "p1" -- it's the on-disk save-path key, not shown to the
    // user. The title is what needed fixing: this core plays both P1 and
    // P2 ROMs (same chip generation, same romSize), so "(P1)" overclaimed.
    TamaDevice(id: "p1", title: "Tamagotchi (Original)", romSize: 12288, family: .v1),
]

public enum DeviceCatalog {
    public static func all() -> [TamaDevice] {
        var result: [TamaDevice] = []
        var i: Int = 0
        while let p = device_at(i) {
            result.append(TamaDevice(profile: p))
            i += 1
        }
        result.append(contentsOf: v1Devices)
        return result
    }

    public static func find(name: String) -> TamaDevice? {
        if let v1 = v1Devices.first(where: { $0.id == name }) {
            return v1
        }
        guard let p = device_find(name) else { return nil }
        return TamaDevice(profile: p)
    }

    public static func defaultDevice() -> TamaDevice {
        TamaDevice(profile: device_default())
    }
}
