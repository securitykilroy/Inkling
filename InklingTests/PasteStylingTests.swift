//
//  PasteStylingTests.swift
//  InklingTests
//
//  Pasting from Word (or any RTF source) must not drag the source document's
//  typeface, size, colour and paragraph metrics into the manuscript.
//

import AppKit
import Testing
@testable import Inkling

@MainActor
struct PasteStylingTests {

    /// What Word puts on the pasteboard: its own font, size, colour and
    /// paragraph metrics, plus — in the reported case — an image.
    private static func wordFlavoured(_ text: String, withImage: Bool = false) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.5
        style.firstLineHeadIndent = 36
        let result = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont(name: "Helvetica", size: 11) ?? NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.systemBlue,
                .backgroundColor: NSColor.systemYellow,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .kern: 2.0,
                .paragraphStyle: style,
            ]
        )
        if withImage {
            let attachment = NSTextAttachment()
            let image = NSImage(size: NSSize(width: 100, height: 80))
            image.lockFocus()
            NSColor.systemTeal.setFill()
            NSRect(x: 0, y: 0, width: 100, height: 80).fill()
            image.unlockFocus()
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: 0, width: 100, height: 80)
            result.append(NSAttributedString(attachment: attachment))
        }
        return result
    }

    private static let destinationFont = NSFont(name: "Times New Roman", size: 14)
        ?? NSFont.systemFont(ofSize: 14)

    private static func destinationStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 12
        style.paragraphSpacing = 9
        return style
    }

    /// A text view holding one paragraph of destination-styled text, with the
    /// Word content already dropped in at `pasteLocation` — the state right
    /// after `super.paste` and before the restyle.
    private static func viewAfterRawPaste(
        withImage: Bool = false
    ) -> (NSTextView, NSRange) {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let existing = NSAttributedString(
            string: "Destination paragraph.\n",
            attributes: [
                .font: destinationFont,
                .paragraphStyle: destinationStyle(),
                .foregroundColor: NSColor.black,
            ]
        )
        view.textStorage?.setAttributedString(existing)

        let pasted = wordFlavoured("Pasted from Word.", withImage: withImage)
        let location = existing.length
        view.textStorage?.insert(pasted, at: location)
        return (view, NSRange(location: location, length: pasted.length))
    }

    @Test func pastedTextTakesTheDestinationFont() {
        let (view, range) = Self.viewAfterRawPaste()
        PasteStyling.adoptDestinationStyle(
            in: view, range: range,
            font: Self.destinationFont, paragraphStyle: Self.destinationStyle()
        )

        let font = view.textStorage?.attribute(
            .font, at: range.location, effectiveRange: nil
        ) as? NSFont
        #expect(font == Self.destinationFont)
    }

    @Test func pastedTextTakesTheDestinationParagraphStyle() {
        let (view, range) = Self.viewAfterRawPaste()
        PasteStyling.adoptDestinationStyle(
            in: view, range: range,
            font: Self.destinationFont, paragraphStyle: Self.destinationStyle()
        )

        let style = view.textStorage?.attribute(
            .paragraphStyle, at: range.location, effectiveRange: nil
        ) as? NSParagraphStyle
        #expect(style?.firstLineHeadIndent == 12)
        // Word's 1.5 line spacing must not survive.
        #expect(style?.lineHeightMultiple == 0)
    }

    @Test func pastedTextLosesTheSourceColourAndDecoration() {
        let (view, range) = Self.viewAfterRawPaste()
        PasteStyling.adoptDestinationStyle(
            in: view, range: range,
            font: Self.destinationFont, paragraphStyle: Self.destinationStyle()
        )

        let storage = view.textStorage
        #expect(storage?.attribute(.backgroundColor, at: range.location, effectiveRange: nil) == nil)
        #expect(storage?.attribute(.underlineStyle, at: range.location, effectiveRange: nil) == nil)
        #expect(storage?.attribute(.kern, at: range.location, effectiveRange: nil) == nil)
        let colour = storage?.attribute(
            .foregroundColor, at: range.location, effectiveRange: nil
        ) as? NSColor
        #expect(colour == .black)
    }

    /// The decision that separates this from a literal "paste as plain text":
    /// an image pasted along with the text is content, and has to survive.
    @Test func pastedImagesSurvive() {
        let (view, range) = Self.viewAfterRawPaste(withImage: true)
        PasteStyling.adoptDestinationStyle(
            in: view, range: range,
            font: Self.destinationFont, paragraphStyle: Self.destinationStyle()
        )

        var found = 0
        view.textStorage?.enumerateAttribute(.attachment, in: range) { value, _, _ in
            if value is NSTextAttachment { found += 1 }
        }
        #expect(found == 1)
    }

    @Test func textOutsideThePasteIsUntouched() {
        let (view, range) = Self.viewAfterRawPaste()
        let before = view.textStorage?.attributes(at: 0, effectiveRange: nil)
        PasteStyling.adoptDestinationStyle(
            in: view, range: range,
            font: Self.destinationFont, paragraphStyle: Self.destinationStyle()
        )

        let after = view.textStorage?.attributes(at: 0, effectiveRange: nil)
        #expect((before?[.font] as? NSFont) == (after?[.font] as? NSFont))
    }

    @Test func anEmptyPasteChangesNothing() {
        let (view, _) = Self.viewAfterRawPaste()
        let before = view.textStorage?.string
        PasteStyling.adoptDestinationStyle(
            in: view, range: NSRange(location: 0, length: 0),
            font: Self.destinationFont, paragraphStyle: Self.destinationStyle()
        )
        #expect(view.textStorage?.string == before)
    }

    @Test func aRangeRunningPastTheEndIsClampedRatherThanTrapping() {
        let (view, _) = Self.viewAfterRawPaste()
        let length = view.textStorage?.length ?? 0
        PasteStyling.adoptDestinationStyle(
            in: view, range: NSRange(location: 0, length: length + 500),
            font: Self.destinationFont, paragraphStyle: Self.destinationStyle()
        )
        #expect(view.textStorage?.length == length)
    }

    /// The menu item has a `nil` target and routes through the responder
    /// chain, so it only works if the focused editor actually implements the
    /// selector. Every text view the user can type into must.
    @Test func everyEditorAnswersPasteWithFormatting() {
        let selector = Selector(("pasteWithFormatting:"))
        let stack = PageStackView()
        stack.setAttributedString(NSAttributedString(string: "x"))
        #expect(stack.pageViews.first?.responds(to: selector) == true)
        #expect(SidebarTextView.make(width: 200).responds(to: selector) == true)
    }

    @Test func theEditMenuOffersPasteWithFormatting() throws {
        let menu = MainMenu.build()
        let edit = try #require(
            menu.items.first { $0.submenu?.title == "Edit" }?.submenu
        )
        let item = try #require(
            edit.items.first { $0.title == "Paste with Formatting" }
        )
        #expect(item.action == Selector(("pasteWithFormatting:")))
        #expect(item.keyEquivalent == "v")
        #expect(item.keyEquivalentModifierMask == [.command, .shift, .option])

        // Plain Paste keeps ⌘V, so the two do not collide.
        let paste = try #require(edit.items.first { $0.title == "Paste" })
        #expect(paste.keyEquivalentModifierMask == [.command])
    }

    @Test func thePastedRangeIsDerivedFromTheCaretMove() {
        #expect(PasteStyling.pastedRange(from: 10, to: 27) == NSRange(location: 10, length: 17))
        // A paste that replaced a selection can leave the caret behind the start.
        #expect(PasteStyling.pastedRange(from: 27, to: 10) == NSRange(location: 10, length: 17))
        #expect(PasteStyling.pastedRange(from: 5, to: 5) == NSRange(location: 5, length: 0))
    }
}
