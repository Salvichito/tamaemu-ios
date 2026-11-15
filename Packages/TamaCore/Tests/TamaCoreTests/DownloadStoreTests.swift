import Foundation
import Testing
@testable import TamaCore

/// A made-up download record in the real container format: "TAMAGO",
/// UTF-16BE name at 0x06, ASCII id at 0x34, big-endian length at 0x48,
/// type/category/flag at 0x4E/0x50/0x51, big-endian byte-sum at the end.
/// No real Bandai content -- just enough structure for the installer to
/// route and verify it.
private func record(name: String, id: String, type: UInt8, category: UInt8, flag: UInt8, size: Int = 0x100) -> Data {
    var b = [UInt8](repeating: 0, count: size)
    b.replaceSubrange(0..<6, with: Array("TAMAGO".utf8))
    var o = 6
    for unit in name.utf16 where o + 1 < 0x34 {
        b[o] = UInt8(unit >> 8); b[o + 1] = UInt8(unit & 0xFF); o += 2
    }
    for (i, c) in id.utf8.prefix(0x13).enumerated() { b[0x34 + i] = c }
    b[0x48] = UInt8((size >> 24) & 0xFF); b[0x49] = UInt8((size >> 16) & 0xFF)
    b[0x4A] = UInt8((size >> 8) & 0xFF); b[0x4B] = UInt8(size & 0xFF)
    b[0x4E] = type; b[0x50] = category; b[0x51] = flag
    let sum = b[0..<(size - 2)].reduce(0) { ($0 + Int($1)) & 0xFFFF }
    b[size - 2] = UInt8(sum >> 8); b[size - 1] = UInt8(sum & 0xFF)
    return Data(b)
}

private func write(_ data: Data, _ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dlctest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try data.write(to: url)
    return url
}

/// A blank (erased) 8 MB P's flash image carrying the P's signature.
private func blankPsImage() -> [UInt8] {
    var img = [UInt8](repeating: 0xFF, count: 8 * 1024 * 1024)
    img.replaceSubrange(0x400000..<0x400004, with: [0xE6, 0xDF, 0x4F, 0x02])
    return img
}

/// The 4 MB iD keeps its signature at the very start instead.
private func blankIDImage() -> [UInt8] {
    var img = [UInt8](repeating: 0xFF, count: 4 * 1024 * 1024)
    img.replaceSubrange(0..<4, with: [0xFA, 0x07, 0xC9, 0x00])
    return img
}

private func categories(_ img: [UInt8], device: String = "ps") -> [DownloadCategory] {
    img.withUnsafeBufferPointer { DownloadStore.categories(deviceID: device, image: $0) }
}

@Test func supportIsPerDevice() {
    for id in ["ps", "idl", "id", "id-melody", "4u", "4u-plain"] {
        #expect(DownloadStore.isSupported(deviceID: id))
    }
    for id in ["plus-color", "plus-color-hexa", "p1", "tamago", "nope"] {
        #expect(!DownloadStore.isSupported(deviceID: id))
    }
}

@Test func blankImageListsEmptySlots() {
    let cats = categories(blankPsImage())
    #expect(cats.map(\.label).contains("Meals"))
    #expect(cats.first { $0.label == "Games" }?.slots.count == 2)
    #expect(cats.allSatisfy { $0.usedCount == 0 })
}

@Test func installListAndRemove() throws {
    var img = blankPsImage()
    let pristine = img
    let meal = try write(record(name: "おにぎり", id: "meal_001", type: 0x81, category: 0x02, flag: 0), "meal.bin")

    let first = img.withUnsafeMutableBufferPointer {
        DownloadStore.install(deviceID: "ps", image: $0, files: [meal])
    }
    #expect(first.count == 1)
    #expect(first[0].succeeded)
    #expect(first[0].categoryLabel == "Meals")
    #expect(first[0].itemName == "おにぎり")

    let meals = try #require(categories(img).first { $0.label == "Meals" })
    #expect(meals.usedCount == 1)
    #expect(meals.slots[0].isOccupied)
    #expect(meals.slots[0].displayName == "おにぎり")
    #expect(meals.slots[0].itemID == "meal_001")

    // Only that one slot's bytes changed.
    let changed = zip(img, pristine).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
    #expect(changed.first! >= 0x5A0000 && changed.last! < 0x5A0000 + 0x800)

    // The same file again is recognised, not installed twice.
    let again = img.withUnsafeMutableBufferPointer {
        DownloadStore.install(deviceID: "ps", image: $0, files: [meal])
    }
    #expect(again[0].failure == "Already installed.")
    #expect(categories(img).first { $0.label == "Meals" }?.usedCount == 1)

    // Removing it puts the image back exactly as it was.
    let freed = img.withUnsafeMutableBufferPointer {
        DownloadStore.free(deviceID: "ps", image: $0, kind: meals.kind, index: 0)
    }
    #expect(freed)
    #expect(img == pristine)
}

@Test func payloadAppendedToJPEGIsFound() throws {
    var img = blankPsImage()
    var jpg = Data([0xFF, 0xD8, 0x01, 0x02, 0x03, 0xFF, 0xD9])
    jpg.append(record(name: "Snack", id: "snack_7", type: 0x81, category: 0x0D, flag: 0))
    let url = try write(jpg, "snack.jpg")
    let r = img.withUnsafeMutableBufferPointer { DownloadStore.install(deviceID: "ps", image: $0, files: [url]) }
    #expect(r[0].succeeded)
    #expect(r[0].categoryLabel == "Snacks")
}

@Test func fullStoreAndBadFilesAreReportedNotWritten() throws {
    var img = blankPsImage()
    let games = try (1...3).map {
        try write(record(name: "Game \($0)", id: "game_0\($0)", type: 0x94, category: 0x5B, flag: 1, size: 0x400), "g\($0).bin")
    }
    let junk = try write(Data("not a download".utf8), "junk.jpg")
    var damaged = record(name: "Broken", id: "x", type: 0x81, category: 0x02, flag: 0)
    damaged[0x80] ^= 0x55
    let damagedURL = try write(damaged, "damaged.bin")
    // A real container, but a header this device has no store for.
    let foreign = try write(record(name: "Other", id: "x", type: 0x10, category: 0x10, flag: 0), "foreign.bin")

    let r = img.withUnsafeMutableBufferPointer {
        DownloadStore.install(deviceID: "ps", image: $0, files: games + [junk, damagedURL, foreign])
    }
    #expect(r[0].succeeded && r[1].succeeded)
    #expect(r[2].failure == "No free Games slot. Remove one first, then try again.")
    #expect(r[3].failure == "This isn't a Tamagotchi download file.")
    #expect(r[4].failure == "This download file is damaged.")
    #expect(r[5].failure == "This download isn't made for this Tama.")
    let cats = categories(img)
    #expect(cats.first { $0.label == "Games" }?.usedCount == 2)
    #expect(cats.filter { $0.label != "Games" }.allSatisfy { $0.usedCount == 0 })
}

@Test func wrongDeviceSaveIsRefused() throws {
    var img = blankPsImage()   // P's signature...
    let pristine = img
    let meal = try write(record(name: "Meal", id: "m", type: 0x81, category: 0x02, flag: 1), "meal.bin")
    // ...handed over as an iD L.
    let r = img.withUnsafeMutableBufferPointer { DownloadStore.install(deviceID: "idl", image: $0, files: [meal]) }
    #expect(r[0].failure?.contains("Tamagotchi P's") == true)
    #expect(img == pristine)
}

@Test func tooSmallImageIsLeftAlone() throws {
    var img = [UInt8](repeating: 0xFF, count: 1024)
    let meal = try write(record(name: "Meal", id: "m", type: 0x81, category: 0x02, flag: 0), "meal.bin")
    let r = img.withUnsafeMutableBufferPointer { DownloadStore.install(deviceID: "ps", image: $0, files: [meal]) }
    #expect(!r[0].succeeded)
    #expect(categories(img).isEmpty)
}

@Test func fourMegabyteDeviceInstallsAndChecksItsOwnSignature() throws {
    // iD headers: group 0x4E = 1, category 0x4F = 1, subtype 0x51 = 1 -> meal.
    var meal = [UInt8](record(name: "Meal", id: "m", type: 0x01, category: 0, flag: 0x01))
    meal[0x4F] = 0x01
    let sum = meal[0..<(meal.count - 2)].reduce(0) { ($0 + Int($1)) & 0xFFFF }
    meal[meal.count - 2] = UInt8(sum >> 8); meal[meal.count - 1] = UInt8(sum & 0xFF)
    let url = try write(Data(meal), "meal.bin")

    var img = blankIDImage()
    let ok = img.withUnsafeMutableBufferPointer { DownloadStore.install(deviceID: "id", image: $0, files: [url]) }
    #expect(ok[0].succeeded)
    #expect(ok[0].categoryLabel == "Meals")

    var other = blankIDImage()
    let pristine = other
    let refused = other.withUnsafeMutableBufferPointer {
        DownloadStore.install(deviceID: "id-melody", image: $0, files: [url])
    }
    #expect(refused[0].failure?.contains("Tamagotchi iD") == true)
    #expect(other == pristine)
}
