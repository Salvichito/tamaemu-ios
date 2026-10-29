import CoreGraphics
import Foundation
import Observation
import TamaCore

@MainActor
@Observable
final class PlayViewModel {
    let devices = DeviceCatalog.all()
    var selectedDevice: TamaDevice
    private(set) var lcdImage: CGImage?
    private(set) var hasFirmware = false
    private(set) var errorMessage: String?

    private var engine: EmulatorEngine?
    private var displayTimer: Timer?

    private static let selectedDeviceIDKey = "selectedDeviceID"

    init() {
        // Prefer the remembered device, but fall back to scanning for
        // whichever device actually has an imported ROM on disk — the
        // filesystem is the ground truth, a lost/stale preference should
        // never hide an already-imported firmware behind the import screen.
        let remembered = UserDefaults.standard.string(forKey: Self.selectedDeviceIDKey)
            .flatMap(DeviceCatalog.find(name:))
        func hasImportedROM(_ device: TamaDevice) -> Bool {
            FileManager.default.fileExists(atPath: SavePaths(device: device).importedROMPath.path)
        }
        if let remembered, hasImportedROM(remembered) {
            selectedDevice = remembered
        } else if let found = devices.first(where: hasImportedROM) {
            selectedDevice = found
        } else {
            selectedDevice = DeviceCatalog.defaultDevice()
        }

        if hasImportedROM(selectedDevice) {
            hasFirmware = true
            startEngine()
        } else {
            lcdImage = LCDImageBuilder.makeImage(
                from: Self.testPattern(width: 128, height: 128),
                width: 128,
                height: 128
            )
        }
    }

    func firmwareImported(for device: TamaDevice, at url: URL) {
        selectedDevice = device
        UserDefaults.standard.set(device.id, forKey: Self.selectedDeviceIDKey)
        hasFirmware = true
        startEngine()
    }

    /// Stops the emulator thread and audio (once there is audio) entirely,
    /// after persisting state — this app does not age in the background for
    /// the MVP. Call on scenePhase == .background.
    func stopEngine() {
        displayTimer?.invalidate()
        displayTimer = nil
        engine?.save()
        engine?.stop()
        engine = nil
    }

    /// Call on scenePhase == .active. Re-creates the engine (which restores
    /// from the state/flash saved in stopEngine()) if it isn't running.
    func resumeIfNeeded() {
        guard hasFirmware, engine == nil else { return }
        startEngine()
    }

    func pressButton(_ button: InputController.Button) {
        engine?.input.press(button)
    }

    func releaseButton(_ button: InputController.Button) {
        engine?.input.release(button)
    }

    private func startEngine() {
        stopEngine()
        do {
            let paths = SavePaths(device: selectedDevice)
            let newEngine = try EmulatorEngine(device: selectedDevice, savePaths: paths)
            newEngine.start()
            engine = newEngine
            errorMessage = nil
            displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                guard let self, let frame = self.engine?.latestFrame() else { return }
                self.lcdImage = LCDImageBuilder.makeImage(from: frame, width: 128, height: 128)
            }
        } catch {
            errorMessage = error.localizedDescription
            hasFirmware = false
        }
    }

    /// Eight vertical color bars in the same 0xAARRGGBB word format
    /// `lcd_render` writes. Shown only until firmware is imported.
    private static func testPattern(width: Int, height: Int) -> [UInt32] {
        let bars: [UInt32] = [
            0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0xFFFFFFFF,
            0xFF000000, 0xFFFFFF00, 0xFF00FFFF, 0xFFFF00FF
        ]
        var buffer = [UInt32](repeating: 0, count: width * height)
        let barWidth = max(1, width / bars.count)
        for y in 0..<height {
            for x in 0..<width {
                buffer[y * width + x] = bars[min(x / barWidth, bars.count - 1)]
            }
        }
        return buffer
    }
}
