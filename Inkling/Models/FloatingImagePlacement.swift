//
//  FloatingImagePlacement.swift
//  Inkling
//
//  Pure geometry for a floating image that is fixed on a page. Positions are
//  expressed in page-local paper coordinates (points from the page's top-left
//  paper corner, y increasing downward to match the flipped text views). The
//  same math is shared by the on-screen editor and the printer so an image
//  lands identically in both. UI-framework-free so it can be unit tested.
//

import CoreGraphics

/// A floating image's fixed placement: which page it lives on, and the top-left
/// corner of the image in that page's paper coordinates.
nonisolated struct FloatingImagePosition: Equatable {
    var page: Int
    var origin: CGPoint
}

nonisolated enum ImportedImageReference: String, Codable, Equatable {
    case page
    case margin
    case column
    case character
    case paragraph
    case line
}

nonisolated enum ImportedImageAlignment: String, Codable, Equatable {
    case start
    case center
    case end
}

/// A Word anchor's relative placement. This remains tied to the attachment's
/// text anchor until the user moves or resizes the image in Inkling.
nonisolated struct ImportedImagePlacementHint: Codable, Equatable {
    var horizontalReference: ImportedImageReference
    var horizontalAlignment: ImportedImageAlignment?
    var horizontalOffset: Double?
    var verticalReference: ImportedImageReference
    var verticalAlignment: ImportedImageAlignment?
    var verticalOffset: Double?
}

/// Which vertical guide a dragged image snapped to, for drawing the guide line.
nonisolated enum HorizontalGuide: Equatable {
    case left, center, right
}

enum FloatingImagePlacement {

    static func approximatedOrigin(
        for hint: ImportedImagePlacementHint,
        anchorLineRect: CGRect,
        imageSize: CGSize,
        paperSize: CGSize,
        leftMargin: CGFloat,
        topMargin: CGFloat,
        contentWidth: CGFloat,
        contentHeight: CGFloat
    ) -> CGPoint {
        let horizontal = referenceFrame(
            hint.horizontalReference,
            anchorLineRect: anchorLineRect,
            paperLength: paperSize.width,
            marginOrigin: leftMargin,
            contentLength: contentWidth,
            isVertical: false
        )
        let vertical = referenceFrame(
            hint.verticalReference,
            anchorLineRect: anchorLineRect,
            paperLength: paperSize.height,
            marginOrigin: topMargin,
            contentLength: contentHeight,
            isVertical: true
        )
        let origin = CGPoint(
            x: resolvedCoordinate(
                frame: horizontal,
                itemLength: imageSize.width,
                alignment: hint.horizontalAlignment,
                offset: hint.horizontalOffset
            ),
            y: resolvedCoordinate(
                frame: vertical,
                itemLength: imageSize.height,
                alignment: hint.verticalAlignment,
                offset: hint.verticalOffset
            )
        )
        return clampedOrigin(origin, imageSize: imageSize, paperSize: paperSize)
    }

    private static func referenceFrame(
        _ reference: ImportedImageReference,
        anchorLineRect: CGRect,
        paperLength: CGFloat,
        marginOrigin: CGFloat,
        contentLength: CGFloat,
        isVertical: Bool
    ) -> (origin: CGFloat, length: CGFloat) {
        switch reference {
        case .page:
            return (0, paperLength)
        case .margin, .column:
            return (marginOrigin, contentLength)
        case .character, .paragraph, .line:
            return isVertical
                ? (marginOrigin + anchorLineRect.minY, anchorLineRect.height)
                : (marginOrigin + anchorLineRect.minX, anchorLineRect.width)
        }
    }

    private static func resolvedCoordinate(
        frame: (origin: CGFloat, length: CGFloat),
        itemLength: CGFloat,
        alignment: ImportedImageAlignment?,
        offset: Double?
    ) -> CGFloat {
        if let offset {
            return frame.origin + CGFloat(offset)
        }
        switch alignment {
        case .center:
            return frame.origin + (frame.length - itemLength) / 2
        case .end:
            return frame.origin + frame.length - itemLength
        case .start, nil:
            return frame.origin
        }
    }

    /// Keep the whole image within the paper. If the image is larger than the
    /// paper on an axis, that axis clamps to 0.
    static func clampedOrigin(
        _ origin: CGPoint,
        imageSize: CGSize,
        paperSize: CGSize
    ) -> CGPoint {
        let maxX = max(0, paperSize.width - imageSize.width)
        let maxY = max(0, paperSize.height - imageSize.height)
        return CGPoint(
            x: min(max(0, origin.x), maxX),
            y: min(max(0, origin.y), maxY)
        )
    }

    /// The image rectangle relative to the page's content-area (text column)
    /// top-left. Negative x/y means the image extends into a margin.
    static func contentRect(
        origin: CGPoint,
        imageSize: CGSize,
        leftMargin: CGFloat,
        topMargin: CGFloat
    ) -> CGRect {
        CGRect(
            x: origin.x - leftMargin,
            y: origin.y - topMargin,
            width: imageSize.width,
            height: imageSize.height
        )
    }

    /// A strip of text column narrower than this isn't worth flowing text into.
    /// TextKit will happily lay a line fragment into a 10pt gap and fit one
    /// character per line, which is what an image positioned just short of the
    /// right margin used to produce: a ladder of orphaned single letters down
    /// the page edge, with the words they came from broken on the other side.
    static let minimumWrappedColumnWidth: CGFloat = 72

    /// The rectangle text should avoid, clipped to the text column
    /// `[0, contentWidth]` and grown by `gutter` so text keeps a small gap.
    /// Returns nil when the image doesn't overlap the text column at all
    /// (e.g. parked entirely in a side margin), so no exclusion is needed.
    /// - Parameter topGutter: how far *above* the image the exclusion reaches.
    ///   Defaults to `gutter`. Pass 0 for an image anchored to a paragraph's
    ///   top: TextKit narrows any line whose fragment the exclusion touches,
    ///   and the previous paragraph's fragment extends down to this one's top
    ///   (it includes the trailing paragraph spacing), so an upward gutter
    ///   reaches into the line above and shoves it sideways. A chapter heading
    ///   directly above an image was being pushed 201pt to the right by exactly
    ///   this. Nothing is lost: paragraph spacing already separates them.
    static func exclusionRect(
        contentRect: CGRect,
        contentWidth: CGFloat,
        gutter: CGFloat,
        topGutter: CGFloat? = nil
    ) -> CGRect? {
        let top = contentRect.minY - (topGutter ?? gutter)
        let grown = CGRect(
            x: contentRect.minX - gutter,
            y: top,
            width: contentRect.width + gutter * 2,
            height: (contentRect.maxY + gutter) - top
        )
        var minX = max(0, grown.minX)
        var maxX = min(contentWidth, grown.maxX)
        guard maxX > minX else { return nil }
        // Swallow a residual column too narrow to hold real text, so the text
        // flows past the image instead of dribbling down beside it.
        if minX < minimumWrappedColumnWidth { minX = 0 }
        if contentWidth - maxX < minimumWrappedColumnWidth { maxX = contentWidth }
        return CGRect(x: minX, y: grown.minY, width: maxX - minX, height: grown.height)
    }

    /// Snap the image's left edge toward the left content edge, the horizontal
    /// center of the column, or the right content edge when within `threshold`.
    /// Returns the (possibly unchanged) x and the guide that was hit, if any.
    static func horizontalSnap(
        originX: CGFloat,
        imageWidth: CGFloat,
        leftMargin: CGFloat,
        contentWidth: CGFloat,
        threshold: CGFloat
    ) -> (x: CGFloat, guide: HorizontalGuide?) {
        let targets: [(HorizontalGuide, CGFloat)] = [
            (.left, leftMargin),
            (.center, leftMargin + (contentWidth - imageWidth) / 2),
            (.right, leftMargin + contentWidth - imageWidth),
        ]
        let nearest = targets.min { abs($0.1 - originX) < abs($1.1 - originX) }
        if let nearest, abs(nearest.1 - originX) <= threshold {
            return (nearest.1, nearest.0)
        }
        return (originX, nil)
    }
}
