import Testing
@testable import TamaCore

@Test func allListsKnownDevices() {
    let devices = DeviceCatalog.all()
    #expect(!devices.isEmpty)
    #expect(devices.contains { $0.id == "ps" })
}

@Test func defaultDeviceIsFindable() {
    let def = DeviceCatalog.defaultDevice()
    let found = DeviceCatalog.find(name: def.id)
    #expect(found?.id == def.id)
}

@Test func unknownDeviceIsNil() {
    #expect(DeviceCatalog.find(name: "not-a-real-device") == nil)
}
