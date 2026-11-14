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

    /// The V1 (TamaLib) family's own CPU/RAM/display snapshot -- a
    /// different, unrelated format from CTama's `.state`/`.lock` pair
    /// above (see ios_hal_save_state's own doc comment), so it gets its
    /// own extension rather than reusing stateBasePath.
    var v1StatePath: URL { savesDir.appendingPathComponent(device.id).appendingPathExtension("v1state") }

    /// The T7 (T7Emu/Tama-Go) family's own CPU/RAM/DRAM/bank snapshot --
    /// `ios_t7_save_state`'s format, unrelated to every other family's.
    var t7StatePath: URL { savesDir.appendingPathComponent(device.id).appendingPathExtension("t7state") }

    /// The T7 family's emulated 4 KB I2C EEPROM -- the Tama's actual game
    /// save (character/stats), kept separate from t7StatePath on purpose:
    /// it's the one piece of this device's state real hardware preserves
    /// across a power-loss, same split as the real chip.
    var t7EepromPath: URL { savesDir.appendingPathComponent(device.id).appendingPathExtension("t7eeprom") }

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

    /// One point on the line that maps a CTama save's own emulated-time
    /// counter (`emu_secs`, stored inside the `.state` file) to real
    /// wall-clock time: "when the core's counter read `emuSecs`, the real
    /// time was `wall`".
    struct ClockAnchor {
        var emuSecs: Double
        var wall: Date
    }

    /// Written alongside every CTama save. `lastSavedAt` alone only says
    /// "some save happened at this moment" -- it has to be written as a
    /// separate step from the `.state` file itself, so if the two ever
    /// disagree (the process was suspended or killed between them, or two
    /// writers interleaved) the next catch-up measures the wrong gap and
    /// the Tama's clock silently ends up behind or ahead. An anchor can't
    /// go stale that way: whichever `.state` actually made it to disk, its
    /// own `emu_secs` says exactly how far along this line it is.
    var clockAnchor: ClockAnchor? {
        get {
            guard let dict = UserDefaults.standard.dictionary(forKey: clockAnchorKey),
                  let emuSecs = dict["emuSecs"] as? Double,
                  let wall = dict["wall"] as? Date else { return nil }
            return ClockAnchor(emuSecs: emuSecs, wall: wall)
        }
        nonmutating set {
            if let newValue {
                UserDefaults.standard.set(["emuSecs": newValue.emuSecs, "wall": newValue.wall], forKey: clockAnchorKey)
            } else {
                UserDefaults.standard.removeObject(forKey: clockAnchorKey)
            }
        }
    }

    private var clockAnchorKey: String { "clockAnchor.\(device.id)" }

    /// The real wall-clock moment a just-loaded CTama state is caught up
    /// to, given the `emu_secs` it was loaded with. Falls back to
    /// `lastSavedAt` for saves made before anchors existed.
    func wallTime(forEmuSecs emuSecs: Double) -> Date? {
        if let anchor = clockAnchor {
            return anchor.wall.addingTimeInterval(emuSecs - anchor.emuSecs)
        }
        return lastSavedAt
    }

    /// Declares this device's saved state current as of right now -- no
    /// time owed. For the moments that deliberately discard a gap rather
    /// than catch up through it: unpausing, or replacing the save.
    func markSyncedNow() {
        UserDefaults.standard.removeObject(forKey: clockAnchorKey)
        lastSavedAt = Date()
    }

    /// Base path for the full snapshot, with `state_save`'s own suffixes
    /// appended — mirrors the plain string concatenation `state_path()`
    /// does in state.c (no extra dot).
    private var stateFilePath: URL { stateBasePath.appendingPathExtension("state") }
    private var stateLockPath: URL { stateBasePath.appendingPathExtension("lock") }

    /// Removes every file this device's ROM/save data occupies, for when the
    /// wrong device was picked at import time and the data underneath it is
    /// simply wrong, not something worth keeping.
    func deleteAll() {
        for url in [importedROMPath, liveFlashPath, stateFilePath, stateLockPath, v1StatePath, t7StatePath, t7EepromPath] {
            try? FileManager.default.removeItem(at: url)
        }
        try? FileManager.default.removeItem(at: backupsDir)
        UserDefaults.standard.removeObject(forKey: lastSavedAtKey)
        UserDefaults.standard.removeObject(forKey: clockAnchorKey)
    }

    /// Drops just the CPU/RAM snapshot, keeping the ROM and flash image —
    /// for importing a `.sav` file, after which the next load should boot
    /// fresh from that flash rather than resume the old (now mismatched)
    /// snapshot.
    func deleteStateOnly() {
        for url in [stateFilePath, stateLockPath] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Backups

    /// Every file that together makes up this device's progress, across
    /// all three families (a given device only ever has its own family's
    /// subset on disk). The firmware itself is deliberately not here: it
    /// never changes after import, so copying it into every backup would
    /// only cost space.
    private var saveFiles: [URL] {
        [liveFlashPath, stateFilePath, v1StatePath, t7StatePath, t7EepromPath]
    }

    private var backupsDir: URL {
        Self.rootDirectory
            .appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent(device.id, isDirectory: true)
    }

    /// How often an automatic backup is taken at most. Automatic backups
    /// ride along with a normal save (leaving a Tama's page, or the app
    /// going to the background), so this is a ceiling, not a timer --
    /// nothing runs in the background for it.
    static let automaticBackupInterval: TimeInterval = 3600

    /// Newest first.
    func backups() -> [SaveBackup] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: backupsDir, includingPropertiesForKeys: nil) else {
            return []
        }
        return folders.compactMap { folder -> SaveBackup? in
            // A folder still being written (or abandoned half-way by a
            // crash) keeps its dot-prefixed temporary name -- never listed.
            guard !folder.lastPathComponent.hasPrefix("."),
                  let meta = NSDictionary(contentsOf: folder.appendingPathComponent(SaveBackup.metaFileName)),
                  let createdAt = meta["createdAt"] as? Date else { return nil }
            let reason = (meta["reason"] as? String).flatMap(SaveBackup.Reason.init(rawValue:)) ?? .automatic
            return SaveBackup(folder: folder, createdAt: createdAt, reason: reason)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    /// Snapshots this device's save files as they are on disk right now.
    /// Call only when nothing is mid-way through writing them -- right
    /// after a save, with the engine stopped.
    ///
    /// Does nothing (returns false) when there's no save yet, when nothing
    /// has been saved since the newest backup, or -- for `.automatic` --
    /// when the newest backup is younger than `automaticBackupInterval`.
    @discardableResult
    func makeBackup(reason: SaveBackup.Reason) -> Bool {
        let fm = FileManager.default
        let present = saveFiles.filter { fm.fileExists(atPath: $0.path) }
        guard !present.isEmpty else { return false }

        let now = Date()
        if let newest = backups().first {
            let age = now.timeIntervalSince(newest.createdAt)
            // A device clock that jumped backwards makes `age` negative;
            // treat that as "long enough" rather than never backing up
            // again until the clock passes the old stamp.
            if reason == .automatic, age >= 0, age < Self.automaticBackupInterval { return false }
            let lastChange = present
                .compactMap { (try? fm.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }
                .max()
            if let lastChange, age >= 0, lastChange <= newest.createdAt { return false }
        }

        let name = String(Int(now.timeIntervalSince1970))
        let finalFolder = backupsDir.appendingPathComponent(name, isDirectory: true)
        let tempFolder = backupsDir.appendingPathComponent("." + name + ".tmp", isDirectory: true)
        guard !fm.fileExists(atPath: finalFolder.path) else { return false }
        do {
            try? fm.removeItem(at: tempFolder)
            try fm.createDirectory(at: tempFolder, withIntermediateDirectories: true)
            // copyItem is a copy-on-write clone on the phone's filesystem:
            // near-instant, and a file that hasn't changed between two
            // backups (the flash image, most of the time) isn't stored
            // twice.
            for file in present {
                try fm.copyItem(at: file, to: tempFolder.appendingPathComponent(file.lastPathComponent))
            }
            // The screen as it looked at this save -- only so the restore
            // list can show which moment each backup is. Optional.
            if let frame = WidgetSharedState.latestFramePath(for: device), fm.fileExists(atPath: frame.path) {
                try? fm.copyItem(at: frame, to: tempFolder.appendingPathComponent(SaveBackup.frameFileName))
            }
            let meta: NSDictionary = ["createdAt": now, "reason": reason.rawValue]
            try meta.write(to: tempFolder.appendingPathComponent(SaveBackup.metaFileName))
            // Only a complete backup ever gets a listable name.
            try fm.moveItem(at: tempFolder, to: finalFolder)
        } catch {
            try? fm.removeItem(at: tempFolder)
            return false
        }
        pruneBackups()
        return true
    }

    /// Keeps the 3 newest backups, plus the newest one from each of the
    /// last 7 days -- so a problem noticed days later (or a run of backups
    /// taken *after* something went wrong) can't push out the last good
    /// one. Everything else is deleted.
    private func pruneBackups() {
        let all = backups()
        let calendar = Calendar.current
        var keep = Set(all.prefix(3).map(\.folder))
        let cutoff = calendar.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        var daysSeen = Set<Date>()
        for backup in all where backup.createdAt >= cutoff {
            if daysSeen.insert(calendar.startOfDay(for: backup.createdAt)).inserted {
                keep.insert(backup.folder)
            }
        }
        for backup in all where !keep.contains(backup.folder) {
            try? FileManager.default.removeItem(at: backup.folder)
        }
    }

    /// Puts a backup's files back in place of the current save. Call only
    /// with this device's engine stopped. The current save is itself
    /// backed up first, so a restore can always be undone.
    ///
    /// The restored Tama resumes exactly where the backup left it, with no
    /// time owed -- deliberately not caught up through however long ago
    /// the backup was made, which for an old one would mean hours of
    /// neglect arriving all at once.
    func restore(_ backup: SaveBackup) throws {
        // Anything else still finishing a save of this Tama (a load that
        // was just superseded, a background pass) has to be done first, or
        // it would write its older state over the restored one.
        let gate = EngineGate.gate(for: device)
        let holdsGate = gate.acquire(timeout: 5)
        defer { if holdsGate { gate.release() } }

        let fm = FileManager.default
        let pairs = saveFiles.map { (live: $0, saved: backup.folder.appendingPathComponent($0.lastPathComponent)) }
        guard pairs.contains(where: { fm.fileExists(atPath: $0.saved.path) }) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        makeBackup(reason: .beforeRestore)
        try ensureDirectoriesExist()

        // Stage every file first, swap them in only once all of them
        // copied -- so a failure half-way leaves the current save intact
        // instead of a mix of two different moments.
        func staging(_ url: URL) -> URL { url.appendingPathExtension("restoring") }
        do {
            for pair in pairs where fm.fileExists(atPath: pair.saved.path) {
                try? fm.removeItem(at: staging(pair.live))
                try fm.copyItem(at: pair.saved, to: staging(pair.live))
            }
        } catch {
            for pair in pairs { try? fm.removeItem(at: staging(pair.live)) }
            throw error
        }
        for pair in pairs {
            // A file the backup doesn't have didn't exist at that moment
            // either -- leaving today's one behind would pair it with a
            // state it doesn't belong to.
            try? fm.removeItem(at: pair.live)
            if fm.fileExists(atPath: staging(pair.live).path) {
                try fm.moveItem(at: staging(pair.live), to: pair.live)
            }
        }
        try? fm.removeItem(at: stateLockPath)

        let savedFrame = backup.folder.appendingPathComponent(SaveBackup.frameFileName)
        if let frame = WidgetSharedState.latestFramePath(for: device), fm.fileExists(atPath: savedFrame.path) {
            try? fm.removeItem(at: frame)
            try? fm.copyItem(at: savedFrame, to: frame)
        }
        markSyncedNow()
    }
}

/// One snapshot of a device's save files, in its own folder under
/// Application Support/TamaEmu/backups/<device id>/. See
/// `SavePaths.makeBackup(reason:)`.
struct SaveBackup: Identifiable, Hashable {
    enum Reason: String {
        case automatic, manual, beforeImport, beforeRestart, beforeRestore

        var label: String {
            switch self {
            case .automatic: return "Automatic"
            case .manual: return "Saved by you"
            case .beforeImport: return "Before importing a save"
            case .beforeRestart: return "Before a restart"
            case .beforeRestore: return "Before restoring a backup"
            }
        }
    }

    static let metaFileName = "backup.plist"
    static let frameFileName = "frame.png"

    let folder: URL
    let createdAt: Date
    let reason: Reason

    var id: URL { folder }

    /// The screen as it looked when this backup was made, if one was
    /// captured (color Tamas only, for now).
    var frameURL: URL? {
        let url = folder.appendingPathComponent(Self.frameFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// What the restore screen needs from whichever kind of view-model backs
/// a device -- so one screen serves every family.
@MainActor
protocol SaveBackupHost: AnyObject {
    /// Flushes the live state to disk and snapshots it right now.
    func backupNow()
    /// Replaces the current save with `backup` and resumes from it.
    func restoreBackup(_ backup: SaveBackup) throws
}
