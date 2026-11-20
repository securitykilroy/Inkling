//
//  FormattingTargetTests.swift
//  InklingTests
//
//  The format toolbar talks to `RichTextController`, whose `textView` is the
//  chapter's page view. While the author is typing in a sidebar box those
//  commands must act on the box — never on whatever happens to be selected in
//  the chapter behind it.
//

import AppKit
import Testing
@testable import Inkling

@MainActor
struct FormattingTargetTests {

    private static let bodyText = String(repeating: "Alpha bravo charlie delta. ", count: 30)

    /// A chapter with an entered sidebar box holding "boxed words", the box's
    /// text selected, and a separate selection left in the body.
    private static func stackWithEnteredSidebar() throws -> (PageStackView, RichTextController, NSWindow) {
        let stack = PageStackView()
        stack.setAttributedString(NSAttributedString(
            string: bodyText, attributes: [.font: NSFont.systemFont(ofSize: 12)]
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 1100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = stack
        stack.prepareSidebars()

        stack.pageViews[0].setSelectedRange(NSRange(location: 6, length: 0))
        stack.insertSidebar()
        let box = try #require(stack.enteredSidebarTextView)
        box.insertText("boxed words", replacementRange: NSRange(location: 0, length: 0))
        box.setSelectedRange(NSRange(location: 0, length: (box.string as NSString).length))

        // A stale body selection: what the toolbar used to format.
        stack.pageViews[0].setSelectedRange(NSRange(location: 40, length: 7))

        let controller = RichTextController()
        controller.textView = stack.pageViews[0]
        return (stack, controller, window)
    }

    private static func bodyIsUnchanged(_ stack: PageStackView, at range: NSRange) -> Bool {
        var unchanged = true
        stack.storage.enumerateAttribute(.font, in: range) { value, _, _ in
            let font = value as? NSFont
            if font?.fontDescriptor.symbolicTraits.contains(.bold) == true
                || font?.fontDescriptor.symbolicTraits.contains(.italic) == true {
                unchanged = false
            }
        }
        return unchanged && !stack.storage.string.contains("•")
    }

    @Test func boldActsOnTheEnteredBoxNotTheBody() throws {
        let (stack, controller, window) = try Self.stackWithEnteredSidebar()
        _ = window
        let box = try #require(stack.enteredSidebarTextView)

        controller.toggleBold()

        let boxFont = try #require(box.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(boxFont.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(Self.bodyIsUnchanged(stack, at: NSRange(location: 40, length: 7)))
    }

    @Test func italicActsOnTheEnteredBoxNotTheBody() throws {
        let (stack, controller, window) = try Self.stackWithEnteredSidebar()
        _ = window
        let box = try #require(stack.enteredSidebarTextView)

        controller.toggleItalic()

        let boxFont = try #require(box.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(boxFont.fontDescriptor.symbolicTraits.contains(.italic))
        #expect(Self.bodyIsUnchanged(stack, at: NSRange(location: 40, length: 7)))
    }

    @Test func bulletsActOnTheEnteredBoxNotTheBody() throws {
        let (stack, controller, window) = try Self.stackWithEnteredSidebar()
        _ = window
        let box = try #require(stack.enteredSidebarTextView)

        controller.toggleBulletList()

        #expect(box.string.hasPrefix("•\t"))
        #expect(Self.bodyIsUnchanged(stack, at: NSRange(location: 40, length: 7)))
    }

    /// Headings and callouts are page-level structure a box can't hold, so
    /// they do nothing while a box is entered — and above all leave the body
    /// behind it alone.
    @Test func paragraphLevelCommandsLeaveTheBodyAloneWhileABoxIsEntered() throws {
        let (stack, controller, window) = try Self.stackWithEnteredSidebar()
        _ = window
        let before = NSAttributedString(attributedString: stack.storage)

        controller.applyStyle(.heading)
        controller.applyCallout(.note)
        controller.removeCallout()

        #expect(stack.storage.isEqual(to: before))
    }

    /// With no box entered, the commands still reach the body as before.
    @Test func boldStillActsOnTheBodyWhenNoBoxIsEntered() throws {
        let (stack, controller, window) = try Self.stackWithEnteredSidebar()
        _ = window
        stack.exitSidebar()
        #expect(stack.enteredSidebarTextView == nil)
        stack.pageViews[0].setSelectedRange(NSRange(location: 40, length: 7))

        controller.toggleBold()

        let font = try #require(stack.storage.attribute(.font, at: 40, effectiveRange: nil) as? NSFont)
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
    }
}
