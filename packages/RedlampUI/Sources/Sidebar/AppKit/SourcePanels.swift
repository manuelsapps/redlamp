import AppKit
import RedlampDesign

/// The Library module's source list (LIB-23, LIB-45), in the Mac's sidebar style: its Library section, above Folders
/// as Lightroom Classic's Catalog panel is, then Folders, Apple Photos once an album is kept in place (LIB-62), and
/// Collections, each open or closed as it was left. Option-click on a section's header leaves it the only one open,
/// and every header's menu opens or closes them all.
@MainActor
enum SourcePanels {
    /// The sections, in their order.
    enum Section: CaseIterable {
        case library, folders, applePhotos, collections

        @MainActor func isExpanded(_ model: EditorModel) -> Bool {
            switch self {
            case .library: model.librarySources.isExpanded(.library)
            case .folders: model.expandedSidebarSections.contains(.folders)
            case .applePhotos: !model.librarySources.isApplePhotosClosed
            case .collections: model.librarySources.isExpanded(.collections)
            }
        }

        @MainActor func setExpanded(_ expanded: Bool, _ model: EditorModel) {
            guard expanded != isExpanded(model) else { return }
            switch self {
            case .library: model.librarySources.toggle(.library)
            case .folders: model.toggleSidebarSection(.folders, solo: false)
            case .applePhotos: model.librarySources.setApplePhotosOpen(expanded)
            case .collections: model.librarySources.toggle(.collections)
            }
        }

        /// Whether it's in the source list: Apple Photos only while an album is kept in place.
        @MainActor func isPresent(_ model: EditorModel) -> Bool {
            self != .applePhotos || model.librarySources.keepsApplePhotos
        }

        /// The sections in the source list now, in their order.
        @MainActor static func present(_ model: EditorModel) -> [Section] {
            allCases.filter { $0.isPresent(model) }
        }

        /// Opens or closes the section; with `solo`, opens it and closes the others, or closes it when it's the only
        /// one open.
        @MainActor func toggle(solo: Bool, _ model: EditorModel) {
            guard solo else { return setExpanded(!isExpanded(model), model) }
            let sections = Section.present(model)
            let alone = sections.allSatisfy { $0.isExpanded(model) == ($0 == self) }
            for section in sections {
                section.setExpanded(!alone && section == self, model)
            }
        }
    }

    /// The four sections, top to bottom.
    static func all(model: EditorModel) -> [NSView] {
        [library(model: model), folders(model: model), applePhotos(model: model), collections(model: model)]
    }

    /// The room a source list leaves under its last row.
    static let columnInsets = NSEdgeInsets(top: 0, left: 0, bottom: 10, right: 0)

    /// The Library section: All Photographs, Previous Import, Marked and Rejected, and Library Health's checks.
    static func library(model: EditorModel) -> SourceListSectionView {
        section(
            .library,
            title: LibrarySources.Panel.library.title,
            first: true,
            model: model,
            list: LibraryOutlineView(model: model),
            identifier: "sources.library",
        )
    }

    /// The Folders section, with a + in its header that adds a folder, or albums of Apple Photos to keep in place
    /// before the Apple Photos section shows (LIB-62); its header's menu has those and Sort Folders Newest First.
    static func folders(model: EditorModel) -> SourceListSectionView {
        let add = SourceListHeaderView.Add(
            help: "Add a Folder or Albums from Apple Photos", identifier: "sources.folders.add",
        ) { button in
            addMenu(model: model).popUp(positioning: nil, at: CGPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
        return section(
            .folders, title: SidebarSection.folders.title, add: add, model: model,
            list: FolderOutlineView(model: model, look: .sourceList), identifier: "sidebar.folders",
            isEmpty: { model.library.roots.isEmpty },
        ) { menu in
            let made = addMenu(model: model)
            let items = made.items
            made.removeAllItems()
            items.forEach(menu.addItem)
            menu.addItem(.separator())
            menu.addItem(SidebarCellView.newestFirstItem(model: model))
        }
    }

    /// Add Folder… and Add Albums from Apple Photos…, Folders' + menu.
    static func addMenu(model: EditorModel) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Add Folder…") { FolderActions.add(model: model) })
        menu.addItem(NSMenuItem(title: addAlbumsTitle) { ApplePhotosActions.open(model: model) })
        return menu
    }

    static let addAlbumsTitle = ShortcutAction.importFromApplePhotos.title

    /// The Apple Photos section (LIB-62), once an album is kept in place: the albums in Photos' folders, with a + in
    /// its header that adds albums.
    static func applePhotos(model: EditorModel) -> SourceListSectionView {
        let add = SourceListHeaderView.Add(help: addAlbumsTitle, identifier: "sidebar.apple-photos.add") { _ in
            ApplePhotosActions.open(model: model)
        }
        let sources = model.librarySources
        return section(
            .applePhotos, title: "Apple Photos", add: add, model: model, list: ApplePhotosOutlineView(model: model),
            identifier: "sidebar.apple-photos",
            commands: { menu in
                menu.addItem(NSMenuItem(title: addAlbumsTitle) { ApplePhotosActions.open(model: model) })
            },
            isPresent: { sources.keepsApplePhotos },
        )
    }

    /// The collection list, with a + in its header that makes a collection, a smart collection or a set.
    static func collections(model: EditorModel) -> SourceListSectionView {
        let add = SourceListHeaderView.Add(
            help: "New Collection, Smart Collection or Collection Set", identifier: "sources.collections.add",
        ) { button in
            newMenu(model: model).popUp(positioning: nil, at: CGPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
        let sources = model.librarySources
        return section(
            .collections, title: LibrarySources.Panel.collections.title, add: add, model: model,
            list: CollectionOutlineView(model: model), identifier: "sources.collections",
            isEmpty: {
                _ = sources.rows
                return sources.collections(inside: nil).isEmpty
            },
        ) { menu in
            let made = newMenu(model: model)
            let items = made.items
            made.removeAllItems()
            items.forEach(menu.addItem)
        }
    }

    /// New Collection…, New Smart Collection… and New Collection Set…, as their actions are in the File menu.
    static func newMenu(model: EditorModel) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for action in [ShortcutAction.newCollection, .newSmartCollection, .newCollectionSet] {
            let item = NSMenuItem(title: action.title) { model.perform(action) }
            item.isEnabled = model.library.service?.isReady == true
            menu.addItem(item)
        }
        return menu
    }

    private static func section(
        _ section: Section, title: String, first: Bool = false, add: SourceListHeaderView.Add? = nil,
        model: EditorModel, list: NSView, identifier: String, isEmpty: @escaping @MainActor () -> Bool = { false },
        commands: @escaping @MainActor (NSMenu) -> Void = { _ in },
        isPresent: @escaping @MainActor () -> Bool = { true },
    ) -> SourceListSectionView {
        let view = SourceListSectionView(
            title: title, first: first, add: add, list: list,
            actions: SourceListSectionView.Actions(
                isExpanded: { section.isExpanded(model) },
                toggle: { solo in section.toggle(solo: solo, model) },
                isEmpty: isEmpty,
                isPresent: isPresent,
            ),
        )
        view.identify(as: identifier)
        view.header.menuProvider = {
            let menu = NSMenu()
            menu.autoenablesItems = false
            commands(menu)
            if !menu.items.isEmpty {
                menu.addItem(.separator())
            }
            menu.addItem(NSMenuItem(title: "Show All Sections") {
                Section.present(model).forEach { $0.setExpanded(true, model) }
            })
            menu.addItem(NSMenuItem(title: "Hide All Sections") {
                Section.present(model).forEach { $0.setExpanded(false, model) }
            })
            return menu
        }
        return view
    }
}
