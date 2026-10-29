import CTama

public struct TamaDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    /// Expected size, in bytes, of this device's ROM dump — the only thing
    /// about a `.bin` file we can check before the user tells us what it is.
    /// Several devices share the same size, so it narrows candidates rather
    /// than uniquely identifying one.
    public let romSize: Int

    fileprivate init(profile: UnsafePointer<DeviceProfile>) {
        id = String(cString: profile.pointee.name)
        title = String(cString: profile.pointee.title)
        romSize = Int(profile.pointee.rom_size)
    }
}

public enum DeviceCatalog {
    public static func all() -> [TamaDevice] {
        var result: [TamaDevice] = []
        var i: Int = 0
        while let p = device_at(i) {
            result.append(TamaDevice(profile: p))
            i += 1
        }
        return result
    }

    public static func find(name: String) -> TamaDevice? {
        guard let p = device_find(name) else { return nil }
        return TamaDevice(profile: p)
    }

    public static func defaultDevice() -> TamaDevice {
        TamaDevice(profile: device_default())
    }
}
