import AppIntents
import TamaCore

/// One owned Tama, as the widget configuration picker sees it.
struct TamaEntity: AppEntity {
    let id: String
    var displayName: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Tama"
    static var defaultQuery = TamaEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }
}

struct TamaEntityQuery: EntityQuery {
    /// "Owned" here means "the main app last told us about it" — the
    /// widget extension runs in its own sandbox, so it can't stat the main
    /// app's save files itself (ActiveDeviceLookup/SavePaths resolve to a
    /// different, empty container when called from here). WidgetSharedState
    /// mirrors the owned-device list into the one place both processes
    /// actually share: the App Group's UserDefaults suite.
    private func ownedDevices() -> [TamaDevice] {
        let ownedIDs = Set(WidgetSharedState.ownedDeviceIDs())
        return DeviceCatalog.all().filter { ownedIDs.contains($0.id) }
    }

    func entities(for identifiers: [String]) async -> [TamaEntity] {
        let idSet = Set(identifiers)
        return ownedDevices()
            .filter { idSet.contains($0.id) }
            .map { TamaEntity(id: $0.id, displayName: $0.title) }
    }

    func suggestedEntities() async -> [TamaEntity] {
        ownedDevices().map { TamaEntity(id: $0.id, displayName: $0.title) }
    }
}

/// Lets each home-screen widget instance be configured (long-press → Edit
/// Widget) to one specific owned Tama, since several can be owned at once
/// now — one widget instance per Tama the player wants to watch.
struct SelectTamaIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Choose Tama"

    @Parameter(title: "Tama")
    var tama: TamaEntity?
}
