import TamaCore

/// Narrows a `.bin` file to the devices whose ROM size matches it — see the
/// comment at the top of device.c: ROM size alone can't uniquely identify a
/// device, since several share the same size, so this narrows rather than
/// identifies.
enum DeviceDetector {
    static func candidates(forFileSize size: Int, in devices: [TamaDevice]) -> [TamaDevice] {
        devices.filter { $0.romSize == size }
    }
}
