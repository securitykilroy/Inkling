//
//  ChapterDeleteConfirmationTests.swift
//  InklingTests
//
//  Deleting a chapter with anything in it asks first; an empty one (a stray
//  New Chapter) goes without a prompt.
//

import AppKit
import Testing
@testable import Inkling

struct ChapterDeleteConfirmationTests {

    private static func rtf(_ text: String) -> Data? {
        RichTextCodec.encode(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)]))
    }

    @Test func emptyChaptersDeleteWithoutAsking() {
        #expect(!ProjectViewModel.needsDeleteConfirmation([(nil, nil)]))
        #expect(!ProjectViewModel.needsDeleteConfirmation([(Self.rtf(""), Self.rtf(""))]))
        #expect(!ProjectViewModel.needsDeleteConfirmation([(Self.rtf("  \n\n\t "), nil)]))
    }

    @Test func aChapterWithTextAsks() {
        #expect(ProjectViewModel.needsDeleteConfirmation([(Self.rtf("Once upon a time"), nil)]))
    }

    @Test func aChapterWithOnlyNotesAsks() {
        #expect(ProjectViewModel.needsDeleteConfirmation([(nil, Self.rtf("Remember the lighthouse"))]))
    }

    @Test func aChapterWithOnlyAnImageAsks() throws {
        let image = NSImage(size: NSSize(width: 10, height: 10))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 10, height: 10).fill()
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let attachment = ImageAttachmentContent.makeSizedAttachment(
            payload: .init(data: png, typeIdentifier: "public.png"), size: NSSize(width: 10, height: 10)
        )
        let body = RichTextCodec.encode(NSAttributedString(attachment: attachment))

        #expect(ProjectViewModel.needsDeleteConfirmation([(body, nil)]))
    }

    /// Several chapters: one with content is enough to ask.
    @Test func oneNonEmptyChapterAmongSeveralAsks() {
        #expect(ProjectViewModel.needsDeleteConfirmation([(nil, nil), (Self.rtf("Words"), nil)]))
    }

    @Test func unreadableDataCountsAsContent() {
        #expect(ProjectViewModel.needsDeleteConfirmation([(Data([0x00, 0x01, 0x02]), nil)]))
    }
}
