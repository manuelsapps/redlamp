import AppKit
import QuartzCore
import RedlampDesign
import RedlampDocument
import RedlampLibrary

/// One photo as Compare and Survey show it (LIB-16): its thumbnail at once, then the photo at the size it's shown,
/// decoded off the main thread in the window's colour space (`GridThumbnails`), and at 1:1 the photo itself with the
/// point `focus` at the middle. An edited photo shows its edit once the library has rendered it, and its embedded
/// preview until then, marked in its corner as a grid cell is (LIB-17). The active photo is outlined. Its owner says
/// which photo it shows and how it's zoomed, and hears of presses, clicks and drags. The judging tools (LIB-38) draw
/// over it, each over both of Compare's photos at once; with the following loupe on, the photo itself is decoded as
/// for 1:1, for the lens to magnify.
final class ComparePhotoView: NSView {
    /// The long edges its images are decoded at: the smallest at least as large as the photo is shown.
    static let edges = [256, 384, 512, 768, 1024, 1536, 2048]

    static func edge(forPixels pixels: CGFloat) -> Int {
        edges.first { CGFloat($0) >= pixels } ?? edges[edges.count - 1]
    }

    private let model: EditorModel
    private let images: GridThumbnails
    private let photo = CALayer()
    private let outline = CALayer()
    private let mark = CALayer()
    /// The photo shown: a file's own edit or one of its versions (LIB-48), each shown with its own edit.
    private(set) var address: PhotoAddress?
    private(set) var zoom = LoupeZoom.fit
    private(set) var focus = CGPoint(x: 0.5, y: 0.5)
    /// The edge of the image shown, 0 while it's a stand-in (its thumbnail, or the loupe's preview), and the edit
    /// it shows, nil for the photo's embedded preview.
    private(set) var shownEdge = 0
    private(set) var shownEdit: EditDigest?
    private(set) var showsFullPhoto = false
    /// The photo's size in pixels, from the index or its header, else from the image shown.
    var pixelSize: CGSize? {
        didSet {
            if pixelSize != oldValue {
                layoutPhoto()
            }
        }
    }

    private var request: (id: UInt64, edge: Int)?
    private var thumbnailRequest: UInt64?
    private var loading: Task<Void, Never>?
    private var drag: (start: CGPoint, focus: CGPoint, moved: Bool)?
    let judging: JudgingOverlay
    private var magnifier: Tracker?
    private var hasPointer = false

    var isActive = false {
        didSet {
            if isActive != oldValue {
                updateOverlays()
            }
        }
    }

    /// A press on the photo, before any drag.
    var onPress: ((ComparePhotoView) -> Void)?
    /// A click without a drag: the point of the photo it landed on, 0 ... 1 across and down (nil off the photo),
    /// and the click count.
    var onClick: ((ComparePhotoView, CGPoint?, Int) -> Void)?
    /// A drag at 1:1: the point of the photo now at the middle.
    var onPan: ((ComparePhotoView, CGPoint) -> Void)?
    /// An image of another shape came in for a photo whose size in pixels isn't known.
    var onReshape: (() -> Void)?
    /// The pointer moved over the photo or left it: the point of the photo the following loupe shows, 0 ... 1, nil
    /// while it shows none.
    var onLens: ((ComparePhotoView, CGPoint?) -> Void)?

    init(model: EditorModel, images: GridThumbnails) {
        self.model = model
        self.images = images
        judging = JudgingOverlay(model: model, view: .compare)
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = true
        photo.contentsGravity = .resize
        photo.minificationFilter = .trilinear
        outline.borderWidth = 2
        outline.isHidden = true
        mark.isHidden = true
        for sublayer in [photo, outline, mark] {
            sublayer.actions = LibraryGridCell.noActions
            layer?.addSublayer(sublayer)
        }
        judging.install(in: self, above: photo)
        judging.shownImage = { [weak self] in self?.image }
        judging.onChange = { [weak self] in self?.updateOverlays() }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    override func setAccessibilityIdentifier(_ identifier: String?) {
        super.setAccessibilityIdentifier(identifier)
        judging.histogram.setAccessibilityIdentifier(identifier.map { "\($0).histogram" })
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        judging.stop()
        magnifier?.cancel()
        magnifier = nil
        guard window != nil else { return }
        judging.start()
        magnifier = Tracker { [weak self] in
            guard let self, model.libraryJudging.magnification != nil, model.module == .library,
                  model.libraryView == .compare else { return }
            loadFullPhoto()
        }
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
        pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with _: NSEvent) {
        hasPointer = false
        judging.pointerExited()
        onLens?(self, nil)
    }

    private func pointerMoved(to point: CGPoint) {
        hasPointer = true
        judging.pointerMoved(to: point)
        onLens?(self, judging.lens.photoPoint)
    }

    /// Shows the following loupe over `point` of the photo, 0 ... 1, where the other photo's shows it; hides it for
    /// nil. The pointer, while it's over this photo, moves its loupe instead.
    func showLens(at point: CGPoint?) {
        guard !hasPointer else { return }
        let frame = judging.placement.photoFrame
        guard let point, frame.width > 0, frame.height > 0 else { return judging.pointerExited() }
        judging.pointerMoved(to: CGPoint(x: frame.minX + point.x * frame.width, y: frame.minY + point.y * frame.height))
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

    /// The image on screen, for the tests.
    var image: CGImage? {
        photo.contents.map { $0 as! CGImage } // swiftlint:disable:this force_cast
    }

    /// The file of the photo shown.
    var url: URL? {
        address?.url
    }

    /// The photo's frame, for the tests.
    var photoFrame: CGRect {
        photo.frame
    }

    /// An edited photo the library renders shows an image without its edit, and is marked so.
    var showsUneditedPreview: Bool {
        guard image != nil, shownEdit == nil, let address, let item = model.comparedItem(address) else { return false }
        return model.editRenders.renders(item)
    }

    // MARK: - Showing a photo

    /// Shows the photo `photo` names at once from what's in memory: its image at the size it's shown, else a smaller
    /// one, the loupe's preview or its thumbnail; what it lacks is asked for.
    func show(_ photo: PhotoAddress?) {
        guard photo != address else { return }
        cancelLoads()
        address = photo
        showsFullPhoto = false
        pixelSize = nil
        guard let photo, let item = model.comparedItem(photo) else {
            setAccessibilityLabel(nil)
            return setImage(nil, edge: 0, edit: nil)
        }
        setAccessibilityLabel(item.title)
        let edge = wantedEdge
        if bounds.width > 1, let image = images.cached(item, edge: edge) {
            setImage(image, edge: edge, edit: images.edit(for: item))
        } else if let standIn = images.standIn(item, below: edge) {
            setImage(standIn.image, edge: 0, edit: standIn.edit)
        } else if let preview = model.previews.cachedPreview(photo) {
            setImage(preview.image, edge: 0, edit: preview.edit)
        } else if let thumbnail = model.thumbnailLoader.cachedThumbnail(item) {
            setImage(thumbnail.image, edge: 0, edit: thumbnail.edit)
        } else {
            setImage(nil, edge: 0, edit: nil)
            let edit = model.editRenders.shownEdit(for: item)
            thumbnailRequest = model.thumbnailLoader.request(item) { [weak self] image in
                guard let self, address == photo, let image else { return }
                thumbnailRequest = nil
                if self.image == nil {
                    setImage(image, edge: 0, edit: edit)
                }
            }
        }
        requestImage()
        if zoom == .actual || model.libraryJudging.magnification != nil {
            loadFullPhoto()
        }
    }

    /// The photo's zoom and the point of it at the middle at 1:1.
    func setZoom(_ zoom: LoupeZoom, focus: CGPoint) {
        guard zoom != self.zoom || focus != self.focus else { return }
        self.zoom = zoom
        self.focus = focus
        if zoom == .actual {
            loadFullPhoto()
        }
        layoutPhoto()
        requestImage()
    }

    /// The photo's edit has been rendered, or its badges' mark may have changed: its image is asked for again.
    func refresh() {
        if showsFullPhoto {
            updateOverlays()
        } else {
            requestImage()
        }
    }

    /// The image at the size the photo is shown, of the edit it's to show, unless it's on screen or asked for.
    private func requestImage() {
        guard let photo = address, let item = model.comparedItem(photo), !showsFullPhoto, bounds.width > 1,
              bounds.height > 1
        else { return }
        let edge = wantedEdge
        let edit = images.edit(for: item)
        guard edge != shownEdge || edit != shownEdit else { return }
        if let image = images.cached(item, edge: edge) {
            cancelRequest()
            return setImage(image, edge: edge, edit: edit)
        }
        guard request?.edge != edge, item.isLocal, !item.isSettling else { return }
        cancelRequest()
        var id: UInt64 = 0
        id = images.request(item, edge: edge) { [weak self] image in
            guard let self, address == photo, request?.id == id else { return }
            request = nil
            guard let image, !showsFullPhoto else { return }
            setImage(image, edge: edge, edit: edit)
        }
        request = (id, edge)
    }

    /// The photo itself, for 1:1: decoded off the main thread at its full size and drawn in the window's colour
    /// space, so the commit that shows it copies it rather than converting it.
    private func loadFullPhoto() {
        guard loading == nil, !showsFullPhoto, let photo = address, let item = model.comparedItem(photo), item.isLocal
        else { return }
        let url = photo.url
        let (engine, scheduler, space) = (model.engine, model.library.scheduler, window?.colorSpace?.cgColorSpace)
        let edge = pixelSize.map { Int(max($0.width, $0.height)) } ?? 1 << 14
        let originals = model.library.needsDownload(url) ? model.originals : nil
        loading = Task { [weak self] in
            // Compare's and Survey's 1:1 of a photo kept in Apple Photos downloads its original first (LIB-60).
            if let originals, await (try? originals.local(url, priority: .open)) == nil {
                if self?.address == photo {
                    self?.loading = nil
                }
                return
            }
            let full = try? await scheduler.run(.onScreen) {
                engine.decodeThumbnail(for: url, maxPixelSize: edge).flatMap { GridThumbnails.drawn($0, in: space) }
            }
            guard let self, address == photo, !Task.isCancelled else { return }
            loading = nil
            guard let full = full ?? nil else { return }
            if pixelSize == nil || CGFloat(full.width) >= (pixelSize?.width ?? 0) {
                pixelSize = CGSize(width: full.width, height: full.height)
            }
            cancelRequest()
            showsFullPhoto = true
            setImage(full, edge: .max, edit: nil)
        }
    }

    private func cancelRequest() {
        if let request {
            images.cancel(request.id)
        }
        request = nil
    }

    private func cancelLoads() {
        cancelRequest()
        thumbnailRequest.map(model.thumbnailLoader.cancel)
        thumbnailRequest = nil
        loading?.cancel()
        loading = nil
    }

    private func setImage(_ image: CGImage?, edge: Int, edit: EditDigest?) {
        let shape = { [pixelSize] (image: CGImage?) in
            LibraryLoupeView.laidOut(pixelSize, image: image).map { $0.width / max($0.height, 1) }
        }
        let (old, new) = (shape(self.image), shape(image))
        let reshaped = if let new {
            old.map { abs($0 - new) > 0.01 } ?? true
        } else {
            false
        }
        photo.contents = image
        shownEdge = image == nil ? 0 : edge
        shownEdit = image == nil ? nil : edit
        layoutPhoto()
        judging.imageChanged()
        if reshaped {
            onReshape?()
        }
    }

    // MARK: - Layout

    /// The photo fitted in the view: the size its image is decoded at.
    private var fitted: CGSize {
        let size = LibraryLoupeView.laidOut(pixelSize, image: image) ?? bounds.size
        guard size.width > 0, size.height > 0 else { return .zero }
        let fit = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: size.width * fit, height: size.height * fit)
    }

    /// Where the photo is at Fit, centred in the view.
    var fittedFrame: CGRect {
        let fitted = fitted
        return CGRect(
            x: (bounds.width - fitted.width) / 2, y: (bounds.height - fitted.height) / 2, width: fitted.width,
            height: fitted.height,
        )
    }

    private var wantedEdge: Int {
        let fitted = fitted
        return Self.edge(forPixels: max(fitted.width, fitted.height) * (window?.backingScaleFactor ?? 2))
    }

    override func layout() {
        super.layout()
        layoutPhoto()
        requestImage()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateOverlays()
    }

    /// The photo's frame: fitted and centred, or at 1:1 with `focus` in the middle, kept covering the view where
    /// it's larger.
    private func layoutPhoto() {
        let size = LibraryLoupeView.laidOut(pixelSize, image: image)
        let frame: CGRect
        if let size, size.width > 0, size.height > 0, zoom == .actual {
            let scale = window?.backingScaleFactor ?? 2
            let shown = CGSize(width: size.width / scale, height: size.height / scale)
            frame = CGRect(
                x: LibraryLoupeView.placed(shown.width, in: bounds.width, focus: focus.x),
                y: LibraryLoupeView.placed(shown.height, in: bounds.height, focus: focus.y), width: shown.width,
                height: shown.height,
            )
        } else {
            frame = size == nil ? CGRect(x: bounds.midX, y: bounds.midY, width: 0, height: 0) : fittedFrame
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        photo.frame = frame
        photo.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
        updateOverlays()
        judging.show(url, edit: shownEdit, pixelSize: pixelSize)
        judging.place(JudgingPlacement(
            photoFrame: frame, bounds: bounds, scale: window?.backingScaleFactor ?? 2, pixels: size,
        ))
    }

    /// The active photo's outline, around what's seen of it, and the mark of an unedited preview in its corner.
    private func updateOverlays() {
        let visible = photo.frame.intersection(bounds)
        let marked = showsUneditedPreview
        let size = GridBadges.Kind.uneditedPreview.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.isHidden = !isActive || visible.isEmpty
        if !outline.isHidden {
            outline.borderColor = LibraryLook.ring
            outline.frame = visible
        }
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
        let states = [isActive ? "active" : nil, marked ? "Unedited preview" : nil].compactMap(\.self)
        setAccessibilityValue((states + judging.spoken).joined(separator: ", "))
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        onPress?(self)
        drag = (convert(event.locationInWindow, from: nil), focus, false)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer { pointerMoved(to: point) }
        guard var drag, zoom == .actual else { return }
        let moved = CGPoint(x: point.x - drag.start.x, y: point.y - drag.start.y)
        if !drag.moved, hypot(moved.x, moved.y) < 3 {
            return
        }
        drag.moved = true
        self.drag = drag
        let size = photo.frame.size
        guard size.width > 0, size.height > 0 else { return }
        onPan?(self, CGPoint(
            x: min(max(drag.focus.x - moved.x / size.width, 0), 1),
            y: min(max(drag.focus.y - moved.y / size.height, 0), 1),
        ))
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil }
        guard let drag, !drag.moved else { return }
        let point = convert(event.locationInWindow, from: nil)
        let frame = photo.frame
        let onPhoto = frame.contains(point) && frame.width > 0 && frame.height > 0
            ? CGPoint(x: (point.x - frame.minX) / frame.width, y: (point.y - frame.minY) / frame.height) : nil
        onClick?(self, onPhoto, event.clickCount)
    }
}
