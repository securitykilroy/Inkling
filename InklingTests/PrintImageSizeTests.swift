//
//  PrintImageSizeTests.swift
//  InklingTests
//
//  The editor scales an image that's bigger than the page down to fit it, but
//  the printer used the stored size as is. An image whose stored size was
//  never fitted (an imported chapter printed before it was opened, a Word
//  extent wider than Inkling's text area) printed past the paper's edge —
//  and an auto-placed one was clipped to the page width without its height
//  following, so it printed squashed as well.
//

import AppKit
import Testing
@testable import Inkling

@MainActor
struct PrintImageSizeTests {

    private static let pageSize = NSSize(width: 468, height: 648)

    private static func chapter(
        imageSize: NSSize,
        caption: String? = nil,
        position: FloatingImagePosition? = nil
    ) throws -> PrintableChapter {
        let image = NSImage(size: NSSize(width: 40, height: 30))
        image.lockFocus()
        NSColor.green.setFill()
        NSRect(x: 0, y: 0, width: 40, height: 30).fill()
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))

        let text = NSMutableAttributedString(
            string: "A paragraph before the picture.\n",
            attributes: [.font: NSFont.systemFont(ofSize: 12)]
        )
        let attachment = NSMutableAttributedString(attachment: ImageAttachmentContent.makeSizedAttachment(
            payload: .init(data: png, typeIdentifier: "public.png"), size: imageSize
        ))
        if let caption {
            attachment.addAttribute(.inklingImageCaption, value: caption, range: NSRange(location: 0, length: 1))
        }
        if let position {
            attachment.addAttribute(.inklingFloatingImagePosition, value: position, range: NSRange(location: 0, length: 1))
        }
        text.append(attachment)
        text.append(NSAttributedString(string: "\nAnd one after.", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        return PrintableChapter(title: "One", bodyData: try #require(RichTextCodec.encode(text)))
    }

    private static func footprints(_ chapter: PrintableChapter) -> [NSRect] {
        let view = ManuscriptPrintView(chapters: [chapter], pageSize: pageSize, leftMargin: 72, topMargin: 72)
        return (1...view.pageCount).flatMap { view.floatingImageFootprints(onPage: $0) }
    }

    @Test func anOversizedImageIsScaledToFitThePageKeepingItsShape() throws {
        let footprint = try #require(Self.footprints(try Self.chapter(imageSize: NSSize(width: 4000, height: 3000))).first)

        #expect(footprint.width <= Self.pageSize.width + 0.5, "\(footprint)")
        #expect(footprint.maxY <= Self.pageSize.height + 0.5, "\(footprint)")
        #expect(abs(footprint.width / footprint.height - 4.0 / 3.0) < 0.01, "\(footprint)")
    }

    @Test func aTallImageIsScaledToFitThePageHeight() throws {
        let footprint = try #require(Self.footprints(try Self.chapter(imageSize: NSSize(width: 300, height: 2000))).first)

        #expect(footprint.height <= Self.pageSize.height + 0.5, "\(footprint)")
        #expect(abs(footprint.width / footprint.height - 0.15) < 0.01, "\(footprint)")
    }

    /// Image plus caption is one footprint, so the caption has to fit too.
    @Test func aCaptionedOversizedImageLeavesRoomForItsCaption() throws {
        let footprint = try #require(Self.footprints(try Self.chapter(
            imageSize: NSSize(width: 600, height: 2000), caption: "The lighthouse at dusk"
        )).first)

        #expect(footprint.height <= Self.pageSize.height + 0.5, "\(footprint)")
    }

    @Test func aPositionedOversizedImageStaysOnThePaper() throws {
        let footprint = try #require(Self.footprints(try Self.chapter(
            imageSize: NSSize(width: 4000, height: 3000),
            position: FloatingImagePosition(page: 0, origin: CGPoint(x: 72, y: 72))
        )).first)

        #expect(footprint.width <= Self.pageSize.width + 0.5, "\(footprint)")
        #expect(footprint.maxY <= Self.pageSize.height + 0.5, "\(footprint)")
    }

    @Test func anImageThatFitsIsLeftAlone() throws {
        let footprint = try #require(Self.footprints(try Self.chapter(imageSize: NSSize(width: 200, height: 150))).first)

        #expect(footprint.size == NSSize(width: 200, height: 150))
    }
}

/// A sidebar whose saved position failed validation on load still prints,
/// where the editor shows it: top right of the first page.
@MainActor
struct PrintUnpositionedSidebarTests {
    @Test func anUnpositionedSidebarPrintsAtTheTopRightOfTheFirstPage() throws {
        let content = try #require(RichTextCodec.encode(NSAttributedString(string: "Box words")))
        let sidebar = SidebarAttachment(contentData: content, width: 180, position: nil, contentHeight: 40)
        let text = NSMutableAttributedString(
            string: "Body text before the box. ", attributes: [.font: NSFont.systemFont(ofSize: 12)]
        )
        text.append(NSAttributedString(attachment: sidebar))
        text.append(NSAttributedString(string: " And after.", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        let data = try #require(RichTextCodec.encode(text))

        let pageSize = NSSize(width: 468, height: 648)
        let view = ManuscriptPrintView(
            chapters: [PrintableChapter(title: "One", bodyData: data)],
            pageSize: pageSize, leftMargin: 72, topMargin: 72
        )

        let boxes = (1...view.pageCount).flatMap { view.sidebarFootprints(onPage: $0) }
        let box = try #require(boxes.first)
        #expect(boxes.count == 1)
        #expect(abs(box.maxX - pageSize.width) < 0.5, "\(box)")
        #expect(box.minY == 0)
    }
}
