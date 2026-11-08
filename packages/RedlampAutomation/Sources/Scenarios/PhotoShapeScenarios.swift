#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import ImageIO
    import RedlampEngineAPI
    @_spi(Harness) import RedlampUI
    import UniformTypeIdentifiers

    /// A photo's shape in the Library's loupe, Compare and Survey (#481), on a scratch folder of three JPEGs stored
    /// 1500 by 1000 pixels: one turned upright to portrait by its EXIF orientation, whose size each view reads from its
    /// header, as for a folder the library hasn't indexed yet; then one turned a quarter and one cropped square in
    /// Develop, shown from the library's renders of their edits. And a crop at 1:1 in the loupe (J10-2169).
    enum PhotoShapeScenarios {
        static let all: [Scenario] = [shapes, zoomedCrop]

        /// The photos in the order they were taken, each with the EXIF orientation it's written with.
        private static let photos = [("Portrait.jpg", 6), ("Turned.jpg", 1), ("Square.jpg", 1)]
        /// Their size in pixels as stored, and turned upright.
        private static let stored = CGSize(width: 1500, height: 1000)
        private static let upright = CGSize(width: 1000, height: 1500)

        /// How a view should draw a photo: at `aspect`, width over height, from the library's render of its edit
        /// when `edited`, with `pixels` as the photo's own size.
        private struct Expected: Sendable, CustomStringConvertible {
            var aspect: Double
            var edited = false
            var pixels: CGSize

            var description: String {
                String(format: "%.3f", aspect) + (edited ? " from its edit" : "")
                    + ", the photo \(Int(pixels.width)) × \(Int(pixels.height))"
            }
        }

        static let shapes = Scenario(
            "library.photo-shapes",
            "A photo turned to portrait by its EXIF orientation, and edits turned a quarter and cropped square, keep "
                + "their shapes in the loupe, fitted and at 1:1, in Compare and in Survey",
            claims: [.feature("library.loupe"), .action(.loupeView), .action(.compareView), .action(.surveyView)],
        ) { app in
            let scratch = try SourcesScratch(app, photos: [])
            defer { app.removeScratch(scratch) }
            for (index, (name, orientation)) in photos.enumerated() {
                try jpeg(orientation: orientation, taken: "2026:10:2\(index + 1) 10:00:00")
                    .write(to: scratch.photo(name))
            }
            try scratch.index(app)
            let folder = scratch.folder
            try app.main { _ in LibraryPhotoFrames.readsHeaders = true }
            defer { try? app.main { _ in LibraryPhotoFrames.readsHeaders = false } }
            try checkViews(app, app.main { $0.items.map(\.url.lastPathComponent) }, [
                "Portrait.jpg": Expected(aspect: 2.0 / 3, pixels: upright),
                "Turned.jpg": Expected(aspect: 1.5, pixels: stored),
                "Square.jpg": Expected(aspect: 1.5, pixels: stored),
            ], zooming: "Portrait.jpg")
            try app.main { _ in LibraryPhotoFrames.readsHeaders = false }

            // A quarter turn and a square crop, each as a person makes them in Develop.
            try selectAlone(app, "Turned.jpg")
            try app.press(.editTool)
            try app.wait("D: Develop on Turned.jpg") { model in
                model.module == .develop && model.selection?.lastPathComponent == "Turned.jpg"
            }
            try app.settle()
            try app.choose(.rotateLeft)
            try app.wait("Turned.jpg turned a quarter") { model in
                model.recipe.orientation != .identity && model.history.last?.title == "Rotate Left"
            }
            try app.open("Square.jpg")
            try app.press(.cropTool)
            try app.wait("R: the Crop tool") { $0.activeTool == .crop }
            // The Aspect menu is SwiftUI's, which takes no click while the app isn't active.
            try app.main { $0.setCropAspect(.square) }
            try app.wait("Square.jpg cropped square") { model in
                abs(model.pixelAspect(of: model.recipe.crop) - 1) < 0.01
            }
            try app.press(.editTool)
            try app.wait("D: the Edit tool") { $0.activeTool == .edit }

            try app.press(.gridView)
            try app.wait("G: the folder's grid") { model in model.module == .library && model.folder == folder }
            try checkViews(app, app.main { $0.items.map(\.url.lastPathComponent) }, [
                "Portrait.jpg": Expected(aspect: 2.0 / 3, pixels: upright),
                "Turned.jpg": Expected(aspect: 2.0 / 3, edited: true, pixels: stored),
                "Square.jpg": Expected(aspect: 1, edited: true, pixels: stored),
            ])
            app.covered(.feature("library.loupe"), via: .key)
        }

        /// A photo larger than the store's previews, 4500 by 3000 pixels, so its edit at full size isn't its preview.
        private static let large = CGSize(width: 4500, height: 3000)

        static let zoomedCrop = Scenario(
            "library.loupe-zoomed-crop",
            "A photo cropped in Develop shows its crop in the loupe at 1:1, rendered at full size, and fitted "
                + "again; cropped again while the loupe is at 1:1, the loupe shows the new crop there at once",
            claims: [.feature("library.loupe"), .action(.toggleZoom), .action(.cropTool)],
        ) { app in
            let scratch = try SourcesScratch(app, photos: [])
            defer { app.removeScratch(scratch) }
            let name = "Cropped.jpg"
            try jpeg(orientation: 1, taken: "2026:11:08 10:00:00", size: large).write(to: scratch.photo(name))
            try scratch.index(app)
            try selectAlone(app, name)
            try app.press(.loupeView)
            try app.wait("E: the loupe on \(name)") { $0.libraryView == .loupe }
            try expectActualSize(app, name, large)

            let wide = 16.0 / 9
            try crop(app, name, .sixteenByNine, ratio: wide)
            try app.press(.loupeView)
            try app.wait("E: the loupe on \(name)") { model in
                model.module == .library && model.libraryView == .loupe && model.selection?.lastPathComponent == name
            }
            try expectShape(app, "library.loupe", name, Expected(aspect: wide, edited: true, pixels: large))
            try app.press(.toggleZoom)
            try app.wait("Z: 1:1") { $0.libraryViews.loupeZoom == .actual }
            try expectFullSizeEdit(app, name, aspect: wide, longEdge: large.width)
            try app.press(.toggleZoom)
            try app.wait("Z: fit") { $0.libraryViews.loupeZoom == .fit }
            try expectShape(app, "library.loupe", name, Expected(aspect: wide, edited: true, pixels: large))

            // Cropped again from 1:1: back in the loupe, still at 1:1, the new crop at full size.
            try app.press(.toggleZoom)
            try app.wait("Z: 1:1") { $0.libraryViews.loupeZoom == .actual }
            try expectFullSizeEdit(app, name, aspect: wide, longEdge: large.width)
            try crop(app, name, .square, ratio: 1)
            try app.press(.loupeView)
            try app.wait("E: the loupe on \(name), at 1:1") { model in
                model.module == .library && model.libraryView == .loupe && model.libraryViews.loupeZoom == .actual
            }
            try expectFullSizeEdit(app, name, aspect: 1, longEdge: large.height)
            try app.press(.toggleZoom)
            try app.wait("Z: fit") { $0.libraryViews.loupeZoom == .fit }
            try expectShape(app, "library.loupe", name, Expected(aspect: 1, edited: true, pixels: large))
            app.covered([.feature("library.loupe"), .action(.toggleZoom)], via: .key)
            app.covered(.action(.cropTool), via: .key)
        }

        /// D, R and an aspect in the Crop tool, then D again: `name` cropped to `aspect`, `ratio` wide, in Develop.
        private static func crop(_ app: RunningApp, _ name: String, _ aspect: CropAspect, ratio: Double) throws {
            try app.press(.editTool)
            try app.wait("D: Develop on \(name)") { model in
                model.module == .develop && model.info?.url.lastPathComponent == name
            }
            try app.settle()
            try app.press(.cropTool)
            try app.wait("R: the Crop tool") { $0.activeTool == .crop }
            // A cropped photo's whole frame is laid out again in the Crop tool before its aspect is set.
            try app.settle()
            // The Aspect menu is SwiftUI's, which takes no click while the app isn't active.
            try app.main { $0.setCropAspect(aspect) }
            do {
                try app.wait("\(name) cropped \(aspect.title)") { model in
                    abs(model.pixelAspect(of: model.recipe.crop) - ratio) < 0.01
                }
            } catch {
                let state = try app.main { model in
                    String(format: "%.3f", model.pixelAspect(of: model.recipe.crop))
                        + ", the Aspect menu on \(model.cropAspect.title), last step "
                        + (model.history.last?.title ?? "none")
                }
                throw ScenarioFailure("\(error): the crop is \(state)")
            }
            try app.press(.editTool)
            try app.wait("D: the Edit tool") { $0.activeTool == .edit }
        }

        /// Waits until the loupe shows `name`'s edit at 1:1 rendered at full size, `aspect` wide with `longEdge` pixels
        /// on
        /// its long edge, one of them to one of the screen's.
        private static func expectFullSizeEdit(
            _ app: RunningApp, _ name: String, aspect: Double, longEdge: CGFloat,
        ) throws {
            do {
                try app.wait("\(name)'s edit at full size at 1:1", timeout: 60) { _ in
                    guard let shown = shown("library.loupe"), shown.showsFullPhoto, shown.showsEdit,
                          let image = shown.image, image.width > 0, image.height > 0
                    else { return false }
                    let scale = Views.editorWindow?.backingScaleFactor ?? 2
                    return abs(image.width / image.height / aspect - 1) < 0.02
                        && abs(max(image.width, image.height) - longEdge) <= 2
                        && abs(shown.frame.width * scale - image.width) < 1
                        && abs(shown.frame.height * scale - image.height) < 1
                }
            } catch {
                let state = try app.main { _ in shown("library.loupe").map(String.init(describing:)) ?? "nothing" }
                throw ScenarioFailure("\(error): the loupe shows \(state)")
            }
        }

        /// Shows each photo in the loupe, then the first beside each of the others in Compare, then all of them in
        /// Survey, in the grid's `order`, and checks each is drawn as `expected` says; `zooming` is also checked at 1:1
        /// in the loupe.
        private static func checkViews(
            _ app: RunningApp, _ order: [String], _ expected: [String: Expected], zooming: String? = nil,
        ) throws {
            func check(_ identifier: String, _ name: String) throws {
                guard let shape = expected[name] else { throw ScenarioFailure("No shape is expected for \(name)") }
                try expectShape(app, identifier, name, shape)
            }

            try selectAlone(app, order[0])
            try app.press(.loupeView)
            try app.wait("E: the loupe") { $0.libraryView == .loupe }
            for (index, name) in order.enumerated() {
                if index > 0 {
                    try app.press(.nextPhoto)
                }
                try app.wait("the loupe on \(name)") { $0.selection?.lastPathComponent == name }
                try check("library.loupe", name)
                if name == zooming, let shape = expected[name] {
                    try expectActualSize(app, name, shape.pixels)
                }
            }

            try app.press(.gridView)
            try app.wait("G: the grid") { $0.libraryView == .grid }
            try selectAlone(app, order[0])
            try app.press(.compareView)
            for (index, name) in order.enumerated().dropFirst() {
                if index > 1 {
                    try app.press(.nextPhoto)
                }
                try app.wait("Compare: \(order[0]) beside \(name)") { model in
                    [model.libraryCompare.select, model.libraryCompare.candidate]
                        .map { $0?.url.lastPathComponent ?? "-" }
                        == [order[0], name]
                }
                if index == 1 {
                    try check("library.compare.select", order[0])
                }
                try check("library.compare.candidate", name)
            }

            try app.press(.gridView)
            try app.wait("G: the grid") { $0.libraryView == .grid }
            try selectAlone(app, order[0])
            for _ in order.dropFirst() {
                try app.press(KeyCombo(.right, shift: true))
            }
            try app.wait("every photo selected") { Set($0.selectedPhotos.map(\.lastPathComponent)) == Set(order) }
            try app.press(.surveyView)
            try app.wait("N: Survey of every photo") { model in
                model.libraryView == .survey && Set(model.surveyPhotos.map(\.url.lastPathComponent)) == Set(order)
            }
            for name in order {
                try check("survey.\(name)", name)
            }
            try app.press(KeyCombo(.escape))
            try app.wait("Esc: the grid") { $0.libraryView == .grid }
        }

        /// Clicks `name`'s cell in the grid, and waits until it alone is selected.
        private static func selectAlone(_ app: RunningApp, _ name: String) throws {
            try app.wait("\(name)'s cell in the grid") { _ in
                Views.editorWindow.flatMap { Views.find("grid.\(name)", in: $0) } != nil
            }
            try app.click(.identifier("grid.\(name)"))
            try app.wait("\(name) alone selected") { $0.selectedPhotos.map(\.lastPathComponent) == [name] }
        }

        @MainActor private static func shown(_ identifier: String) -> LibraryPhotoFrames.Shown? {
            Views.editorWindow.flatMap { LibraryPhotoFrames.shown(identifier, in: $0) }
        }

        /// Whether `shown` is drawn as `expected`, its image the same shape: within a fiftieth, where the views tell
        /// shapes apart by a hundredth (`LibraryLoupeView.laidOut`) and a thumbnail's rounding takes some of it.
        private static func matches(_ shown: LibraryPhotoFrames.Shown, _ expected: Expected) -> Bool {
            guard let image = shown.image, image.width > 0, image.height > 0, shown.frame.width > 0,
                  shown.frame.height > 0, shown.pixelSize == expected.pixels, shown.showsEdit == expected.edited
            else { return false }
            return abs(shown.frame.width / shown.frame.height / expected.aspect - 1) < 0.02
                && abs(image.width / image.height / expected.aspect - 1) < 0.02
        }

        /// Waits until the view carrying `identifier` draws `name` as `expected`.
        private static func expectShape(
            _ app: RunningApp, _ identifier: String, _ name: String, _ expected: Expected,
        ) throws {
            do {
                try app.wait("\(name) drawn at its shape by \(identifier)", timeout: expected.edited ? 60 : 30) { _ in
                    shown(identifier).map { matches($0, expected) } ?? false
                }
            } catch {
                let state = try app.main { _ in shown(identifier).map(String.init(describing:)) ?? "nothing" }
                throw ScenarioFailure("\(error): \(identifier) shows \(state), not \(expected)")
            }
        }

        /// Z: at 1:1, one of the photo's pixels to one of the screen's, upright; Z again fits it.
        private static func expectActualSize(_ app: RunningApp, _ name: String, _ pixels: CGSize) throws {
            try app.press(.toggleZoom)
            try app.wait("Z: 1:1") { $0.libraryViews.loupeZoom == .actual }
            do {
                try app.wait("\(name) itself at 1:1", timeout: 30) { _ in
                    guard let shown = shown("library.loupe"), shown.showsFullPhoto else { return false }
                    let scale = Views.editorWindow?.backingScaleFactor ?? 2
                    return abs(shown.frame.width - pixels.width / scale) < 0.5
                        && abs(shown.frame.height - pixels.height / scale) < 0.5
                }
            } catch {
                let state = try app.main { _ in shown("library.loupe").map(String.init(describing:)) ?? "nothing" }
                throw ScenarioFailure("\(error): the loupe shows \(state)")
            }
            try app.press(.toggleZoom)
            try app.wait("Z: fit") { $0.libraryViews.loupeZoom == .fit }
        }

        /// A JPEG `size` pixels as stored, with a pale band along its stored top edge so a turn shows, turned by its
        /// EXIF `orientation` and taken at `taken`.
        private static func jpeg(orientation: Int, taken: String, size: CGSize = stored) throws -> Data {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
                  )
            else { throw ScenarioFailure("No bitmap context") }
            context.setFillColor(red: 0.35, green: 0.3, blue: 0.25, alpha: 1)
            context.fill(CGRect(origin: .zero, size: size))
            context.setFillColor(red: 0.85, green: 0.85, blue: 0.8, alpha: 1)
            context.fill(CGRect(x: 0, y: size.height * 0.8, width: size.width, height: size.height * 0.2))
            let data = NSMutableData()
            guard let image = context.makeImage(),
                  let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
            else { throw ScenarioFailure("No JPEG encoder") }
            let properties: [CFString: Any] = [
                kCGImagePropertyOrientation: orientation,
                kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: taken],
            ]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ScenarioFailure("The JPEG wasn't written") }
            return data as Data
        }
    }
#endif
