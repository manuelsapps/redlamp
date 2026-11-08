import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary
@_spi(Harness) @testable import RedlampUI

/// Roll Back and Resume in the import window (LIB-27). The Trash is the Mac's own: each test takes out of it what
/// it put there.
@MainActor
struct ImportWindowRollbackTests {
    private static func emptyTrash(_ rollback: ImportRollback?) {
        for file in rollback?.trashed ?? [] {
            try? FileManager.default.removeItem(atPath: file.to)
        }
    }

    /// A window's import of `count` photos that a forced quit stops once two are done, and the window closed.
    private static func interrupted(_ fixture: ImportWindowFixture, count: Int) async throws {
        let model = fixture.model()
        try await model.addFolder(fixture.folder("Card", count: count))
        await model.browsed()
        fixture.settle(model)
        model.importer.interruption.withLock { $0 = .afterPhotos(2) }
        model.startImport()
        await model.imported()
        model.close()
    }

    /// A window's import of 24 photos from a slow card, which the Mac's disk filling up stops once two are done.
    private static func stoppedByFullDisk(_ fixture: ImportWindowFixture) async throws -> ImportWindowModel {
        // 4 MB a second, one read at a time: the photos copying when the disk fills are done long before the last.
        let slow = SimulatedFileSystem(profile: VolumeProfile(
            name: "slow card", latency: .milliseconds(5), bandwidth: 4_000_000, maxInFlight: 1, isLocal: true,
            isInternal: false,
        ))
        let model = fixture.model(fileSystem: slow)
        try await model.addFolder(fixture.folder("Card", count: 24, padding: 400_000))
        await model.browsed()
        fixture.settle(model)
        model.importer.interruption.withLock { $0 = .diskFull(afterPhotos: 2) }
        model.startImport()
        await model.imported()
        return model
    }

    @Test func `an import the disk fills partway offers Resume and Roll Back at once, and Resume finishes it`(
    ) async throws {
        let fixture = try await ImportWindowFixture.make()
        defer { fixture.remove() }
        let model = try await Self.stoppedByFullDisk(fixture)
        let copied = ImportWindowFixture.files(in: fixture.backup).count
        try #require(copied >= 2 && copied < 24)
        let entry = try #require(model.interrupted.first)
        #expect(entry.id == model.plan?.id && model.phase == .finished && model.outcome == nil)
        #expect(model.rollBackTarget == entry.id)
        #expect(model.importBlocker == "An import that was interrupted has to be resumed or rolled back first.")
        #expect(model.summary == "The import stopped with \(copied) of 24 photos copied: No space left on device. "
            + "Resume copies the rest from their cards or folders, which have to be there; Roll Back moves those "
            + "copied to the Trash.")
        #expect(model.copied.count == copied && model.chosen.photos == 24 - copied, "the photos copied shown so")
        #expect(model.sources.allSatisfy { $0.progress == nil } && model.detail(of: model.sources[0]) == "24 photos")
        #expect(ImportWindowFixture.leftovers(in: fixture.destination).isEmpty, "nothing half copied")

        model.resume()
        await model.imported()
        #expect(model.interrupted.isEmpty && model.failure == nil)
        #expect(model.outcome?.state == .finished && model.outcome?.verified == 24)
        #expect(ImportWindowFixture.files(in: fixture.backup).count == 24)
        #expect(ImportWindowFixture.leftovers(in: fixture.destination).isEmpty)
        #expect(model.chosen.photos == 0 && model.importBlocker == "No photos are chosen.")
        #expect(model.detail(of: model.sources[0]) == "Safe to erase: every photo on it is in the library.")
    }

    @Test func `an import the disk fills partway can be rolled back at once, its photos chosen again`() async throws {
        let fixture = try await ImportWindowFixture.make()
        defer { fixture.remove() }
        let model = try await Self.stoppedByFullDisk(fixture)
        let copied = ImportWindowFixture.files(in: fixture.backup).count
        try #require(copied >= 2 && copied < 24 && model.rollBackTarget != nil)
        model.rollBack()
        await model.imported()
        let rollback = try #require(model.rollback)
        defer { Self.emptyTrash(rollback) }
        #expect(rollback.state == .rolledBack && rollback.rolledBack.count == copied)
        #expect(model.interrupted.isEmpty && model.rollBackTarget == nil && model.importBlocker == nil)
        #expect(model.chosen.photos == 24 && model.copied.isEmpty)
        #expect(model.summary.hasPrefix("Rolled back: the copies of \(ImportWindowModel.count(copied, "photo"))"))
    }

    @Test func `an Import that finds an import cut short it hadn't heard of offers that for Resume`() async throws {
        let fixture = try await ImportWindowFixture.make()
        defer { fixture.remove() }
        try await Self.interrupted(fixture, count: 6)
        // A window that hasn't read the journal yet.
        let next = fixture.model()
        try await next.addFolder(fixture.folder("Second card", count: 2, from: 20))
        await next.browsed()
        fixture.settle(next)
        #expect(next.importBlocker == nil)
        next.startImport()
        await next.imported()
        let entry = try #require(next.interrupted.first)
        #expect(next.rollBackTarget == entry.id && entry.id != next.plan?.id)
        #expect(next.failure?.hasPrefix("The import couldn't start: import \(entry.id.uuidString)") == true)
        #expect(next.summary.hasPrefix("\(entry.title) was interrupted with"))
        #expect(next.importBlocker == "An import that was interrupted has to be resumed or rolled back first.")
        next.resume()
        await next.imported()
        #expect(next.interrupted.isEmpty && next.outcome?.verified == 6)
    }

    @Test func `Roll Back after Cancel moves the copies to the Trash, and their photos can be chosen again`(
    ) async throws {
        let fixture = try await ImportWindowFixture.make()
        defer { fixture.remove() }
        // A slow card: 4 MB a second, one read at a time, so its 24 photos take seconds to copy.
        let slow = SimulatedFileSystem(profile: VolumeProfile(
            name: "slow card", latency: .milliseconds(5), bandwidth: 4_000_000, maxInFlight: 1, isLocal: true,
            isInternal: false,
        ))
        let model = fixture.model(fileSystem: slow)
        try await model.addFolder(fixture.folder("Card", count: 24, padding: 400_000))
        await model.browsed()
        fixture.settle(model)
        model.startImport()
        try await waitUntil("the first photo copied") { model.progress != nil }
        model.cancel()
        await model.imported()
        let stopped = try #require(model.outcome)
        try #require(stopped.state == .stopped && stopped.verified >= 1)
        #expect(model.rollBackTarget == stopped.id)
        #expect(model.failure?.hasSuffix("Roll Back moves those copied to the Trash.") == true)

        model.rollBack()
        await model.imported()
        let rollback = try #require(model.rollback)
        defer { Self.emptyTrash(rollback) }
        #expect(rollback.state == .rolledBack && rollback.rolledBack.count == stopped.verified)
        for root in [fixture.destination, fixture.backup] {
            #expect(ImportWindowFixture.files(in: root).filter { $0.hasSuffix(".JPG") }.isEmpty, "\(root.path)")
        }
        #expect(model.phase == .finished && model.rollBackTarget == nil && model.interrupted.isEmpty)
        #expect(model.summary.hasPrefix(
            "Rolled back: the copies of \(ImportWindowModel.count(stopped.verified, "photo")) are in the Trash",
        ))
        #expect(model.destinationLines.isEmpty)
        #expect(model.chosen.photos == 24, "every photo can be chosen again")
        #expect(model.sources.allSatisfy { $0.outcome == nil })
        #expect(model.importBlocker == nil)
    }

    @Test func `an import a forced quit cut short can be rolled back rather than resumed`() async throws {
        let fixture = try await ImportWindowFixture.make()
        defer { fixture.remove() }
        try await Self.interrupted(fixture, count: 12)
        let copied = ImportWindowFixture.files(in: fixture.backup).count
        try #require(copied >= 2)

        // The next launch's window.
        let next = fixture.model()
        next.start()
        try await waitUntil("the interrupted import") { !next.interrupted.isEmpty }
        let entry = try #require(next.interrupted.first)
        #expect(next.rollBackTarget == entry.id)
        #expect(next.importBlocker == "An import that was interrupted has to be resumed or rolled back first.")
        #expect(next.summary.hasSuffix("Roll Back moves those copied to the Trash."))
        next.rollBack()
        await next.imported()
        let rollback = try #require(next.rollback)
        defer { Self.emptyTrash(rollback) }
        #expect(rollback.state == .rolledBack && rollback.rolledBack.count == copied)
        #expect(next.interrupted.isEmpty && next.rollBackTarget == nil && next.failure == nil)
        // The destination and the backup were made by the import, and are left empty: they go too.
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.backup.path))
        #expect(next.importBlocker == "Insert a card, or add a folder.")
    }

    @Test func `a rollback a forced quit cut short waits for Resume, which finishes it`() async throws {
        let fixture = try await ImportWindowFixture.make()
        defer { fixture.remove() }
        try await Self.interrupted(fixture, count: 6)
        let next = fixture.model()
        next.start()
        try await waitUntil("the interrupted import") { !next.interrupted.isEmpty }
        next.importer.interruption.withLock { $0 = .afterTakingBack(1) }
        next.rollBack()
        await next.imported()
        next.close()

        let last = fixture.model()
        last.start()
        try await waitUntil("the interrupted rollback") { last.interrupted.first?.state == .rollingBack }
        #expect(last.rollBackTarget == nil)
        #expect(last.importBlocker == "A rollback that was interrupted has to be finished first: Resume finishes it.")
        #expect(last.summary.contains("was being rolled back when it was interrupted"))
        last.resume()
        await last.imported()
        let rollback = try #require(last.rollback)
        defer { Self.emptyTrash(rollback) }
        #expect(rollback.state == .rolledBack && rollback.recoveredFrom == 0)
        #expect(last.interrupted.isEmpty && last.failure == nil)
        for root in [fixture.destination, fixture.backup] {
            #expect(ImportWindowFixture.files(in: root).isEmpty, "\(root.path)")
        }
        #expect(rollback.trashed.allSatisfy { FileManager.default.fileExists(atPath: $0.to) })
    }

    @Test func `after Resume, Library shows the resumed import's photos selected, as after an import straight through`(
    ) async throws {
        let fixture = try await ImportWindowFixture.make()
        defer { fixture.remove() }
        try await Self.interrupted(fixture, count: 6)
        let next = fixture.model()
        let editor = EditorModel(engine: StubEngine(), library: FolderLibrary(defaults: fixture.defaults))
        next.showInLibrary = { editor.showImported($0) }
        next.start()
        try await waitUntil("the interrupted import") { !next.interrupted.isEmpty }
        next.resume()
        await next.imported()
        #expect(next.outcome?.state == .finished && next.outcome?.verified == 6 && next.failure == nil)
        let folder = fixture.destination.appending(path: "2026/2026-10-05", directoryHint: .isDirectory)
        try await waitUntil("the photos selected in Library") { editor.selectedPhotos.count == 6 }
        #expect(editor.module == .library && editor.libraryView == .grid)
        #expect(editor.folder.map(LibraryService.path) == LibraryService.path(folder))
        #expect(Set(editor.selectedPhotos.map { $0.deletingLastPathComponent().lastPathComponent }) == ["2026-10-05"])
    }

    @Test func `a shown Previous Import follows an import Resume finishes, its photos selected`() async throws {
        let (sandbox, model, second) = try await PreviousImportTests.library()
        defer { sandbox.remove() }
        let core = try #require(sandbox.service?.core)
        let library = ImportLibrary(
            paths: core.paths, index: core.index, store: core.store, indexer: core.indexer, live: core.live,
        )
        let session = try ImportSession(sources: [ImportSource.at(second)], library: library, makesPreviews: false)
        let plan = try await session.plan(ImportSettings(
            destination: sandbox.folder("Imported"),
            folders: NamingTemplate(parsing: ""),
        ))
        let importer = session.importer()
        importer.interruption.withLock { $0 = .afterPhotos(1) }
        await #expect(throws: Importer.ForcedQuit.self) { try await importer.run(plan) }

        let suite = "import-rollback-tests-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let window = try ImportWindowModel(
            library: library, preferences: ImportPreferences(defaults: #require(UserDefaults(suiteName: suite))),
            cards: ImportCards { _ in nil },
        )
        window.showInLibrary = { model.showImported($0) }
        window.start()
        try await waitUntil("the interrupted import") { !window.interrupted.isEmpty }
        window.resume()
        await window.imported()
        try await sandbox.eventually(seconds: 20) {
            !model.librarySources.isListing && model.items.map(\.name) == ["IMG_0003.JPG"]
        }
        #expect(model.librarySources.shown == .previousImport, "Previous Import stays shown")
        #expect(model.selection?.lastPathComponent == "IMG_0003.JPG")
        window.close()
    }
}
