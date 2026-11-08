import Foundation
import RedlampLibrary
import Synchronization

extension ImportWindowModel {
    /// Why Import can't start now, as a sentence; nil when it can.
    var importBlocker: String? {
        if let entry = interrupted.first {
            return entry.state == .rollingBack
                ? "A rollback that was interrupted has to be finished first: Resume finishes it."
                : "An import that was interrupted has to be resumed or rolled back first."
        }
        if phase == .planning || phase == .copying {
            return "An import is running."
        }
        if phase == .adding {
            return "The import is adding its photos to the library."
        }
        if phase == .rollingBack {
            return "An import is being rolled back."
        }
        if let folderError {
            return "The folder template has an error: \(folderError)"
        }
        if let namesError {
            return "The name template has an error: \(namesError)"
        }
        let destination = LibraryService.path(settings.destination)
        if hasDestination, let backup = settings.backup.map(LibraryService.path), backup == destination {
            return "The backup has to be somewhere other than the destination."
        }
        if hasDestination, let source = sources.first(where: { source in
            source.isIncluded && Self.isWithin(destination, LibraryService.path(source.source.url))
        }) {
            return "The destination is on \(source.source.name), which is being imported from."
        }
        if chosen.photos == 0 {
            return sources.isEmpty ? "Insert a card, or add a folder." : "No photos are chosen."
        }
        return nil
    }

    private static func isWithin(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder == "/" ? "/" : folder + "/")
    }

    /// Import: the chosen photos of every source included, planned together and copied, as the type says. Not before
    /// the destination is chosen, which Import asks for first (`ImportWindowController`).
    func startImport() {
        guard hasDestination, importBlocker == nil else { return }
        let included = sources.filter { $0.isIncluded && $0.problem == nil }
        let settings = settings
        let destinationFileSystem = destinationFileSystem
        failure = nil
        outcome = nil
        rollback = nil
        progress = nil
        for index in sources.indices {
            sources[index].progress = nil
            sources[index].outcome = nil
        }
        phase = .planning
        notify(.status)
        notify(.sources)
        let together = ImportSession(
            sources: included.map(\.source), library: library, fileSystem: fileSystem, volumes: volumes,
            makesPreviews: false,
        )
        together.add(included.flatMap(\.session.photos).filter { !copied.contains($0.id) })
        let importer = importer
        importing = Task { [weak self] in
            var made: ImportPlan?
            do {
                let planned = await self?.withPreset(settings) ?? settings
                let plan = try await together.plan(planned, destinationFileSystem: destinationFileSystem)
                try Task.checkCancellation()
                guard let self else { return }
                made = plan
                self.plan = plan
                guard !plan.items.isEmpty else {
                    phase = .finished
                    failure = "Nothing was copied: every photo chosen is in the library or at the destination already."
                    notify(.status)
                    return
                }
                phase = .copying
                notify(.status)
                let latest = ImportLatest<ImportProgress>()
                let interval = Self.progressInterval
                let outcome = try await importer.run(plan) { progress in
                    guard latest.set(progress) else { return }
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: interval)
                        if let progress = latest.take() {
                            self?.progressed(progress)
                        }
                    }
                }
                if let last = latest.take() {
                    progressed(last)
                }
                await finished(outcome, plan: plan)
            } catch {
                await self?.stopped(made, by: error)
            }
            self?.importing = nil
        }
    }

    /// An import or a Resume that threw: before its plan was copied from, or partway, as when the Mac's disk
    /// fills. The journal keeps one stopped partway unfinished, so it's offered for Resume and Roll Back at once,
    /// and the photos it placed are shown as copied.
    private func stopped(_ plan: ImportPlan?, by error: any Error, resuming: Bool = false) async {
        // Read before anything changes, so the window never says it's over without what it copied.
        let entries = await (try? importer.unfinishedEntries()) ?? []
        var placed: [(String, URL)] = []
        if let plan {
            placed = await Self.placed(plan, failed: [], on: destinationFileSystem)
            self.plan = plan
        }
        interrupted = entries
        phase = .finished
        for index in sources.indices {
            sources[index].progress = nil
        }
        copied.formUnion(placed.map(\.0))
        let unfinished = plan.flatMap { plan in interrupted.first { $0.id == plan.id } }
        let reason = Self.reason(error)
        if let plan, unfinished != nil || !placed.isEmpty {
            failure = placed.isEmpty ? "The import stopped before any photo was copied: \(reason)."
                : "The import stopped with \(placed.count) of \(Self.count(plan.items.count, "photo")) copied: "
                + "\(reason)."
        } else if resuming {
            failure = "The interrupted import couldn't be resumed: \(reason)"
        } else {
            failure = error is CancellationError ? "The import was cancelled before anything was copied."
                : "The import couldn't start: \(reason)"
        }
        notify(.status)
        notify(.sources)
        notify(.photos(ids: nil))
    }

    /// An error as the window says it: a system call's in the system's words.
    private static func reason(_ error: any Error) -> String {
        switch error {
        case let error as POSIXError: String(cString: strerror(error.code.rawValue))
        case is CancellationError: "it was cancelled"
        default: String(describing: error)
        }
    }

    /// The photos of `plan` but `failed` at the destination, each with the place of its first file there.
    private static func placed(
        _ plan: ImportPlan, failed: Set<String>, on destinationFileSystem: any LibraryFileSystem,
    ) async -> [(String, URL)] {
        await Task.detached(priority: .userInitiated) {
            plan.items.filter { !failed.contains($0.photo) }.compactMap { item -> (String, URL)? in
                guard let copy = item.photos.first, let target = plan.targets(of: copy).first,
                      destinationFileSystem.exists(target)
                else { return nil }
                return (item.photo, target)
            }
        }.value
    }

    /// Cancel: stops the import once the photos being copied are in place, so nothing is left half copied; or
    /// stops a rollback between batches of photos, for Resume to finish.
    func cancel() {
        importing?.cancel()
    }

    /// Returns once the import running is over.
    func imported() async {
        await importing?.value
    }

    /// The importer's progress; once every photo is copied, the window says they're being added to the library,
    /// and shows those placed as copied, so the next can be chosen meanwhile.
    func progressed(_ progress: ImportProgress) {
        guard phase == .copying || phase == .adding else { return }
        let adding = progress.adding != nil
        if adding, phase == .copying, let plan {
            let destinationFileSystem = destinationFileSystem
            Task { [weak self] in
                let placed = await Self.placed(plan, failed: [], on: destinationFileSystem)
                guard let self, phase == .adding else { return }
                copied.formUnion(placed.map(\.0))
                notify(.status)
                notify(.photos(ids: nil))
            }
        }
        phase = adding ? .adding : .copying
        self.progress = progress
        for index in sources.indices {
            sources[index].progress = progress.sources[sources[index].id]
        }
        notify(.status)
        notify(.sources)
    }

    private func finished(_ outcome: ImportOutcome, plan: ImportPlan) async {
        // Read before anything changes, so the window never says it's over without what it copied.
        let placed = await Self.placed(
            plan, failed: Set(outcome.failures.map(\.photo)), on: destinationFileSystem,
        )
        self.outcome = outcome
        phase = .finished
        preferences.update { $0.counters = plan.counters }
        for index in sources.indices {
            sources[index].progress = nil
            sources[index].outcome = outcome.sources.first { $0.id == sources[index].id }
        }
        copied.formUnion(placed.map(\.0))
        failure = outcome.state == .stopped
            ? "The import was cancelled: the photos copied so far are in place, the others are still where they were; "
            + "Roll Back moves those copied to the Trash."
            : nil
        notify(.status)
        notify(.sources)
        notify(.photos(ids: nil))
        if !placed.isEmpty {
            showInLibrary(placed.map(\.1))
        }
        if preferences.ejectsAfterImport {
            for source in sources where source.isCard && isSafeToErase(source) {
                await eject(source.id)
            }
        }
    }

    /// Resume: finishes the imports a forced quit or an error cut short, copying the rest from their sources,
    /// which have to be there, then shows their photos in Library as an import that ran straight through does;
    /// or finishes a rollback that was stopped or cut short.
    func resume() {
        guard let entry = interrupted.first, importing == nil else { return }
        if entry.state == .rollingBack {
            rollBack(entry.id)
            return
        }
        phase = .copying
        failure = nil
        rollback = nil
        notify(.status)
        let importer = importer
        importing = Task { [weak self] in
            guard let self else { return }
            let latest = ImportLatest<ImportProgress>()
            let interval = Self.progressInterval
            do {
                plan = try? await importer.plan(of: entry.id)
                let outcomes = try await importer.recover { [weak self] progress in
                    guard latest.set(progress) else { return }
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: interval)
                        if let progress = latest.take() {
                            self?.progressed(progress)
                        }
                    }
                }
                if let last = latest.take() {
                    progressed(last)
                }
                interrupted = await (try? importer.unfinishedEntries()) ?? []
                for outcome in outcomes {
                    if let plan = try? await importer.plan(of: outcome.id) {
                        self.plan = plan
                        await finished(outcome, plan: plan)
                    } else {
                        self.outcome = outcome
                    }
                }
                phase = .finished
                let verified = outcomes.reduce(0) { $0 + $1.verified }
                let photos = outcomes.reduce(0) { $0 + $1.photos }
                if !outcomes.contains(where: { $0.state == .stopped }) {
                    failure = verified == photos ? nil
                        : "\(photos - verified) of the interrupted import's photos weren't copied: their card or "
                        + "folder wasn't there, or changed."
                }
            } catch {
                let plan = try? await importer.plan(of: entry.id)
                await stopped(plan, by: error, resuming: true)
            }
            notify(.status)
            importing = nil
        }
    }

    /// The import Roll Back takes back: one a forced quit cut short while it copied, else the import this
    /// window ran when it was cancelled with photos copied, until it's rolled back. A rollback waiting to be
    /// finished is Resume's.
    var rollBackTarget: UUID? {
        if let entry = interrupted.first {
            return entry.state == .rollingBack ? nil : entry.id
        }
        guard let outcome, outcome.state == .stopped, outcome.verified > 0, rollback?.id != outcome.id else {
            return nil
        }
        return outcome.id
    }

    /// Roll Back: takes back the import `rollBackTarget` names, as `Importer.rollBack` does.
    func rollBack() {
        guard let id = rollBackTarget, importing == nil, !isBusy else { return }
        rollBack(id)
    }

    private func rollBack(_ id: UUID) {
        phase = .rollingBack
        failure = nil
        rollbackProgress = nil
        notify(.status)
        let importer = importer
        importing = Task { [weak self] in
            guard let self else { return }
            let latest = ImportLatest<ImportRollback.Progress>()
            let interval = Self.progressInterval
            do {
                let rollback = try await importer.rollBack(id) { [weak self] progress in
                    guard latest.set(progress) else { return }
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: interval)
                        if let progress = latest.take() {
                            self?.rollingBack(progress)
                        }
                    }
                }
                interrupted = await (try? importer.unfinishedEntries()) ?? []
                rolledBack(rollback)
            } catch {
                interrupted = await (try? importer.unfinishedEntries()) ?? []
                phase = .finished
                failure = "The import couldn't be rolled back: \(String(describing: error))"
            }
            notify(.status)
            notify(.sources)
            notify(.photos(ids: nil))
            importing = nil
        }
    }

    func rollingBack(_ progress: ImportRollback.Progress) {
        guard phase == .rollingBack else { return }
        rollbackProgress = progress
        notify(.status)
    }

    /// The photos taken back can be chosen again; the sources no longer say what the import made of them.
    private func rolledBack(_ rollback: ImportRollback) {
        self.rollback = rollback
        rollbackProgress = nil
        phase = .finished
        copied.subtract(rollback.rolledBack)
        if rollback.state == .rolledBack, outcome?.id == rollback.id {
            for index in sources.indices {
                sources[index].outcome = nil
            }
        }
    }

    /// Ejects the card, once its photos are copied or it's left out.
    func eject(_ id: String) async {
        guard let index = sources.firstIndex(where: { $0.id == id }), sources[index].isCard,
              sources[index].source.medium.isEjectable, phase != .copying
        else { return }
        let card = sources[index].source
        do {
            try await ejector(card)
            if let index = sources.firstIndex(where: { $0.id == id }) {
                sources[index].isEjected = true
                sources[index].isIncluded = false
            }
        } catch {
            failure = "\(card.name) couldn't be ejected: \(error.localizedDescription)"
        }
        notify(.sources)
        notify(.status)
    }

    /// Each destination's line while copying and after: the destination and the backup get every
    /// photo at once, and a photo counts once it's verified at both.
    var destinationLines: [String] {
        let roots = [settings.destination] + (settings.backup.map { [$0] } ?? [])
        let verified = progress?.done ?? outcome?.verified
        let total = progress?.photos ?? outcome?.photos
        guard let verified, let total, phase == .copying || phase == .adding || phase == .finished, rollback == nil
        else { return [] }
        return roots.map { "\($0.lastPathComponent): \(verified) of \(Self.count(total, "photo")) verified" }
    }
}

/// The latest of something told often from other threads, taken on the main thread now and then.
final class ImportLatest<Value: Sendable>: Sendable {
    private let state = Mutex<(value: Value?, waiting: Bool)>((nil, false))

    /// Keeps `value`; true when nothing waits to take it yet, so it's to be taken.
    func set(_ value: Value) -> Bool {
        state.withLock { state in
            state.value = value
            defer { state.waiting = true }
            return !state.waiting
        }
    }

    func take() -> Value? {
        state.withLock { state in
            defer { state = (nil, false) }
            return state.value
        }
    }
}
