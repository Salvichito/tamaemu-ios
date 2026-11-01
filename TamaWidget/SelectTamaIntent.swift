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
    func entities(for identifiers: [String]) async -> [TamaEntity] {
        DeviceCatalog.all()
            .filter { identifiers.contains($0.id) && ActiveDeviceLookup.hasImportedROM($0) }
            .map { TamaEntity(id: $0.id, displayName: $0.title) }
    }

    func suggestedEntities() async -> [TamaEntity] {
        ActiveDeviceLookup.allImported().map { TamaEntity(id: $0.id, displayName: $0.title) }
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
