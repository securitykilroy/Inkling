//
//  SidebarProtectionTests.swift
//  InklingTests
//
//  A sidebar box holds its own text, so — like a floating image — it can't be
//  swept away by typing over a selection that happens to span its anchor. It
//  is deleted on purpose by selecting the box itself (covered in
//  SidebarPortTests). Refused edits beep instead of silently doing nothing.
//

import AppKit
import Testing
@testable import Inkling

@MainActor
struct SidebarProtectionTests {

    private static let original = String(repeating: "Alpha bravo charlie delta. ", count: 30)

    private static func stackWithSidebar() -> (PageStackView, NSWindow) {
        let stack = PageStackView()
        stack.setAttributedString(NSAttributedString(
            string: original, attributes: [.font: NSFont.systemFont(ofSize: 12)]
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 1100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = stack
        stack.prepareSidebars()
        stack.pageViews[0].setSelectedRange(NSRange(location: 6, length: 0))
        stack.insertSidebar()
        stack.exitSidebar()
        return (stack, window)
    }

    private static func sidebarCount(in stack: PageStackView) -> Int {
        var count = 0
        stack.storage.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: stack.storage.length)
        ) { value, _, _ in
            if value is SidebarAttachment { count += 1 }
        }
        return count
    }

    @Test func typingOverASelectionSpanningABoxLeavesTheBox() throws {
        let (stack, window) = Self.stackWithSidebar()
        _ = window
        let page = stack.pageViews[0]
        let before = stack.storage.string
        page.setSelectedRange(NSRange(location: 2, length: 20))

        page.insertText("x", replacementRange: page.selectedRange())

        #expect(Self.sidebarCount(in: stack) == 1)
        #expect(stack.storage.string == before)
    }

    @Test func deletingASelectionSpanningABoxLeavesTheBox() throws {
        let (stack, window) = Self.stackWithSidebar()
        _ = window
        let page = stack.pageViews[0]
        page.setSelectedRange(NSRange(location: 2, length: 20))

        page.deleteBackward(nil)

        #expect(Self.sidebarCount(in: stack) == 1)
    }

    /// Ordinary text away from the box still edits normally.
    @Test func editingTextAwayFromTheBoxStillWorks() throws {
        let (stack, window) = Self.stackWithSidebar()
        _ = window
        let page = stack.pageViews[0]
        page.setSelectedRange(NSRange(location: 100, length: 5))

        page.insertText("x", replacementRange: page.selectedRange())

        #expect(stack.storage.length == (Self.original as NSString).length + 1 - 5 + 1)
        #expect(Self.sidebarCount(in: stack) == 1)
    }

    @Test func resizingABoxIsUndoneAsResizeNotMove() throws {
        let (stack, window) = Self.stackWithSidebar()
        _ = window
        let id = try #require(stack.sidebarPlacements.keys.first)
        let sidebar = try #require(stack.sidebarAttachments[id])
        stack.sidebarResizeSession = PageStackView.SidebarDragSession(
            id: id, startPoint: .zero, startOrigin: .zero,
            startWidth: sidebar.width, startPosition: sidebar.position
        )
        sidebar.width += 40

        #expect(stack.endSidebarDrag())
        #expect(stack.sharedUndoManager.undoActionName == "Resize Sidebar")
    }
}
