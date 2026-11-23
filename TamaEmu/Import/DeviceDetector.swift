import Foundation
import TamaCore

/// Works out which device a `.bin` file belongs to.
///
/// ROM size alone can't do it (see the comment at the top of device.c):
/// the P's, iD L, 4U and 4U+ are all 8 MB, and the iD, iD Melody, Plus
/// Color and Hexagontchi are all 4 MB. So after the size check this also
/// looks inside the file, two ways:
///
/// 1. **Family tags.** The 8 MB ROMs name their own resources with a
///    model prefix (`t4u_` for the 4U/4U+, `idn_` for the P's, `id2_` for
///    the iD L), and the 4 MB iD-family ROMs contain the UTF-16 string
///    "ODL_MDP" that the Plus Color/Hexagontchi never do. Fan translations
///    keep these, so they survive patched ROMs.
/// 2. **Reset vector.** The first entry of the ROM's interrupt table (the
///    address the CPU jumps to on power-up) is different for every known
///    firmware build, and translations don't move it.
///
/// Checked against every real dump on hand (12 retail builds, plus 5 fan
/// translations); all identified correctly.
enum DeviceDetector {
    struct Result {
        /// Every device this file could be, the best match first.
        let candidates: [TamaDevice]
        /// True when the contents positively identified one device, so the
        /// user doesn't need to be asked.
        let isCertain: Bool
        var best: TamaDevice? { candidates.first }
    }

    static func candidates(forFileSize size: Int, in devices: [TamaDevice]) -> [TamaDevice] {
        devices.filter { $0.romSize == size }
    }

    static func detect(size: Int, rom: Data?, in devices: [TamaDevice]) -> Result {
        let bySize = candidates(forFileSize: size, in: devices)
        guard bySize.count > 1, let rom else {
            return Result(candidates: bySize, isCertain: bySize.count == 1)
        }

        // First-generation toys: known dumps have a whole-file fingerprint.
        if bySize.allSatisfy({ $0.family == .v1 }) {
            if let id = DeviceCatalog.v1DeviceID(forROM: rom),
               let match = bySize.first(where: { $0.id == id }) {
                return Result(candidates: [match], isCertain: true)
            }
            return Result(candidates: bySize, isCertain: false)
        }

        guard let vector = resetVector(rom) else {
            return Result(candidates: bySize, isCertain: false)
        }
        let ids = Set(bySize.map(\.id))

        // Narrow by family tag, keeping only devices that could actually
        // be picked at this size.
        var narrowed = ids
        if let family = familyIDs(rom), !family.isDisjoint(with: ids) {
            narrowed = family.intersection(ids)
        }

        let known = knownResetVectors[vector].flatMap { narrowed.contains($0) ? $0 : nil }
        let bestID: String?
        let certain: Bool
        if let known {
            bestID = known
            certain = true
        } else if narrowed.count == 1 {
            bestID = narrowed.first
            certain = true
        } else {
            // Unknown build: guess the device whose known builds start
            // closest to this one. Usually right (code layout barely moves
            // between versions of one model), but the user confirms.
            bestID = narrowed.min { distance(vector, to: $0) < distance(vector, to: $1) }
            certain = false
        }

        // Keep every size match in the list so a wrong guess can still be
        // corrected, but put the best one first and the other likely ones
        // right after it.
        let ordered = bySize.enumerated().sorted { a, b in
            let ra = rank(a.element.id, best: bestID, narrowed: narrowed)
            let rb = rank(b.element.id, best: bestID, narrowed: narrowed)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
        return Result(candidates: certain ? [ordered[0]] : ordered, isCertain: certain)
    }

    // MARK: - ROM inspection

    /// The power-up jump address: the interrupt table sits at the start of
    /// a 4 MB ROM, and halfway into an 8 MB one (the CPU boots from
    /// 0x02400000 on those, see `ttbr_reset` in device.c).
    private static func resetVector(_ rom: Data) -> UInt32? {
        let offset: Int
        switch rom.count {
        case 0x400000: offset = 0
        case 0x800000: offset = 0x400000
        default: return nil
        }
        let start = rom.startIndex + offset
        return rom[start..<start + 4].enumerated().reduce(UInt32(0)) { acc, pair in
            acc | UInt32(pair.element) << (8 * UInt32(pair.offset))
        }
    }

    private static func familyIDs(_ rom: Data) -> Set<String>? {
        switch rom.count {
        case 0x800000:
            if rom.range(of: Data("t4u_".utf8)) != nil { return ["4u", "4u-plain"] }
            if rom.range(of: Data("idn_".utf8)) != nil { return ["ps"] }
            if rom.range(of: Data("id2_".utf8)) != nil { return ["idl"] }
            return nil
        case 0x400000:
            let tag = Data("ODL_MDP".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
            return rom.range(of: tag) != nil ? ["id", "id-melody"] : ["plus-color", "plus-color-hexa"]
        default:
            return nil
        }
    }

    /// Reset vectors of the firmware builds this app has been checked
    /// against, and the device each one plays as.
    private static let knownResetVectors: [UInt32: String] = [
        0x024F_6256: "4u",               // 4U+ (Japanese, and the English patch)
        0x024C_680A: "4u-plain",         // 4U
        0x024F_DFE6: "ps",               // P's v56
        0x024B_D18A: "idl",              // iD L 15th Anniversary v54
        0x024C_14F6: "idl",              // iD L Princess Spacey
        0x00C9_07FA: "id",               // iD v43
        0x00C9_39EA: "id-melody",        // iD Lovely Melody v48
        0x00C2_F0EC: "plus-color",       // Plus Color v040 (and English patches)
        0x00C4_215E: "plus-color-hexa",  // Hexagontchi
    ]

    private static func distance(_ vector: UInt32, to id: String) -> UInt32 {
        knownResetVectors.filter { $0.value == id }.keys
            .map { $0 > vector ? $0 - vector : vector - $0 }
            .min() ?? .max
    }

    private static func rank(_ id: String, best: String?, narrowed: Set<String>) -> Int {
        if id == best { return 0 }
        return narrowed.contains(id) ? 1 : 2
    }
}
