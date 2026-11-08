import Foundation
import RedlampDocument
import RedlampLibrary
import Synchronization

/// The import window's state (LIB-27), which the window and the tests drive alike.
///
/// - **From:** the cards on this Mac as they come and go (`ImportCards`), and the folders added, each
///   browsed in an `ImportSession` of its own from its embedded previews before anything is copied, and
///   each counted, the photos the library has already apart: they're left out. Several go at once.
/// - **The photos:** the source shown, newest first, listed at once and filled in as their heads and
///   previews are read; a card's in moments until Group By says otherwise (DEC-69, `ImportGrouping`). The
///   choices (which go, the rating, flag and label each gets) are kept in its session, and written in each
///   photo's `.redlamp` at the destination.
/// - **To:** the destination, the folder and name templates with a live example and their errors in
///   words, a backup, raw only, keywords and a metadata preset, kept from one import to the next
///   (`ImportPreferences`).
/// - **Import:** the photos of every source included, planned together so collisions are numbered in
///   capture order across them, and copied by one journaled `Importer` run off the main thread, with
///   each source's part as it goes; Cancel stops it once the photos being copied are done. Once every
///   photo is copied, the window says so as the run adds them to the library, with nothing to cancel,
///   and the next can be chosen meanwhile. A run a
///   forced quit cut short waits to be resumed, and so does one an error such as a full disk stops
///   partway, offered at once with the photos it placed shown as copied. At the end each card says
///   whether it's safe to erase, which it is once every photo on it is in the library, and the photos
///   copied are shown in Library, selected, after a Resume as after a run straight through.
/// - **Roll Back:** an import cancelled here, or one a forced quit cut short, is taken back whole
///   (`Importer.rollBack`): its copies to the Trash, its photos out of the library, the folders it made
///   removed. A rollback stopped or cut short waits, and Resume finishes it.
///
/// Events from the sessions and the importer's progress reach the main thread in batches.
@MainActor
final class ImportWindowModel {
    /// A card or a folder in From.
    struct Source: Identifiable {
        let source: ImportSource
        let session: ImportSession
        /// Its photos go in the import.
        var isIncluded = true
        /// Its photos, newest first by their files' dates, once it's listed.
        var photos: [String] = []
        var isListed = false
        /// Photos the library has already: counted apart and left out.
        var imported = 0
        /// Photos whose first bytes couldn't be read.
        var unreadable = 0
        var isBrowsed = false
        /// Why it can't be imported from: it couldn't be listed, or its card was taken out.
        var problem: String?
        /// Its part of the import as it copies.
        var progress: ImportProgress.Source?
        /// What the import made of it.
        var outcome: ImportOutcome.Source?
        var isEjected = false

        var id: String {
            source.id
        }

        var isCard: Bool {
            source.kind == .card
        }
    }

    enum Phase: Equatable {
        /// Browsing and choosing: nothing is being copied.
        case choosing
        case planning
        case copying
        /// Every photo is copied or failed, and those copied are being added to the library: there's nothing
        /// to cancel, and the next photos can be chosen meanwhile, but not imported.
        case adding
        case rollingBack
        /// The import or the rollback is over, or stopped; `outcome` and `rollback` say what they did.
        case finished
    }

    /// What the window shows that changed.
    enum Change: Equatable {
        case sources
        /// Photos shown: every one when `ids` is nil.
        case photos(ids: Set<String>?)
        /// The settings, the example and the templates' errors.
        case settings
        /// The summary, the phase and the progress.
        case status
    }

    let library: ImportLibrary
    let preferences: ImportPreferences
    let cards: ImportCards
    let fileSystem: any LibraryFileSystem
    let destinationFileSystem: any LibraryFileSystem
    /// Readers shared by every session and the importer, so a volume is read by one set of them.
    let volumes: VolumeIORegistry
    let importer: Importer
    /// Shows the photos copied in Library, selected.
    var showInLibrary: @MainActor ([URL]) -> Void = { _ in }
    /// The photo the example names while no source holds one: in the Apple Photos window, its first photo (LIB-54).
    var exampleStandIn: (@MainActor () -> (ImportPhoto, ImportSource)?)?
    /// Ejects a card's volume.
    var ejector: @Sendable (ImportSource) async throws -> Void = { try await ImportCards.eject($0) }
    var onChange: ((Change) -> Void)?

    var sources: [Source] = []
    /// The source whose photos are shown.
    private(set) var shown: String?
    /// The shown source's photos, in its listing's order, or in its groups' when it's grouped.
    private(set) var photos: [ImportPhoto] = []
    /// The shown source's groups, each a run of `photos`: one without a name when it isn't grouped.
    private(set) var groups: [ImportGroup] = []
    private var positions: [String: Int] = [:]
    /// Group By as chosen for each source, by its ID; the others are grouped as their kind is by default.
    private var groupings: [String: ImportGrouping] = [:]
    private var regroupDue = false
    /// Photos this window has copied: shown as imported, and no longer counted as chosen.
    var copied: Set<String> = []

    // The plan's settings, as typed.
    private(set) var folderText: String
    private(set) var namesText: String
    private(set) var folderError: String?
    private(set) var namesError: String?
    /// Where the example photo goes, below the destination.
    private(set) var example: String?
    private(set) var examplePhoto: String?

    // The import.
    var phase = Phase.choosing
    var progress: ImportProgress?
    var plan: ImportPlan?
    var outcome: ImportOutcome?
    /// What the last rollback did, since the last import began.
    var rollback: ImportRollback?
    var rollbackProgress: ImportRollback.Progress?
    /// What went wrong, as a sentence.
    var failure: String?
    /// Imports a forced quit cut short, waiting to be resumed or rolled back, and rollbacks waiting to be finished.
    var interrupted: [ImportJournal.Entry] = []
    /// The library's keywords, for completing those typed.
    private(set) var keywordCompletion: KeywordCompletion?
    /// The library's metadata presets, by name, as last read (`ImportWindowModel+Presets`).
    var metadataPresets: [MetadataPreset] = []

    private var browsing: [String: Task<Void, Never>] = [:]
    var importing: Task<Void, Never>?
    private var counted: (photos: Int, bytes: Int64)?
    private var countsDue = false
    private var exampleTask: Task<Void, Never>?
    private var cardsObservation: LibraryObservation?
    /// Previews made while browsing go to the library's store; without a library, to one of the window's own,
    /// removed as it closes.
    private let ownStore: (store: PhotoStore, root: URL)?

    /// How long events wait to reach the main thread, so a card read fast costs it a turn a batch.
    static let batching = Duration.milliseconds(30)
    /// How often the counts browsing changes reach the window.
    static let countsInterval = Duration.milliseconds(250)
    /// How often the importer's progress reaches the main thread.
    static let progressInterval = Duration.milliseconds(100)

    init(
        library: ImportLibrary, preferences: ImportPreferences = .shared, cards: ImportCards = .shared,
        fileSystem: any LibraryFileSystem = LocalFileSystem(),
        destinationFileSystem: any LibraryFileSystem = LocalFileSystem(),
    ) {
        if library.store == nil {
            let root = FileManager.default.temporaryDirectory
                .appending(path: "Redlamp Import Previews \(UUID().uuidString)", directoryHint: .isDirectory)
            let store = PhotoStore(root: root)
            ownStore = (store, root)
            self.library = ImportLibrary(
                paths: library.paths, index: library.index, store: store, indexer: library.indexer,
                live: library.live,
            )
        } else {
            ownStore = nil
            self.library = library
        }
        self.preferences = preferences
        self.cards = cards
        self.fileSystem = fileSystem
        self.destinationFileSystem = destinationFileSystem
        volumes = VolumeIORegistry(fileSystem: fileSystem)
        importer = Importer(
            library: self.library, fileSystem: fileSystem, destinationFileSystem: destinationFileSystem,
            volumes: volumes,
        )
        folderText = preferences.settings.folders.description
        namesText = preferences.settings.names.description
    }

    /// Lists the cards in and follows them, finds the imports a forced quit cut short, and loads the
    /// library's keywords.
    func start() {
        cardsObservation = cards.observe { [weak self] cards in self?.cardsChanged(cards) }
        cardsChanged(cards.cards)
        Task {
            interrupted = await (try? importer.unfinishedEntries()) ?? []
            if !interrupted.isEmpty {
                notify(.status)
            }
        }
        loadCompletions()
    }

    /// Loads the library's keywords, for completing those typed in To, and its metadata presets: all To needs where
    /// it chooses an import's destination with no sources, as the Apple Photos window's does (LIB-54).
    func loadCompletions() {
        if let index = library.index {
            let keywords = LibraryKeywords(index: index, paths: library.paths, live: library.live)
            Task {
                keywordCompletion = try? await keywords.completion()
            }
        }
        Task {
            await readPresets()
        }
    }

    /// An import is being planned, copied or added to the library, or rolled back.
    var isBusy: Bool {
        phase == .planning || phase == .copying || phase == .adding || phase == .rollingBack
    }

    /// Cancel is offered: not once every photo is copied.
    var canCancel: Bool {
        isBusy && phase != .adding
    }

    /// Stops browsing and lets the sessions go, unless an import is copying or rolling back, which carries on.
    func close() {
        cardsObservation?.invalidate()
        cardsObservation = nil
        exampleTask?.cancel()
        guard !isBusy else { return }
        for task in browsing.values {
            task.cancel()
        }
        browsing = [:]
        for source in sources {
            source.session.close()
        }
        if let (store, root) = ownStore {
            Task.detached(priority: .utility) {
                store.close()
                try? FileManager.default.removeItem(at: root)
            }
        }
    }

    /// Returns once every source is browsed: listed, and each photo read and previewed.
    func browsed() async {
        for task in browsing.values {
            await task.value
        }
    }

    // MARK: - Sources

    /// Adds `source` to From and starts browsing it; a source already there is left as it is.
    func add(_ source: ImportSource) {
        guard !sources.contains(where: { $0.id == source.id }) else { return }
        let session = ImportSession(
            sources: [source], library: library, fileSystem: fileSystem, volumes: volumes,
            makesPreviews: library.store != nil,
        )
        sources.append(Source(source: source, session: session))
        browse(session, id: source.id)
        if shown == nil {
            show(source.id)
        }
        notify(.sources)
        notify(.status)
    }

    /// Add Folder…: the folder at `url`, and every folder below it, as a source.
    func addFolder(_ url: URL) async throws {
        let fileSystem = fileSystem
        let source = try await Task.detached(priority: .userInitiated) {
            try ImportSource.at(url, fileSystem: fileSystem)
        }.value
        add(source)
        show(source.id)
    }

    /// Takes the source out of From: its photos aren't imported, and its choices go.
    func remove(_ id: String) {
        guard phase != .copying, phase != .planning, let index = sources.firstIndex(where: { $0.id == id }) else {
            return
        }
        browsing.removeValue(forKey: id)?.cancel()
        sources.remove(at: index).session.close()
        if shown == id {
            shown = nil
            show(sources.first?.id)
        }
        notify(.sources)
        notify(.status)
    }

    func setIncluded(_ id: String, _ included: Bool) {
        guard let index = sources.firstIndex(where: { $0.id == id }), sources[index].isIncluded != included else {
            return
        }
        sources[index].isIncluded = included
        notify(.sources)
        notify(.status)
        updateExample()
    }

    /// Shows `id`'s photos.
    func show(_ id: String?) {
        guard shown != id || id == nil else { return }
        shown = id
        loadShownPhotos()
        updateExample()
    }

    func source(_ id: String) -> Source? {
        sources.first { $0.id == id }
    }

    /// The session browsing the source shown.
    var shownSession: ImportSession? {
        shown.flatMap(source)?.session
    }

    private func cardsChanged(_ cards: [ImportSource]) {
        let busy = phase == .copying || phase == .planning
        for card in cards {
            if let index = sources.firstIndex(where: { $0.id == card.id }) {
                // A card taken out and put back is browsed afresh.
                guard sources[index].problem != nil, !sources[index].isEjected, !busy else { continue }
                remove(card.id)
            }
            add(card)
        }
        let present = Set(cards.map(\.id))
        for index in sources.indices where sources[index].isCard && !present.contains(sources[index].id) {
            guard sources[index].problem == nil else { continue }
            sources[index].isEjected = sources[index].isEjected || sources[index].outcome != nil
            if !sources[index].isEjected {
                sources[index].problem = "The card was taken out."
            }
            sources[index].isIncluded = false
            browsing.removeValue(forKey: sources[index].id)?.cancel()
        }
        notify(.sources)
        notify(.status)
    }

    // MARK: - Browsing

    private func browse(_ session: ImportSession, id: String) {
        let buffer = ImportEventBuffer()
        let batching = Self.batching
        browsing[id] = Task.detached(priority: .userInitiated) { [weak self] in
            for await event in session.browse() {
                if buffer.append(event) {
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: batching)
                        self?.received(buffer.take(), from: id)
                    }
                }
            }
            await self?.received(buffer.take(), from: id)
        }
    }

    private func received(_ events: [ImportEvent], from id: String) {
        guard !events.isEmpty, let index = sources.firstIndex(where: { $0.id == id }) else { return }
        counted = nil
        var changed = Set<String>()
        var listed = false
        for event in events {
            switch event {
            case let .listed(_, photos):
                sources[index].photos = photos
                sources[index].isListed = true
                listed = true
            case let .read(ids), let .provisional(ids), let .previewed(ids):
                changed.formUnion(ids)
            case let .imported(ids):
                sources[index].imported += ids.count
                changed.formUnion(ids)
            case let .failed(photo, _):
                sources[index].unreadable += 1
                changed.insert(photo)
            case let .sourceFailed(_, message):
                sources[index].problem = sources[index].problem ?? message
            case .browsed:
                sources[index].isBrowsed = true
            }
        }
        if shown == id {
            if listed {
                loadShownPhotos()
            } else {
                refresh(changed)
            }
        }
        if listed || examplePhoto.map(changed.contains) == true || examplePhoto == nil {
            updateExample()
        }
        countsChanged()
    }
}

extension ImportWindowModel {
    /// Tells the window its counts changed, at most every `countsInterval`: browsing changes them a batch
    /// at a time.
    private func countsChanged() {
        guard !countsDue else { return }
        countsDue = true
        let interval = Self.countsInterval
        Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard let self else { return }
            countsDue = false
            notify(.sources)
            notify(.status)
        }
    }

    private func loadShownPhotos() {
        arrangeShownPhotos()
        notify(.photos(ids: nil))
    }

    /// The shown source's photos taken from its session as it lists them, and put in their groups.
    private func arrangeShownPhotos() {
        let source = shown.flatMap(source)
        let listed = source.map { source in source.photos.compactMap(source.session.photo) } ?? []
        (photos, groups) = grouping.arrange(listed)
        positions = Dictionary(photos.enumerated().map { ($1.id, $0) }) { first, _ in first }
    }

    /// Takes `ids`' photos again from their session.
    private func refresh(_ ids: Set<String>) {
        guard let session = shown.flatMap(source)?.session, !ids.isEmpty else { return }
        var shownChanged = Set<String>()
        var recaptured = false
        for id in ids {
            if let place = positions[id], let photo = session.photo(id) {
                recaptured = recaptured || photo.captured != photos[place].captured
                photos[place] = photo
                shownChanged.insert(id)
            }
        }
        if !shownChanged.isEmpty {
            notify(.photos(ids: shownChanged))
        }
        if recaptured, grouping != .none {
            regroupSoon()
        }
    }

    // MARK: - Groups

    /// How the shown source's photos are grouped.
    var grouping: ImportGrouping {
        shown.flatMap(source).map(grouping(of:)) ?? .none
    }

    func grouping(of source: Source) -> ImportGrouping {
        groupings[source.id] ?? ImportGrouping.standard(for: source.source.kind)
    }

    /// Group By: the shown source's photos grouped by `grouping`, which it keeps while the window is open.
    func setGrouping(_ grouping: ImportGrouping) {
        guard let shown, grouping != self.grouping else { return }
        groupings[shown] = grouping
        loadShownPhotos()
    }

    /// Groups the shown source's photos again as browsing reads their capture times: at most every `countsInterval`,
    /// the grid told only when the groups or their order changed.
    private func regroupSoon() {
        guard !regroupDue else { return }
        regroupDue = true
        let interval = Self.countsInterval
        Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard let self else { return }
            regroupDue = false
            let (before, order) = (groups, photos.map(\.id))
            arrangeShownPhotos()
            if groups != before || photos.map(\.id) != order {
                notify(.photos(ids: nil))
            }
        }
    }

    /// Returns once the regrouping browsing asked for is done.
    func regrouped() async {
        while regroupDue {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Reads these photos first: the cells on screen.
    func prioritise(_ ids: [String]) {
        shown.flatMap(source)?.session.prioritise(ids)
    }

    func photo(at index: Int) -> ImportPhoto? {
        photos.indices.contains(index) ? photos[index] : nil
    }

    func index(of id: String) -> Int? {
        positions[id]
    }

    /// The photo's files are all in the library already, or this window copied it: it's left out.
    func isLeftOut(_ photo: ImportPhoto) -> Bool {
        photo.isImported || copied.contains(photo.id)
    }

    // MARK: - Choices

    /// Which photos go: those left out can't be chosen.
    func choose(_ ids: [String], _ chosen: Bool) {
        let choosable = ids.filter { id in photo(id: id).map { !isLeftOut($0) } ?? false }
        change(choosable) { $0.choose($1, chosen) }
    }

    /// Space, or a click on a cell's box: chooses them all, unless they all are already.
    func toggleChosen(_ ids: [String]) {
        let all = ids.compactMap(photo(id:)).filter { !isLeftOut($0) }.allSatisfy(\.choices.isChosen)
        choose(ids, !all)
    }

    /// 0 to 5.
    func rate(_ ids: [String], _ stars: Int) {
        change(ids) { $0.rate($1, stars) }
    }

    func flag(_ ids: [String], _ flag: PhotoFlag?) {
        change(ids) { $0.flag($1, flag) }
    }

    func label(_ ids: [String], _ label: ColorLabel?) {
        change(ids) { $0.label($1, label) }
    }

    func photo(id: String) -> ImportPhoto? {
        positions[id].map { photos[$0] } ?? sources.lazy.compactMap { $0.session.photo(id) }.first
    }

    private func change(_ ids: [String], _ body: (ImportSession, [String]) -> Void) {
        guard phase != .copying, phase != .planning, !ids.isEmpty else { return }
        for source in sources {
            let mine = ids.filter { source.session.photo($0) != nil }
            if !mine.isEmpty {
                body(source.session, mine)
            }
        }
        refresh(Set(ids))
        if examplePhoto.map(ids.contains) == true || ids.contains(where: { photo(id: $0)?.choices.isChosen == true }) {
            updateExample()
        }
        notify(.status)
    }

    // MARK: - Counts

    /// Photos chosen from the sources included, those the library has or this window copied left out,
    /// and their bytes, as raw only counts them; counted once between changes.
    var chosen: (photos: Int, bytes: Int64) {
        if let counted {
            return counted
        }
        var count = 0
        var bytes: Int64 = 0
        let rawOnly = preferences.settings.rawOnly
        for source in sources where source.isIncluded && source.problem == nil {
            for id in source.photos {
                guard let photo = source.session.photo(id), photo.choices.isChosen, !isLeftOut(photo) else { continue }
                let files = photo.photoFiles.filter { !rawOnly || $0.isRaw }
                guard !files.isEmpty else { continue }
                count += 1
                bytes += files.reduce(0) { $0 + $1.size }
            }
        }
        counted = (count, bytes)
        return (count, bytes)
    }

    /// The photos the library has already, of the sources included.
    var alreadyImported: Int {
        sources.filter(\.isIncluded).reduce(0) { $0 + $1.imported }
    }

    /// The photos on `source` the library doesn't have and this window hasn't copied: those not chosen, those raw
    /// only leaves and those that couldn't be read included.
    func notImported(_ source: Source) -> Int {
        source.photos.count { id in source.session.photo(id).map { !isLeftOut($0) } ?? true }
    }

    /// The source can be erased: the import is done with it, every photo copied from it verified at every
    /// destination, and every photo on it is in the library. The import's own verdict leaves out the photos
    /// the user didn't choose.
    func isSafeToErase(_ source: Source) -> Bool {
        source.outcome?.isSafeToErase == true && notImported(source) == 0
    }

    // MARK: - What the window says

    /// The line under the photos: what's chosen, what's left out, and how the import or its rollback is going.
    var summary: String {
        if let entry = interrupted.first, !isBusy {
            if entry.state == .rollingBack {
                return "\(entry.title) was being rolled back when it was interrupted, with "
                    + "\(Self.count(entry.rolledBack, "photo")) taken back. Resume finishes rolling it back."
            }
            let next = "Resume copies the rest from their cards or folders, which have to be there; Roll Back moves "
                + "those copied to the Trash."
            // One this window ran says why it stopped.
            if let failure, entry.id == plan?.id {
                return failure + " " + next
            }
            return "\(entry.title) was interrupted with \(entry.done) of \(entry.photos) photos copied. " + next
        }
        switch phase {
        case .choosing:
            let (photos, bytes) = chosen
            var text = "\(Self.count(photos, "photo")) chosen, \(ImportFormat.size(bytes))"
            let imported = alreadyImported
            if imported > 0 {
                text += "; \(Self.count(imported, "photo")) already in the library, left out"
            }
            return text + "."
        case .planning:
            return "Working out where each photo goes…"
        case .copying:
            guard let progress else { return "Copying…" }
            return "Copied and verified \(progress.done) of \(Self.count(progress.photos, "photo")), "
                + "\(ImportFormat.size(progress.copied)) of \(ImportFormat.size(progress.bytes))"
                + (progress.failed > 0 ? "; \(progress.failed) couldn't be copied" : "") + "."
        case .adding:
            guard let adding = progress?.adding else { return "Adding the photos to the library…" }
            return "Adding \(Self.count(adding.photos, "photo")) to the library… \(adding.done.formatted()) of "
                + adding.photos.formatted()
        case .rollingBack:
            guard let rollbackProgress else { return "Rolling back…" }
            return "Moving the copies to the Trash: \(rollbackProgress.done) of "
                + "\(Self.count(rollbackProgress.photos, "photo")) taken back."
        case .finished:
            if let rollback {
                return Self.describe(rollback) + (failure.map { " " + $0 } ?? "")
            }
            guard let outcome else { return failure ?? "" }
            var text = "Copied and verified \(outcome.verified) of \(Self.count(outcome.photos, "photo"))"
            if settings.backup != nil {
                text += " at the destination and the backup"
            }
            text += String(format: " in %.0f s.", outcome.elapsed / .seconds(1))
            if let failure {
                text += " " + failure
            }
            return text
        }
    }

    /// What a source's row says under its name.
    func detail(of source: Source) -> String {
        if let outcome = source.outcome {
            if source.isEjected {
                return "Ejected. \(outcome.verified) of \(Self.count(outcome.photos, "photo")) copied and verified."
            }
            guard outcome.isSafeToErase else {
                return "Not safe to erase: \(outcome.verified) of \(outcome.photos) photos verified"
                    + (outcome.failed > 0 ? ", \(outcome.failed) not copied." : ".")
            }
            let waiting = notImported(source)
            return waiting == 0 ? "Safe to erase: every photo on it is in the library."
                : "Not safe to erase: \(Self.count(waiting, "photo")) not imported yet."
        }
        if let progress = source.progress {
            let failed = progress.failed > 0 ? ", \(progress.failed) failed" : ""
            return phase == .adding ? "Copied \(progress.done) of \(progress.photos)\(failed); adding them to the library…"
                : "Copying: \(progress.done) of \(progress.photos)\(failed)"
        }
        if let problem = source.problem {
            return source.isEjected ? "Ejected." : problem
        }
        guard source.isListed else { return "Listing…" }
        var text = Self.count(source.photos.count, "photo")
        if source.imported > 0 {
            text += ", \(source.imported) already in the library"
        }
        if source.unreadable > 0 {
            text += ", \(source.unreadable) unreadable"
        }
        return text
    }

    static func count(_ value: Int, _ noun: String) -> String {
        "\(value.formatted()) \(noun)\(value == 1 ? "" : "s")"
    }

    /// What a rollback did, as the line under the photos says it.
    static func describe(_ rollback: ImportRollback) -> String {
        let taken = rollback.rolledBack.count
        guard rollback.state == .rolledBack else {
            return "Rolling back stopped with \(taken) of \(count(rollback.photos, "photo")) taken back. "
                + "Resume finishes rolling it back."
        }
        var text = taken == 0 && rollback.left.isEmpty
            ? "Rolled back: the import had no copies to take back."
            : "Rolled back: the copies of \(count(taken, "photo")) are in the Trash and out of the library."
        let folders = rollback.removedFolders.count
        if folders > 0 {
            text += " \(count(folders, "empty folder")) the import made \(folders == 1 ? "is" : "are") removed."
        }
        if let first = rollback.left.first {
            let photos = Set(rollback.left.map(\.photo)).count
            text += " " + (photos == 1 ? "1 photo is left where it was copied to" : "\(count(photos, "photo")) are "
                + "left where they were copied to") + ": \((first.path as NSString).lastPathComponent): \(first.message)."
        }
        return text
    }

    // MARK: - Settings

    var settings: ImportSettings {
        preferences.settings
    }

    /// The destination was chosen; until it is, Import asks for it.
    var hasDestination: Bool {
        preferences.hasDestination
    }

    /// The destination, chosen in its panel at `url`.
    func setDestination(_ url: URL) {
        preferences.chooseDestination(url)
        settingsChanged()
    }

    /// A second copy at `url`, chosen in its panel; nil for none.
    func setBackup(_ url: URL?) {
        preferences.chooseBackup(url)
        settingsChanged()
    }

    /// The folder template as it's typed: an error in it is said in words, and the last one that reads stays.
    func setFolders(_ text: String) {
        folderText = text
        do {
            let template = try NamingTemplate(parsing: text, asYouType: true)
            folderError = nil
            preferences.update { $0.folders = template }
        } catch {
            folderError = error.message
        }
        settingsChanged()
    }

    func setNames(_ text: String) {
        namesText = text
        do {
            let template = try NamingTemplate(parsing: text, asYouType: true)
            namesError = nil
            preferences.update { $0.names = template }
        } catch {
            namesError = error.message
        }
        settingsChanged()
    }

    /// `{text}` and `{text:shoot}`, by their names ("" and "shoot").
    func setText(_ name: String, _ value: String) {
        preferences.update { settings in
            settings.texts[name] = value.isEmpty ? nil : value
        }
        settingsChanged()
    }

    /// The names of the texts the templates use, `{text}` as "".
    var textNames: [String] {
        var names: [String] = []
        for name in settings.folders.textNames + settings.names.textNames where !names.contains(name) {
            names.append(name)
        }
        return names
    }

    func setRawOnly(_ rawOnly: Bool) {
        preferences.update { $0.rawOnly = rawOnly }
        settingsChanged()
        notify(.status)
    }

    /// Keywords by path, `Places/Portugal/Lisbon`, put on every photo imported.
    func setKeywords(_ keywords: [String]) {
        preferences.update { $0.metadata.keywords = KeywordPath.texts(keywords) }
        settingsChanged()
    }

    func setEjectsAfterImport(_ ejects: Bool) {
        preferences.ejectsAfterImport = ejects
        notify(.settings)
    }

    /// The library's keywords that complete `text`, the best first.
    func keywords(completing text: String) -> [String] {
        keywordCompletion?.matches(text).map(\.path.description) ?? []
    }

    private func settingsChanged() {
        updateExample()
        notify(.settings)
    }

    // MARK: - The example

    /// The photo the example names: the first chosen of the shown source, else of the first source included.
    private var exampleCandidate: (ImportPhoto, ImportSource)? {
        let order = (shown.flatMap(source).map { [$0] } ?? []) + sources.filter { $0.isIncluded && $0.id != shown }
        for source in order where source.isIncluded {
            for id in source.photos {
                if let photo = source.session.photo(id), photo.choices.isChosen, !isLeftOut(photo) {
                    return (photo, source.source)
                }
            }
        }
        return sources.isEmpty ? exampleStandIn?() : nil
    }

    /// Names the example photo again, off the main thread, as the plan would.
    func updateExample() {
        exampleTask?.cancel()
        guard folderError == nil, namesError == nil, let (photo, source) = exampleCandidate else {
            if example != nil || examplePhoto != nil {
                example = nil
                examplePhoto = nil
                notify(.settings)
            }
            return
        }
        let settings = settings
        let paths = library.paths
        exampleTask = Task { [weak self] in
            let named = await ImportExample.path(of: photo, on: source, settings: settings, paths: paths)
            guard !Task.isCancelled, let self else { return }
            example = named
            examplePhoto = photo.id
            notify(.settings)
        }
    }

    /// Returns once the example asked for last is named.
    func exampled() async {
        await exampleTask?.value
    }

    func notify(_ change: Change) {
        if change != .settings {
            counted = nil
        }
        onChange?(change)
    }
}

/// Sizes as the window writes them.
enum ImportFormat {
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Events gathered off the main thread and taken in batches.
final class ImportEventBuffer: Sendable {
    private let state = Mutex<(events: [ImportEvent], waiting: Bool)>(([], false))

    /// Adds `event`; true when no batch waits to be taken yet, so one is to be.
    func append(_ event: ImportEvent) -> Bool {
        state.withLock { state in
            state.events.append(event)
            defer { state.waiting = true }
            return !state.waiting
        }
    }

    func take() -> [ImportEvent] {
        state.withLock { state in
            defer { state = ([], false) }
            return state.events
        }
    }
}
