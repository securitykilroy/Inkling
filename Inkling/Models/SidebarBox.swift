//
//  SidebarBox.swift
//  Inkling
//
//  A floating margin sidebar: a narrow, bordered text box the body text wraps
//  around, placed on a page like a floating image but holding its own editable
//  text. `SidebarAttachment` is the invisible anchor that lives in the body text
//  stream (so the box has a home in the flow and survives copy/paste); the box's
//  content, page position, and width ride in the RTFD sidecar via RichTextCodec.
//
//  Reuses `FloatingImagePosition` for placement so the on-screen editor and the
//  printer share one coordinate system, exactly like floating images.
//

import AppKit

/// Fixed visual style + geometry for the floating sidebar box, shared by the
/// editable child view (`SidebarTextView`) and the printer so a sidebar looks
/// identical on screen and on paper.
enum SidebarStyle {
    /// Drawn on the header band when a box has no title of its own — which is
    /// every sidebar written before titles existed, so old documents keep the
    /// look they were saved with.
    static let defaultTitle = "SIDEBAR"
    static let accentHex = "6B7280"
    static let fillHex = "F3F4F6"

    static var accentColor: NSColor { NSColor(inklingHex: accentHex) }
    static var fillColor: NSColor { NSColor(inklingHex: fillHex) }

    /// Height of the "SIDEBAR" header band at the top of the box.
    static let headerHeight: CGFloat = 22
    /// Padding around the text inside the box.
    static let padding: CGFloat = 10
    static let cornerRadius: CGFloat = 6
    static let borderWidth: CGFloat = 1.5

    static let defaultWidth: CGFloat = 220
    static let minWidth: CGFloat = 130

    /// Typography inside the box. Deliberately its own size rather than the
    /// body's — a 220pt column reads badly at manuscript size — and the single
    /// source of truth for both typing in the box and text moved into one.
    static let contentFontSize: CGFloat = 12
    static var contentFont: NSFont { .systemFont(ofSize: contentFontSize) }
    /// Fallback text height for a brand-new, empty box before its child view has
    /// measured real content.
    static let minContentHeight: CGFloat = 20

    /// Width available to the sidebar's text inside its padding.
    static func textWidth(forBoxWidth width: CGFloat) -> CGFloat {
        max(20, width - padding * 2)
    }

    /// Total box height for a measured text height.
    static func boxHeight(forContentHeight contentHeight: CGFloat) -> CGFloat {
        headerHeight + padding + max(minContentHeight, contentHeight) + padding
    }
}

/// Seeds a new sidebar box from whatever the author had selected when they
/// asked for one. Inserting a sidebar over a selection *moves* that text into
/// the box: the anchor replaces the selected range, so without this the words
/// were simply overwritten and the box came up empty.
enum SidebarContent {

    /// Whether a selection can move into a box. One carrying an attachment
    /// can't: a floating image or another sidebar keeps state (page position,
    /// box content, a hosted child editor) that a box's plain text storage has
    /// nowhere to put, and consuming the range would destroy its anchor along
    /// with the text. Those selections are left alone instead.
    nonisolated static func canMove(_ selection: NSAttributedString) -> Bool {
        guard selection.length > 0 else { return false }
        var movable = true
        selection.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: selection.length)
        ) { value, _, stop in
            if value != nil {
                movable = false
                stop.pointee = true
            }
        }
        return movable
    }

    /// The box's starting content for `selection`, restyled to the box's own
    /// typography — the same adoption a paste into the box gets, so moved text
    /// reads as if it had been typed there rather than dragging a slab of
    /// manuscript-sized body text into a 220pt column.
    ///
    /// Bold and italic survive, because in prose they carry meaning (a title, a
    /// stressed word); the face, size, colour, and paragraph metrics do not.
    ///
    /// Returns nil when nothing survives trimming, so asking for a sidebar with
    /// only blank lines selected still gives an empty box rather than one
    /// pre-filled with whitespace.
    nonisolated static func content(from selection: NSAttributedString) -> Data? {
        let text = restyled(selection)
        guard text.length > 0 else { return nil }
        return RichTextCodec.encode(text)
    }

    nonisolated static func restyled(_ selection: NSAttributedString) -> NSAttributedString {
        let trimmed = trimming(selection)
        guard trimmed.length > 0 else { return NSAttributedString() }

        let styled = NSMutableAttributedString(attributedString: trimmed)
        let whole = NSRange(location: 0, length: styled.length)
        // A run with no font at all still comes through here (value is nil),
        // so every character ends up with the box's face.
        styled.enumerateAttribute(.font, in: whole) { value, range, _ in
            styled.addAttribute(.font, value: boxFont(matching: value as? NSFont), range: range)
        }
        for attribute in PasteStyling.sourceOnlyAttributes {
            styled.removeAttribute(attribute, range: whole)
        }
        // Text lifted out of a callout is no longer in one — the box is the
        // aside now, and leaving the tag would draw callout chrome inside it.
        styled.removeAttribute(.inklingCallout, range: whole)
        styled.addAttribute(.foregroundColor, value: NSColor.black, range: whole)
        styled.addAttribute(
            .paragraphStyle, value: RichTextCodec.defaultParagraphStyle, range: whole
        )
        return styled
    }

    /// The box's font wearing the source run's bold/italic, if it had any.
    nonisolated private static func boxFont(matching source: NSFont?) -> NSFont {
        let base = SidebarStyle.contentFont
        guard let source else { return base }
        let traits = source.fontDescriptor.symbolicTraits.intersection([.bold, .italic])
        guard !traits.isEmpty else { return base }
        return NSFont(
            descriptor: base.fontDescriptor.withSymbolicTraits(traits),
            size: SidebarStyle.contentFontSize
        ) ?? base
    }

    /// Drops leading/trailing whitespace and newlines. A selection made by
    /// dragging almost always picks up a trailing space or the paragraph break
    /// after it, which inside the box would show as a stray blank line.
    nonisolated private static func trimming(_ text: NSAttributedString) -> NSAttributedString {
        let string = text.string as NSString
        let skippable = CharacterSet.whitespacesAndNewlines
        var start = 0
        var end = string.length
        func isSkippable(at index: Int) -> Bool {
            guard let scalar = Unicode.Scalar(string.character(at: index)) else { return false }
            return skippable.contains(scalar)
        }
        while start < end, isSkippable(at: start) { start += 1 }
        while end > start, isSkippable(at: end - 1) { end -= 1 }
        return text.attributedSubstring(from: NSRange(location: start, length: end - start))
    }
}

/// The anchor for a floating sidebar. Like `FloatingImageAttachment`, its inline
/// bounds collapse to a point so it never disturbs the line it sits on; the
/// visible box is drawn/hosted separately by `PageStackView` and the printer.
final class SidebarAttachment: NSTextAttachment {
    /// The sidebar's rich text, as RTF.
    var contentData: Data?
    /// The author's label for this box. Empty means "no title of its own" — the
    /// header falls back to `SidebarStyle.defaultTitle` rather than drawing an
    /// empty band, so a blank title is never a way to lose the header.
    var title: String = ""
    /// Fixed page placement (page + top-left in paper coordinates). New sidebars
    /// are placed immediately on insert, so this is effectively always set.
    var position: FloatingImagePosition?
    /// Box width in points (author-adjustable via resize handles).
    var width: CGFloat
    /// Last measured text height, so layout has a size before the child view
    /// re-measures. Kept current by `PageStackView` as the box's text changes.
    var contentHeight: CGFloat

    nonisolated init(contentData: Data?, width: CGFloat, position: FloatingImagePosition?, contentHeight: CGFloat) {
        self.contentData = contentData
        self.width = width
        self.position = position
        self.contentHeight = contentHeight
        super.init(data: nil, ofType: nil)
        // A 1×1 transparent image collapsed to 0.1pt makes the in-flow anchor
        // invisible: with an image set, TextKit sizes/draws the image (nothing)
        // instead of falling back to a generic file-icon cell. It also carries
        // the U+FFFC anchor character through RTFD encoding. The sidebar's real
        // content + geometry ride in the sidecar, keyed by this anchor's location.
        image = Self.invisibleAnchorImage
        attachmentCell = nil
        bounds = NSRect(x: 0, y: 0, width: 0.1, height: 0.1)
    }

    required init?(coder: NSCoder) {
        width = SidebarStyle.defaultWidth
        contentHeight = SidebarStyle.minContentHeight
        super.init(coder: coder)
    }

    /// What the header band actually draws, on screen and on paper.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? SidebarStyle.defaultTitle : trimmed
    }

    /// The box's full display size for the current width + measured content.
    var displaySize: NSSize {
        NSSize(width: width, height: SidebarStyle.boxHeight(forContentHeight: contentHeight))
    }

    nonisolated private static let invisibleAnchorImage: NSImage = {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        if let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) {
            representation.size = image.size
            image.addRepresentation(representation)
        }
        return image
    }()
}
