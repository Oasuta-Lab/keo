import AppIntents

/// One pinned folder, as the widget's edit sheet sees it.
///
/// An `EntityQuery` rather than a `DynamicOptionsProvider`: the choice has to persist by a
/// stable identity — the Freebox path — and be re-resolved later, when the list of pinned
/// folders has changed. An options provider stores the value instead of a reference, and goes
/// stale badly the first time someone pins or unpins anything.
struct FolderEntity: AppEntity {
    /// The Freebox path. Identity, not decoration.
    let id: String
    let name: String

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Dossier")
    static let defaultQuery = FolderQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(id)")
    }
}

struct FolderQuery: EntityQuery {
    /// Both of these run **inside the extension**, where the app may well not be running. The
    /// manifest is therefore the only source — no socket, no keychain, no SQLite.
    func entities(for identifiers: [String]) async throws -> [FolderEntity] {
        pinned().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [FolderEntity] {
        pinned()
    }

    private func pinned() -> [FolderEntity] {
        (WidgetStore.manifest()?.folders ?? []).map { FolderEntity(id: $0.path, name: $0.name) }
    }
}

struct SelectFolder: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choisir un dossier"
    // A folder missing from the list has a one-gesture answer, and the sheet is where
    // someone is actually looking when they notice it is missing.
    static let description = IntentDescription("Le dossier épinglé dont le widget montre les photos. Pour en proposer un autre, appuie longuement sur sa tuile dans Keo.")

    /// Optional on purpose: a widget dropped before Keo has ever run has no folder to resolve
    /// and must render its empty state rather than fail.
    @Parameter(title: "Dossier")
    var folder: FolderEntity?

    init() {}

    init(folder: FolderEntity?) {
        self.folder = folder
    }
}
