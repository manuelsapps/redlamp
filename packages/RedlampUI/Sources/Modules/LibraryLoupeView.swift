import AppKit
import QuartzCore
import RedlampCanvas
import RedlampDesign
import RedlampDocument
import RedlampLibrary

/// The Library loupe (E): the active photo large, from its thumbnail at once and its screen-size preview
/// once that's decoded, with its name, date and camera settings above it as an expanded grid cell has
/// them, and its rating, flag, label and mark beside them as they change (LIB-15). Z, Space or a click
/// zoom it to 1:1, where the preview shows at the photo's full size until the photo itself is decoded off
/// the main thread, or for an edited photo the library renders, until its edit is rendered at full size; a drag
/// pans it, and Z or a click fit it again. At Fit the scroll wheel steps to the photo before or
/// after, as ← and → do (`LoupeWheel`). An edited photo shows its edit once the
/// library has rendered it, and until then its embedded preview, marked in its corner as a grid cell is
/// (LIB-17); a change to its edit is made again at full size too, the preview shown meanwhile. It reads nothing
/// while it isn't shown. LIB-16 adds Compare and Survey. The judging tools (LIB-38)
/// draw over the photo, their buttons in the caption row; with the following loupe on, the photo is made at its full
/// size as for 1:1, for the lens to magnify. The caption row also shows the loupe's own Auto Advance, on until it's
/// turned off there (DEC-68), and turns it on or off. It's drawn on Develop's canvas grey (`PhotoSurround`), its
/// caption row in the surround's colours (`LibraryLook.surroundTokens`).
final class LibraryLoupeView: NSView, ThemeFollowing {
    private static let inset: CGFloat = 20
    private static let captionHeight: CGFloat = 34
    private static let captionFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

    private let model: EditorModel
    private let photo = CALayer()
    private let mark = CALayer()
    private let name = NSTextField(labelWithString: "")
    private let caption = NSTextField(labelWithString: "")
    let badges = LoupeBadgesView()
    let judging: JudgingOverlay
    let judgingBar: JudgingBar
    let autoAdvance = ToolbarButton(symbol: "arrow.right.to.line", identifier: "library.loupe.autoAdvance")
    private let details: PhotoDetailsCache
    /// The shown photo's details, which the caption shows as much of as its width does.
    private var captionDetails: PhotoDetails?
    private var trackers: [Tracker] = []
    private var editObservation: LibraryObservation?
    private var libraryObservation: LibraryObservation?
    /// The photo shown, a file's own or one of its versions (LIB-48), and whether its preview, and at 1:1 the photo at
    /// its full size, are in: its edit rendered at full size where the library renders it, else the photo itself.
    private var shown: PhotoAddress?
    private(set) var showsPreview = false
    private(set) var showsFullPhoto = false
    /// The edit the image shows, nil for the photo's embedded preview or the photo itself.
    private(set) var shownEdit: EditDigest?
    /// The edit the photo had when the image at full size being made was asked for.
    private var loadingEdit: EditDigest?
    /// The photo's size in pixels, from the index or its header, else from the image shown.
    private(set) var pixelSize: CGSize?
    /// At 1:1, the point of the photo at the view's middle, 0 ... 1 across and down.
    private(set) var focus = CGPoint(x: 0.5, y: 0.5)
    private var drag: (start: CGPoint, focus: CGPoint, moved: Bool)?
    private var wheel = LoupeWheel()
    private var loading: Task<Void, Never>?

    init(model: EditorModel) {
        self.model = model
        details = PhotoDetailsCache(library: model.library)
        judging = JudgingOverlay(model: model, view: .loupe)
        judgingBar = JudgingBar(model: model, prefix: "library.loupe.judging")
        super.init(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = true
        photo.contentsGravity = .resize
        photo.minificationFilter = .trilinear
        photo.actions = LibraryGridCell.noActions
        layer?.addSublayer(photo)
        mark.actions = LibraryGridCell.noActions
        mark.isHidden = true
        layer?.addSublayer(mark)
        name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        caption.font = Self.captionFont
        followTheme()
        for label in [name, caption] {
            label.lineBreakMode = .byTruncatingMiddle
            addSubview(label)
        }
        addSubview(badges)
        addSubview(judgingBar)
        autoAdvance.onPress = { model.perform(.autoAdvance) }
        autoAdvance.onSurround = true
        addSubview(autoAdvance)
        judging.install(in: self, above: photo)
        judging.histogram.setAccessibilityIdentifier("library.loupe.histogram")
        judging.shownImage = { [weak self] in self?.image }
        judging.onChange = { [weak self] in self?.updateMark() }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityIdentifier("library.loupe")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    override var wantsUpdateLayer: Bool {
        true
    }

    override func updateLayer() {}

    func followTheme() {
        name.textColor = LibraryLook.surroundTokens.value.nsColor
        caption.textColor = LibraryLook.surroundTokens.label.nsColor
    }

    /// The image on screen, for the tests.
    var image: CGImage? {
        photo.contents.map { $0 as! CGImage } // swiftlint:disable:this force_cast
    }

    /// The photo's frame, for the tests.
    var photoFrame: CGRect {
        photo.frame
    }

    /// An edited photo the library renders shows an image without its edit, and is marked so.
    var showsUneditedPreview: Bool {
        guard image != nil, shownEdit == nil, let shown, let item = item(shown) else { return false }
        return model.editRenders.renders(item)
    }

    /// The row of the photo `photo` names, while it's shown and read.
    private func item(_ photo: PhotoAddress) -> LibraryItem? {
        model.library.index(of: photo).flatMap { model.library.items.row($0) }
    }

    /// The photo the loupe shows: the selection's active photo, a file's own or one of its versions, while it's of the
    /// active photo's file; else the file's own.
    static func shownPhoto(_ selection: URL?, active: Int64?, in library: FolderLibrary) -> PhotoAddress? {
        guard let selection else { return nil }
        if let active, let photo = library.address(ofPhoto: active), photo.url == selection {
            return photo
        }
        return PhotoAddress(url: selection)
    }

    private var zoom: LoupeZoom {
        model.libraryViews.loupeZoom
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        trackers.forEach { $0.cancel() }
        trackers = []
        editObservation = nil
        libraryObservation = nil
        judging.stop()
        guard window != nil else { return }
        editObservation = model.editRenders.observe { [weak self] photos in self?.editsShown(photos) }
        libraryObservation = model.library.observe { [weak self] diff in self?.libraryChanged(diff) }
        judging.start()
        trackers = [
            Tracker { [weak self] in
                guard let self else { return }
                let (selection, active) = (model.selection, model.photoSelection.active)
                // Away from the loupe, the photo at full size being made stops, leaving Develop's engine to Develop.
                guard isShownView else {
                    loading?.cancel()
                    loading = nil
                    return
                }
                show(Self.shownPhoto(selection, active: active, in: model.library))
                if wantsFullPhoto, let shown, let item = item(shown) {
                    loadFullPhoto(item)
                }
            },
            Tracker { [weak self] in
                guard let self else { return }
                _ = model.libraryViews.loupeZoom
                zoomChanged()
            },
            Tracker { [weak self] in
                guard let self else { return }
                let on = model.autoAdvance(in: .loupe)
                autoAdvance.isOn = on
                autoAdvance.toolTip = "Auto Advance in the Loupe: \(on ? "on" : "off")"
            },
            Tracker { [weak self] in
                guard let self else { return }
                let magnifies = model.libraryJudging.magnification != nil
                guard magnifies, model.module == .library, model.libraryView == .loupe, let shown,
                      let item = item(shown) else { return }
                loadFullPhoto(item)
            },
        ]
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        judging.pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with _: NSEvent) {
        judging.pointerExited()
    }

    /// Develop's Show Sensor Clipping key, which the key monitor leaves to the view in Library.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard model.isSensorClippingKey(event), model.libraryView == .loupe, isInShownModule(model) else {
            return super.performKeyEquivalent(with: event)
        }
        model.toggleSensorClipping()
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard model.isSensorClippingKey(event), model.libraryView == .loupe, isInShownModule(model) else {
            return super.keyDown(with: event)
        }
        model.toggleSensorClipping()
    }

    private func show(_ photo: PhotoAddress?) {
        guard photo != shown else { return }
        shown = photo
        showsPreview = false
        showsFullPhoto = false
        loading?.cancel()
        loading = nil
        pixelSize = nil
        guard let photo, let item = item(photo) else {
            setImage(nil)
            name.stringValue = ""
            showCaption(nil)
            badges.metadata = nil
            setAccessibilityLabel(nil)
            return
        }
        badges.metadata = item.metadata
        name.stringValue = item.name
        showCaption(nil)
        setAccessibilityLabel(item.name)
        showDetails(of: item)
        details.request([item]) { [weak self] _ in
            guard let self, shown == photo else { return }
            showDetails(of: item)
        }
        showPreview(of: item)
        if wantsFullPhoto {
            loadFullPhoto(item)
        }
    }

    /// The photo's preview of the edit it shows, from memory at once, else its thumbnail until the preview's decoded.
    private func showPreview(of item: LibraryItem) {
        let photo = item.address
        let edit = model.editRenders.shownEdit(for: item)
        showsPreview = false
        if let preview = model.previews.cachedPreview(photo) {
            setImage(preview.image, edit: preview.edit)
            showsPreview = true
            if preview.edit != edit {
                requestPreview(of: item)
            }
        } else {
            let thumbnail = model.thumbnailLoader.cachedThumbnail(item)
            setImage(thumbnail?.image, edit: thumbnail?.edit)
            if thumbnail.map({ $0.edit != edit }) ?? true {
                model.thumbnailLoader.request(item) { [weak self] image in
                    guard let self, shown == photo, !showsPreview, !showsFullPhoto, let image else { return }
                    setImage(image, edit: edit)
                }
            }
            requestPreview(of: item)
        }
    }

    /// At 1:1, and for the following loupe to magnify, the photo is shown at its full size.
    private var wantsFullPhoto: Bool {
        zoom == .actual || model.libraryJudging.magnification != nil
    }

    private var isShownView: Bool {
        model.module == .library && model.libraryView == .loupe
    }

    private func requestPreview(of item: LibraryItem) {
        let edit = model.editRenders.shownEdit(for: item)
        model.previews.request(item) { [weak self] preview in
            guard let self, shown == item.address, !showsFullPhoto, let preview else { return }
            setImage(preview, edit: edit)
            showsPreview = true
        }
    }

    /// The shown photo's badges, as a culling change or the library leaves them.
    private func libraryChanged(_ diff: LibraryDiff) {
        guard let shown, diff.reset || model.library.index(of: shown).map(diff.updated.contains) == true else { return }
        badges.metadata = item(shown)?.metadata
    }

    /// The previews of these photos show another edit: the one shown is asked for again. At full size, an image of
    /// another edit than the photo has now, or of the photo itself once it has one, gives way to the preview and is
    /// made again while it's wanted and the loupe is shown, never left showing the edit the photo had.
    private func editsShown(_ photos: [PhotoAddress]) {
        guard let shown, photos.contains(shown), let item = item(shown) else { return }
        let edit = model.editRenders.readEdit(of: item)
        if loading != nil, loadingEdit != edit {
            loading?.cancel()
            loading = nil
        }
        guard !showsFullPhoto || shownEdit != edit else { return updateMark() }
        if showsFullPhoto {
            showsFullPhoto = false
            showPreview(of: item)
        } else {
            requestPreview(of: item)
        }
        if wantsFullPhoto, isShownView {
            loadFullPhoto(item)
        }
    }

    private func showDetails(of item: LibraryItem) {
        guard let details = details.details(for: item.url) else { return }
        showCaption(details)
        // The photo itself, decoded, has its own size.
        if let width = details.width, let height = details.height, width > 0, height > 0,
           !showsFullPhoto || shownEdit != nil {
            pixelSize = CGSize(width: width, height: height)
            layoutPhoto()
        }
    }

    private func setImage(_ image: CGImage?, edit: EditDigest? = nil) {
        photo.contents = image
        shownEdit = image == nil ? nil : edit
        layoutPhoto()
        judging.imageChanged()
    }

    private func updateMark() {
        let marked = showsUneditedPreview
        let value = ((marked ? ["Unedited preview"] : []) + judging.spoken).joined(separator: ", ")
        setAccessibilityValue(value.isEmpty ? nil : value)
        let size = GridBadges.Kind.uneditedPreview.size
        let visible = photo.frame.intersection(bounds)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mark.isHidden = !marked || visible.width < size.width * 3 || visible.height < size.height * 3
        if !mark.isHidden {
            let scale = window?.backingScaleFactor ?? 2
            mark.contents = GridBadges.image(.uneditedPreview, scale: scale)
            mark.contentsScale = scale
            mark.frame = CGRect(
                x: visible.maxX - size.width - 8, y: visible.maxY - size.height - 8, width: size.width,
                height: size.height,
            )
        }
        CATransaction.commit()
    }

    // MARK: - Zoom

    private func zoomChanged() {
        if zoom == .actual, !showsFullPhoto, let shown, let item = item(shown) {
            loadFullPhoto(item)
        }
        layoutPhoto()
    }

    /// The photo at its full size, for 1:1: its edit rendered at full size where the library renders it, else, or
    /// where that can't be made, the photo itself, decoded off the main thread. Either is drawn there in the window's
    /// colour space, so the commit that shows it copies it rather than converting it.
    private func loadFullPhoto(_ item: LibraryItem) {
        guard loading == nil, !showsFullPhoto, item.isLocal else { return }
        let (engine, scheduler, space) = (model.engine, model.library.scheduler, window?.colorSpace?.cgColorSpace)
        let edge = pixelSize.map { Int(max($0.width, $0.height)) } ?? 1 << 14
        let (url, photo) = (item.url, item.address)
        let originals = model.library.needsDownload(url) ? model.originals : nil
        let renders = model.editRenders
        let rendersEdit = renders.renders(item)
        loadingEdit = renders.readEdit(of: item)
        loading = Task { [weak self] in
            // A photo kept in Apple Photos downloads its original first (LIB-60), its preview shown meanwhile and the
            // download counted in the filmstrip; one that couldn't be had is asked for again at the next zoom.
            if let originals, await (try? originals.local(url, priority: .open)) == nil {
                // One cancelled for another of the same photo leaves that one be.
                if !Task.isCancelled, self?.shown == photo {
                    self?.loading = nil
                }
                return
            }
            var full: (image: CGImage, edit: EditDigest?)?
            if rendersEdit, let rendered = await renders.renderFullSize(item) {
                let drawn = try? await scheduler.run(.onScreen) { GridThumbnails.drawn(rendered.image, in: space) }
                if let drawn = drawn ?? nil {
                    full = (drawn, rendered.edit)
                }
            }
            if full == nil, !Task.isCancelled {
                let decoded = try? await scheduler.run(.onScreen) {
                    engine.decodeThumbnail(for: url, maxPixelSize: edge).flatMap { GridThumbnails.drawn($0, in: space) }
                }
                if let decoded = decoded ?? nil {
                    full = (decoded, nil)
                }
            }
            guard let self, shown == photo, !Task.isCancelled else { return }
            loading = nil
            guard let full else { return }
            if full.edit == nil, pixelSize == nil || CGFloat(full.image.width) >= (pixelSize?.width ?? 0) {
                pixelSize = CGSize(width: full.image.width, height: full.image.height)
            }
            showsFullPhoto = true
            setImage(full.image, edit: full.edit)
        }
    }

    /// The photo's frame: fitted inside the view below its caption, or at 1:1 with `focus` in the middle,
    /// kept covering the view where it's larger.
    private func layoutPhoto() {
        let area = CGRect(
            x: Self.inset, y: Self.captionHeight, width: max(bounds.width - Self.inset * 2, 1),
            height: max(bounds.height - Self.captionHeight - Self.inset, 1),
        )
        let laidOut = renderedSize ?? Self.laidOut(pixelSize, image: image)
        let size = laidOut ?? area.size
        guard size.width > 0, size.height > 0 else { return }
        let frame: CGRect
        if zoom == .actual {
            let scale = window?.backingScaleFactor ?? 2
            let shown = CGSize(width: size.width / scale, height: size.height / scale)
            frame = CGRect(
                x: Self.placed(shown.width, in: bounds.width, focus: focus.x),
                y: Self.placed(shown.height, in: bounds.height, focus: focus.y), width: shown.width,
                height: shown.height,
            )
        } else {
            let fit = min(area.width / size.width, area.height / size.height)
            let fitted = CGSize(width: size.width * fit, height: size.height * fit)
            frame = CGRect(
                x: area.midX - fitted.width / 2, y: area.midY - fitted.height / 2, width: fitted.width,
                height: fitted.height,
            )
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        photo.frame = frame
        photo.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
        updateMark()
        judging.show(shown?.url, edit: shownEdit, pixelSize: pixelSize)
        judging.place(JudgingPlacement(
            photoFrame: frame, bounds: bounds, scale: window?.backingScaleFactor ?? 2, pixels: laidOut,
        ))
    }

    /// An edit rendered at full size is laid out at its own size: its crop's, not the photo's.
    private var renderedSize: CGSize? {
        guard showsFullPhoto, shownEdit != nil, let image else { return nil }
        return CGSize(width: image.width, height: image.height)
    }

    /// The size a photo is laid out at, Compare's and Survey's too: its size in pixels, unless the image shown is
    /// another shape, as an edit's crop or turn makes it, then the image's shape at the photo's long edge; the image's
    /// own size while the photo's isn't known.
    static func laidOut(_ pixelSize: CGSize?, image: CGImage?) -> CGSize? {
        guard let image, image.width > 0, image.height > 0 else { return pixelSize }
        let shape = CGFloat(image.width) / CGFloat(image.height)
        guard let pixelSize, pixelSize.width > 0, pixelSize.height > 0 else {
            return CGSize(width: image.width, height: image.height)
        }
        guard abs(pixelSize.width / pixelSize.height / shape - 1) > 0.01 else { return pixelSize }
        let edge = max(pixelSize.width, pixelSize.height)
        return shape < 1 ? CGSize(width: edge * shape, height: edge) : CGSize(width: edge, height: edge / shape)
    }

    /// Where a side `length` long goes in `extent` with the point `focus` along it in the middle: centred
    /// when it's shorter, else never leaving a gap at either end.
    static func placed(_ length: CGFloat, in extent: CGFloat, focus: CGFloat) -> CGFloat {
        guard length > extent else { return (extent - length) / 2 }
        return min(max(extent / 2 - focus * length, extent - length), 0)
    }

    override func layout() {
        super.layout()
        let size = LoupeBadgesView.size
        badges.frame = CGRect(
            x: bounds.width - Self.inset - size.width, y: (Self.captionHeight - size.height) / 2, width: size.width,
            height: size.height,
        )
        autoAdvance.frame = CGRect(
            x: badges.frame.minX - Self.inset - 28, y: (Self.captionHeight - JudgingBar.height) / 2, width: 28,
            height: JudgingBar.height,
        )
        let tools = judgingBar.width
        judgingBar.frame = CGRect(
            x: autoAdvance.frame.minX - 12 - tools, y: (Self.captionHeight - JudgingBar.height) / 2, width: tools,
            height: JudgingBar.height,
        )
        let width = max(judgingBar.frame.minX - Self.inset * 2, 0)
        name.frame = CGRect(x: Self.inset, y: 2, width: width, height: name.intrinsicContentSize.height)
        caption.frame = CGRect(x: Self.inset, y: 18, width: width, height: caption.intrinsicContentSize.height)
        showCaption(captionDetails)
        layoutPhoto()
    }

    /// What the caption shows of `details` in a frame `width` wide: their date and settings, whole fields left out
    /// from the end until the rest fits.
    static func caption(_ details: PhotoDetails, width: CGFloat) -> String {
        details.caption { text in
            captionMeasure.stringValue = text
            return captionMeasure.intrinsicContentSize.width <= width
        }
    }

    /// A label set up as the caption is, to measure what it shows.
    private static let captionMeasure: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = captionFont
        return label
    }()

    private func showCaption(_ details: PhotoDetails?) {
        captionDetails = details
        let text = details.map { Self.caption($0, width: caption.frame.width) } ?? ""
        if caption.stringValue != text {
            caption.stringValue = text
        }
    }

    // MARK: - Mouse

    override var acceptsFirstResponder: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        drag = (convert(event.locationInWindow, from: nil), focus, false)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer { judging.pointerMoved(to: point) }
        guard var drag, zoom == .actual else { return }
        let moved = CGPoint(x: point.x - drag.start.x, y: point.y - drag.start.y)
        if !drag.moved, hypot(moved.x, moved.y) < 3 {
            return
        }
        drag.moved = true
        self.drag = drag
        let size = photo.frame.size
        guard size.width > 0, size.height > 0 else { return }
        focus = CGPoint(
            x: min(max(drag.focus.x - moved.x / size.width, 0), 1),
            y: min(max(drag.focus.y - moved.y / size.height, 0), 1),
        )
        layoutPhoto()
    }

    /// At Fit, the wheel or a swipe steps to the photo before or after, as ← and → do; ⌘-scrolling and scrolling at 1:1
    /// are left alone.
    override func scrollWheel(with event: NSEvent) {
        guard zoom == .fit, !event.modifierFlags.contains(.command), model.selection != nil else {
            return super.scrollWheel(with: event)
        }
        let step = wheel.step(
            notches: CanvasMetalView.notches(of: event), precise: event.hasPreciseScrollingDeltas, phase: event.phase,
            momentumPhase: event.momentumPhase,
        )
        guard step != 0 else { return }
        let action: ShortcutAction = step < 0 ? .previousPhoto : .nextPhoto
        if model.canPerform(action) {
            _ = model.perform(action)
        }
    }

    /// A click without a drag zooms to 1:1 where it landed, or fits the photo again.
    override func mouseUp(with event: NSEvent) {
        defer { drag = nil }
        guard let drag, !drag.moved, model.selection != nil else { return }
        if zoom == .fit {
            let frame = photo.frame
            let point = convert(event.locationInWindow, from: nil)
            if frame.width > 0, frame.height > 0 {
                focus = CGPoint(
                    x: min(max((point.x - frame.minX) / frame.width, 0), 1),
                    y: min(max((point.y - frame.minY) / frame.height, 0), 1),
                )
            }
        }
        model.toggleLoupeZoom()
        zoomChanged()
    }
}

/// How the scroll wheel browses the loupe (J10-2139), in the photos to step by: a mouse wheel's notch is one photo,
/// rolled away from you the one before, as in Lightroom, however fast it spins. A trackpad's swipe is one photo once it
/// has gone `swipe` notches, however far it goes and its momentum carries it; a smooth mouse's scrolling, which has no
/// gesture, a photo for each notch it goes.
struct LoupeWheel {
    static let swipe = 2.0

    private var travelled = 0.0
    private var stepped = false

    /// -1 for the photo before, 1 for the one after, 0 for none, for a scroll of `notches`
    /// (`CanvasMetalView.notches(of:)`).
    mutating func step(
        notches: Double, precise: Bool, phase: NSEvent.Phase = [], momentumPhase: NSEvent.Phase = [],
    ) -> Int {
        guard precise else { return notches > 0 ? -1 : notches < 0 ? 1 : 0 }
        let gesture = !phase.isEmpty || !momentumPhase.isEmpty
        if phase.contains(.began) || !gesture && stepped || travelled * notches < 0 {
            travelled = 0
            stepped = false
        }
        guard momentumPhase.isEmpty, !stepped else { return 0 }
        travelled += notches
        guard abs(travelled) >= (gesture ? Self.swipe : 1) else { return 0 }
        stepped = true
        return travelled > 0 ? -1 : 1
    }
}

/// The loupe's rating, flag, label and mark, drawn as a grid cell's are, on the photo's surround (Compare's and
/// Survey's
/// too), and said to VoiceOver.
final class LoupeBadgesView: NSView, ThemeFollowing {
    static let size = CGSize(width: 104, height: 16)
    private let rating = CALayer()
    private let flag = CALayer()
    private let label = CALayer()
    private let mark = CALayer()

    var metadata: PhotoMetadata? {
        didSet {
            if metadata != oldValue {
                show()
            }
        }
    }

    init() {
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        for badge in [rating, flag, label, mark] {
            badge.actions = LibraryGridCell.noActions
            badge.isHidden = true
            layer?.addSublayer(badge)
        }
        label.cornerRadius = 2.5
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityIdentifier("library.loupe.badges")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Its rating's places are drawn in the theme's colours.
    func followTheme() {
        show()
    }

    override var isFlipped: Bool {
        true
    }

    override var wantsUpdateLayer: Bool {
        true
    }

    override func updateLayer() {}

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        show()
    }

    /// `3 stars, Pick, Red, Marked`, as VoiceOver and the regression suite read it.
    var summary: String {
        guard let metadata else { return "" }
        let flag = metadata.flag.map { $0 == .pick ? "Pick" : "Rejected" }
        let label = metadata.label.map(\.rawValue.capitalized) ?? metadata.customLabel
        return [
            metadata.rating == 1 ? "1 star" : "\(metadata.rating) stars", flag, label, metadata.mark ? "Marked" : nil,
        ].compactMap(\.self).joined(separator: ", ")
    }

    /// From the right: the mark, the flag, the label and the stars.
    private func show() {
        let scale = window?.backingScaleFactor ?? 2
        let width = Self.size.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        setAccessibilityValue(summary)
        guard let metadata else {
            [rating, flag, label, mark].forEach { $0.isHidden = true }
            return
        }
        func place(_ badge: CALayer, _ kind: GridBadges.Kind?, x: CGFloat) {
            badge.isHidden = kind == nil
            guard let kind else { return }
            let size = kind.size
            badge.contents = GridBadges.image(kind, scale: scale, onSurround: true)
            badge.contentsScale = scale
            badge.frame = CGRect(x: x, y: (Self.size.height - size.height) / 2, width: size.width, height: size.height)
        }
        place(mark, metadata.mark ? .mark : nil, x: width - 16)
        place(flag, metadata.flag.map { $0 == .pick ? .pick : .reject }, x: width - 34)
        let colour = GridBadges.color(of: metadata)
        label.isHidden = colour == nil
        label.backgroundColor = colour?.cgColor
        label.frame = CGRect(x: width - 50, y: 3, width: 10, height: 10)
        place(rating, .ratingSlots(metadata.rating), x: 0)
    }
}
