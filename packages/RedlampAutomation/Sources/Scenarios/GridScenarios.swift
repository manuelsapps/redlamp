#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import Carbon.HIToolbox
    import RedlampCanvas
    import RedlampEngineAPI
    @_spi(Harness) import RedlampUI

    extension RunningApp {
        /// The Library grid on screen and taking the keyboard, with its cells: the photos' names in the folder's order,
        /// as Library's culling follows it.
        @discardableResult
        func showGrid() throws -> [String] {
            try openWorking()
            let names = try photoNames()
            try expect(names.count >= 6, "The folder has \(names.count) photos")
            try main { model in model.select(model.items[0].url) }
            try settle()
            try press(.gridView)
            try wait("the grid to take the keyboard") { _ in
                Views.editorWindow?.firstResponder.map { "\(Swift.type(of: $0))" } == "LibraryGridContentView"
            }
            _ = try gridNames()
            // Laid out for the size and style the scenario before left.
            try settle()
            return names
        }

        /// The photos in the grid's order once each has a cell of its own: an open stack's photos follow its top,
        /// which needn't come first in the folder (the JPEG of a pair, ahead of its HEIC). Stacks found after
        /// `photoNames` opened them can start closed, so they're opened again until every photo has its cell.
        func gridNames() throws -> [String] {
            // Listed from the disk first, the folder has no stacks until the library shows it and finds them, and an
            // open pair then shows its JPEG first, in the cell its other photo had.
            try wait("the folder shown from the library", timeout: 90) { $0.library.isShownFromLibrary }
            try? wait("its stacks found", timeout: 10) { $0.gridStacks.list != nil }
            try wait("a cell in the grid for every photo", timeout: 30) { model in
                model.gridStacks.openAll()
                guard let window = Views.editorWindow, !model.items.isEmpty else { return false }
                return model.items.allSatisfy { Views.find("grid.\($0.url.lastPathComponent)", in: window) != nil }
            }
            return try main { model in
                model.gridStacks.list.map { list in
                    list.compactMap { model.library.url(ofPhoto: $0)?.lastPathComponent }
                } ?? model.items.map(\.url.lastPathComponent)
            }
        }

        /// What a click at `point` (window points) reaches, for a failure's message.
        func hitView(at point: NSPoint) throws -> String {
            try main { _ in
                let view = Views.editorWindow?.contentView?.superview?.hitTest(point)
                return view.map { "\(Swift.type(of: $0)) \($0.accessibilityIdentifier())" } ?? "nothing"
            }
        }

        /// Drags from `start` to `end` (window points) through the view under `start`, as the mouse does
        /// in a window that may not be key.
        func dragView(from start: NSPoint, to end: NSPoint, modifiers: NSEvent.ModifierFlags = []) throws {
            let steps = 6
            for step in 0 ... steps + 1 {
                try main { _ in
                    guard let window = Views.editorWindow,
                          let view = window.contentView?.superview?.hitTest(start) else {
                        throw ScenarioFailure("Nothing to drag at \(start)")
                    }
                    let t = CGFloat(min(step, steps)) / CGFloat(steps)
                    let location = NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                    let type: NSEvent.EventType = step == 0 ? .leftMouseDown : step > steps ? .leftMouseUp
                        : .leftMouseDragged
                    guard let event = NSEvent.mouseEvent(
                        with: type, location: location, modifierFlags: modifiers,
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1,
                    ) else { return }
                    switch type {
                    case .leftMouseDown: view.mouseDown(with: event)
                    case .leftMouseDragged: view.mouseDragged(with: event)
                    default: view.mouseUp(with: event)
                    }
                }
                pause(0.02)
            }
            pause(0.05)
        }

        /// Chooses the item titled `title` (or "`title`    key") in the context menu of the view carrying
        /// `identifier`, at `point` (window points), as a right-click there opens it.
        func chooseInContextMenu(_ title: String, at point: NSPoint, submenu: String? = nil) throws {
            try main { _ in
                guard let window = Views.editorWindow, let view = window.contentView?.superview?.hitTest(point),
                      let event = NSEvent.mouseEvent(
                          with: .rightMouseDown, location: point, modifierFlags: [],
                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                          context: nil, eventNumber: 0, clickCount: 1, pressure: 1,
                      ),
                      var menu = view.menu(for: event)
                else { throw ScenarioFailure("No context menu at \(point)") }
                if let submenu {
                    guard let inner = menu.items.first(where: { $0.title == submenu })?.submenu else {
                        throw ScenarioFailure("The context menu has no \(submenu)")
                    }
                    menu = inner
                }
                guard let index = menu.items
                    .firstIndex(where: { $0.title == title || $0.title.hasPrefix("\(title)    ") })
                else { throw ScenarioFailure("The context menu has no \(title): \(menu.items.map(\.title))") }
                guard menu.items[index].isEnabled else { throw ScenarioFailure("\(title) is disabled") }
                menu.performActionForItem(at: index)
                view.didCloseMenu(menu, with: nil)
            }
            pause(0.05)
        }
    }

    enum GridScenarios {
        static let all: [Scenario] = [sizes, styles, selection, loupe, loupeWheel, sourceViews]

        @MainActor private static func size(_ model: EditorModel) -> Double {
            model.libraryViews.thumbnailSize
        }

        static let sizes = Scenario(
            "library.grid-sizes",
            "= and - in the grid, the View menu, the toolbar's slider and the palette size the thumbnails, "
                + "and the cells follow",
            claims: [.action(.largerThumbnails), .action(.smallerThumbnails), .feature("library.grid")],
        ) { app in
            let names = try app.showGrid()
            try app.main { $0.setThumbnailSize(GridSize.standard) }
            try app.press(.largerThumbnails)
            try app.wait("= to grow the thumbnails") { size($0) > GridSize.standard }
            app.covered(.action(.largerThumbnails), via: .key)
            try app.press(.smallerThumbnails)
            try app.wait("- to shrink them back") { size($0) == GridSize.standard }
            app.covered(.action(.smallerThumbnails), via: .key)
            try app.choose(.largerThumbnails)
            try app.choose(.smallerThumbnails)
            try app.wait("the menu's sizes") { size($0) == GridSize.standard }
            let slider = try app.frame(of: .identifier("library.toolbar.size"))
            try app.dragView(
                from: NSPoint(x: slider.midX, y: slider.midY), to: NSPoint(x: slider.maxX - 2, y: slider.midY),
            )
            try app.wait("the slider to make them as large as they go") { size($0) > 390 }
            try app.wait("the cells to follow") { _ in
                Views.editorWindow.flatMap { Views.find("grid.\(names[0])", in: $0) }.map { $0.width > 390 } == true
            }
            app.covered(.feature("library.grid"), via: .mouse)
            try app.runFromPalette(.smallerThumbnails)
            try app.wait("the palette's size") { size($0) < 390 }
            try app.main { $0.setThumbnailSize(GridSize.standard) }
            try app.backToDevelop()
        }

        static let styles = Scenario(
            "library.grid-styles",
            "J, the View menu's Grid View Style, the toolbar and the palette cycle the cell styles: compact, "
                + "expanded with the photo's name, date and settings, and thumbnails only",
            claims: [.action(.cycleGridStyle), .feature("library.grid")],
        ) { app in
            let names = try app.showGrid()
            try app.main { $0.setCellStyle(.compact) }
            let compact = try app.frame(of: .identifier("grid.\(names[0])"))
            try app.press(.cycleGridStyle)
            try app.wait("J: expanded cells") { $0.libraryViews.cellStyle == .expanded }
            try app.wait("taller cells") { _ in
                (Views.editorWindow.flatMap { Views.find("grid.\(names[0])", in: $0) }?.height ?? 0) > compact.height
            }
            try app.choose(.cycleGridStyle)
            try app.wait("the menu: thumbnails only") { $0.libraryViews.cellStyle == .none }
            try app.clickView("library.toolbar.compact")
            try app.wait("the toolbar: compact cells") { $0.libraryViews.cellStyle == .compact }
            app.covered(.feature("library.grid"), via: .mouse)
            try app.runFromPalette(.cycleGridStyle)
            try app.wait("the palette: expanded cells") { $0.libraryViews.cellStyle == .expanded }
            try app.main { $0.setCellStyle(.compact) }
            try app.backToDevelop()
        }

        static let selection = Scenario(
            "library.grid-selection",
            "A rubber band selects the photos it meets, with ⇧ adding to them; the context menu shows them in "
                + "Finder and opens one in the loupe; ⌘R shows them from the Photo menu",
            claims: [.action(.showInFinder), .feature("library.grid"), .feature("library.filmstrip")],
        ) { app in
            // By the cells the band meets, each with its photos: a closed stack's cell selects all of them.
            try app.showGrid()
            let cells = try app.gridCells()
            try app.expect(cells.count >= 5, "The grid has \(cells.count) cells")
            let first = try app.frame(of: .identifier("grid.\(cells[0][0])"))
            let third = try app.frame(of: .identifier("grid.\(cells[2][0])"))
            let start = NSPoint(x: first.minX - 3, y: first.maxY + 3)
            try app.dragView(from: start, to: NSPoint(x: third.midX, y: third.midY))
            var state = try app.selectionState()
            let reached = try app.hitView(at: start)
            let banded = Set(cells[0 ... 2].joined())
            try app.expect(
                Set(state.photos) == banded && state.active == cells[0][0],
                "The band from \(start) (\(reached), the first cell at \(first)) over \(Array(cells[0 ... 2])) gave \(state)",
            )
            let fifth = try app.frame(of: .identifier("grid.\(cells[4][0])"))
            try app.dragView(
                from: NSPoint(x: fifth.minX - 3, y: fifth.maxY + 3), to: NSPoint(x: fifth.midX, y: fifth.midY),
                modifiers: .shift,
            )
            state = try app.selectionState()
            try app.expect(Set(state.photos) == banded.union(cells[4]), "⇧ with the band gave \(state)")
            app.covered(.feature("library.filmstrip"), via: .mouse)

            try app.main { _ in Revealed.photos = [] }
            try app.main { $0.libraryViews.revealInFinder = { Revealed.photos.append(contentsOf: $0) } }
            defer { try? app.main { $0.libraryViews.revealInFinder = Revealed.finder } }
            try app.chooseInContextMenu("Show in Finder", at: NSPoint(x: third.midX, y: third.midY))
            let shown = try app.main { _ in Revealed.photos.map(\.lastPathComponent) }
            try app.expect(
                Set(shown) == Set(state.photos),
                "Show in Finder showed \(shown) where \(state.photos) are selected",
            )
            app.covered(.action(.showInFinder), via: .mouse)
            try app.main { _ in Revealed.photos = [] }
            var greyed: String?
            do {
                try app.choose(.showInFinder)
                try app.expect(try app.main { _ in Revealed.photos.count } == state.photos.count, "⌘R's menu item")
            } catch let failure as ScenarioFailure where failure.message.contains("is disabled in the menu") {
                greyed = failure.message
            }

            try app.chooseInContextMenu("Open in Loupe", at: NSPoint(x: third.midX, y: third.midY))
            try app.wait("the loupe on \(cells[2][0])") { $0.libraryView == .loupe }
            try app.expect(try app.selectionState().active == cells[2][0], "The loupe shows another photo")
            app.covered(.feature("library.grid"), via: .mouse)
            try app.press(.gridView)
            try app.wait("the grid") { $0.libraryView == .grid }
            try app.chooseInContextMenu(
                "Expanded",
                at: NSPoint(x: first.minX - 3, y: first.maxY + 3),
                submenu: "Grid View Style",
            )
            try app.wait("the background menu's style") { $0.libraryViews.cellStyle == .expanded }
            try app.main { model in
                model.setCellStyle(.compact)
                model.deselectOtherPhotos()
            }
            try app.backToDevelop()
            if let greyed {
                throw ScenarioSkip(
                    knownIssue: "UX-48",
                    "Photo › Show in Finder was greyed in the menu bar; the rest passed: \(greyed)",
                )
            }
        }

        static let loupe = Scenario(
            "library.loupe-zoom",
            "The loupe zooms to 1:1 and fits again by Z, Space, a click and its toolbar, showing the photo's name",
            claims: [.action(.toggleZoom), .feature("library.loupe")],
        ) { app in
            let names = try app.showGrid()
            try app.press(.loupeView)
            try app.wait("the loupe") { $0.libraryView == .loupe && $0.libraryViews.loupeZoom == .fit }
            try app.wait("the loupe's preview", timeout: 20) { model in
                model.selection.flatMap(model.previews.cached) != nil
            }
            try app.press(.toggleZoom)
            try app.wait("Z: 1:1") { $0.libraryViews.loupeZoom == .actual }
            try app.clickView("library.loupe")
            try app.wait("a click: fit") { $0.libraryViews.loupeZoom == .fit }
            app.covered(.feature("library.loupe"), via: .mouse)
            try app.press(KeyCombo(.space))
            try app.wait("Space: 1:1") { $0.libraryViews.loupeZoom == .actual }
            let fit = try app.frame(of: .identifier("library.toolbar.fit"))
            try app.clickView("library.toolbar.fit")
            let reached = try app.hitView(at: NSPoint(x: fit.midX, y: fit.midY))
            try app
                .wait("the toolbar's Fit at \(fit), reaching \(reached), to fit") { $0.libraryViews.loupeZoom == .fit }
            try app.expect(
                try app.main { _ in
                    Views.editorWindow.flatMap { window in
                        Views.all(NSView.self, in: window.contentView?.superview ?? NSView())
                            .first { $0.accessibilityIdentifier() == "library.loupe" }?.accessibilityLabel()
                    }
                } == names[0], "The loupe doesn't name its photo",
            )
            try app.press(KeyCombo(.escape))
            try app.wait("Esc: the grid") { $0.libraryView == .grid }
            try app.backToDevelop()
        }

        /// J10-2139: the wheel browses the loupe as Lightroom's does.
        static let loupeWheel = Scenario(
            "library.loupe-wheel",
            "In the loupe at Fit the mouse wheel steps a photo a notch, towards you the next and away the one before; "
                + "at 1:1 it doesn't browse",
            claims: [.feature("library.loupe")],
        ) { app in
            _ = try app.showGrid()
            try app.press(.loupeView)
            try app.wait("the loupe at Fit") { $0.libraryView == .loupe && $0.libraryViews.loupeZoom == .fit }
            // The driver hands the wheel to the view it's over, past the app's monitors: Develop's canvas, under the
            // Library, mustn't be the one to take it in the app.
            let canvasTakes = {
                try app.main { _ in
                    Views.editorWindow.flatMap { window in
                        Views.all(CanvasMetalView.self, in: window.contentView?.superview ?? NSView()).first
                    }?.forwardsCoveredEvents
                }
            }
            try app.expect(try canvasTakes() == false, "Develop's canvas takes the loupe's scrolls")
            let shown = { try app.main { $0.selection?.lastPathComponent } }
            // The wheel goes the way ← and → do: towards you the next photo, away the one before.
            let first = try shown()
            try app.turnWheel(.identifier("library.loupe"), notches: -1)
            try app.wait("a notch towards you to move on") { $0.selection?.lastPathComponent != first }
            let second = try shown()
            try app.press(.nextPhoto)
            try app.wait("→ to move on") { $0.selection?.lastPathComponent != second }
            try app.turnWheel(.identifier("library.loupe"), notches: 1)
            try app.wait("a notch away: \(String(describing: second))") { $0.selection?.lastPathComponent == second }
            try app.press(.previousPhoto)
            try app.wait("←: \(String(describing: first))") { $0.selection?.lastPathComponent == first }
            app.covered(.feature("library.loupe"), via: .mouse)
            try app.press(.toggleZoom)
            try app.wait("Z: 1:1") { $0.libraryViews.loupeZoom == .actual }
            try app.turnWheel(.identifier("library.loupe"), notches: -1)
            try app.settle()
            try app.expect(try shown() == first, "The wheel browsed the loupe at 1:1")
            try app.press(.toggleZoom)
            try app.wait("Z: Fit") { $0.libraryViews.loupeZoom == .fit }
            try app.press(KeyCombo(.escape))
            try app.wait("Esc: the grid") { $0.libraryView == .grid }
            try app.backToDevelop()
            try app.wait("Develop's canvas taking scrolls over its tools again") { _ in (try? canvasTakes()) == true }
        }

        static let sourceViews = Scenario(
            "library.source-views",
            "Each source keeps its thumbnail size, cell style and selection: the folder with and without its "
                + "subfolders",
            claims: [.feature("library.grid"), .feature("library.subfolders")],
        ) { app in
            let names = try app.showGrid()
            try app.main { model in
                model.setThumbnailSize(168)
                model.setCellStyle(.expanded)
                model.click(model.items[1].url, toggling: true)
            }
            let kept = try app.selectionState()
            try app.expect(kept.photos == [names[0], names[1]], "⌘-click gave \(kept)")
            try app.main { $0.setIncludesSubfolders(true) }
            try app.wait("the folder with its subfolders") { $0.library.includesSubfolders && !$0.library.isListing }
            try app.main { model in
                model.setThumbnailSize(96)
                model.setCellStyle(.none)
            }
            try app.main { $0.setIncludesSubfolders(false) }
            try app.wait("the folder alone") { !$0.library.includesSubfolders && !$0.library.isListing }
            try app.wait("its size and style back") { model in
                model.libraryViews.thumbnailSize == 168 && model.libraryViews.cellStyle == .expanded
            }
            let back = try app.selectionState()
            try app.expect(
                back.photos == kept.photos && back.active == kept.active,
                "The selection came back as \(back)",
            )
            app.covered([.feature("library.grid"), .feature("library.subfolders")], via: .model)
            try app.main { model in
                model.setThumbnailSize(GridSize.standard)
                model.setCellStyle(.compact)
                model.deselectOtherPhotos()
            }
            try app.backToDevelop()
        }
    }
#endif
