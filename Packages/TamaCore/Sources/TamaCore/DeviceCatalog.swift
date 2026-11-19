import CTama

/// Which emulator core plays a device. Everything in this catalog used to
/// be `.ctama` implicitly; `.v1` (TamaLib, via TamaLibCore) is the first
/// device family that doesn't speak CTama's `DeviceProfile` C struct at
/// all, so it needs its own, non-`fileprivate` way to build a `TamaDevice`.
public enum TamaDeviceFamily: Hashable, Sendable {
    case ctama
    case v1
    case t7
    /// Tomomix, the built-in original pet: no ROM, no emulator core. Its
    /// rules live in the app (TamaEmu/Tomomix), not in this package.
    case tomomix
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
    // The same core's bigger chip (E0C6S48): 16 KB ROMs. They all share one
    // size, so the import tells them apart by content -- see
    // `v1DeviceID(forROM:)` below.
    TamaDevice(id: "angel", title: "Tamagotchi Angel", romSize: 16384, family: .v1),
    TamaDevice(id: "morino", title: "Tamagotchi Morino", romSize: 16384, family: .v1),
    TamaDevice(id: "umino", title: "Tamagotchi Umino", romSize: 16384, family: .v1),
    TamaDevice(id: "genjintch", title: "Genjintch", romSize: 16384, family: .v1),
    TamaDevice(id: "tamaotch", title: "Tamaotch", romSize: 16384, family: .v1),
    TamaDevice(id: "mothra", title: "Mothra Tamagotchi", romSize: 16384, family: .v1),
    TamaDevice(id: "yasashii", title: "Yasashii Tamagotchi", romSize: 16384, family: .v1),
    TamaDevice(id: "digimon-v1", title: "Digital Monster Ver. 1", romSize: 16384, family: .v1),
    TamaDevice(id: "digimon-v2", title: "Digital Monster Ver. 2", romSize: 16384, family: .v1),
    TamaDevice(id: "digimon-v3", title: "Digital Monster Ver. 3", romSize: 16384, family: .v1),
]

/// Known `.v1` ROM dumps by content fingerprint (`DeviceCatalog.romFingerprint`)
/// -> the device id that plays them. The fingerprints for every ROM but
/// Mothra's are the ones Paramix Studio's own ROM detection uses
/// (mameise/Paramix-Studio, `V1_NAMES` in src/emu.js), so a dump it
/// recognises is recognised here too.
private let v1ROMFingerprints: [UInt32: String] = [
    0x1A03E02A: "p1",        // P1 (Japanese)
    0xEF932FA1: "p1",        // P1 (English)
    0xF0A58E57: "p1",        // P2
    0xD1BF093B: "angel",
    0x4E0B9922: "morino",
    0x0809B7FA: "umino",
    0x02E0C792: "genjintch",
    0x5E1091E3: "tamaotch",
    0x9EBAAAF8: "mothra",
    0xDFEA1952: "yasashii",
    0x58200E73: "digimon-v1",
    0x55DF2A89: "digimon-v2",
    0xD32D442C: "digimon-v3",
]

/// Same reasoning as `v1Devices` -- T7Emu (via T7EmuCore) speaks neither
/// CTama's `DeviceProfile` nor TamaLib's HAL. The two sizes are distinct
/// (640 KB vs. 768 KB), so romSize alone tells them apart during import,
/// same as every other device in this catalog.
private let t7Devices: [TamaDevice] = [
    TamaDevice(id: "tamago", title: "Tama-Go", romSize: 640 * 1024, family: .t7),
    TamaDevice(id: "tamagotchi-friends", title: "Tamagotchi Friends", romSize: 768 * 1024, family: .t7),
]

/// Temporarily off while the T7 (Tama-Go/Tamagotchi Friends) integration
/// gets more polish before shipping -- flip back to `true` when it's ready.
/// Leaving `t7Devices` out of `all()` is enough on its own: `DeviceDetector`
/// only ever matches against whatever `all()` hands it, so a Tama-Go/Friends
/// `.bin` simply won't match any candidate during import (same as any other
/// unrecognized file) while every other device keeps working unchanged.
/// `find(name:)` deliberately still resolves `.t7` ids regardless of this
/// flag, so the rest of the T7 code (engine, views, save paths) stays fully
/// intact and compiling, not half-ripped-out.
private let t7Enabled = false

public enum DeviceCatalog {
    /// The built-in pet. Not part of `all()`, which lists devices a ROM
    /// can be imported for.
    public static let tomomix = TamaDevice(id: "tomomix", title: "Tomomix", romSize: 0, family: .tomomix)

    public static func all() -> [TamaDevice] {
        var result: [TamaDevice] = []
        var i: Int = 0
        while let p = device_at(i) {
            result.append(TamaDevice(profile: p))
            i += 1
        }
        result.append(contentsOf: v1Devices)
        if t7Enabled {
            result.append(contentsOf: t7Devices)
        }
        return result
    }

    public static func find(name: String) -> TamaDevice? {
        if name == tomomix.id {
            return tomomix
        }
        if let v1 = v1Devices.first(where: { $0.id == name }) {
            return v1
        }
        if let t7 = t7Devices.first(where: { $0.id == name }) {
            return t7
        }
        guard let p = device_find(name) else { return nil }
        return TamaDevice(profile: p)
    }

    /// 32-bit FNV-1a over the raw ROM bytes -- cheap, and the same
    /// fingerprint Paramix Studio uses for these ROMs.
    public static func romFingerprint<Bytes: Sequence>(_ bytes: Bytes) -> UInt32 where Bytes.Element == UInt8 {
        var hash: UInt32 = 2166136261
        for byte in bytes {
            hash = (hash ^ UInt32(byte)) &* 16777619
        }
        return hash
    }

    /// The `.v1` device a ROM dump is known to be, or nil for a dump this
    /// catalog has no fingerprint for (the user then picks by hand, same
    /// as any other ambiguous size).
    public static func v1DeviceID(forROM bytes: some Sequence<UInt8>) -> String? {
        v1ROMFingerprints[romFingerprint(bytes)]
    }

    public static func defaultDevice() -> TamaDevice {
        TamaDevice(profile: device_default())
    }
}
