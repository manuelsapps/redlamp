import Foundation
import Observation
import RedlampDocument
import RedlampLibrary

/// What the import window keeps from one import to the next (LIB-27), in the app's defaults: the
/// destination and the backup with their bookmarks, the folder and name templates and their texts,
/// raw only, the keywords, the named counters an import moves on, and what the app does around a card:
/// the import window shown when one is inserted (on, as in Lightroom Classic) and the cards ejected
/// after importing (off).
@MainActor
@Observable
public final class ImportPreferences {
    public static let shared = ImportPreferences(defaults: .standard)
    static let settingsKey = "import.settings"
    static let destinationChosenKey = "import.destinationChosen"
    static let bookmarksKey = "import.bookmarks"

    /// Where they're kept; nil for a copy that keeps nothing.
    @ObservationIgnored private let defaults: UserDefaults?
    public private(set) var settings: ImportSettings
    /// The destination was chosen, in its panel or by an earlier version, which kept it with the
    /// settings. Until it is, the first import asks for it (ARC-17): the App Sandbox reaches only the
    /// folders people choose, and the destination isn't Pictures by itself.
    public private(set) var hasDestination: Bool
    /// The destination's and the backup's, which reach them in the App Sandbox.
    @ObservationIgnored private(set) var bookmarks: FolderBookmarks

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.settingsKey)
            .flatMap { try? JSONDecoder().decode(ImportSettings.self, from: $0) }
        settings = saved ?? Self.standard
        hasDestination = defaults.object(forKey: Self.destinationChosenKey) as? Bool ?? (saved != nil)
        bookmarks = defaults.data(forKey: Self.bookmarksKey)
            .flatMap { try? JSONDecoder().decode(FolderBookmarks.self, from: $0) } ?? FolderBookmarks()
    }

    /// `preferences` as they are, in a copy that keeps nothing it's changed to: Copy to Folder's for photos kept in
    /// Apple Photos dropped on a folder (LIB-63), which copies them there without changing Import's destination.
    init(copying preferences: ImportPreferences) {
        defaults = nil
        settings = preferences.settings
        hasDestination = preferences.hasDestination
        bookmarks = preferences.bookmarks
    }

    /// The first import's: a folder a day in a folder a year, the camera's names. Its destination,
    /// Pictures, is only where the destination's panel opens until one is chosen.
    static var standard: ImportSettings {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Pictures", directoryHint: .isDirectory)
        return ImportSettings(destination: pictures, startsWhenCardInserted: true)
    }

    /// The import window opens on a card as it's inserted.
    public var showsWindowWhenCardInserted: Bool {
        get { settings.startsWhenCardInserted }
        set { update { $0.startsWhenCardInserted = newValue } }
    }

    /// Cards are ejected once an import is over and they can be erased: every photo on them is in the library.
    public var ejectsAfterImport: Bool {
        get { settings.ejectsWhenDone }
        set { update { $0.ejectsWhenDone = newValue } }
    }

    func update(_ change: (inout ImportSettings) -> Void) {
        var changed = settings
        change(&changed)
        guard changed != settings else { return }
        settings = changed
        if let data = try? JSONEncoder().encode(changed) {
            defaults?.set(data, forKey: Self.settingsKey)
        }
        keepBookmarks()
    }

    /// The destination, chosen in its panel at `url`: its bookmark is made while the panel's access lasts.
    func chooseDestination(_ url: URL) {
        update { $0.destination = URL(fileURLWithPath: LibraryService.path(url), isDirectory: true) }
        hasDestination = true
        defaults?.set(true, forKey: Self.destinationChosenKey)
        remember(url)
    }

    /// The backup, chosen in its panel at `url`; nil for none.
    func chooseBackup(_ url: URL?) {
        update { settings in
            settings.backup = url.map { URL(fileURLWithPath: LibraryService.path($0), isDirectory: true) }
        }
        if let url {
            remember(url)
        }
    }

    /// No destination chosen, as on a Mac Redlamp hasn't imported on: for the regression suite.
    func forgetDestination() {
        hasDestination = false
        defaults?.set(false, forKey: Self.destinationChosenKey)
        keepBookmarks()
    }

    /// The folders that keep bookmarks: the destination once it's chosen, and the backup.
    var folders: [String] {
        (hasDestination ? [settings.destination.path] : []) + (settings.backup.map { [$0.path] } ?? [])
    }

    /// Makes the bookmarks of the destination and the backup an earlier version chose, which it didn't keep
    /// (ARC-17), at launch: off the main thread, as the folders may be on a disk that's slow to answer.
    public func bookmarkRemembered() async {
        let lacking = bookmarks.lacking(folders)
        guard !lacking.isEmpty else { return keepBookmarks() }
        let made = await Task.detached(priority: .utility) { FolderBookmarks.make(for: lacking) }.value
        keepBookmarks(adding: made)
    }

    private func remember(_ url: URL) {
        if bookmarks.remember(url) {
            saveBookmarks()
        }
        keepBookmarks()
    }

    private func keepBookmarks(adding made: [String: Data] = [:]) {
        if bookmarks.keep(folders, adding: made) {
            saveBookmarks()
        }
    }

    private func saveBookmarks() {
        defaults?.set(try? JSONEncoder().encode(bookmarks), forKey: Self.bookmarksKey)
    }
}
