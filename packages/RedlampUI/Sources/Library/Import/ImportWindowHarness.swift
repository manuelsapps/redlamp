import AppKit
@_spi(Harness) import RedlampLibrary

/// What the regression suite reads and sets in the import window: what a person sets through its
/// panels, which can't be driven, and what it shows.
@_spi(Harness) public extension ImportWindowController {
    /// The destination, the backup and the templates, as the panels and fields would set them.
    func prepare(destination: URL, backup: URL?, folders: String, names: String) {
        model.setDestination(destination)
        model.setBackup(backup)
        model.setFolders(folders)
        model.setNames(names)
    }

    /// Add Folder…'s folder.
    func add(folder: URL) async throws {
        try await model.addFolder(folder)
    }

    /// No destination chosen, as on a Mac Redlamp hasn't imported on, so Import asks for one.
    static func forgetDestination() {
        ImportPreferences.shared.forgetDestination()
        current?.model.notify(.settings)
    }

    /// What To shows as the destination.
    var destinationShown: String {
        destinationView.destinationShown
    }

    /// The destination has its bookmark.
    var keepsDestinationBookmark: Bool {
        model.preferences.bookmarks.bookmark(for: model.settings.destination.path) != nil
    }

    /// The card at `root`, its photos in `DCIM`, as the Mac would describe a card in a reader, shown.
    func add(card root: URL) async throws {
        let source = try await Task.detached(priority: .userInitiated) {
            try ImportSource.at(root, medium: .card(at: root))
        }.value
        model.add(source)
        model.show(source.id)
    }

    /// The photos the grid shows.
    var photoCount: Int {
        model.photos.count
    }

    /// Every source is listed, and each of its photos read.
    var isBrowsed: Bool {
        !model.sources.isEmpty && model.sources.allSatisfy(\.isBrowsed)
    }

    /// Previews put on screen in the grid so far.
    var imagesShown: Int {
        grid.imagesShown
    }

    /// Provisional previews put on screen in the grid so far: large JPEGs' EXIF thumbnails.
    var provisionalShown: Int {
        grid.provisionalShown
    }

    /// The photos shown whose grid thumbnails are made, and those still shown from a provisional preview.
    var previewed: (made: Int, provisional: Int) {
        (model.photos.count { $0.state == .previewed }, model.photos.count { $0.state == .provisional })
    }

    /// The grid's cells on screen.
    var visibleCount: Int {
        grid.collectionView.indexPathsForVisibleItems().count
    }

    /// The library's metadata presets the window offers, and the one chosen.
    var presetNames: [String] {
        model.metadataPresets.map(\.name)
    }

    var presetChosen: String? {
        model.preset?.name
    }

    /// The names of the photos given `rating` stars.
    func ratedNames(rating: Int) -> [String] {
        model.photos.filter { $0.choices.rating == rating }.map(\.primary.name)
    }

    /// Imports the photos chosen, as the Import button does, once every source is browsed, and returns once the
    /// import is over, or after a minute.
    func importAndWait() async {
        let started = ContinuousClock.now
        while !isBrowsed, ContinuousClock.now - started < .seconds(30) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        model.startImport()
        while model.phase != .finished, ContinuousClock.now - started < .seconds(60) {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Cancel Import.
    func stop() {
        model.cancel()
    }

    /// Stops the next import once `photos` photos are done, as a forced quit would, leaving it to be resumed or
    /// rolled back by the next window.
    func simulateForcedQuit(afterPhotos photos: Int) {
        model.importer.simulateForcedQuit(afterPhotos: photos)
    }

    /// An import a forced quit cut short, or a rollback, waits for Resume.
    var isInterrupted: Bool {
        !model.interrupted.isEmpty
    }

    /// Roll Back is offered.
    var canRollBack: Bool {
        model.rollBackTarget != nil && !model.isBusy
    }

    /// What the last rollback did: photos taken back, whether it's over, and where each file went in the Trash.
    var rollbackResult: (rolledBack: Int, isOver: Bool, trashed: [String])? {
        model.rollback.map { ($0.rolledBack.count, $0.state == .rolledBack, $0.trashed.map(\.to)) }
    }

    /// Selects the photos at these places in the grid, and gives the grid the keys.
    func select(_ items: [Int]) {
        grid.collectionView.selectionIndexPaths = Set(items.compactMap(grid.path(of:)))
        window?.makeFirstResponder(grid.collectionView)
    }

    /// The groups the grid shows, by their names, each with its photos' names; one without a name when it isn't
    /// grouped.
    var groups: [(name: String, photos: [String])] {
        model.groups.map { group in (group.name, model.photos[group.places].map(\.primary.name)) }
    }

    /// Group By, as it groups the photos shown.
    var grouping: String {
        model.grouping.title
    }

    /// Returns once the photos shown are grouped by the capture times browsing has read so far.
    func regrouped() async {
        await model.regrouped()
    }

    /// The rating, flag and label given the photo at `item`, as the grid's badges write them.
    func badges(at item: Int) -> String? {
        model.photo(at: item).map { ImportGridCell.badges($0, leftOut: false, copied: false) }
    }

    func scroll(to fraction: Double) {
        grid.scroll(to: fraction)
    }

    var isCopying: Bool {
        model.phase == .copying && model.progress != nil
    }

    var isFinished: Bool {
        model.phase == .finished
    }

    /// What the import did: photos verified, and whether every source can be erased, as their rows say.
    var result: (verified: Int, safeToErase: Bool)? {
        model.outcome.map { outcome in
            let sources = model.sources.filter { $0.outcome != nil }
            return (outcome.verified, outcome.isSafeToErase && sources.allSatisfy(model.isSafeToErase))
        }
    }

    /// What the row of the source shown says under its name.
    var shownSourceDetail: String? {
        model.shown.flatMap(model.source).map(model.detail(of:))
    }

    /// Fills the Mac's disk once `photos` photos of the next import are done, so it stops partway; the disk has
    /// space again for the next.
    func simulateFullDisk(afterPhotos photos: Int) {
        model.importer.simulateFullDisk(afterPhotos: photos)
    }

    /// Resume is offered in Import's place.
    var offersResume: Bool {
        !resumeButton.isHidden && importButton.isHidden
    }

    /// The photos the window shows as copied.
    var copiedCount: Int {
        model.copied.count
    }

    /// The photos chosen for the next import.
    var chosenCount: Int {
        model.chosen.photos
    }

    /// The photos selected in the grid.
    var selectedCount: Int {
        grid.collectionView.selectionIndexPaths.count
    }

    /// Holds the imports, once every photo is copied, before they add the rest to the library, until it's called
    /// with false.
    func holdAddingToLibrary(_ holds: Bool) {
        model.importer.holdAddingToLibrary(holds)
    }

    /// The import is adding the photos it copied to the library.
    var isAdding: Bool {
        model.phase == .adding
    }

    /// Cancel Import, or Stop Rolling Back, is offered.
    var offersCancel: Bool {
        !cancelButton.isHidden
    }

    /// What Import reads.
    var importTitle: String {
        importButton.title
    }

    var summary: String {
        model.summary
    }

    /// What the window is doing, as a scenario's failure says it: the import's phase, whether the window is shown
    /// and key, what holds Import back, and the line under the photos.
    var state: String {
        let shown = window?.isVisible != true ? "not shown" : window?.isKeyWindow == true ? "key" : "shown, not key"
        let blocker = model.importBlocker.map { "Import held back: \($0)" } ?? "Import can start"
        return "\(model.phase), \(shown); \(blocker); “\(model.summary)”"
    }

    /// Takes the folder holding `url` out of Folders, as the scenarios leave Folders as they found it.
    static func forget(_ url: URL, in editor: EditorModel) {
        if let root = editor.library.root(containing: url) {
            editor.library.remove(root)
        }
    }
}
