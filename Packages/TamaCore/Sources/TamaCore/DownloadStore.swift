import CTama
import Foundation

/// One place a download can live on a Tama. The firmware gives each kind
/// of content (meals, games, ...) a small fixed number of these.
public struct DownloadSlot: Identifiable, Hashable, Sendable {
    public let kind: Int
    public let index: Int
    public let isOccupied: Bool
    /// The item's own name, as stored in its header (usually Japanese).
    public let name: String
    /// Community English name, where one is known (4U items only).
    public let englishName: String?
    public let itemID: String

    public var id: String { "\(kind)-\(index)" }

    public var displayName: String {
        if let englishName, !englishName.isEmpty { return englishName }
        if !name.isEmpty { return name }
        if !itemID.isEmpty { return itemID }
        return "Unnamed download"
    }
}

/// All the slots for one kind of content.
public struct DownloadCategory: Identifiable, Hashable, Sendable {
    public let kind: Int
    public let label: String
    public let slots: [DownloadSlot]

    public var id: Int { kind }
    public var usedCount: Int { slots.filter(\.isOccupied).count }
}

/// What happened to one file handed to `DownloadStore.install`.
public struct DownloadInstallResult: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let fileName: String
    public let itemName: String
    /// Where it went (or would have gone), e.g. "Meals".
    public let categoryLabel: String?
    /// nil when the item was installed.
    public let failure: String?

    public init(fileName: String, itemName: String, categoryLabel: String?, failure: String?) {
        self.fileName = fileName
        self.itemName = itemName
        self.categoryLabel = categoryLabel
        self.failure = failure
    }

    public var succeeded: Bool { failure == nil }
}

/// Downloadable content ("DLC") for the color Tamas: reads and edits the
/// fixed download slots inside a device's flash image. A thin Swift face
/// over upstream's installer (dlc.c) -- all the knowledge about where
/// things go is upstream's.
public enum DownloadStore {
    /// Whether this device has download slots we know how to fill. False
    /// for Plus Color (it uses codes, not downloads) and every non-color
    /// family.
    public static func isSupported(deviceID: String) -> Bool {
        dlc_ios_supported(deviceID) != 0
    }

    /// Every download slot on the device, grouped by kind of content.
    public static func categories(deviceID: String, image: UnsafeBufferPointer<UInt8>) -> [DownloadCategory] {
        var result: [DownloadCategory] = []
        for i in 0..<dlc_ios_kind_count(deviceID) {
            guard let k = dlc_ios_kind_at(deviceID, i) else { continue }
            let capacity = Int(k.pointee.nslots)
            var raw = [DlcSlot](repeating: DlcSlot(), count: capacity)
            let n = Int(dlc_ios_slots(deviceID, image.baseAddress, image.count, k.pointee.kind, &raw, Int32(capacity)))
            let slots = raw.prefix(n).map { s -> DownloadSlot in
                let itemID = string(s.id)
                return DownloadSlot(
                    kind: Int(k.pointee.kind),
                    index: Int(s.slot),
                    isOccupied: s.occupied != 0,
                    name: string(s.name),
                    englishName: englishName(itemID),
                    itemID: itemID
                )
            }
            guard !slots.isEmpty else { continue }
            result.append(DownloadCategory(
                kind: Int(k.pointee.kind),
                label: String(cString: k.pointee.label),
                slots: slots
            ))
        }
        return result
    }

    /// Installs each file into the first free slot of the store it belongs
    /// in. One bad file doesn't stop the rest. Nothing is written for a
    /// file that fails.
    public static func install(
        deviceID: String,
        image: UnsafeMutableBufferPointer<UInt8>,
        files: [URL]
    ) -> [DownloadInstallResult] {
        func refuseAll(_ why: String) -> [DownloadInstallResult] {
            files.map {
                DownloadInstallResult(fileName: $0.lastPathComponent, itemName: "", categoryLabel: nil, failure: why)
            }
        }
        guard isSupported(deviceID: deviceID) else {
            return refuseAll("This Tama doesn't take downloads.")
        }
        // A save that carries another device's signature means something
        // is already badly wrong; don't make it worse.
        if let other = dlc_ios_mismatch_title(deviceID, image.baseAddress, image.count) {
            return refuseAll("This Tama's save looks like a \(String(cString: other)). Nothing was changed.")
        }
        return files.map { url in
            var r = DlcResult()
            let rc = url.path.withCString { dlc_ios_install(deviceID, image.baseAddress, image.count, $0, &r) }
            let label = r.kind >= 0 ? dlc_ios_kind(deviceID, r.kind).map { String(cString: $0.pointee.label) } : nil
            return DownloadInstallResult(
                fileName: url.lastPathComponent,
                itemName: englishName(string(r.id)) ?? string(r.name),
                categoryLabel: label,
                failure: rc == 0 ? nil : friendly(string(r.error), category: label)
            )
        }
    }

    /// Erases one slot. Returns false if there is no such slot.
    public static func free(
        deviceID: String,
        image: UnsafeMutableBufferPointer<UInt8>,
        kind: Int,
        index: Int
    ) -> Bool {
        dlc_ios_free(deviceID, image.baseAddress, image.count, Int32(kind), Int32(index)) == 0
    }

    private static func englishName(_ itemID: String) -> String? {
        guard !itemID.isEmpty, let name = dlc_4u_name_en(itemID) else { return nil }
        return String(cString: name)
    }

    /// The installer's own wording is written for its developers; these
    /// are the cases a person will actually run into, in plain words.
    private static func friendly(_ error: String, category: String?) -> String {
        if error.contains("store full") {
            if let category {
                return "No free \(category) slot. Remove one first, then try again."
            }
            return "No free slot for this. Remove a download first, then try again."
        }
        if error.contains("already installed") { return "Already installed." }
        if error.contains("no TAMAGO payload") || error.contains("empty file") {
            return "This isn't a Tamagotchi download file."
        }
        if error.contains("MAC mismatch") { return "This download file is damaged." }
        if error.contains("no route") { return "This download isn't made for this Tama." }
        if error.contains("cannot open") || error.contains("short read") {
            return "The file couldn't be read."
        }
        return error.prefix(1).uppercased() + error.dropFirst()
    }

    private static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
