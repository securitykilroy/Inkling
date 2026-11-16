//
//  PasteStyling.swift
//  Inkling
//
//  Pasted text adopts the destination's styling rather than carrying the
//  source document's. Shared by every editor that accepts a paste.
//

import AppKit

enum PasteStyling {
    /// Character attributes that describe how the *source* document looked.
    /// Everything here is dropped on paste; the destination's own font and
    /// paragraph style are applied in their place.
    ///
    /// `.attachment` is deliberately absent: an image pasted along with the
    /// text is content, not styling, and has to survive. So are Inkling's own
    /// attributes (callout, floating-image position, import hints) — a paste
    /// into a callout must stay in that callout.
    ///
    /// Shared with `SidebarContent`: text moved into a sidebar box is the same
    /// problem as text pasted into one, so both drop the same list.
    static let sourceOnlyAttributes: [NSAttributedString.Key] = [
        .backgroundColor,
        .underlineStyle,
        .underlineColor,
        .strikethroughStyle,
        .strikethroughColor,
        .strokeWidth,
        .strokeColor,
        .shadow,
        .kern,
        .ligature,
        .baselineOffset,
        .obliqueness,
        .expansion,
        .superscript,
        .link,
        .textEffect,
        .cursor,
        .toolTip,
    ]

    /// Restyles `range` so it reads as if it had been typed here.
    ///
    /// Word (and any other RTF source) hands over its own typeface, point size,
    /// colour and paragraph metrics. Pasting that verbatim left a paragraph of
    /// Calibri 11pt sitting inside a manuscript set in the project's body font.
    ///
    /// `font` and `paragraphStyle` are the destination's typing attributes,
    /// captured *before* the paste — after it, AppKit has already adopted the
    /// incoming text's attributes, so reading them then would just echo the
    /// source back.
    static func adoptDestinationStyle(
        in textView: NSTextView,
        range: NSRange,
        font: NSFont?,
        paragraphStyle: NSParagraphStyle?
    ) {
        guard let storage = textView.textStorage, range.length > 0 else { return }
        let bounded = NSIntersectionRange(
            range,
            NSRange(location: 0, length: storage.length)
        )
        guard bounded.length > 0,
              textView.shouldChangeText(in: bounded, replacementString: nil)
        else { return }

        storage.beginEditing()
        for attribute in sourceOnlyAttributes {
            storage.removeAttribute(attribute, range: bounded)
        }
        if let font {
            storage.addAttribute(.font, value: font, range: bounded)
        }
        if let paragraphStyle {
            storage.addAttribute(.paragraphStyle, value: paragraphStyle, range: bounded)
        }
        // Paper is white in every appearance, so the ink is explicitly dark —
        // matching `PageStackView.appendPage`. Word's "automatic" black comes
        // across as an explicit colour that would not follow the theme.
        storage.addAttribute(.foregroundColor, value: NSColor.black, range: bounded)
        storage.endEditing()

        textView.didChangeText()
    }

    /// Removes what an RTF round trip would drop from text just pasted into
    /// `range` — the "\r" of a Windows line ending, and NUL — and returns the
    /// range the paste occupies afterwards.
    ///
    /// `RichTextCodec.encode` strips these anyway, so nothing saved depends on
    /// this. It keeps the text on screen the same length as the text on disk,
    /// which is what offsets handed out by project-wide Find and the outline
    /// are measured in.
    @discardableResult
    static func normalizeLineEndings(in textView: NSTextView, range: NSRange) -> NSRange {
        guard let storage = textView.textStorage, range.length > 0 else { return range }
        let bounded = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        guard bounded.length > 0 else { return range }

        let string = storage.string as NSString
        var doomed: [Int] = []
        for index in bounded.location..<NSMaxRange(bounded) {
            switch string.character(at: index) {
            case 0x0D where index + 1 < string.length && string.character(at: index + 1) == 0x0A:
                doomed.append(index)
            case 0x00:
                doomed.append(index)
            default:
                break
            }
        }
        guard !doomed.isEmpty else { return bounded }

        var removed = 0
        for index in doomed.reversed() {
            let target = NSRange(location: index, length: 1)
            guard textView.shouldChangeText(in: target, replacementString: "") else { continue }
            storage.replaceCharacters(in: target, with: "")
            removed += 1
        }
        guard removed > 0 else { return bounded }
        textView.didChangeText()
        let result = NSRange(location: bounded.location, length: bounded.length - removed)
        textView.setSelectedRange(NSRange(location: NSMaxRange(result), length: 0))
        return result
    }

    /// The range a paste just wrote, derived from where the caret sat before
    /// and after. NSTextView leaves the selection collapsed at the end of the
    /// inserted text, so the difference is the paste.
    static func pastedRange(from caretBefore: Int, to caretAfter: Int) -> NSRange {
        NSRange(
            location: min(caretBefore, caretAfter),
            length: abs(caretAfter - caretBefore)
        )
    }
}
