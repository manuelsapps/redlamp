import AppKit
import QuartzCore
import RedlampDesign
import RedlampDocument
import RedlampEngineAPI
import RedlampLibrary

/// Where a host shows its photo: the photo's frame (larger than the view at 1:1), the view's bounds and its backing
/// scale.
struct JudgingPlacement: Equatable {
    var photoFrame = CGRect.zero
    var bounds = CGRect.zero
    var scale: CGFloat = 2
    /// The size in pixels the host lays the photo out at: an edit's own where it's rendered at full size, else the
    /// shape of the image shown, as an edit's crop or turn makes it, at the photo's long edge. Nil while it's unknown.
    var pixels: CGSize?

    var visible: CGRect {
        photoFrame.intersection(bounds)
    }

    /// Whether the photo is larger than the view, as at 1:1.
    var isZoomed: Bool {
        photoFrame.width > bounds.width + 0.5 || photoFrame.height > bounds.height + 0.5
    }

    /// The part of the photo on screen, 0 ... 1 across and down.
    var visibleRegion: ImageRect? {
        let visible = visible
        guard photoFrame.width > 0, photoFrame.height > 0, !visible.isEmpty else { return nil }
        return ImageRect(
            x: (visible.minX - photoFrame.minX) / photoFrame.width,
            y: (visible.minY - photoFrame.minY) / photoFrame.height,
            width: visible.width / photoFrame.width, height: visible.height / photoFrame.height,
        )
    }

    /// Where a part of the photo, 0 ... 1, lies in the view.
    func rect(of region: ImageRect) -> CGRect {
        CGRect(
            x: photoFrame.minX + region.x * photoFrame.width, y: photoFrame.minY + region.y * photoFrame.height,
            width: region.width * photoFrame.width, height: region.height * photoFrame.height,
        )
    }
}

/// The judging tools drawn over one photo in the Library loupe or Compare (LIB-38). Its host shows the photo, and
/// tells the overlay which photo it is, which edit it shows and where; the overlay asks for what the tools that are
/// on need, the host's photo staying on screen meanwhile, and draws each as it comes:
///
/// - **Sensor clipping**: Develop's marks, from the raw through `SensorClipping`, over the whole photo at the size
///   it's shown, and at 1:1 over the part on screen, rendered for it once a pan settles.
/// - **The raw histogram**: each channel's clipped share, from the same render, in the photo's top right corner.
/// - **Focus peaking**: `PeakingCache`'s mask, read from the photo's largest embedded preview, or from the render
///   of its edit when that's shown; pooled to the size shown at fit, at its full size at 1:1.
/// - **The AF point**: `AFPointCache`'s areas, through the edit's crop and turns when an edit is shown.
/// - **The following loupe** (`JudgingLens`), with the tools inside.
@MainActor
final class JudgingOverlay {
    /// The longest edge sensor clipping renders the whole photo at: a 5K display's loupe.
    static let longestMarks = 3072
    /// How long a pan rests before the part on screen is rendered with its marks, and the pointer before the part
    /// the following loupe shows is.
    static let settle = Duration.milliseconds(150)
    static let lensSettle = Duration.milliseconds(80)

    private unowned let model: EditorModel
    /// The view the host is part of.
    private let view: LibraryView
    private let clipping = CALayer()
    private let clippingRegion = CALayer()
    private let peaking = CALayer()
    private let afPoints = CAShapeLayer()
    let histogram = RawHistogramView()
    let lens: JudgingLens

    private(set) var url: URL?
    /// The edit the host shows, nil for the photo's embedded preview or the photo itself.
    private(set) var edit: EditDigest?
    /// The photo's size in pixels upright, which AF points and the lens count in.
    private(set) var pixelSize: CGSize?
    private(set) var placement = JudgingPlacement()
    private(set) var marks: ClippingMarks?
    private(set) var regionMarks: ClippingMarks?
    private(set) var peakingEntry: PeakingCache.Entry?
    private(set) var points: AFPoints?
    /// What's been asked for the photo shown, each once whether it's found or not: its AF point, its peaking, and
    /// the photo sensor clipping couldn't read.
    private var pointsAsked: URL?
    private var peakingAsked: ShownPhoto?
    /// The photo kept in Apple Photos whose original downloads for its peaking (LIB-60).
    private var peakingDownload: URL?
    private var clippingFailed: ShownPhoto?
    /// The recipe of the edit shown, read from its sidecar for sensor clipping and the AF point.
    private var recipe: (edit: EditDigest, recipe: EditRecipe?)?
    private var clippingTask: Task<Void, Never>?
    private var regionTask: Task<Void, Never>?
    private var regionTaskRegion: ImageRect?
    private var recipeTask: Task<EditRecipe?, Never>?
    /// The photo shown before this one, which says which way the photos are being stepped through.
    private var previousURL: URL?
    private var tracker: Tracker?
    /// The image the host shows, which the lens magnifies and focus peaking reads when it's an edit's render.
    var shownImage: () -> CGImage? = { nil }
    private weak var host: NSView?

    /// The window's colour space, which the tools' images are made in.
    private var colorSpace: CGColorSpace? {
        host?.window?.colorSpace?.cgColorSpace
    }

    /// Overlays came in: the host's accessibility and tests hear of it.
    var onChange: (() -> Void)?

    init(model: EditorModel, view: LibraryView) {
        self.model = model
        self.view = view
        lens = JudgingLens()
        for layer in [clipping, clippingRegion, peaking, afPoints] {
            layer.actions = LibraryGridCell.noActions
            layer.isHidden = true
        }
        for layer in [clipping, clippingRegion, peaking] {
            layer.contentsGravity = .resize
            layer.magnificationFilter = .nearest
        }
        afPoints.fillColor = nil
        afPoints.lineWidth = 1.5
        afPoints.shadowColor = .black
        afPoints.shadowOpacity = 0.8
        afPoints.shadowRadius = 1.5
        afPoints.shadowOffset = .zero
        histogram.isHidden = true
    }

    /// Puts the overlay's layers over `photo`, and the histogram and the lens over everything, in `host`.
    func install(in host: NSView, above photo: CALayer) {
        self.host = host
        var below = photo
        for layer in [clipping, clippingRegion, peaking, afPoints] {
            host.layer?.insertSublayer(layer, above: below)
            below = layer
        }
        host.addSubview(histogram)
        host.layer?.addSublayer(lens.layer)
    }

    /// Follows the tools being turned on and off while the host is in a window.
    func start() {
        tracker?.cancel()
        tracker = Tracker { [weak self] in self?.follow() }
    }

    /// Reads every setting the tools follow, whatever `refresh` reads of them, so a change to any brings it again.
    private func follow() {
        let judging = model.libraryJudging
        _ = model.showRawClipping
        _ = judging.showsHistogram
        _ = judging.showsPeaking
        _ = judging.showsAFPoints
        _ = judging.magnification
        _ = model.module
        _ = model.libraryView
        refresh()
    }

    func stop() {
        tracker?.cancel()
        tracker = nil
        cancelRequests()
    }

    /// The photo shown and the edit it's shown with.
    private var shownPhoto: ShownPhoto? {
        url.map { ShownPhoto(url: $0, edit: edit) }
    }

    /// Whether the host's view is the one Library shows.
    private var isShown: Bool {
        model.module == .library && model.libraryView == view
    }

    // MARK: - The photo shown

    /// The host shows `url`'s photo, with `edit` or as the camera rendered it, `pixelSize` pixels upright.
    func show(_ url: URL?, edit: EditDigest?, pixelSize: CGSize?) {
        let samePhoto = url == self.url
        if samePhoto, edit == self.edit, pixelSize == self.pixelSize {
            return
        }
        if !samePhoto {
            previousURL = self.url
            points = nil
            pointsAsked = nil
            peakingEntry = nil
            histogram.state = .reading
        }
        if !samePhoto || edit != self.edit {
            marks = nil
            regionMarks = nil
            recipe = nil
            recipeTask?.cancel()
            recipeTask = nil
            clippingTask?.cancel()
            clippingTask = nil
            clippingFailed = nil
            regionTask?.cancel()
            regionTask = nil
            regionTaskRegion = nil
            lens.marksTask?.cancel()
            lens.marksTask = nil
            lens.regionMarks = nil
            peakingAsked = nil
            if samePhoto {
                peakingEntry = nil
            }
        }
        self.url = url
        self.edit = edit
        self.pixelSize = pixelSize
        refresh()
    }

    /// The host laid its photo out again.
    func place(_ placement: JudgingPlacement) {
        guard placement != self.placement else { return }
        let resized = placement.photoFrame.size != self.placement.photoFrame.size
        self.placement = placement
        if model.showRawClipping, isShown {
            if resized {
                requestMarks()
            }
            requestRegionMarks()
        }
        layoutLayers()
    }

    /// Asks for what the tools that are on need, and shows and hides their layers.
    func refresh() {
        let judging = model.libraryJudging
        let shown = isShown && url != nil
        let clipped = shown && model.showRawClipping
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clipping.isHidden = !clipped || marks?.image == nil
        clippingRegion.isHidden = !clipped || regionMarks?.image == nil
        peaking.isHidden = !(shown && judging.showsPeaking) || peakingEntry == nil
        afPoints.isHidden = !(shown && judging.showsAFPoints) || points == nil
        histogram.isHidden = !(shown && judging.showsHistogram)
        CATransaction.commit()
        if !(shown && judging.magnification != nil) {
            lens.hide()
        }
        guard shown else {
            cancelRequests()
            spokenChanged()
            return
        }
        if model.showRawClipping || judging.showsHistogram {
            requestMarks()
            requestRegionMarks()
        } else {
            judging.clipping?.forget(self)
        }
        if judging.showsPeaking {
            requestPeaking()
        }
        if judging.showsAFPoints {
            requestAFPoints()
        }
        layoutLayers()
        spokenChanged()
    }

    private func cancelRequests() {
        clippingTask?.cancel()
        clippingTask = nil
        regionTask?.cancel()
        regionTask = nil
        regionTaskRegion = nil
        lens.marksTask?.cancel()
        lens.marksTask = nil
        model.libraryJudging.clipping?.forget(self)
    }

    // MARK: - Sensor clipping and the histogram

    private var sensorClipping: SensorClipping {
        let judging = model.libraryJudging
        if let clipping = judging.clipping {
            return clipping
        }
        let made = SensorClipping { [weak model] in model?.makeWorkerEngine?().map(WorkerClippingEngine.init) }
        judging.clipping = made
        return made
    }

    /// The size the whole photo's marks are rendered at: as it's shown at fit, at most `longestMarks` long.
    private var wholeMarksSize: PixelSize? {
        let frame = placement.isZoomed ? fittedFrame : placement.photoFrame
        let long = max(frame.width, frame.height) * placement.scale
        guard long >= 1 else { return nil }
        let scale = min(1, Double(Self.longestMarks) / Double(long))
        return PixelSize(
            width: max(1, Int((frame.width * placement.scale * scale).rounded())),
            height: max(1, Int((frame.height * placement.scale * scale).rounded())),
        )
    }

    /// The photo fitted in the host's bounds.
    private var fittedFrame: CGRect {
        let size = placement.photoFrame.size
        guard size.width > 0, size.height > 0 else { return .zero }
        let fit = min(placement.bounds.width / size.width, placement.bounds.height / size.height, 1)
        return CGRect(x: 0, y: 0, width: size.width * fit, height: size.height * fit)
    }

    private func requestMarks() {
        guard let url, clippingTask == nil, let size = wholeMarksSize else { return }
        if let marks, marks.region == nil, marks.size.longEdge >= size.longEdge * 3 / 4 {
            return
        }
        guard SupportedFormats.isRaw(url) else {
            histogram.state = .notRaw
            return
        }
        let photo = ShownPhoto(url: url, edit: edit)
        guard clippingFailed != photo else { return }
        let clipping = sensorClipping
        clipping.prefetch(model.workingSet(around: url, comingFrom: previousURL), for: self)
        let space = colorSpace
        clippingTask = Task { [weak self] in
            guard let self, let recipe = await editRecipe() else { return }
            let marks: ClippingMarks?
            do {
                marks = try await clipping.marks(.init(url: url, recipe: recipe, size: size, region: nil), in: space)
            } catch {
                // Cancelled: the next refresh asks again.
                if !Task.isCancelled, shownPhoto == photo {
                    clippingTask = nil
                }
                return
            }
            guard !Task.isCancelled, shownPhoto == photo else { return }
            clippingTask = nil
            guard let marks else {
                clippingFailed = photo
                histogram.state = .unreadable
                return
            }
            self.marks = marks
            histogram.state = .read(marks.reading)
            refresh()
        }
    }

    /// At 1:1, the part on screen rendered with its marks once a pan rests.
    private func requestRegionMarks() {
        guard let url, model.showRawClipping, placement.isZoomed, SupportedFormats.isRaw(url),
              clippingFailed != shownPhoto, let region = placement.visibleRegion else {
            regionTask?.cancel()
            regionTask = nil
            regionTaskRegion = nil
            return
        }
        if regionMarks?.region == region || (regionTask != nil && regionTaskRegion == region) {
            return
        }
        regionTask?.cancel()
        regionTaskRegion = region
        let visible = placement.visible
        let size = PixelSize(
            width: max(1, Int((visible.width * placement.scale).rounded())),
            height: max(1, Int((visible.height * placement.scale).rounded())),
        )
        let clipping = sensorClipping
        let space = colorSpace
        regionTask = Task { [weak self] in
            try? await Task.sleep(for: Self.settle)
            guard let self, !Task.isCancelled, let recipe = await editRecipe() else { return }
            let marks = try? await clipping.marks(
                .init(url: url, recipe: recipe, size: size, region: region),
                in: space,
            )
            guard !Task.isCancelled, self.url == url, regionTaskRegion == region else { return }
            regionTask = nil
            regionTaskRegion = nil
            guard let marks = marks ?? nil else { return }
            regionMarks = marks
            refresh()
        }
    }

    /// The recipe the photo is shown with: the edit's, read from its sidecar, or as shot.
    private func editRecipe() async -> EditRecipe? {
        guard let url, let edit else { return EditRecipe() }
        if let recipe, recipe.edit == edit {
            return recipe.recipe
        }
        if recipeTask == nil {
            let (sidecars, scheduler) = (model.library.sidecars, model.library.scheduler)
            recipeTask = Task {
                let loaded = try? await scheduler.run(.onScreen) { sidecars.store(for: url).load(for: url)?.recipe }
                return loaded ?? nil
            }
        }
        let loaded = await recipeTask?.value
        guard self.url == url, self.edit == edit else { return nil }
        recipe = (edit, loaded)
        return loaded ?? EditRecipe()
    }

    // MARK: - Focus peaking and the AF point

    /// The host's image changed: an edit's render, larger than the thumbnail shown first, can be read for peaking.
    func imageChanged() {
        if edit != nil, peakingEntry == nil, model.libraryJudging.showsPeaking, isShown {
            requestPeaking()
        }
        lens.update(with: self)
    }

    /// The smallest render of an edit focus peaking reads: a thumbnail would mark every edge.
    private static let smallestPeakingSource = 1024

    private func requestPeaking() {
        guard let url, peakingEntry == nil else { return }
        let key = ShownPhoto(url: url, edit: edit)
        guard peakingAsked != key else { return }
        let source: @Sendable () -> CGImage?
        if edit != nil {
            guard let shown = shownImage(), max(shown.width, shown.height) >= Self.smallestPeakingSource else { return }
            source = { shown }
        } else {
            if model.library.needsDownload(url) {
                // Peaking reads the photo itself: one kept in Apple Photos downloads its original first (LIB-60).
                guard peakingDownload != url, let originals = model.originals else { return }
                peakingDownload = url
                Task { [weak self] in
                    let arrived = await (try? originals.local(url, priority: .open)) != nil
                    guard let self, peakingDownload == url else { return }
                    peakingDownload = nil
                    if arrived, self.url == url, model.libraryJudging.showsPeaking {
                        requestPeaking()
                    }
                }
                return
            }
            let engine = model.engine
            source = { engine.decodeThumbnail(for: url, maxPixelSize: FocusPeaking.longestEdge) }
        }
        peakingAsked = key
        let frame = placement.isZoomed ? fittedFrame : placement.photoFrame
        let longEdge = Int((max(frame.width, frame.height) * placement.scale).rounded())
        model.libraryJudging.peaking.request(
            key, scheduler: model.library.scheduler, shownLongEdge: longEdge, space: colorSpace, source: source,
        ) { [weak self] entry in
            guard let self, self.url == url, edit == key.edit else { return }
            peakingEntry = entry
            refresh()
        }
    }

    /// Asks once for the photo's AF point, once its size is known: Fujifilm's and SubjectArea's are counted in it.
    private func requestAFPoints() {
        guard let url, pointsAsked != url, let size = pixelSize else { return }
        pointsAsked = url
        model.libraryJudging.afPoints
            .request(url, imageSize: size, scheduler: model.library.scheduler) { [weak self] found in
                guard let self, self.url == url else { return }
                points = found
                if edit != nil {
                    Task { [weak self] in
                        _ = await self?.editRecipe()
                        self?.layoutLayers()
                    }
                }
                refresh()
            }
    }

    /// The AF areas in the photo as shown, 0 ... 1: through the edit's crop and turns when an edit is shown.
    var shownAreas: [AFPoints.Area] {
        guard let points else { return [] }
        let upright = points.upright
        guard edit != nil else { return upright }
        guard let recipe = recipe?.recipe, let pixelSize, pixelSize.width > 0, pixelSize.height > 0 else { return [] }
        let map = GeometryMap(
            recipe: recipe, imageSize: PixelSize(width: Int(pixelSize.width), height: Int(pixelSize.height)), lens: nil,
        )
        guard !map.isIdentity else { return upright }
        return upright.compactMap { area in
            let corners = [
                (area.rect.minX, area.rect.minY), (area.rect.maxX, area.rect.minY), (area.rect.minX, area.rect.maxY),
                (area.rect.maxX, area.rect.maxY),
            ].compactMap { map.outputPoint(SIMD2<Double>(Double($0.0), Double($0.1))) }
            guard corners.count == 4 else { return nil }
            let xs = corners.map(\.x)
            let ys = corners.map(\.y)
            let rect = CGRect(
                x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0),
                height: (ys.max() ?? 0) - (ys.min() ?? 0),
            )
            guard rect.maxX > 0, rect.minX < 1, rect.maxY > 0, rect.minY < 1 else { return nil }
            return AFPoints.Area(rect: rect, inFocus: area.inFocus)
        }
    }

    /// The AF areas drawn in a frame of `size`: rectangles, at least 16 points across, or a cross for a point.
    static func path(of areas: [AFPoints.Area], in size: CGSize, inFocus: Bool) -> CGPath {
        let path = CGMutablePath()
        for area in areas where area.inFocus == inFocus {
            let rect = CGRect(
                x: area.rect.minX * size.width, y: area.rect.minY * size.height, width: area.rect.width * size.width,
                height: area.rect.height * size.height,
            )
            if area.rect.width == 0, area.rect.height == 0 {
                let (x, y) = (rect.midX, rect.midY)
                path.addRect(CGRect(x: x - 12, y: y - 12, width: 24, height: 24))
                path.move(to: CGPoint(x: x - 5, y: y))
                path.addLine(to: CGPoint(x: x + 5, y: y))
                path.move(to: CGPoint(x: x, y: y - 5))
                path.addLine(to: CGPoint(x: x, y: y + 5))
            } else {
                let width = max(rect.width, 16)
                let height = max(rect.height, 16)
                path.addRect(CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height))
            }
        }
        return path
    }

    // MARK: - Layout

    private func layoutLayers() {
        let frame = placement.photoFrame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clipping.frame = frame
        clipping.contents = marks?.image
        if let regionMarks, let region = regionMarks.region {
            clippingRegion.frame = placement.rect(of: region)
            clippingRegion.contents = regionMarks.image
        }
        peaking.frame = frame
        let longEdge = Int((max(frame.width, frame.height) * placement.scale).rounded())
        if let entry = peakingEntry {
            if let image = entry.image(forLongEdge: longEdge) {
                peaking.contents = image
            } else {
                // The nearest image there is, until the mask's pooled for this size.
                peaking.contents = entry.shown?.image ?? entry.image
                model.libraryJudging.peaking.pool(entry, toLongEdge: longEdge, scheduler: model.library.scheduler) {
                    [weak self] in self?.layoutLayers()
                }
            }
        } else {
            peaking.contents = nil
        }
        afPoints.frame = frame
        let areas = shownAreas
        // Areas chosen where the camera didn't focus are drawn dashed, and only when it focused nowhere.
        let focused = areas.contains(where: \.inFocus)
        afPoints.path = Self.path(of: areas, in: frame.size, inFocus: focused)
        afPoints.strokeColor = CGColor(gray: 1, alpha: 0.95)
        afPoints.lineDashPattern = focused ? nil : [4, 3]
        // The photo's frame is empty, or off the view, before its size is known.
        let visible = placement.visible.isEmpty ? placement.bounds : placement.visible
        histogram.frame = CGRect(
            x: max(visible.maxX - RawHistogramView.size.width - 8, visible.minX + 8), y: visible.minY + 8,
            width: RawHistogramView.size.width, height: RawHistogramView.size.height,
        )
        CATransaction.commit()
        lens.update(with: self)
    }

    // MARK: - What's drawn

    /// Which layers are on screen: sensor clipping over the whole photo and over the part shown, peaking, the AF
    /// point and the histogram.
    var drawn: (clipping: Bool, region: Bool, peaking: Bool, afPoints: Bool, histogram: Bool) {
        (!clipping.isHidden, !clippingRegion.isHidden, !peaking.isHidden, !afPoints.isHidden, !histogram.isHidden)
    }

    /// What's drawn over the photo, for VoiceOver and the regression suite: "sensor clipping marked", "nothing
    /// clipped on the sensor", "no sensor data" for a photo that isn't raw or "the raw couldn't be read", then "focus
    /// peaking", "AF point" and "loupe at 400%", each once it's on screen. The host adds them to its accessibility
    /// value.
    var spoken: [String] {
        let drawn = drawn
        var parts: [String] = []
        if isShown, model.showRawClipping, let url {
            if !SupportedFormats.isRaw(url) {
                parts.append("no sensor data")
            } else if let marks {
                parts.append(drawn.clipping || drawn.region || marks.image != nil
                    ? "sensor clipping marked" : "nothing clipped on the sensor")
            } else if clippingFailed == shownPhoto {
                parts.append("the raw couldn't be read")
            }
        }
        if drawn.peaking {
            parts.append("focus peaking")
        }
        if drawn.afPoints {
            parts.append("AF point")
        }
        if lens.isShown, let magnification = model.libraryJudging.magnification {
            parts.append("loupe at \(magnification.title)")
        }
        return parts
    }

    private var lastSpoken: [String] = []

    /// Tells the host when what's drawn has changed.
    private func spokenChanged() {
        let spoken = spoken
        guard spoken != lastSpoken else { return }
        lastSpoken = spoken
        onChange?()
    }

    var clippingFrame: CGRect {
        clipping.frame
    }

    /// The AF areas' outline, in the host's coordinates.
    var afOutline: CGRect? {
        afPoints.path.map { $0.boundingBoxOfPath.offsetBy(dx: afPoints.frame.minX, dy: afPoints.frame.minY) }
    }

    // MARK: - The following loupe

    /// The pointer moved over the host, at `point` in its coordinates.
    func pointerMoved(to point: CGPoint) {
        let lensShown = lens.isShown
        defer {
            if lens.isShown != lensShown {
                spokenChanged()
            }
        }
        guard isShown, let magnification = model.libraryJudging.magnification, url != nil else {
            lens.hide()
            return
        }
        lens.follow(point, overlay: self, magnification: magnification)
        requestLensMarks()
    }

    func pointerExited() {
        guard lens.isShown else { return }
        lens.hide()
        spokenChanged()
    }

    /// The part of the photo the lens shows rendered with its marks, once the pointer rests.
    private func requestLensMarks() {
        guard let url, model.showRawClipping, SupportedFormats.isRaw(url), clippingFailed != shownPhoto,
              let region = lens.region, let size = lens.regionPixels else { return }
        let clipping = sensorClipping
        let space = colorSpace
        lens.marksTask?.cancel()
        lens.marksTask = Task { [weak self] in
            try? await Task.sleep(for: Self.lensSettle)
            guard let self, !Task.isCancelled, let recipe = await editRecipe() else { return }
            let marks = try? await clipping.marks(
                .init(url: url, recipe: recipe, size: size, region: region),
                in: space,
            )
            guard !Task.isCancelled, self.url == url, let marks = marks ?? nil else { return }
            lens.regionMarks = marks
            lens.update(with: self)
        }
    }

    /// What the lens magnifies: the host's image and the tools' images and areas.
    var lensContent: JudgingLens.Content {
        JudgingLens.Content(
            photo: shownImage(),
            marks: model.showRawClipping ? marks?.image : nil,
            peaking: model.libraryJudging.showsPeaking ? peakingEntry?.image : nil,
            areas: model.libraryJudging.showsAFPoints ? shownAreas : [],
            showsClipping: model.showRawClipping,
        )
    }
}

/// The following loupe (LIB-38): a lens over the photo, centred on the pointer, showing the photo under it at 100,
/// 200 or 400% with the judging tools that are on. Moving it moves one layer, so it keeps up with the pointer within
/// a frame; sensor clipping's marks for the part it shows are rendered once the pointer rests, the whole photo's
/// shown magnified meanwhile.
@MainActor
final class JudgingLens {
    static let size = CGSize(width: 260, height: 260)

    struct Content {
        var photo: CGImage?
        var marks: CGImage?
        var peaking: CGImage?
        var areas: [AFPoints.Area]
        var showsClipping: Bool
    }

    let layer = CALayer()
    /// The photo magnified, its tools inside, moved under the lens as the pointer moves.
    private let content = CALayer()
    private let photo = CALayer()
    private let clipping = CALayer()
    private let clippingRegion = CALayer()
    private let peaking = CALayer()
    private let afPoints = CAShapeLayer()
    /// The part of the photo the lens shows, and its size in the photo's pixels.
    private(set) var region: ImageRect?
    private(set) var regionPixels: PixelSize?
    var regionMarks: ClippingMarks?
    var marksTask: Task<Void, Never>?
    /// Where the lens is, in the host, and the photo point under its middle; nil while it's hidden.
    private(set) var center: CGPoint?
    private(set) var photoPoint: CGPoint?
    private var magnification = LoupeMagnification.double
    /// The time the last move took, for the tests.
    private(set) var lastMove = Duration.zero

    init() {
        layer.actions = LibraryGridCell.noActions
        layer.masksToBounds = true
        layer.cornerRadius = 10
        layer.borderWidth = 1.5
        layer.borderColor = CGColor(gray: 1, alpha: 0.7)
        layer.backgroundColor = CGColor(gray: 0.1, alpha: 1)
        layer.isHidden = true
        layer.zPosition = 10
        for sublayer in [content, photo, clipping, clippingRegion, peaking, afPoints] {
            sublayer.actions = LibraryGridCell.noActions
        }
        for sublayer in [photo, clipping, clippingRegion, peaking] {
            sublayer.contentsGravity = .resize
            sublayer.magnificationFilter = .nearest
        }
        afPoints.fillColor = nil
        afPoints.lineWidth = 1.5
        afPoints.strokeColor = CGColor(gray: 1, alpha: 0.95)
        afPoints.shadowColor = .black
        afPoints.shadowOpacity = 0.8
        afPoints.shadowRadius = 1.5
        afPoints.shadowOffset = .zero
        for sublayer in [photo, clipping, clippingRegion, peaking, afPoints] {
            content.addSublayer(sublayer)
        }
        layer.addSublayer(content)
    }

    var isShown: Bool {
        !layer.isHidden
    }

    /// The photo magnified, in the lens's points, for the tests.
    var magnified: CGSize {
        content.bounds.size
    }

    func hide() {
        marksTask?.cancel()
        marksTask = nil
        center = nil
        photoPoint = nil
        guard !layer.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.isHidden = true
        CATransaction.commit()
    }

    /// Centres the lens on `point`, showing the photo under it at `magnification`; hidden off the photo.
    func follow(_ point: CGPoint, overlay: JudgingOverlay, magnification: LoupeMagnification) {
        let started = ContinuousClock.now
        defer { lastMove = .now - started }
        let frame = overlay.placement.photoFrame
        guard frame.width > 0, frame.height > 0, frame.contains(point), overlay.placement.bounds.contains(point) else {
            return hide()
        }
        let reshaped = magnification != self.magnification || layer.isHidden
        self.magnification = magnification
        center = point
        photoPoint = CGPoint(x: (point.x - frame.minX) / frame.width, y: (point.y - frame.minY) / frame.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = CGRect(
            x: point.x - Self.size.width / 2, y: point.y - Self.size.height / 2, width: Self.size.width,
            height: Self.size.height,
        )
        if reshaped {
            fill(with: overlay)
        }
        position(overlay)
        layer.isHidden = false
        CATransaction.commit()
    }

    /// The tools changed, or another photo came in: what the lens shows is drawn again where it is.
    func update(with overlay: JudgingOverlay) {
        guard !layer.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill(with: overlay)
        position(overlay)
        CATransaction.commit()
    }

    /// The photo magnified, in points: its pixels as the host lays it out times the magnification, over the screen's
    /// scale.
    private func magnifiedSize(_ overlay: JudgingOverlay) -> CGSize {
        let placement = overlay.placement
        let pixels = placement.pixels ?? overlay.pixelSize
            ?? overlay.shownImage().map { CGSize(width: $0.width, height: $0.height) }
            ?? CGSize(
                width: placement.photoFrame.width * placement.scale,
                height: placement.photoFrame.height * placement.scale,
            )
        let factor = CGFloat(magnification.rawValue) / placement.scale
        return CGSize(width: pixels.width * factor, height: pixels.height * factor)
    }

    private func fill(with overlay: JudgingOverlay) {
        let size = magnifiedSize(overlay)
        let bounds = CGRect(origin: .zero, size: size)
        let shown = overlay.lensContent
        content.bounds = bounds
        photo.frame = bounds
        photo.contents = shown.photo
        clipping.frame = bounds
        clipping.contents = shown.marks
        clipping.isHidden = shown.marks == nil
        if shown.showsClipping, let regionMarks, let region = regionMarks.region {
            clippingRegion.frame = CGRect(
                x: region.x * size.width, y: region.y * size.height, width: region.width * size.width,
                height: region.height * size.height,
            )
            clippingRegion.contents = regionMarks.image
            clippingRegion.isHidden = false
        } else {
            clippingRegion.isHidden = true
        }
        peaking.frame = bounds
        peaking.contents = shown.peaking
        peaking.isHidden = shown.peaking == nil
        afPoints.frame = bounds
        let focused = shown.areas.contains(where: \.inFocus)
        afPoints.path = JudgingOverlay.path(of: shown.areas, in: size, inFocus: focused)
        afPoints.lineDashPattern = focused ? nil : [4, 3]
    }

    private func position(_ overlay: JudgingOverlay) {
        guard let photoPoint else { return }
        let size = magnifiedSize(overlay)
        content.position = CGPoint(
            x: Self.size.width / 2 + (0.5 - photoPoint.x) * size.width,
            y: Self.size.height / 2 + (0.5 - photoPoint.y) * size.height,
        )
        guard size.width > 0, size.height > 0 else { return }
        let extent = CGSize(width: Self.size.width / size.width, height: Self.size.height / size.height)
        region = ImageRect(
            x: min(max(photoPoint.x - extent.width / 2, 0), 1), y: min(max(photoPoint.y - extent.height / 2, 0), 1),
            width: min(extent.width, 1), height: min(extent.height, 1),
        )
        let scale = overlay.placement.scale / CGFloat(magnification.rawValue)
        regionPixels = PixelSize(
            width: max(1, Int((Self.size.width * scale).rounded())),
            height: max(1, Int((Self.size.height * scale).rounded())),
        )
    }
}
