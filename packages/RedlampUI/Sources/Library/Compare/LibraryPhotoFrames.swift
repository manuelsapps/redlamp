import AppKit

/// The photos the loupe, Compare and Survey show in a window, for the regression suite: where each is drawn and the
/// image drawn there, found by the identifier its view carries (`library.loupe`, `library.compare.select`,
/// `survey.<name>`, and a version's `survey.<name>:<version name>`).
@_spi(Harness) public enum LibraryPhotoFrames {
    /// The views read each photo's size from its own header, as they do for a folder the library hasn't indexed yet,
    /// which the library takes over before a check could find it listed.
    @MainActor public static var readsHeaders = false

    public struct Shown: Sendable, Equatable, CustomStringConvertible {
        /// Where the photo is drawn in its view, in points.
        public let frame: CGRect
        /// The image drawn there, in pixels.
        public let image: CGSize?
        /// The photo's size in pixels as the view has it, from the index or the photo's header.
        public let pixelSize: CGSize?
        /// The image is the library's render of the photo's edit.
        public let showsEdit: Bool
        /// At 1:1: the image is at the photo's full size, the photo itself, or with `showsEdit` its edit rendered at
        /// full size.
        public let showsFullPhoto: Bool

        public var description: String {
            func size(_ size: CGSize?) -> String {
                size.map { "\(Int($0.width.rounded())) × \(Int($0.height.rounded()))" } ?? "none"
            }
            let full = !showsFullPhoto ? "" : showsEdit ? " at full size" : ", the photo itself"
            return "drawn at \(size(frame.size)) points, the image \(size(image)) pixels, the photo \(size(pixelSize))"
                + (showsEdit ? ", its edit" : "") + full
        }
    }

    @MainActor public static func shown(_ identifier: String, in window: NSWindow) -> Shown? {
        func search(_ view: NSView) -> Shown? {
            guard !view.isHidden, view.alphaValue > 0 else { return nil }
            if view.accessibilityIdentifier() == identifier {
                if let loupe = view as? LibraryLoupeView {
                    return Shown(
                        frame: loupe.photoFrame, image: loupe.image.map(size), pixelSize: loupe.pixelSize,
                        showsEdit: loupe.shownEdit != nil, showsFullPhoto: loupe.showsFullPhoto,
                    )
                }
                if let photo = view as? ComparePhotoView {
                    return Shown(
                        frame: photo.photoFrame, image: photo.image.map(size), pixelSize: photo.pixelSize,
                        showsEdit: photo.shownEdit != nil, showsFullPhoto: photo.showsFullPhoto,
                    )
                }
            }
            return view.subviews.lazy.compactMap(search).first
        }
        return (window.contentView?.superview ?? window.contentView).flatMap(search)
    }

    private static func size(_ image: CGImage) -> CGSize {
        CGSize(width: image.width, height: image.height)
    }
}
