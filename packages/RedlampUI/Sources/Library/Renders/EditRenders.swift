import Foundation
import RedlampDocument
import RedlampEngineAPI
import RedlampLibrary

/// Thumbnails and previews that show the edit (LIB-17). An edited photo the library shows is rendered
/// with its edit by Redlamp's own engine, in an engine of the library's own (`makeEngine`), at the
/// store's preview size, and its preview and grid tiers are stored under its content key and its edit's
/// digest (`EditDigest(rendering:)`). Until they're there, its embedded preview shows, marked so it's
/// clear which is showing: the loaders ask `shownEdit(for:)` which to load, and the views `renders(_:)`
/// whether to mark it.
///
/// - Order: the photos on screen first (the grid's, the filmstrip's and the active photo), then those
///   within a screen of them, nearest first, then the rest of the source in its order. A photo's sidecar
///   is read off the main thread for its edit's digest, up to `readAhead` photos ahead of the renders.
/// - Relaunching: the index records each photo's edit once its render is stored, with the date its sidecar had
///   (`PhotoEdit`), and the photo comes from the index with it (`LibraryItem.renderedEdit`) while its sidecar's
///   date is the same, so its render shows from the start, before its sidecar is read again.
/// - Changes: a photo whose sidecar or file changed (the editor's saves, and other apps' changes that
///   LibraryLive reports) is read again, showing what it showed until then. When its edit changed, it
///   shows its embedded preview until the new edit is rendered, never the old edit's, whose renders leave
///   the store unless another copy of the photo shows them. A photo given its first edit is read and rendered
///   in its turn, as the others are, wherever it is in the source.
/// - Develop first: a render starts, and goes from one step to the next (opening the photo, rendering
///   it), only while no export runs and no dialog is open, Develop isn't shown or has asked for no frame
///   for `developQuiet` and isn't opening a photo, no thumbnail on screen waits, and the Mac isn't hot or
///   saving power. The photo open in Develop waits until it's left, and renders in Develop's engine while Develop
///   keeps it open behind Library, where it's decoded already. `statistics` counts the waits, and Develop's frames
/// asked for
///   while a step ran.
/// - Bounded: one render at a time, cancelled when its photo leaves the source, its edit changes or Develop shows
///   it. The
///   engine is let go once the photos it opened would hold more than `engineBudget` on the GPU, and after
///   `engineIdle` with nothing to render.
/// - Full size: the loupe's 1:1 asks for a photo's edit rendered at its full size (`renderFullSize`), which isn't
///   stored. It takes the place of the render running, and none starts until it ends.
/// - Versions (LIB-48): a photo is known by its address, a file's own edit or one of its versions, whose edit is the
///   version's in the file's sidecar (`Sidecar[edit:]`) and whose render is recorded under its own row. A file's
///   photos with the same edit share its render, and the renders of the edits its sidecar holds stay while another
///   source shows the photos that have them.
@MainActor
public final class EditRenders {
    /// Where the views report the rows on screen from.
    public enum Place: Hashable, Sendable {
        case grid, filmstrip
    }

    public struct Statistics: Sendable, Equatable {
        /// Photos rendered and stored, and those that couldn't be (a file that doesn't open, say).
        public var rendered = 0
        public var failed = 0
        /// Renders that waited for Develop, the thumbnails on screen or a cool Mac, and how long in all.
        public var waits = 0
        public var waited: Duration = .zero
        /// Frames Develop asked for while a render's step ran.
        public var overlaps = 0
        /// Engines made, one again after each was let go.
        public var engines = 0
        /// Each render's photo and steps.
        public var steps: [Step] = []

        public struct Step: Sendable, Equatable {
            public var pixels: Int
            /// In seconds: the photo opened, the edit rendered, the tiers stored.
            public var opening: Double
            public var rendering: Double
            public var storing: Double
        }
    }

    /// Names how the library renders edits, in every digest: a change to it makes every render again.
    nonisolated static let renderVersion = "app.redlamp.library.edit-render \(renderer)\n"
    /// Its number, which the index keeps with each photo's rendered edit (`PhotoEdit`): a render made before a
    /// change to it never shows as current.
    nonisolated static let renderer = 1
    /// How long Develop must have asked for no frame before a render goes on.
    static let developQuiet = Duration.milliseconds(1000)
    /// The GPU memory the pyramids of the engine's opened photos may take before it's let go: their
    /// sessions stay cached in it, each taking about twice its pyramid. And how long it's kept with
    /// nothing to render.
    static let engineBudget = 256 << 20
    static let engineIdle = Duration.seconds(10)
    /// Sidecars read in a job, jobs at once, and photos read but not yet rendered, at most, beyond
    /// those on screen and their neighbours.
    static let readBatch = 16
    static let readJobs = 2
    static let readAhead = 48
    /// How long a change to what's on screen waits for others before the next is chosen.
    static let onScreenDelay = Duration.milliseconds(50)

    /// Makes the engine edits are rendered in, off the main thread; the app sets it. Nil renders nothing.
    public var makeEngine: (@Sendable () -> (any EditingEngine)?)?
    public internal(set) var statistics = Statistics()
    /// While false, renders wait before their next step (the measurements' baselines).
    public var isRunning = true {
        didSet {
            if isRunning, !oldValue {
                schedulePump()
            }
        }
    }

    /// False while the editor window is closed: renders wait, without an engine, until it's back.
    private(set) var isWindowOpen = true

    /// The editor, for what Develop is doing and its Base Looks.
    weak var editor: EditorModel?
    let library: FolderLibrary
    let scheduler: WorkScheduler
    var known: [PhotoAddress: Known] = [:]
    /// Photos whose edits are read but not rendered: those still to render.
    private(set) var waiting = 0
    private var reading: Set<PhotoAddress> = []
    private var readJobs = 0
    /// Rows of the rest of the source looked at in one turn; fewer in tests.
    var scanLimit = 1024
    private var onScreen: [Place: Range<Int>] = [:]
    /// The rows of the rest of the source before these need no reading, and no rendering.
    private var readCursor = 0
    private var renderCursor = 0
    /// Photos the render cursor moved past while Develop had them open: it comes back to them once it doesn't.
    private var passedInDevelop: Set<PhotoAddress> = []
    /// A large source's photos with an edit, by their rows in order, which the rest of the source is looked at in:
    /// nil until they're found, and again once photos come, go or change (`findEdited`).
    private var editedRows: [Int]?
    private var findingEdited = false
    /// Photos changed while their edits were being found, so they're found again.
    private var findAgain = false
    /// Counts the changes that move the source's photos, which `editedRows` are rows of.
    private var layout = 0
    /// Whether a photo whose sidecar isn't read shows the render the index records for it; not once
    /// `renderAgain()` removed the renders.
    private var showsRecords = true
    /// The index's records of rendered edits being written, one write after another.
    private var recording: Task<Void, Never>?
    var current: (photo: PhotoAddress, task: Task<Void, Never>)?
    /// Full-size renders asked for and not yet ended, which no render starts beside, and whether one is running.
    var fullSizeAsked = 0
    var fullSizeRunning = false
    var engine: (any EditingEngine)?
    var engineBytes = 0
    var idleRelease: Task<Void, Never>?
    /// When Develop last asked for a frame or got one, and whether a render's step is running.
    var developActive: ContinuousClock.Instant?
    var stepRunning = false
    private var observers: [UUID: @MainActor ([PhotoAddress]) -> Void] = [:]
    private var windowClosing: [UUID: @MainActor () -> Void] = [:]
    private var observation: LibraryObservation?
    private var pumping = false

    /// A photo's edit as last read.
    struct Known {
        var key: ContentKey
        /// The photo's file and sidecar when it was read: either changing reads it again.
        var size: Int64
        var modified: Date
        var sidecarModified: Date?
        /// Nil: its sidecar holds no edit to render.
        var digest: EditDigest?
        /// The digests of the edits to render its file's sidecar held when it was read, by version, nil for the file's
        /// own: the file's photos with its edit share its render, and the renders of the others' edits stay.
        var fileEdits: [UUID?: EditDigest] = [:]
        var state: State

        enum State {
            case unrendered, rendered, failed
        }
    }

    /// What a row needs next.
    private enum Need {
        case nothing, read, render
    }

    init(library: FolderLibrary, scheduler: WorkScheduler) {
        self.library = library
        self.scheduler = scheduler
        observation = library.observe { [weak self] diff in self?.changed(diff) }
    }

    isolated deinit {
        current?.task.cancel()
        idleRelease?.cancel()
    }

    // MARK: - What's shown

    /// The edit `item`'s thumbnails and previews show: its edit's digest once that's rendered, else nil
    /// for its embedded preview. Until its sidecar is read, the edit the index records as rendered for the sidecar
    /// as it is.
    func shownEdit(for item: LibraryItem) -> EditDigest? {
        guard item.hasEdits else { return nil }
        guard let known = known[item.address] else { return showsRecords ? item.renderedEdit : nil }
        return known.state == .rendered ? known.digest : nil
    }

    func shownEdit(at photo: PhotoAddress) -> EditDigest? {
        item(photo).flatMap(shownEdit(for:))
    }

    /// The edit `item`'s sidecar held when it was last read, rendered or not: nil for none to render, and until it's
    /// read as the file and sidecar are now.
    func readEdit(of item: LibraryItem) -> EditDigest? {
        guard item.hasEdits, let entry = known[item.address], Self.isCurrent(entry, for: item) else { return nil }
        return entry.digest
    }

    /// The row of the photo `photo` names, while the source shows it and it's read.
    func item(_ photo: PhotoAddress) -> LibraryItem? {
        library.index(of: photo).flatMap { library.items.row($0) }
    }

    /// Whether the library renders `item`'s edit, so its embedded preview is marked until then.
    public func renders(_ item: LibraryItem) -> Bool {
        item.hasEdits && item.isLocal && library.storeThumbnail(for: item) != nil
    }

    /// Calls `handler` with the photos whose thumbnails and previews show another edit, until the
    /// returned token is released.
    func observe(_ handler: @escaping @MainActor ([PhotoAddress]) -> Void) -> LibraryObservation {
        let id = UUID()
        observers[id] = handler
        return LibraryObservation { [weak self] in self?.observers.removeValue(forKey: id) }
    }

    /// Calls `handler` when the editor window closes, for what keeps thumbnails beside the renders to let
    /// go of them.
    func observeWindowClosing(_ handler: @escaping @MainActor () -> Void) -> LibraryObservation {
        let id = UUID()
        windowClosing[id] = handler
        return LibraryObservation { [weak self] in self?.windowClosing.removeValue(forKey: id) }
    }

    /// The editor window closed: the render running stops, the engine lets go of its photos, renders wait
    /// until the window is back, and what keeps thumbnails beside them lets them go.
    func windowClosed() {
        isWindowOpen = false
        letEngineGo()
        for handler in windowClosing.values {
            handler()
        }
    }

    /// The editor window is back: renders go on.
    func windowReopened() {
        guard !isWindowOpen else { return }
        isWindowOpen = true
        schedulePump()
    }

    func notify(_ photos: [PhotoAddress]) {
        guard !photos.isEmpty else { return }
        for observer in observers.values {
            observer(photos)
        }
    }

    /// A loader found no render of `edit` in the store, where one was, or where the index recorded one: it's made
    /// again. It was the render of the file's other photos with that edit too, which show without it until then.
    func missing(_ photo: PhotoAddress, _ edit: EditDigest) {
        if known[photo] == nil {
            guard let item = item(photo), shownEdit(for: item) == edit,
                  let (_, key) = library.storeThumbnail(for: item)
            else { return }
            set(photo, Known(
                key: key, size: item.size, modified: item.modified, sidecarModified: item.sidecarModified, digest: edit,
                state: .rendered,
            ))
        }
        let gone = known.compactMap { address, entry in
            address.url == photo.url && entry.digest == edit && entry.state == .rendered ? address : nil
        }
        guard !gone.isEmpty else { return }
        for address in gone {
            settle(address, as: .unrendered)
            revisit(address)
        }
        notify(gone)
        schedulePump()
    }

    /// The photo `photo` names needs reading or rendering again: the rest of the source is looked at from it.
    func revisit(_ photo: PhotoAddress) {
        guard let row = library.index(of: photo) else { return }
        readCursor = min(readCursor, row)
        renderCursor = min(renderCursor, row)
    }

    /// Forgets every photo's edit and removes the store's renders of them and the index's records of those, so
    /// they're read and rendered again, and starts the statistics again: for measurements. The renders are removed
    /// off the main thread, rewriting the store's shards, with renders paused until they're gone.
    @_spi(Harness) public func renderAgain() async {
        current?.task.cancel()
        let wasRunning = isRunning
        isRunning = false
        if let store = library.service?.thumbnails?.store {
            let keys = Set(known.values.map(\.key))
            _ = try? await scheduler.run(.background) {
                for key in keys {
                    store.removeEdits(of: key)
                }
            }
        }
        record(known.keys.map { Record(photo: $0, sidecarModified: nil, digest: nil) })
        showsRecords = false
        known = [:]
        waiting = 0
        (readCursor, renderCursor) = (0, 0)
        statistics = Statistics()
        isRunning = wasRunning
        schedulePump()
    }

    /// Whether `item`'s edit, as its file and sidecar are now, is rendered: true once it is, false once it's found
    /// it can't be, nil until then. For measurements.
    @_spi(Harness) public func isRendered(_ item: LibraryItem) -> Bool? {
        guard let entry = known[item.address], Self.isCurrent(entry, for: item), entry.state != .unrendered else {
            return nil
        }
        return entry.state == .rendered
    }

    /// Stops the render running and lets the engine go: for measurements.
    @_spi(Harness) public func letEngineGo() {
        current?.task.cancel()
        idleRelease?.cancel()
        idleRelease = nil
        releaseEngine()
    }

    // MARK: - What's on screen

    /// The rows `place` shows, which go first.
    public func show(_ rows: Range<Int>, in place: Place) {
        guard onScreen[place] != rows else { return }
        onScreen[place] = rows
        schedulePump(after: Self.onScreenDelay)
    }

    /// Develop is shown: a render of the photo it shows stops, so its frames don't wait behind it in Develop's engine.
    func developShown() {
        if let current, isOpenInDevelop(current.photo) {
            current.task.cancel()
        }
    }

    /// Develop asked for a frame.
    func developAsked() {
        developActive = .now
        if stepRunning {
            statistics.overlaps += 1
        }
    }

    /// Develop's frame came.
    func developRendered() {
        developActive = .now
    }

    // MARK: - The source's changes

    private func changed(_ diff: LibraryDiff) {
        if diff.reset || !diff.removed.isEmpty || !diff.inserted.isEmpty {
            layout += 1
            (readCursor, renderCursor) = (0, 0)
            editedRows = nil
            if diff.reset {
                onScreen = [:]
                for photo in known.keys where library.index(of: photo) == nil {
                    set(photo, nil)
                }
            }
            if let current, library.index(of: current.photo) == nil {
                current.task.cancel()
            }
        } else if let first = diff.updated.first {
            // A photo may have been given its first edit, on screen or off it (Sync, Paste, another Mac): the rest of
            // the source is looked at again from the first photo that changed, and a large source's photos with an
            // edit are found again.
            readCursor = min(readCursor, first)
            renderCursor = min(renderCursor, first)
            if library.items.readsOnRequest {
                editedRows = nil
                findAgain = findingEdited
            }
        }
        var gone: [PhotoAddress] = []
        let items = library.items
        // A change to thousands of rows (culling a whole selection) reaches the photos known here alone.
        let rows = diff.updated.count > known.count
            ? known.keys.compactMap { library.index(of: $0) }.filter(diff.updated.contains).sorted()
            : Array(diff.updated)
        for row in rows where items.indices.contains(row) {
            guard let item = items.row(row), let entry = known[item.address] else { continue }
            if !item.hasEdits {
                drop(entry.digest, of: entry.key, unlessShownBy: item.address)
                set(item.address, nil)
                gone.append(item.address)
                if current?.photo == item.address {
                    current?.task.cancel()
                }
            } else if !Self.isCurrent(entry, for: item) {
                readCursor = min(readCursor, row)
                renderCursor = min(renderCursor, row)
            }
        }
        notify(gone)
        schedulePump()
    }

    /// Whether `entry` was read from the file and sidecar `item` has now.
    static func isCurrent(_ entry: Known, for item: LibraryItem) -> Bool {
        entry.size == item.size && entry.modified == item.modified && entry.sidecarModified == item.sidecarModified
    }

    func set(_ photo: PhotoAddress, _ entry: Known?) {
        let before = known[photo]?.state == .unrendered
        known[photo] = entry
        waiting += (entry?.state == .unrendered ? 1 : 0) - (before ? 1 : 0)
    }

    func settle(_ photo: PhotoAddress, as state: Known.State) {
        guard var entry = known[photo] else { return }
        entry.state = state
        set(photo, entry)
    }

    /// The file's other photos, its own or its versions, read with `entry`'s edit from the file and sidecar `entry` was
    /// read from, and still to render: what rendering `entry`'s edit renders for them too.
    func sharing(_ entry: Known, with photo: PhotoAddress) -> [PhotoAddress] {
        entry.fileEdits.compactMap { version, edit in
            let other = PhotoAddress(url: photo.url, version: version)
            guard other != photo, edit == entry.digest, let known = known[other], known.digest == edit,
                  known.state == .unrendered, known.size == entry.size, known.modified == entry.modified,
                  known.sidecarModified == entry.sidecarModified
            else { return nil }
            return other
        }
    }

    /// Removes the store's renders of `edit` of the photo `key` names, unless another photo with that
    /// key shows them (a copy of it, or another of its file's versions) or a sidecar read holds it.
    func drop(_ edit: EditDigest?, of key: ContentKey, unlessShownBy photo: PhotoAddress) {
        guard let edit, let store = library.service?.thumbnails?.store else { return }
        let keeping = claims(of: key, except: photo)
        guard !keeping.contains(edit) else { return }
        scheduler.submit(.background) { _ = store.removeEdits(of: key, keeping: keeping) }
    }

    /// The edits other photos with `key` show, or will once rendered, and those the sidecars read for photos with `key`
    /// hold for photos other than `photo`, which another source may show.
    func claims(of key: ContentKey, except photo: PhotoAddress) -> Set<EditDigest> {
        var claims = Set<EditDigest>()
        for (address, entry) in known where entry.key == key {
            if address != photo, let digest = entry.digest {
                claims.insert(digest)
            }
            for (version, edit) in entry.fileEdits where PhotoAddress(url: address.url, version: version) != photo {
                claims.insert(edit)
            }
        }
        return claims
    }
}

extension EditRenders {
    // MARK: - Choosing what's next

    /// Chooses what to read and render next on a later turn of the main thread, after `delay`, once
    /// for every call made before then.
    func schedulePump(after delay: Duration = .zero) {
        guard !pumping else { return }
        pumping = true
        Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard let self else { return }
            pumping = false
            let focus = focusRows()
            readEdits(focus)
            renderNext(focus)
        }
    }

    private func need(_ item: LibraryItem) -> Need {
        guard item.hasEdits, item.isLocal, !item.isSettling, item.sidecarIsLocal,
              library.storeThumbnail(for: item) != nil
        else { return .nothing }
        let photo = item.address
        guard let entry = known[photo], Self.isCurrent(entry, for: item) else {
            return reading.contains(photo) ? .nothing : .read
        }
        // A photo kept in Apple Photos renders once its original is downloaded (LIB-60), Photos' image showing until
        // then: `originalArrived` looks at it again.
        guard entry.state != .unrendered || !library.needsDownload(item.url) else { return .nothing }
        return entry.state == .unrendered && !reading.contains(photo) ? .render : .nothing
    }

    /// The original of a photo kept in Apple Photos arrived (LIB-60): its edit, which waited for it, renders now.
    func originalArrived(_ url: URL) {
        revisit(PhotoAddress(url: url))
        schedulePump()
    }

    /// The rows on screen, the active photo's first, then those within a screen of them, nearest first.
    private func focusRows() -> [Int] {
        let count = library.items.count
        var ranges = Array(onScreen.values).map { $0.clamped(to: 0 ..< count) }.filter { !$0.isEmpty }
        if let row = activeRow {
            ranges.insert(row ..< row + 1, at: 0)
        }
        var seen = Set<Int>()
        var rows: [Int] = []
        for range in ranges {
            for row in range where seen.insert(row).inserted {
                rows.append(row)
            }
        }
        let screen = ranges.map(\.count).max() ?? 0
        if screen > 0 {
            for distance in 1 ... screen {
                for range in ranges {
                    for row in [range.lowerBound - distance, range.upperBound - 1 + distance]
                        where (0 ..< count).contains(row) && seen.insert(row).inserted {
                        rows.append(row)
                    }
                }
            }
        }
        return rows
    }

    /// The active photo's row: the selection's active photo, a file's own or one of its versions, while it's of the
    /// file
    /// the editor has active; else that file's own.
    private var activeRow: Int? {
        guard let editor, let selection = editor.selection else { return nil }
        if let active = editor.photoSelection.active, let row = library.photoList.index(of: active),
           library.items.row(row)?.url == selection {
            return row
        }
        return library.index(of: selection)
    }

    /// The rows of the rest of the source from `cursor`, `scanLimit` at most, `visit`ed in order until it
    /// returns false. The cursor moves past those `isDone` says need nothing. Of a large source's, those of its
    /// photos with an edit alone (`scanLarge`).
    private func scan(from cursor: inout Int, isDone: (LibraryItem) -> Bool, _ visit: (Int) -> Bool) {
        let items = library.items
        guard !items.readsOnRequest else { return scanLarge(from: &cursor, isDone: isDone, visit) }
        var row = cursor
        let end = min(items.count, cursor + scanLimit)
        while row < end {
            if row == cursor, isDone(items[row]) {
                cursor += 1
            } else if !visit(row) {
                return
            }
            row += 1
        }
        if row == end, end < items.count {
            schedulePump()
        }
    }

    /// `scan` over a large source's photos with an edit, as the engine finds them: those whose rows aren't read are
    /// asked for, a batch at a time, and looked at once they're in.
    private func scanLarge(from cursor: inout Int, isDone: (LibraryItem) -> Bool, _ visit: (Int) -> Bool) {
        guard let edited = editedRows else { return findEdited() }
        let items = library.items
        var (index, high) = (0, edited.count)
        while index < high {
            let middle = (index + high) / 2
            if edited[middle] < cursor {
                index = middle + 1
            } else {
                high = middle
            }
        }
        let end = min(edited.count, index + scanLimit)
        var asking: [Int] = []
        while index < end {
            let row = edited[index]
            guard items.indices.contains(row), let item = items.row(row) else {
                asking.append(row)
                guard asking.count < Self.readBatch * 4 else { break }
                index += 1
                continue
            }
            if asking.isEmpty, isDone(item) {
                cursor = row + 1
            } else if !visit(row) {
                break
            }
            index += 1
        }
        // Rows are read for renders only while they can be made.
        if makeEngine != nil, isWindowOpen {
            library.askForRows(at: asking)
        }
        if index == end, end < edited.count, asking.isEmpty {
            schedulePump()
        }
    }

    /// Finds the large source's or folder's photos with an edit, and their rows, off the main thread, for
    /// `scanLarge`: again when photos moved or changed meanwhile.
    private func findEdited() {
        guard !findingEdited, let engine = library.service?.core?.engine,
              let query = try? LibraryQuery(parsing: "edited:yes")
        else { return }
        findingEdited = true
        findAgain = false
        let (layout, list) = (layout, library.photoList)
        let source = list.source
        Task { [weak self] in
            let rows = await Task.detached(priority: .utility) { () -> [Int]? in
                guard let found = try? await engine.list(source, matching: query) else { return nil }
                return found.ids.compactMap(list.index(of:)).sorted()
            }.value
            guard let self else { return }
            findingEdited = false
            guard library.items.readsOnRequest else { return }
            guard self.layout == layout, !findAgain else { return findEdited() }
            editedRows = rows ?? []
            schedulePump()
        }
    }

    /// Starts reading the edits of the next photos that need it, a batch to a job: those on screen and
    /// near it, then the rest of the source's, `readAhead` at most ahead of the renders.
    private func readEdits(_ focus: [Int]) {
        let items = library.items
        while readJobs < Self.readJobs {
            var batch: [ReadPhoto] = []
            var urgent = false
            let add = { (row: Int) in
                guard let item = items.row(row), self.need(item) == .read,
                      !batch.contains(where: { $0.item.address == item.address }),
                      let (thumbnails, key) = self.library.storeThumbnail(for: item)
                else { return }
                batch.append(ReadPhoto(item: item, key: key, store: thumbnails.store))
            }
            for row in focus where batch.count < Self.readBatch {
                add(row)
            }
            urgent = !batch.isEmpty
            if batch.count < Self.readBatch, waiting < Self.readAhead {
                scan(from: &readCursor, isDone: { need($0) != .read }) { row in
                    add(row)
                    return batch.count < Self.readBatch && waiting + batch.count < Self.readAhead
                }
            }
            guard !batch.isEmpty else { return }
            readJobs += 1
            reading.formUnion(batch.map(\.item.address))
            let (photos, sidecars) = (batch, library.sidecars)
            scheduler.submit(urgent ? .lookAhead : .background) {
                let read = Self.read(photos, sidecars: sidecars)
                Task { @MainActor [weak self] in self?.received(read) }
            }
        }
    }

    /// A photo whose edit is to be read: as it was listed, its content key and the store.
    struct ReadPhoto: Sendable {
        let item: LibraryItem
        let key: ContentKey
        let store: PhotoStore
    }

    /// What reading a photo's edit found: its digest (nil for none to render), the digests of the edits to render its
    /// file's sidecar holds, by version, and whether the store has both its tiers of the file as it is.
    struct ReadEdit: Sendable {
        let digest: EditDigest?
        let fileEdits: [UUID?: EditDigest]
        let isStored: Bool
    }

    /// Reads the edits of `photos`, each file's sidecar once for its photos among them, its own and its versions'.
    nonisolated static func read(_ photos: [ReadPhoto], sidecars: SidecarPlacement) -> [(ReadPhoto, ReadEdit)] {
        var files: [URL: [UUID?: EditDigest]] = [:]
        return photos.map { photo in
            let url = photo.item.url
            let edits = files[url] ?? digests(of: url, in: sidecars.store(for: url))
            files[url] = edits
            return (photo, read(photo, in: edits))
        }
    }

    /// The digests of the edits to render in `photo`'s sidecar, by version, nil for the photo's own. An edit made by a
    /// newer Redlamp isn't rendered: a render made here would be kept under its digest after an update that renders
    /// it as it was made.
    nonisolated static func digests(of photo: URL, in store: SidecarStore) -> [UUID?: EditDigest] {
        var digests: [UUID?: EditDigest] = [:]
        for (version, recipe) in recipes(of: photo, in: store)
            where !recipe.isPristine && !recipe.requiresNewerProcess {
            digests[version] = EditDigest(rendering: recipe)
        }
        return digests
    }

    /// `photo`'s edit among its file's, and whether the store holds its render.
    nonisolated static func read(_ photo: ReadPhoto, in fileEdits: [UUID?: EditDigest]) -> ReadEdit {
        guard let digest = fileEdits[photo.item.version] else {
            return ReadEdit(digest: nil, fileEdits: fileEdits, isStored: false)
        }
        let stored = PhotoStore.Tier.allCases.allSatisfy { tier in
            photo.store.contains(
                photo.key, tier: tier, edit: digest, size: photo.item.size, modified: photo.item.modified,
            )
        }
        return ReadEdit(digest: digest, fileEdits: fileEdits, isStored: stored)
    }

    /// Takes the edits read. Before a photo's sidecar is read, the edit the index records stands for the one it
    /// showed; a photo whose edit isn't recorded as it's now stored has its record set right. A photo with the edit
    /// another of its file's photos shows rendered, read from the same sidecar, shows that render.
    private func received(_ read: [(ReadPhoto, ReadEdit)]) {
        readJobs -= 1
        var changed: [PhotoAddress] = []
        var records: [Record] = []
        for (photo, edit) in read {
            let address = photo.item.address
            reading.remove(address)
            guard let item = item(address), item.size == photo.item.size,
                  item.modified == photo.item.modified, item.sidecarModified == photo.item.sidecarModified,
                  library.storeThumbnail(for: item)?.1 == photo.key
            else {
                revisit(address)
                continue
            }
            let shown = shownEdit(for: item)
            let before = known[address]
            let previous = before == nil ? shown : before?.digest
            let isStored = edit.isStored || edit.fileEdits.contains { version, other in
                guard version != item.version, other == edit.digest,
                      let entry = known[PhotoAddress(url: item.url, version: version)]
                else { return false }
                return entry.digest == other && entry.state == .rendered && Self.isCurrent(entry, for: item)
            }
            set(address, Known(
                key: photo.key, size: item.size, modified: item.modified, sidecarModified: item.sidecarModified,
                digest: edit.digest, fileEdits: edit.fileEdits,
                state: edit.digest == nil ? .failed : isStored ? .rendered : .unrendered,
            ))
            if let previous, previous != edit.digest {
                drop(previous, of: before?.key ?? photo.key, unlessShownBy: address)
            }
            if edit.digest != item.renderedEdit, isStored || item.renderedEdit != nil {
                records.append(Record(
                    photo: address, sidecarModified: item.sidecarModified, digest: isStored ? edit.digest : nil,
                ))
            }
            if shownEdit(for: item) != shown {
                changed.append(address)
            }
        }
        record(records)
        notify(changed)
        schedulePump()
    }

    /// What the index is to record of a photo's rendered edit: the digest whose render the store holds, read from
    /// its sidecar as modified at `sidecarModified`; with no digest, that it has none.
    struct Record: Sendable {
        let photo: PhotoAddress
        let sidecarModified: Date?
        let digest: EditDigest?
    }

    /// Records the edits whose renders the store holds in the index, each under its photo's own row, off the main
    /// thread and in the order asked, so a relaunch shows them before the photos' sidecars are read again
    /// (`PhotoEdit`); forgets a photo's for a record with no digest.
    func record(_ records: [Record]) {
        guard !records.isEmpty, let index = library.service?.core?.index else { return }
        let (renderer, previous) = (Self.renderer, recording)
        recording = Task.detached(priority: .utility) {
            await previous?.value
            _ = try? await index.write { writer in
                for record in records {
                    guard let photo = try Self.row(of: record.photo, in: writer) else { continue }
                    if let digest = record.digest, let modified = record.sidecarModified {
                        try writer.setPhotoEdit(
                            digest,
                            ofPhoto: photo.id,
                            sidecarModified: modified,
                            renderer: renderer,
                        )
                    } else {
                        try writer.removePhotoEdits([photo.id])
                    }
                }
            }
        }
    }

    /// The index's row of `photo`: its file's own, or its version's.
    nonisolated static func row(of photo: PhotoAddress, in reader: some IndexQueries) throws -> PhotoRecord? {
        guard let file = try LibraryService.photo(at: photo.url, in: reader) else { return nil }
        guard let version = photo.version else { return file }
        return try reader.versions(folder: file.folder, name: file.name).first { $0.version == version }
    }

    /// A photo to render: its edit's digest, and the store its tiers go to under its content key.
    struct NextRender {
        let item: LibraryItem
        let key: ContentKey
        let store: PhotoStore
        let digest: EditDigest
    }

    /// The next photo to render: the first of `focus` that needs it, else of the rest of the source,
    /// leaving the one open in Develop until it's left. The cursor moves past that one, or every turn would scan the
    /// same rows from it, and starts the next at once, until Develop is left.
    func nextRender(_ focus: [Int]) -> NextRender? {
        let left = passedInDevelop.filter { !isOpenInDevelop($0) }
        for photo in left {
            revisit(photo)
        }
        passedInDevelop.subtract(left)
        let items = library.items
        var found: NextRender?
        let take = { (row: Int) -> Bool in
            guard let item = items.row(row), self.need(item) == .render, !self.isOpenInDevelop(item.address),
                  let digest = self.known[item.address]?.digest,
                  let (thumbnails, key) = self.library.storeThumbnail(for: item)
            else { return false }
            found = NextRender(item: item, key: key, store: thumbnails.store, digest: digest)
            return true
        }
        if focus.contains(where: take) {
            return found
        }
        scan(from: &renderCursor, isDone: { item in
            if need(item) == .render, isOpenInDevelop(item.address) {
                passedInDevelop.insert(item.address)
                return true
            }
            return need(item) == .nothing && !reading.contains(item.address)
        }) { !take($0) }
        return found
    }

    /// Whether Develop shows `photo`, a file's own edit or one of its versions, or is to open it: the file's other
    /// photos render meanwhile.
    func isOpenInDevelop(_ photo: PhotoAddress) -> Bool {
        guard let editor, editor.module == .develop else { return false }
        if editor.info?.url == photo.url, editor.openVersion == photo.version {
            return true
        }
        let isOpen = editor.info?.url == photo.url && editor.opening == nil
        return editor.selection == photo.url && !isOpen && editor.openingVersion == photo.version
    }
}
