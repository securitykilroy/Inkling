//
//  FloatingImageAttachment.swift
//  Inkling
//
//  An editor-only attachment. Its tiny inline bounds act as a stable text
//  anchor while PageStackView draws the full image and wraps text around it.
//

import AppKit
import UniformTypeIdentifiers

extension NSAttributedString.Key {
    /// Carries a `FloatingImagePosition` from `RichTextCodec.decode` to the code
    /// that builds `FloatingImageAttachment`s (the editor and the printer). This
    /// attribute lives only in memory — it is never serialized into RTFD.
    nonisolated static let inklingFloatingImagePosition = NSAttributedString.Key("inklingFloatingImagePosition")
    nonisolated static let inklingImportedImagePlacementHint = NSAttributedString.Key("inklingImportedImagePlacementHint")
}

final class FloatingImageAttachment: NSTextAttachment {
    var displaySize: NSSize

    /// The image's fixed page placement, or nil for images that still use the
    /// automatic left-edge placement (legacy files and freshly inserted images
    /// the user hasn't moved yet).
    var position: FloatingImagePosition?
    var importedPlacementHint: ImportedImagePlacementHint?
    /// Plain text shown beneath the image; nil for none. See `ImageCaption`.
    var caption: String?

    /// On-screen pixels per point the display copy is rendered at: Retina's 2×
    /// with headroom for zooming in past 100%.
    private static let displayPixelsPerPoint: CGFloat = 3

    private var cachedDisplayImage: NSImage?
    private var cachedDisplayPixelSize = 0

    /// Holds the source's original image bytes, never re-encoded: see
    /// `ImageAttachmentContent`. Deliberately never assigns `image`, which
    /// would make AppKit replace those bytes with a much larger PNG.
    init(copying source: NSTextAttachment, displaySize: NSSize) {
        self.displaySize = displaySize
        let payload = ImageAttachmentContent.payload(of: source)
        super.init(data: payload?.data, ofType: payload?.typeIdentifier)
        // The visible image is drawn by the page view as an overlay; in the
        // text it is only a near-zero anchor.
        bounds = NSRect(x: 0, y: 0, width: 0.1, height: 0.1)
    }

    required init?(coder: NSCoder) {
        displaySize = .zero
        super.init(coder: coder)
    }

    /// The image for on-screen drawing at `displaySize`, downsampled from the
    /// original so a camera photo doesn't cost a full-resolution bitmap per
    /// image on every scroll frame. Regenerated only when the image has grown
    /// past the resolution of the cached copy.
    var displayImage: NSImage? {
        guard displaySize.width > 0, displaySize.height > 0,
              let data = contents, !data.isEmpty
        else { return nil }
        let needed = Int((max(displaySize.width, displaySize.height) * Self.displayPixelsPerPoint).rounded(.up))
        if let cached = cachedDisplayImage, cachedDisplayPixelSize >= needed {
            cached.size = displaySize
            return cached
        }
        // A little headroom so a live resize doesn't re-render on every step.
        let requested = Int(Double(needed) * 1.25)
        let image = ImageAttachmentContent.displayImage(
            from: data, pointSize: displaySize, maxPixelSize: requested
        ) ?? NSImage(data: data)
        image?.size = displaySize
        cachedDisplayImage = image
        cachedDisplayPixelSize = image == nil ? 0 : requested
        return image
    }

    /// The original, full-resolution image, for printing and export. Decoded
    /// on demand and not cached: it is large and rarely needed.
    var fullImage: NSImage? {
        contents.flatMap(NSImage.init(data:))
    }

    /// The inline anchor is 0.1pt and draws nothing. Without this override
    /// AppKit would decode the full image just to draw that speck.
    override func image(
        forBounds imageBounds: NSRect,
        textContainer: NSTextContainer?,
        characterIndex charIndex: Int
    ) -> NSImage? {
        Self.emptyImage
    }

    private static let emptyImage = NSImage(size: NSSize(width: 1, height: 1))
}
