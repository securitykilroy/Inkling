//
//  NonFiniteGeometryTests.swift
//  InklingTests
//
//  The image and sidebar sidecars are JSON, and JSONEncoder throws on an
//  infinite or NaN number. The throw was swallowed by `try?`, so a single bad
//  value silently dropped the *whole* sidecar: every image in the chapter lost
//  its size, position and caption — or, for the sidebar sidecar, every box
//  lost its text. A malformed .docx could supply one (`Double("inf")` parses).
//

import AppKit
import Testing
@testable import Inkling

@MainActor
struct NonFiniteGeometryTests {

    private static func pngAttachment(size: NSSize) throws -> NSTextAttachment {
        let image = NSImage(size: NSSize(width: 10, height: 10))
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 10, height: 10).fill()
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        return ImageAttachmentContent.makeSizedAttachment(
            payload: .init(data: png, typeIdentifier: "public.png"), size: size
        )
    }

    private static func captions(in text: NSAttributedString) -> [String] {
        var found: [String] = []
        text.enumerateAttribute(.inklingImageCaption, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let value = value as? String { found.append(value) }
        }
        return found
    }

    @Test func oneInfiniteImageDoesNotCostTheOthersTheirCaptions() throws {
        let text = NSMutableAttributedString(string: "Before ")
        text.append(NSAttributedString(attachment: try Self.pngAttachment(
            size: NSSize(width: CGFloat.infinity, height: 40)
        )))
        text.append(NSAttributedString(string: " middle "))
        let kept = NSMutableAttributedString(attachment: try Self.pngAttachment(size: NSSize(width: 80, height: 60)))
        kept.addAttribute(.inklingImageCaption, value: "Kept caption", range: NSRange(location: 0, length: 1))
        text.append(kept)
        text.append(NSAttributedString(string: " after."))

        let data = try #require(RichTextCodec.encode(text))
        let decoded = try #require(RichTextCodec.decode(data))

        #expect(Self.captions(in: decoded) == ["Kept caption"])
    }

    @Test func aNaNPositionDropsOnlyThatPosition() throws {
        let text = NSMutableAttributedString(string: "Before ")
        let image = NSMutableAttributedString(attachment: try Self.pngAttachment(size: NSSize(width: 80, height: 60)))
        image.addAttributes([
            .inklingImageCaption: "Still here",
            .inklingFloatingImagePosition: FloatingImagePosition(page: 0, origin: CGPoint(x: CGFloat.nan, y: 100)),
        ], range: NSRange(location: 0, length: 1))
        text.append(image)
        text.append(NSAttributedString(string: " after."))

        let data = try #require(RichTextCodec.encode(text))
        let decoded = try #require(RichTextCodec.decode(data))

        #expect(Self.captions(in: decoded) == ["Still here"])
    }

    @Test func anInfiniteSidebarKeepsItsText() throws {
        let content = try #require(RichTextCodec.encode(NSAttributedString(string: "Box words")))
        let sidebar = SidebarAttachment(
            contentData: content,
            width: CGFloat.infinity,
            position: FloatingImagePosition(page: 0, origin: CGPoint(x: CGFloat.infinity, y: 20)),
            contentHeight: CGFloat.nan
        )
        let text = NSMutableAttributedString(string: "Before ")
        text.append(NSAttributedString(attachment: sidebar))
        text.append(NSAttributedString(string: " after."))

        let data = try #require(RichTextCodec.encode(text))
        let decoded = try #require(RichTextCodec.decode(data))

        var restored: SidebarAttachment?
        decoded.enumerateAttribute(.attachment, in: NSRange(location: 0, length: decoded.length)) { value, _, _ in
            if let value = value as? SidebarAttachment { restored = value }
        }
        let box = try #require(restored)
        #expect(RichTextCodec.decode(box.contentData)?.string == "Box words")
        #expect(box.width == SidebarStyle.defaultWidth)
        #expect(box.position == nil)
    }
}
