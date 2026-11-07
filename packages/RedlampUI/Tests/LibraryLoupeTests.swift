import AppKit
import CoreGraphics
import Foundation
import ImageIO
import RedlampCanvas
import Testing
import UniformTypeIdentifiers
@testable import RedlampUI

/// The Library loupe's zoom (LIB-14): fit and 1:1, by Z and by a click, from the preview and then the
/// photo itself, with the photo's name shown.
@MainActor
struct LibraryLoupeTests {
    /// Photos 1200 by 800 pixels: their previews at most 2048, so the same.
    private nonisolated static func photo(_ size: Int) -> CGImage? {
        ModuleFixture.image(min(size, 1200))
    }

    /// A photo `size` pixels high and two thirds as wide, as the engine decodes a portrait photo, upright.
    private nonisolated static func portrait(_ size: Int) -> CGImage? {
        blank(width: size * 2 / 3, height: size)
    }

    private nonisolated static func blank(width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ) else { return nil }
        return context.makeImage()
    }

    /// A JPEG `width` by `height` pixels as stored, which its EXIF `orientation` turns.
    private nonisolated static func writeJPEG(_ url: URL, width: Int, height: Int, orientation: Int) throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil,
        ))
        let properties = [kCGImagePropertyOrientation: orientation] as CFDictionary
        try CGImageDestinationAddImage(destination, #require(context.makeImage()), properties)
        #expect(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: url)
    }

    /// Opens a folder of one JPEG, `width` by `height` pixels as stored and turned by `orientation`, listed from the
    /// disk, so the loupe reads its size from its header.
    private func open(_ fixture: ModuleFixture, width: Int, height: Int, orientation: Int) async throws -> URL {
        try FileManager.default.createDirectory(at: fixture.folder, withIntermediateDirectories: true)
        let photo = fixture.folder.appending(path: "IMG_00001.JPG")
        try Self.writeJPEG(photo, width: width, height: height, orientation: orientation)
        fixture.model.open([fixture.folder])
        try await fixture.eventually { fixture.model.library.count == 1 && fixture.model.info?.url == photo }
        return photo
    }

    private func click(_ loupe: LibraryLoupeView, at point: CGPoint) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: loupe.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: loupe.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1,
            ))
            if type == .leftMouseDown {
                loupe.mouseDown(with: event)
            } else {
                loupe.mouseUp(with: event)
            }
        }
    }

    @Test func `the Z key and a click zoom the loupe to 1:1 from the photo itself and fit it again`() async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        fixture.engine.decodedThumbnail = { _, size in Self.photo(size) }
        try await fixture.open(count: 5)
        let modules = fixture.showModules()
        let model = fixture.model
        let loupe = modules.content.library.loupe
        model.showLibrary(.loupe)
        try await fixture.settle()
        loupe.layoutSubtreeIfNeeded()
        try await fixture.eventually { loupe.showsPreview }
        #expect(loupe.accessibilityLabel() == fixture.photos[0].lastPathComponent, "the photo's name is shown")
        let fitted = loupe.photoFrame
        let scale = loupe.window?.backingScaleFactor ?? 2
        #expect(model.libraryViews.loupeZoom == .fit && fitted.width > 0 && fitted.height > 0)
        #expect(abs(fitted.width / fitted.height - 1.5) < 0.01, "the photo keeps its shape")

        let toolbar = modules.content.library.toolbar
        toolbar.layoutSubtreeIfNeeded()
        let fit = try #require(toolbar.subviews.first { $0.accessibilityIdentifier() == "library.toolbar.fit" })
        let middle = toolbar.convert(CGPoint(x: fit.frame.midX, y: fit.frame.midY), to: toolbar.superview)
        #expect(toolbar.hitTest(middle) === fit, "the grid's buttons, hidden in the loupe, take no clicks")

        #expect(model.canPerform(.toggleZoom) && model.perform(.toggleZoom))
        #expect(model.libraryViews.loupeZoom == .actual)
        try await fixture.eventually { loupe.showsFullPhoto }
        #expect(loupe.showsFullPhoto, "1:1 decodes the photo itself")
        #expect(loupe.image?.width == 1200)
        #expect(abs(loupe.photoFrame.width - 1200 / scale) < 0.5, "one of the photo's pixels to one of the screen's")

        try click(loupe, at: CGPoint(x: loupe.bounds.midX, y: loupe.bounds.midY))
        #expect(model.libraryViews.loupeZoom == .fit, "a click fits it again")
        #expect(loupe.photoFrame == fitted)
        try click(loupe, at: CGPoint(x: fitted.minX + fitted.width / 4, y: fitted.midY))
        #expect(model.libraryViews.loupeZoom == .actual, "a click zooms where it lands")
        #expect(abs(loupe.focus.x - 0.25) < 0.02 && abs(loupe.focus.y - 0.5) < 0.02)
        try await fixture.settle()
        #expect(abs(loupe.photoFrame.width - 1200 / scale) < 0.5)

        model.perform(.nextPhoto)
        try await fixture.eventually { loupe.accessibilityLabel() == fixture.photos[1].lastPathComponent }
        #expect(model.libraryViews.loupeZoom == .actual, "the next photo is shown at the same zoom")
        model.showLibrary(.grid)
        #expect(!model.canPerform(.toggleZoom) && !model.perform(.toggleZoom), "Space and Z go on to the grid")
        model.showModule(.develop)
        #expect(model.perform(.toggleZoom) && model.libraryViews.loupeZoom == .actual, "Develop's Z zooms its canvas")
    }

    /// A notch of a mouse wheel over `loupe`, rolled away from you or towards you as the canvas reads it.
    private func notch(away: Bool) throws -> NSEvent {
        for lines: Int32 in [1, -1] {
            let cgEvent = try #require(CGEvent(
                scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0,
            ))
            if let event = NSEvent(cgEvent: cgEvent), (CanvasMetalView.notches(of: event) > 0) == away {
                return event
            }
        }
        throw CancellationError()
    }

    @Test func `the wheel steps through the photos at Fit, one a notch, and leaves 1:1 and ⌘-scrolling alone`(
    ) async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        fixture.engine.decodedThumbnail = { _, size in Self.photo(size) }
        try await fixture.open(count: 5)
        let modules = fixture.showModules()
        let model = fixture.model
        let loupe = modules.content.library.loupe
        model.showLibrary(.loupe)
        try await fixture.settle()
        let name = { model.selection?.lastPathComponent }
        let names = fixture.photos.map(\.lastPathComponent)

        try loupe.scrollWheel(with: notch(away: false))
        try loupe.scrollWheel(with: notch(away: false))
        #expect(name() == names[2], "two notches towards you: two photos on")
        try loupe.scrollWheel(with: notch(away: true))
        #expect(name() == names[1], "a notch away: the photo before")

        let command = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0,
        ))
        command.flags = .maskCommand
        try loupe.scrollWheel(with: #require(NSEvent(cgEvent: command)))
        #expect(name() == names[1], "⌘-scrolling doesn't browse")

        #expect(model.perform(.toggleZoom) && model.libraryViews.loupeZoom == .actual)
        try loupe.scrollWheel(with: notch(away: false))
        #expect(name() == names[1], "at 1:1 the wheel doesn't browse")
        #expect(model.perform(.toggleZoom) && model.libraryViews.loupeZoom == .fit)

        model.perform(.firstPhoto)
        try loupe.scrollWheel(with: notch(away: true))
        #expect(name() == names[0], "the wheel stops at the first photo, as ← does")
    }

    @Test func `a mouse wheel's notch is one photo, however fast it spins, rolled away the one before`() {
        var wheel = LoupeWheel()
        #expect(wheel.step(notches: 1, precise: false) == -1)
        #expect(wheel.step(notches: -4, precise: false) == 1)
        #expect(wheel.step(notches: 0, precise: false) == 0)
    }

    @Test func `a trackpad swipe is one photo once it has gone far enough, its momentum none`() {
        var wheel = LoupeWheel()
        #expect(wheel.step(notches: -0.5, precise: true, phase: .began) == 0, "a light touch")
        #expect(wheel.step(notches: -1, precise: true, phase: .changed) == 0)
        #expect(wheel.step(notches: -1, precise: true, phase: .changed) == 1, "past the threshold: the next photo")
        #expect(wheel.step(notches: -5, precise: true, phase: .changed) == 0, "however far the swipe goes")
        #expect(wheel.step(notches: 0, precise: true, phase: .ended) == 0)
        #expect(wheel.step(notches: -5, precise: true, momentumPhase: .changed) == 0, "nor its momentum")
        #expect(wheel.step(notches: 1.5, precise: true, phase: .began) == 0, "a new swipe starts again")
        #expect(wheel.step(notches: 1, precise: true, phase: .changed) == -1, "swiped up: the photo before")
    }

    @Test func `a smooth mouse's scrolling, with no gesture, is a photo a notch`() {
        var wheel = LoupeWheel()
        #expect(wheel.step(notches: -0.6, precise: true) == 0)
        #expect(wheel.step(notches: -0.6, precise: true) == 1)
        #expect(wheel.step(notches: -0.6, precise: true) == 0)
        #expect(wheel.step(notches: -0.6, precise: true) == 1)
        #expect(wheel.step(notches: 0.6, precise: true) == 0, "turning back starts again")
        #expect(wheel.step(notches: 0.6, precise: true) == -1)
    }

    @Test func `a photo read from its header has its size upright, turned by its EXIF orientation`() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "loupe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (orientation, width, height) in [(1, 120, 80), (3, 120, 80), (6, 80, 120), (8, 80, 120)] {
            let url = folder.appending(path: "\(orientation).jpg")
            try Self.writeJPEG(url, width: 120, height: 80, orientation: orientation)
            let details = try #require(PhotoDetails(reading: url))
            #expect(details.width == width && details.height == height, "orientation \(orientation)")
        }
    }

    @Test func `a portrait photo turned by its EXIF orientation keeps its shape in the loupe, fitted and at 1:1`(
    ) async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        fixture.engine.decodedThumbnail = { _, size in Self.portrait(min(size, 1200)) }
        _ = try await open(fixture, width: 1200, height: 800, orientation: 6)
        let modules = fixture.showModules()
        let model = fixture.model
        let loupe = modules.content.library.loupe
        model.showLibrary(.loupe)
        try await fixture.settle()
        loupe.layoutSubtreeIfNeeded()
        try await fixture.eventually { loupe.showsPreview && loupe.pixelSize != nil }
        #expect(loupe.pixelSize == CGSize(width: 800, height: 1200), "its size from its header, upright")
        let fitted = loupe.photoFrame
        #expect(abs(fitted.width / fitted.height - 2.0 / 3) < 0.01, "fitted, it keeps its shape: \(fitted.size)")

        #expect(model.perform(.toggleZoom))
        try await fixture.eventually { loupe.showsFullPhoto }
        let scale = loupe.window?.backingScaleFactor ?? 2
        let actual = loupe.photoFrame.size
        #expect(
            abs(actual.width - 800 / scale) < 0.5 && abs(actual.height - 1200 / scale) < 0.5,
            "at 1:1, one of its pixels to one of the screen's, upright: \(actual)",
        )
    }

    @Test func `a photo is laid out at its size, or in the shape of an image an edit crops or turns, at its long edge`(
    ) throws {
        let photo = CGSize(width: 1200, height: 800)
        func laidOut(_ width: Int, _ height: Int) throws -> CGSize? {
            let image = try #require(Self.blank(width: width, height: height))
            return LibraryLoupeView.laidOut(photo, image: image)
        }
        #expect(try laidOut(300, 200) == photo, "an image of its shape")
        #expect(try laidOut(1203, 800) == photo, "within a hundredth of it")
        #expect(try laidOut(200, 300) == CGSize(width: 800, height: 1200), "a quarter turn")
        #expect(try laidOut(500, 500) == CGSize(width: 1200, height: 1200), "a square crop")
        #expect(try laidOut(400, 100) == CGSize(width: 1200, height: 300), "a panoramic crop")
        let image = try #require(Self.blank(width: 200, height: 300))
        #expect(LibraryLoupeView.laidOut(nil, image: image) == CGSize(width: 200, height: 300), "the image's own size")
        #expect(LibraryLoupeView.laidOut(photo, image: nil) == photo, "the photo's, with no image yet")
    }

    @Test func `an image of another shape, as an edit's crop or turn makes it, keeps its own shape in the loupe`(
    ) async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        fixture.engine.decodedThumbnail = { _, size in Self.blank(width: min(size, 800), height: min(size, 800)) }
        _ = try await open(fixture, width: 1200, height: 800, orientation: 1)
        let modules = fixture.showModules()
        let loupe = modules.content.library.loupe
        fixture.model.showLibrary(.loupe)
        try await fixture.settle()
        loupe.layoutSubtreeIfNeeded()
        try await fixture.eventually { loupe.showsPreview && loupe.pixelSize != nil }
        #expect(loupe.pixelSize == CGSize(width: 1200, height: 800), "its size from its header")
        let fitted = loupe.photoFrame
        #expect(abs(fitted.width / fitted.height - 1) < 0.01, "fitted, it keeps the image's shape: \(fitted.size)")
    }

    @Test func `the caption shows the date and settings in whole fields, as many as its width does, never part of one`(
    ) throws {
        var details = PhotoDetails()
        details.captured = Date(timeIntervalSinceReferenceDate: 542_652_000)
        details.shutter = 1.0 / 50
        details.aperture = 4
        details.iso = 400
        details.focal = 32
        let fields = ["1/50 s", "ƒ/4", "ISO 400", "32 mm"]
        let steps = [""] + (0 ... fields.count).map { count in
            [details.date, fields.prefix(count).joined(separator: "  ")].filter { !$0.isEmpty }
                .joined(separator: "  ·  ")
        }
        func width(_ text: String) -> CGFloat {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            return label.intrinsicContentSize.width
        }
        var shown: Set<String> = []
        for room in stride(from: CGFloat(0), through: 420, by: 3) {
            let caption = LibraryLoupeView.caption(details, width: room)
            let step = try #require(steps.firstIndex(of: caption), "\(room): “\(caption)” is whole fields")
            #expect(caption.isEmpty || width(caption) <= room, "\(room): the caption shows all of “\(caption)”")
            #expect(step == steps.count - 1 || width(steps[step + 1]) > room, "\(room): and a field more doesn't fit")
            shown.insert(caption)
        }
        #expect(shown == Set(steps), "from nothing to the whole caption")
    }
}
