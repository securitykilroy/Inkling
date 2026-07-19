//
//  Callout.swift
//  Inkling
//
//  Inline callout boxes — Note / Sidebar / Warning — a run of paragraphs drawn
//  inside a framed, tinted box separate from the main body text. A callout is
//  just body text tagged with the `.inklingCallout` paragraph attribute (its
//  kind); the box, tint, and label are drawn as chrome by `CalloutLayoutManager`
//  in both the editor and the printer, and synthesized into every export path.
//
//  Like `.inklingFloatingImagePosition`, the attribute lives only in memory —
//  RTF can't carry it, so `RichTextCodec` persists callout ranges + kinds in the
//  RTFD sidecar and re-applies the canonical styling on decode.
//

import AppKit

extension NSAttributedString.Key {
    /// Marks a run of paragraphs as a callout. The value is a
    /// `CalloutKind.rawValue`. Never serialized into RTFD directly — restored
    /// from the sidecar by `RichTextCodec.decode`.
    static let inklingCallout = NSAttributedString.Key("inklingCallout")
}

/// The kinds of inline callout an author can apply. Each carries the label drawn
/// on the box and written into exports, plus a fixed accent/fill color so the
/// box looks identical on screen, in print, and in Word regardless of the
/// system's light/dark appearance.
enum CalloutKind: String, CaseIterable, Identifiable {
    case note, warning

    var id: String { rawValue }

    /// Resolves a stored raw value to a kind, migrating the retired inline
    /// `sidebar` kind (superseded by the floating margin Sidebar) to `note` so
    /// existing chapters keep their box rather than losing the styling.
    init?(storedRawValue raw: String) {
        if raw == "sidebar" { self = .note; return }
        self.init(rawValue: raw)
    }

    /// Title-cased name for the authoring menu.
    var menuLabel: String {
        switch self {
        case .note: return "Note"
        case .warning: return "Warning"
        }
    }

    /// Upper-cased label drawn on the box and written into exports (so NotebookLM
    /// and other readers see a clearly-labeled aside, not narrative text).
    var exportLabel: String { menuLabel.uppercased() }

    var symbolName: String {
        switch self {
        case .note: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        }
    }

    /// Border/label color as a 6-digit hex string. Kept as hex so the exact same
    /// value flows to AppKit drawing and to Word's `w:color`/`w:fill`.
    var accentHex: String {
        switch self {
        case .note: return "3B82F6"
        case .warning: return "D97706"
        }
    }

    /// Box fill color as a 6-digit hex string.
    var fillHex: String {
        switch self {
        case .note: return "EAF2FE"
        case .warning: return "FEF3E2"
        }
    }

    var accentColor: NSColor { NSColor(inklingHex: accentHex) }
    var fillColor: NSColor { NSColor(inklingHex: fillHex) }
}

extension NSColor {
    /// A device-RGB color from a 6-digit hex string (e.g. "3B82F6"). Fixed sRGB
    /// (not a dynamic system color) so callout chrome prints identically whether
    /// the app is in light or dark mode. Falls back to gray on a malformed value.
    convenience init(inklingHex hex: String) {
        let scanner = Scanner(string: hex)
        var value: UInt64 = 0
        guard scanner.scanHexInt64(&value), hex.count == 6 else {
            self.init(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
            return
        }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }
}

/// Shared geometry + attribute application for callouts, used by the authoring
/// controller, the codec (on decode), and the drawing layout manager, so a
/// callout's inset text and reserved box padding are defined in exactly one place.
enum CalloutStyling {
    /// Horizontal inset of the callout text from the box's sides.
    static let sideInset: CGFloat = 16
    /// Vertical gap between the callout text and the box's top/bottom edges.
    static let innerVerticalPad: CGFloat = 10
    /// Height reserved above the first text line for the box's label.
    static let labelHeight: CGFloat = 16
    /// Breathing room between the box and the surrounding body text.
    static let outerGap: CGFloat = 10
    static let cornerRadius: CGFloat = 6
    static let borderWidth: CGFloat = 1.5

    /// Space reserved before a callout's first paragraph: outer gap + the box's
    /// top padding + the label band.
    static var topReserve: CGFloat { outerGap + innerVerticalPad + labelHeight }
    /// Space reserved after a callout's last paragraph: outer gap + bottom padding.
    static var bottomReserve: CGFloat { outerGap + innerVerticalPad }

    /// Tags `range` (expected to be whole paragraphs) as a callout of `kind` and
    /// applies the inset/spacing paragraph style. The first paragraph reserves
    /// room for the label + top padding; the last reserves the bottom padding.
    static func apply(_ kind: CalloutKind, to storage: NSMutableAttributedString, range: NSRange) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        storage.addAttribute(.inklingCallout, value: kind.rawValue, range: range)

        let paragraphs = paragraphEnclosingRanges(in: storage.string as NSString, within: range)
        for (index, paragraph) in paragraphs.enumerated() {
            let base = storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
            let style = (base?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            style.firstLineHeadIndent = sideInset
            style.headIndent = sideInset
            style.tailIndent = -sideInset
            style.paragraphSpacingBefore = index == 0 ? topReserve : 0
            style.paragraphSpacing = index == paragraphs.count - 1
                ? bottomReserve
                : RichTextCodec.defaultParagraphSpacing
            storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
        }
    }

    /// Clears the callout tag from `range` and resets its paragraphs to the
    /// default body paragraph style (dropping the inset and reserved padding).
    static func remove(from storage: NSMutableAttributedString, range: NSRange) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        storage.removeAttribute(.inklingCallout, range: range)
        for paragraph in paragraphEnclosingRanges(in: storage.string as NSString, within: range) {
            storage.addAttribute(.paragraphStyle, value: RichTextCodec.defaultParagraphStyle, range: paragraph)
        }
    }

    private static func paragraphEnclosingRanges(in string: NSString, within range: NSRange) -> [NSRange] {
        var ranges: [NSRange] = []
        string.enumerateSubstrings(in: range, options: [.byParagraphs, .substringNotRequired]) { _, _, enclosing, _ in
            ranges.append(enclosing)
        }
        return ranges
    }
}
