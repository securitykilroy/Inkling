//
//  InklingTests.swift
//  InklingTests
//
//  Created by Ric Messier on 6/19/26.
//

import AppKit
import ObjectiveC.runtime
import PDFKit
import Testing
@testable import Inkling

struct InklingTests {

    @Test @MainActor func pagedEditorFactoryBuildsPagedTextView() {
        let scrollView = PagedTextView.makePagedScrollView()

        #expect(scrollView.documentView is PagedTextView)
        #expect(scrollView is PagedEditorScrollView)
    }

    @Test func pagedEditorFitsWidePaperIntoNarrowEditorPane() {
        let scale = PagedEditorScrollView.fitMagnification(
            viewportWidth: 440,
            canvasWidth: 676
        )

        #expect(abs(scale - (440 / 676)) < 0.001)
    }

    @Test func pagedEditorDoesNotEnlargePaperBeyondActualSize() {
        let scale = PagedEditorScrollView.fitMagnification(
            viewportWidth: 900,
            canvasWidth: 676
        )

        #expect(scale == 1)
    }

    @Test @MainActor func pagedEditorZoomsAboveActualSizeOnCommand() {
        let scrollView = PagedTextView.makePagedScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 900, height: 792)
        scrollView.layoutSubtreeIfNeeded()

        scrollView.zoomIn(nil)

        #expect(scrollView.magnification > 1)
    }

    @Test @MainActor func emptyPagedEditorInsertionPointStartsInsideTopMargin() throws {
        let scrollView = PagedTextView.makePagedScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 676, height: 792)
        scrollView.layoutSubtreeIfNeeded()
        let textView = try #require(scrollView.documentView as? PagedTextView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        let rect = textView.firstRect(
            forCharacterRange: NSRange(location: 0, length: 0),
            actualRange: nil
        )
        let localOrigin = textView.convert(rect.origin, from: nil)

        #expect(abs(localOrigin.x - textView.textContainerOrigin.x) < 0.5)
        #expect(localOrigin.y >= textView.textContainerOrigin.y + textView.pageLayout.topMargin - 0.5)
    }

    @Test @MainActor func pagedEditorResetsNewParagraphAfterHeadingToBodyFont() throws {
        let scrollView = PagedTextView.makePagedScrollView()
        let textView = try #require(scrollView.documentView as? PagedTextView)
        textView.textStorage?.setAttributedString(NSAttributedString(
            string: "Coming Home",
            attributes: [.font: TextStyle.heading.font]
        ))
        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))

        textView.insertNewline(nil)
        textView.insertText("Body text.", replacementRange: textView.selectedRange())

        let bodyRange = (textView.string as NSString).range(of: "Body text.")
        let font = try #require(textView.textStorage?.attribute(.font, at: bodyRange.location, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize == TextStyle.body.font.pointSize)
        #expect(!font.fontDescriptor.symbolicTraits.contains(.bold))
    }

    /// A short body fits on a single real editor page — where the old
    /// 250-words-per-page estimate would have rounded up to 2.
    @Test @MainActor func realPageCountFitsAShortChapterOnOnePage() {
        let body = NSAttributedString(
            string: String(repeating: "word ", count: 300),
            attributes: [.font: NSFont.systemFont(ofSize: 14)]
        )
        let data = body.rtf(from: NSRange(location: 0, length: body.length), documentAttributes: [:])

        #expect(PagedTextView.pageCount(forRTF: data) == 1)
    }

    /// An empty (or missing) chapter still occupies its own page, matching what
    /// the editor footer shows for an empty chapter.
    @Test @MainActor func realPageCountIsOneForEmptyChapter() {
        #expect(PagedTextView.pageCount(forRTF: nil) == 1)
    }

    /// A long body spills onto multiple real pages, and the count matches an
    /// on-screen editor laying out the same text.
    @Test @MainActor func realPageCountSpillsLongChapterAcrossPages() throws {
        let body = NSAttributedString(
            string: String(repeating: "A comfortably long manuscript line that wraps across the page. ", count: 400),
            attributes: [.font: NSFont.systemFont(ofSize: 14)]
        )
        let data = body.rtf(from: NSRange(location: 0, length: body.length), documentAttributes: [:])

        let helperCount = PagedTextView.pageCount(forRTF: data)
        #expect(helperCount > 1)

        let scrollView = PagedTextView.makePagedScrollView()
        let textView = try #require(scrollView.documentView as? PagedTextView)
        textView.textStorage?.setAttributedString(body)
        textView.updatePageLayout()
        #expect(helperCount == textView.pageCount)
    }

    /// The sidebar (real editor layout) and print (ManuscriptPrintView) share
    /// paper size, 1" margins, fonts and per-chapter page breaks, so their page
    /// counts should agree to within about a page per chapter — not the big
    /// gap the old word-estimate produced. Prints both totals for the record.
    @Test @MainActor func editorAndPrintPageCountsAgreeWithinAPagePerChapter() {
        // Letter minus 1" margins on every side — exactly what ManuscriptPrinter
        // hands ManuscriptPrintView, and the content band PagedEditorLayout uses.
        let printPageSize = NSSize(width: 612 - 144, height: 792 - 144)

        let chapterBodies = (0..<8).map { index in
            NSAttributedString(
                string: String(repeating: "A comfortably long manuscript line that wraps across the printable page. ", count: 90 + index * 15),
                attributes: [.font: NSFont.systemFont(ofSize: 14)]
            )
        }
        let datas = chapterBodies.map {
            $0.rtf(from: NSRange(location: 0, length: $0.length), documentAttributes: [:])
        }

        let editorTotal = datas.reduce(0) { $0 + PagedTextView.pageCount(forRTF: $1) }

        let printView = ManuscriptPrintView(
            chapters: datas.enumerated().map { PrintableChapter(title: "Ch \($0.offset)", bodyData: $0.element) },
            pageSize: printPageSize
        )
        let printTotal = printView.pageCount

        #expect(abs(editorTotal - printTotal) <= datas.count,
                "editor=\(editorTotal) print=\(printTotal) chapters=\(datas.count)")
    }

    @Test @MainActor func typewriterScrollingHoldsTheCaretAtAFixedFractionOfTheViewport() throws {
        let scrollView = PagedTextView.makePagedScrollView()
        let textView = try #require(scrollView.documentView as? PagedTextView)
        scrollView.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        scrollView.layoutSubtreeIfNeeded()
        textView.isTypewriterScrollingEnabled = true

        let manyLines = Array(repeating: "A line of text.", count: 60).joined(separator: "\n")
        textView.textStorage?.setAttributedString(NSAttributedString(string: manyLines))
        textView.updatePageLayout()
        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))

        let glyphIndex = try #require(
            textView.layoutManager?.glyphIndexForCharacter(at: textView.selectedRange().location - 1)
        )
        let lineRect = try #require(textView.layoutManager?.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil))
        let caretMidY = lineRect.midY + textView.textContainerOrigin.y

        let visibleHeight = scrollView.contentView.bounds.height
        let expectedOriginY = caretMidY - visibleHeight * 0.42
        #expect(abs(scrollView.contentView.bounds.origin.y - expectedOriginY) < 1)
    }

    @Test @MainActor func typewriterScrollingDoesNothingWhenDisabled() throws {
        let scrollView = PagedTextView.makePagedScrollView()
        let textView = try #require(scrollView.documentView as? PagedTextView)
        scrollView.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        scrollView.layoutSubtreeIfNeeded()
        textView.isTypewriterScrollingEnabled = false

        let manyLines = Array(repeating: "A line of text.", count: 60).joined(separator: "\n")
        textView.textStorage?.setAttributedString(NSAttributedString(string: manyLines))
        let originBeforeSelection = scrollView.contentView.bounds.origin.y

        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))

        #expect(scrollView.contentView.bounds.origin.y == originBeforeSelection)
    }

    @Test @MainActor func currentStyleClassifiesTheFontAtTheCursor() throws {
        let scrollView = PagedTextView.makePagedScrollView()
        let textView = try #require(scrollView.documentView as? PagedTextView)
        let controller = RichTextController()
        controller.textView = textView

        textView.textStorage?.setAttributedString(NSAttributedString(
            string: "My Heading",
            attributes: [.font: TextStyle.heading.font]
        ))
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        controller.selectionDidChange()
        #expect(controller.currentStyle == .heading)

        textView.textStorage?.setAttributedString(NSAttributedString(
            string: "Plain body text",
            attributes: [.font: TextStyle.body.font]
        ))
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        controller.selectionDidChange()
        #expect(controller.currentStyle == .body)
    }

    @Test @MainActor func applyStyleImmediatelyUpdatesCurrentStyle() throws {
        let scrollView = PagedTextView.makePagedScrollView()
        let textView = try #require(scrollView.documentView as? PagedTextView)
        let controller = RichTextController()
        controller.textView = textView

        textView.textStorage?.setAttributedString(NSAttributedString(string: "Some text"))
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        controller.selectionDidChange()
        #expect(controller.currentStyle == .body)

        controller.applyStyle(.heading)
        #expect(controller.currentStyle == .heading)
    }

    @Test @MainActor func applyStyleRespectsTheControllersFontFamily() throws {
        let scrollView = PagedTextView.makePagedScrollView()
        let textView = try #require(scrollView.documentView as? PagedTextView)
        let controller = RichTextController()
        controller.textView = textView
        controller.fontFamilyName = "Georgia"

        textView.textStorage?.setAttributedString(NSAttributedString(string: "Some text"))
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        controller.applyStyle(.heading)

        let font = try #require(textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.familyName == "Georgia")
        #expect(font.pointSize == TextStyle.heading.pointSize)
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
    }

    @Test @MainActor func richTextCodecReadsExistingRTF() throws {
        let original = NSAttributedString(string: "Existing chapter")
        let rtf = try #require(original.rtf(
            from: NSRange(location: 0, length: original.length),
            documentAttributes: [:]
        ))

        #expect(RichTextCodec.decode(rtf)?.string == "Existing chapter")
    }

    @Test @MainActor func decodeBackfillsDefaultParagraphSpacingOnPlainText() throws {
        // A chapter written before paragraph spacing existed: separate
        // paragraphs joined by a plain "\n", no paragraphStyle at all.
        let original = NSAttributedString(string: "First paragraph.\nSecond paragraph.")
        let rtf = try #require(original.rtf(
            from: NSRange(location: 0, length: original.length),
            documentAttributes: [:]
        ))

        let decoded = try #require(RichTextCodec.decode(rtf))
        for location in [0, decoded.string.count - 1] {
            let style = try #require(
                decoded.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
            )
            #expect(style.paragraphSpacing == RichTextCodec.defaultParagraphSpacing)
        }
    }

    @Test @MainActor func decodePreservesAnExplicitNonDefaultParagraphSpacing() throws {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 20
        let original = NSAttributedString(
            string: "Custom spacing.",
            attributes: [.paragraphStyle: paragraph]
        )
        let rtf = try #require(original.rtf(
            from: NSRange(location: 0, length: original.length),
            documentAttributes: [:]
        ))

        let decoded = try #require(RichTextCodec.decode(rtf))
        let style = try #require(decoded.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.paragraphSpacing == 20)
    }

    @Test @MainActor func paragraphSpacingRoundTripsThroughEncodeAndDecode() throws {
        let original = NSAttributedString(
            string: "Round trips.",
            attributes: [.paragraphStyle: RichTextCodec.defaultParagraphStyle]
        )
        let encoded = try #require(RichTextCodec.encode(original))
        let decoded = try #require(RichTextCodec.decode(encoded))
        let style = try #require(decoded.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.paragraphSpacing == RichTextCodec.defaultParagraphSpacing)
    }

    @Test @MainActor func richTextCodecEmbedsAndRestoresAnImage() throws {
        let image = NSImage(size: NSSize(width: 40, height: 20), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let attachment = NSTextAttachment(data: image.tiffRepresentation, ofType: "public.tiff")
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: 0, width: 40, height: 20)
        let original = NSMutableAttributedString(string: "Before ")
        original.append(NSAttributedString(attachment: attachment))
        original.append(NSAttributedString(string: " after"))

        let encoded = try #require(RichTextCodec.encode(original))
        let decoded = try #require(RichTextCodec.decode(encoded))
        let restored = decoded.attribute(
            .attachment,
            at: "Before ".count,
            effectiveRange: nil
        ) as? NSTextAttachment

        #expect(restored != nil)
        #expect(restored?.bounds.size == NSSize(width: 40, height: 20))
        #expect(decoded.string == "Before \u{fffc} after")
    }

    @Test func oversizedImageFitsPageMarginsWithoutChangingAspectRatio() {
        let size = RichTextImageInserter.fittedSize(
            NSSize(width: 1200, height: 600),
            maximumWidth: 468
        )

        #expect(size == NSSize(width: 468, height: 234))
    }

    @Test func imageResizePreservesAspectRatioAndPageWidth() {
        let size = ImageResizeGeometry.resizedSize(
            original: NSSize(width: 400, height: 200),
            horizontalDelta: 200,
            verticalDelta: 0,
            draggingLeftEdge: false,
            draggingTopEdge: false,
            minimumWidth: 32,
            maximumWidth: 468
        )

        #expect(size == NSSize(width: 468, height: 234))
    }

    @Test func imageResizeUsesTheDraggedCornerDirection() {
        let size = ImageResizeGeometry.resizedSize(
            original: NSSize(width: 400, height: 200),
            horizontalDelta: 100,
            verticalDelta: 0,
            draggingLeftEdge: true,
            draggingTopEdge: false,
            minimumWidth: 32,
            maximumWidth: 468
        )

        #expect(size == NSSize(width: 300, height: 150))
    }

    @Test func imageResizeRespondsToVerticalCornerDrag() {
        let size = ImageResizeGeometry.resizedSize(
            original: NSSize(width: 400, height: 200),
            horizontalDelta: 0,
            verticalDelta: -50,
            draggingLeftEdge: false,
            draggingTopEdge: false,
            minimumWidth: 32,
            maximumWidth: 468
        )

        #expect(size == NSSize(width: 300, height: 150))
    }

    @Test func floatingImageExclusionMatchesImageHeightBelowFirstLine() {
        // An image laid out partway down page 1 (well below the page's first
        // line) must reserve exactly its own displayed height — plus the wrap
        // gutter — so text does not leave a hole above the image.
        let imageRect = NSRect(x: 0, y: 200, width: 240, height: 150)
        let rect = PagedEditorLayout.letter.exclusionRect(forImageRect: imageRect)

        #expect(rect.minY == 200)
        #expect(rect.height == 158)
    }

    @Test func floatingImageExclusionClampsWidthToContentWidth() {
        let imageRect = NSRect(x: 0, y: 0, width: 468, height: 100)
        let rect = PagedEditorLayout.letter.exclusionRect(forImageRect: imageRect)

        #expect(rect.width == PagedEditorLayout.letter.contentWidth)
    }

    @Test func floatingImageExclusionStopsAtPageTextBottom() {
        let imageRect = NSRect(x: 0, y: 560, width: 240, height: 190)
        let rect = PagedEditorLayout.letter.exclusionRect(forImageRect: imageRect)

        #expect(rect.maxY == PagedEditorLayout.letter.contentBottom(forPage: 0))
    }

    /// An image anchored to the first line of a page *other than page 0* has
    /// its top edge translated back into TextKit's pre-page-break "proposed"
    /// coordinate space (see the big comment on `exclusionRect`). The bottom
    /// edge must shift by that same amount, or the rect's height balloons by
    /// a full page margin/gap: on a real manuscript this produced a tall,
    /// bogus exclusion straddling the page break, which made TextKit collapse
    /// everything after it into one degenerate zero-size line for the rest of
    /// the chapter (11,654 characters in the reproduction case).
    @Test func floatingImageExclusionHeightIsUnaffectedByFirstLineTranslation() {
        let layout = PagedEditorLayout.letter
        let page1Top = layout.contentTop(forPage: 1)
        let imageRect = NSRect(x: 0, y: page1Top, width: 240, height: 150)
        let rect = layout.exclusionRect(forImageRect: imageRect)

        // Height must match the un-translated image height + gutter, exactly
        // as it would for the same image sitting mid-page (not inflated by
        // the page's margins/gap just because it happens to anchor the
        // page's first line).
        #expect(rect.height == 158)
        #expect(rect.maxY == rect.minY + 158)
    }

    @Test @MainActor func imageInsertionReplacesTheCurrentSelection() {
        let textView = NSTextView()
        textView.string = "before selected after"
        textView.setSelectedRange(NSRange(location: 7, length: 8))
        let image = NSImage(size: NSSize(width: 100, height: 50))

        let inserted = RichTextImageInserter.insert(
            image,
            into: textView,
            at: textView.selectedRange(),
            maximumWidth: 468
        )

        #expect(inserted)
        #expect(textView.string == "before \u{fffc} after")
        #expect(textView.selectedRange() == NSRange(location: 8, length: 0))
    }

    @Test @MainActor func pastedOversizedImageIsFittedToPageWidth() throws {
        let image = NSImage(size: NSSize(width: 1200, height: 600), flipped: false) { rect in
            NSColor.systemPurple.setFill()
            rect.fill()
            return true
        }
        let attachment = NSTextAttachment(data: image.tiffRepresentation, ofType: "public.tiff")
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: 0, width: 1200, height: 600)
        let textView = NSTextView()
        textView.textStorage?.setAttributedString(NSAttributedString(attachment: attachment))

        #expect(RichTextImageInserter.fitOversizedAttachments(
            in: textView,
            maximumWidth: 468
        ))
        let fitted = try #require(textView.textStorage?.attribute(
            .attachment,
            at: 0,
            effectiveRange: nil
        ) as? NSTextAttachment)

        #expect(fitted.bounds.size == NSSize(width: 468, height: 234))
    }

    @Test @MainActor func pastedOversizedFloatingImageIsFittedToPageWidth() throws {
        let scrollView = PagedTextView.makePagedScrollView()
        let textView = try #require(scrollView.documentView as? PagedTextView)
        let image = NSImage(size: NSSize(width: 1200, height: 600), flipped: false) { rect in
            NSColor.systemPurple.setFill()
            rect.fill()
            return true
        }
        RichTextImageInserter.insert(
            image,
            into: textView,
            at: NSRange(location: 0, length: 0),
            maximumWidth: 1200
        )
        textView.prepareFloatingImages()

        #expect(RichTextImageInserter.fitOversizedAttachments(
            in: textView,
            maximumWidth: textView.pageLayout.contentWidth
        ))
        let fitted = try #require(textView.textStorage?.attribute(
            .attachment,
            at: 0,
            effectiveRange: nil
        ) as? FloatingImageAttachment)

        #expect(fitted.displaySize == NSSize(width: 468, height: 234))
        #expect(fitted.image?.size == NSSize(width: 468, height: 234))
        #expect(fitted.bounds.size.width <= 1)
    }

    @Test @MainActor func pastedSmallImageKeepsItsOriginalSize() {
        let attachment = NSTextAttachment()
        attachment.bounds = NSRect(x: 0, y: 0, width: 200, height: 100)
        let textView = NSTextView()
        textView.textStorage?.setAttributedString(NSAttributedString(attachment: attachment))

        #expect(!RichTextImageInserter.fitOversizedAttachments(
            in: textView,
            maximumWidth: 468
        ))
        #expect(attachment.bounds.size == NSSize(width: 200, height: 100))
    }

    @Test @MainActor func pagedEditorRecognizesDraggedImageData() {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            NSColor.systemGreen.setFill()
            rect.fill()
            return true
        }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.clearContents()
        pasteboard.writeObjects([image])

        #expect(PagedTextView.draggedImage(from: pasteboard) != nil)
    }

    @Test @MainActor func pagedEditorHitTestsAnInsertedImageForSelection() throws {
        let scrollView = PagedTextView.makePagedScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 676, height: 792)
        scrollView.layoutSubtreeIfNeeded()
        let textView = try #require(scrollView.documentView as? PagedTextView)
        let image = NSImage(size: NSSize(width: 120, height: 60), flipped: false) { rect in
            NSColor.systemOrange.setFill()
            rect.fill()
            return true
        }
        #expect(RichTextImageInserter.insert(
            image,
            into: textView,
            at: NSRange(location: 0, length: 0),
            maximumWidth: textView.pageLayout.contentWidth
        ))
        textView.updatePageLayout()

        let range = NSRange(location: 0, length: 1)
        let rect = try #require(textView.imageAttachmentRect(for: range))

        #expect(textView.imageAttachmentRange(at: NSPoint(x: rect.midX, y: rect.midY)) == range)
    }

    @Test @MainActor func resizingAttachmentUpdatesItsLaidOutRectangle() throws {
        let scrollView = PagedTextView.makePagedScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 676, height: 792)
        scrollView.layoutSubtreeIfNeeded()
        let textView = try #require(scrollView.documentView as? PagedTextView)
        let image = NSImage(size: NSSize(width: 120, height: 60), flipped: false) { rect in
            NSColor.systemPink.setFill()
            rect.fill()
            return true
        }
        RichTextImageInserter.insert(
            image,
            into: textView,
            at: NSRange(location: 0, length: 0),
            maximumWidth: textView.pageLayout.contentWidth
        )
        let range = NSRange(location: 0, length: 1)
        #expect(try #require(textView.imageAttachmentRect(for: range)).width == 120)

        textView.setImageAttachmentSize(NSSize(width: 60, height: 30), at: range)

        #expect(try #require(textView.imageAttachmentRect(for: range)).width == 60)
    }

    @Test @MainActor func enlargingAttachmentScalesImageToFillItsFrame() throws {
        let scrollView = PagedTextView.makePagedScrollView()
        let textView = try #require(scrollView.documentView as? PagedTextView)
        let image = NSImage(size: NSSize(width: 120, height: 60), flipped: false) { rect in
            NSColor.systemIndigo.setFill()
            rect.fill()
            return true
        }
        RichTextImageInserter.insert(
            image,
            into: textView,
            at: NSRange(location: 0, length: 0),
            maximumWidth: textView.pageLayout.contentWidth
        )
        let range = NSRange(location: 0, length: 1)

        textView.setImageAttachmentSize(NSSize(width: 240, height: 120), at: range)

        let attachment = try #require(textView.textStorage?.attribute(
            .attachment,
            at: 0,
            effectiveRange: nil
        ) as? NSTextAttachment)
        #expect(attachment.bounds.size == NSSize(width: 240, height: 120))
        #expect(attachment.image?.size == NSSize(width: 240, height: 120))
    }

    @Test @MainActor func floatingImageCreatesTextExclusionPath() throws {
        let scrollView = PagedTextView.makePagedScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 676, height: 792)
        scrollView.layoutSubtreeIfNeeded()
        let textView = try #require(scrollView.documentView as? PagedTextView)
        let image = NSImage(size: NSSize(width: 120, height: 60), flipped: false) { rect in
            NSColor.systemBrown.setFill()
            rect.fill()
            return true
        }
        RichTextImageInserter.insert(
            image,
            into: textView,
            at: NSRange(location: 0, length: 0),
            maximumWidth: textView.pageLayout.contentWidth
        )
        textView.textStorage?.append(NSAttributedString(
            string: " Text that should wrap alongside the image instead of starting below it."
        ))

        textView.prepareFloatingImages()
        textView.updatePageLayout()

        let floating = try #require(textView.textStorage?.attribute(
            .attachment,
            at: 0,
            effectiveRange: nil
        ) as? FloatingImageAttachment)
        #expect(floating.displaySize == NSSize(width: 120, height: 60))
        #expect(floating.bounds.width <= 1)
        #expect(textView.textContainer?.exclusionPaths.isEmpty == false)
        let exclusionBounds = try #require(textView.textContainer?.exclusionPaths.first?.bounds)
        #expect(exclusionBounds.width > 120)
        let imageRect = try #require(textView.imageAttachmentRect(
            for: NSRange(location: 0, length: 1)
        )).offsetBy(dx: -textView.textContainerOrigin.x, dy: -textView.textContainerOrigin.y)
        #expect(exclusionBounds.maxY >= imageRect.maxY + 8)
        let layoutManager = try #require(textView.layoutManager)
        let textGlyph = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: 1, length: 1),
            actualCharacterRange: nil
        )
        let wrappedLine = layoutManager.lineFragmentRect(
            forGlyphAt: textGlyph.location,
            effectiveRange: nil
        )
        #expect(wrappedLine.minX > 120, "wrapped line was \(wrappedLine)")
    }

    @Test @MainActor func floatingImageDoesNotReserveAFullSizeInlineGlyph() throws {
        let scrollView = PagedTextView.makePagedScrollView()
        let textView = try #require(scrollView.documentView as? PagedTextView)
        let image = NSImage(size: NSSize(width: 180, height: 120), flipped: false) { rect in
            NSColor.systemRed.setFill()
            rect.fill()
            return true
        }
        RichTextImageInserter.insert(
            image,
            into: textView,
            at: NSRange(location: 0, length: 0),
            maximumWidth: textView.pageLayout.contentWidth
        )

        textView.prepareFloatingImages()

        let layoutManager = try #require(textView.layoutManager)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: 0, length: 1),
            actualCharacterRange: nil
        )
        let inlineSize = layoutManager.attachmentSize(forGlyphAt: glyphRange.location)
        #expect(inlineSize.width <= 1)
        #expect(inlineSize.height <= 1)
    }

    @Test @MainActor func cellBackedPastedImageBecomesMovableFloatingImage() throws {
        let scrollView = PagedTextView.makePagedScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 676, height: 792)
        scrollView.layoutSubtreeIfNeeded()
        let textView = try #require(scrollView.documentView as? PagedTextView)
        let image = NSImage(size: NSSize(width: 180, height: 120), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let attachment = NSTextAttachment()
        attachment.attachmentCell = NSTextAttachmentCell(imageCell: image)
        attachment.bounds = .zero
        let body = NSMutableAttributedString(string: "Words before the pasted image ")
        let imageLocation = body.length
        body.append(NSAttributedString(attachment: attachment))
        body.append(NSAttributedString(string: " words after the pasted image."))
        textView.textStorage?.setAttributedString(body)

        textView.prepareFloatingImages()
        textView.updatePageLayout()

        let range = NSRange(location: imageLocation, length: 1)
        let floating = try #require(textView.textStorage?.attribute(
            .attachment,
            at: imageLocation,
            effectiveRange: nil
        ) as? FloatingImageAttachment)
        #expect(floating.displaySize == NSSize(width: 180, height: 120))
        let rect = try #require(textView.imageAttachmentRect(for: range))
        #expect(textView.imageAttachmentRange(at: NSPoint(x: rect.midX, y: rect.midY)) == range)
    }

    @Test @MainActor func floatingImageLineBreaksFromWordPasteCollapseIntoTextFlow() throws {
        let scrollView = PagedTextView.makePagedScrollView()
        let textView = try #require(scrollView.documentView as? PagedTextView)
        let image = NSImage(size: NSSize(width: 120, height: 80), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let attachment = NSTextAttachment()
        attachment.attachmentCell = NSTextAttachmentCell(imageCell: image)
        attachment.bounds = .zero
        let body = NSMutableAttributedString(string: "and\n")
        body.append(NSAttributedString(attachment: attachment))
        body.append(NSAttributedString(string: "\nmissing"))
        textView.textStorage?.setAttributedString(body)

        textView.prepareFloatingImages()

        #expect(textView.string == "and \u{fffc} missing")
    }

    @Test @MainActor func backspaceDoesNotDeleteFloatingImageAnchor() throws {
        let scrollView = PagedTextView.makePagedScrollView()
        let textView = try #require(scrollView.documentView as? PagedTextView)
        let image = NSImage(size: NSSize(width: 120, height: 80), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        RichTextImageInserter.insert(
            image,
            into: textView,
            at: NSRange(location: 0, length: 0),
            maximumWidth: textView.pageLayout.contentWidth
        )
        textView.textStorage?.append(NSAttributedString(string: " missing"))
        textView.prepareFloatingImages()
        textView.setSelectedRange(NSRange(location: 1, length: 0))

        #expect(!textView.shouldChangeText(in: NSRange(location: 0, length: 1), replacementString: ""))
        #expect(textView.textStorage?.attribute(.attachment, at: 0, effectiveRange: nil) is FloatingImageAttachment)
    }

    @Test @MainActor func preparingFloatingImageAfterInitialLayoutRegeneratesAttachmentGlyph() throws {
        let scrollView = PagedTextView.makePagedScrollView()
        let textView = try #require(scrollView.documentView as? PagedTextView)
        let image = NSImage(size: NSSize(width: 180, height: 120), flipped: false) { rect in
            NSColor.systemRed.setFill()
            rect.fill()
            return true
        }
        RichTextImageInserter.insert(
            image,
            into: textView,
            at: NSRange(location: 0, length: 0),
            maximumWidth: textView.pageLayout.contentWidth
        )

        let layoutManager = try #require(textView.layoutManager)
        let textContainer = try #require(textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)
        textView.prepareFloatingImages()

        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: 0, length: 1),
            actualCharacterRange: nil
        )
        let inlineSize = layoutManager.attachmentSize(forGlyphAt: glyphRange.location)
        #expect(inlineSize.width <= 1)
        #expect(inlineSize.height <= 1)
    }

    @Test @MainActor func floatingImageAnchorsToItsOwnLineNotParagraphTop() throws {
        let scrollView = PagedTextView.makePagedScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 676, height: 792)
        scrollView.layoutSubtreeIfNeeded()
        let textView = try #require(scrollView.documentView as? PagedTextView)
        // A long run of text, an image referenced partway through it, then more
        // text — the shape of a Word-imported image sitting mid-paragraph.
        let prefix = String(repeating: "Words before the referenced image ", count: 8)
        textView.string = prefix
        let imageLocation = (prefix as NSString).length
        let image = NSImage(size: NSSize(width: 120, height: 80), flipped: false) { rect in
            NSColor.systemOrange.setFill()
            rect.fill()
            return true
        }
        RichTextImageInserter.insert(
            image,
            into: textView,
            at: NSRange(location: imageLocation, length: 0),
            maximumWidth: textView.pageLayout.contentWidth
        )
        textView.textStorage?.append(NSAttributedString(
            string: " More words after the image that belong to the same paragraph."
        ))

        textView.prepareFloatingImages()
        textView.updatePageLayout()

        let imageRect = try #require(textView.imageAttachmentRect(
            for: NSRange(location: imageLocation, length: 1)
        ))
        let layoutManager = try #require(textView.layoutManager)
        let firstGlyph = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: 0, length: 1),
            actualCharacterRange: nil
        )
        let firstLine = layoutManager.lineFragmentRect(
            forGlyphAt: firstGlyph.location,
            effectiveRange: nil
        )

        // The image is no longer lifted to the paragraph's first line: it floats
        // beside its own line, which is well below the top of the text...
        #expect(imageRect.minY > firstLine.minY + 1,
                "image should sit below the first line, not be lifted to the paragraph top")
        // ...and the first line (above the image) is full width, not wrapped.
        #expect(firstLine.minX < 1,
                "text above the image should not be wrapped around it: \(firstLine)")
    }

    @Test @MainActor func rebuildingFloatingLayoutDoesNotMoveImageDownward() throws {
        let scrollView = PagedTextView.makePagedScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 676, height: 792)
        scrollView.layoutSubtreeIfNeeded()
        let textView = try #require(scrollView.documentView as? PagedTextView)
        let image = NSImage(size: NSSize(width: 120, height: 80), flipped: false) { rect in
            NSColor.systemPurple.setFill()
            rect.fill()
            return true
        }
        RichTextImageInserter.insert(
            image,
            into: textView,
            at: NSRange(location: 0, length: 0),
            maximumWidth: textView.pageLayout.contentWidth
        )
        textView.textStorage?.append(NSAttributedString(
            string: String(repeating: "Text alongside the image. ", count: 20)
        ))
        textView.prepareFloatingImages()
        textView.updatePageLayout()
        let range = NSRange(location: 0, length: 1)
        let initialRect = try #require(textView.imageAttachmentRect(for: range))

        textView.updatePageLayout()
        textView.updatePageLayout()

        let rebuiltRect = try #require(textView.imageAttachmentRect(for: range))
        #expect(abs(rebuiltRect.minY - initialRect.minY) < 0.5)
    }

    @Test @MainActor func floatingImageRoundTripsAtDisplaySizeForPrinting() throws {
        let scrollView = PagedTextView.makePagedScrollView()
        let textView = try #require(scrollView.documentView as? PagedTextView)
        let image = NSImage(size: NSSize(width: 160, height: 80), flipped: false) { rect in
            NSColor.systemCyan.setFill()
            rect.fill()
            return true
        }
        RichTextImageInserter.insert(
            image,
            into: textView,
            at: NSRange(location: 0, length: 0),
            maximumWidth: textView.pageLayout.contentWidth
        )
        textView.prepareFloatingImages()

        let encoded = try #require(RichTextCodec.encode(textView.attributedString()))
        let decoded = try #require(RichTextCodec.decode(encoded))
        let restored = try #require(decoded.attribute(
            .attachment,
            at: 0,
            effectiveRange: nil
        ) as? NSTextAttachment)

        #expect(restored.bounds.size == NSSize(width: 160, height: 80))
        #expect(restored.image?.size == NSSize(width: 160, height: 80))
    }

    @Test @MainActor func resizingFloatingImageUpdatesImageAndWrapBoundary() throws {
        let scrollView = PagedTextView.makePagedScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 676, height: 792)
        scrollView.layoutSubtreeIfNeeded()
        let textView = try #require(scrollView.documentView as? PagedTextView)
        let image = NSImage(size: NSSize(width: 120, height: 60), flipped: false) { rect in
            NSColor.systemMint.setFill()
            rect.fill()
            return true
        }
        RichTextImageInserter.insert(
            image,
            into: textView,
            at: NSRange(location: 0, length: 0),
            maximumWidth: textView.pageLayout.contentWidth
        )
        textView.textStorage?.append(NSAttributedString(string: " Wrapped text beside the image."))
        textView.prepareFloatingImages()
        let range = NSRange(location: 0, length: 1)

        textView.setImageAttachmentSize(NSSize(width: 240, height: 120), at: range)

        let floating = try #require(textView.textStorage?.attribute(
            .attachment,
            at: 0,
            effectiveRange: nil
        ) as? FloatingImageAttachment)
        #expect(floating.displaySize == NSSize(width: 240, height: 120))
        #expect(floating.image?.size == NSSize(width: 240, height: 120))
        #expect(textView.imageAttachmentRect(for: range)?.size == NSSize(width: 240, height: 120))
        #expect(textView.textContainer?.exclusionPaths.first?.bounds.width ?? 0 > 240)
    }

    @Test @MainActor func draggingSelectedImageHandleResizesAttachment() throws {
        let scrollView = PagedTextView.makePagedScrollView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 676, height: 792),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        window.layoutIfNeeded()
        let textView = try #require(scrollView.documentView as? PagedTextView)
        let image = NSImage(size: NSSize(width: 120, height: 60), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        RichTextImageInserter.insert(
            image,
            into: textView,
            at: NSRange(location: 0, length: 0),
            maximumWidth: textView.pageLayout.contentWidth
        )
        let range = NSRange(location: 0, length: 1)
        let imageRect = try #require(textView.imageAttachmentRect(for: range))

        textView.mouseDown(with: mouseEvent(
            .leftMouseDown,
            at: NSPoint(x: imageRect.midX, y: imageRect.midY),
            in: textView,
            window: window
        ))
        textView.mouseDown(with: mouseEvent(
            .leftMouseDown,
            at: NSPoint(x: imageRect.maxX, y: imageRect.maxY),
            in: textView,
            window: window
        ))
        textView.mouseDragged(with: mouseEvent(
            .leftMouseDragged,
            at: NSPoint(x: imageRect.maxX - 60, y: imageRect.maxY),
            in: textView,
            window: window
        ))
        textView.mouseUp(with: mouseEvent(
            .leftMouseUp,
            at: NSPoint(x: imageRect.maxX - 60, y: imageRect.maxY),
            in: textView,
            window: window
        ))

        #expect(try #require(textView.imageAttachmentRect(for: range)).width == 60)
    }

    @MainActor
    private func mouseEvent(
        _ type: NSEvent.EventType,
        at viewPoint: NSPoint,
        in view: NSView,
        window: NSWindow
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: view.convert(viewPoint, to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    @Test func pagedEditorPlacesFirstLineAtTopMarginWithoutDuplicateTitle() {
        let layout = PagedEditorLayout.letter

        #expect(layout.lineOriginY(proposedY: 0, lineHeight: 20) == 72)
    }

    @Test func pagedEditorMovesWholeLineToNextPage() {
        let layout = PagedEditorLayout.letter

        #expect(layout.lineOriginY(proposedY: 710, lineHeight: 20) == 888)
        #expect(layout.pageIndex(atY: 888) == 1)
    }

    @Test func pagedEditorCountsPagesFromLaidOutContent() {
        let layout = PagedEditorLayout.letter

        #expect(layout.pageCount(forContentMaxY: 700) == 1)
        #expect(layout.pageCount(forContentMaxY: 900) == 2)
    }

    @Test func documentControllerOverridesTheSystemOpenPath() throws {
        let selector = NSSelectorFromString("openDocumentWithContentsOfURL:display:completionHandler:")
        let inklingMethod = try #require(class_getInstanceMethod(InklingDocumentController.self, selector))
        let appKitMethod = try #require(class_getInstanceMethod(NSDocumentController.self, selector))

        #expect(method_getImplementation(inklingMethod) != method_getImplementation(appKitMethod))
    }

    @Test func untouchedUntitledDocumentIsReplaceable() {
        #expect(InklingDocumentController.isReplaceableUntitled(
            fileURL: nil,
            isDocumentEdited: false
        ))
    }

    @Test func editedOrSavedDocumentIsNotReplaceable() {
        #expect(!InklingDocumentController.isReplaceableUntitled(
            fileURL: nil,
            isDocumentEdited: true
        ))
        #expect(!InklingDocumentController.isReplaceableUntitled(
            fileURL: URL(fileURLWithPath: "/tmp/saved.inkling"),
            isDocumentEdited: false
        ))
    }

    @Test func documentDropOnlyAcceptsInklingFiles() {
        let inkling = URL(fileURLWithPath: "/tmp/My Project.inkling")
        let uppercase = URL(fileURLWithPath: "/tmp/Archive.INKLING")
        let text = URL(fileURLWithPath: "/tmp/notes.txt")

        #expect(InklingDocumentDrop.isInklingDocumentURL(inkling))
        #expect(InklingDocumentDrop.isInklingDocumentURL(uppercase))
        #expect(!InklingDocumentDrop.isInklingDocumentURL(text))
    }

    @Test func documentDropDecodesFileURLPayload() throws {
        let url = URL(fileURLWithPath: "/tmp/My Project.inkling")
        let data = try #require(url.absoluteString.data(using: .utf8))

        #expect(InklingDocumentDrop.fileURL(from: data) == url)
        #expect(InklingDocumentDrop.fileURL(from: url as NSURL) == url)
        #expect(InklingDocumentDrop.fileURL(from: "not a file URL") == nil)
    }

    @Test func standardDocumentPrintCommandIsImplementedByInklingDocument() throws {
        let selector = NSSelectorFromString("printOperationWithSettings:error:")
        let inklingMethod = try #require(class_getInstanceMethod(InklingDocument.self, selector))
        let appKitMethod = try #require(class_getInstanceMethod(NSDocument.self, selector))

        #expect(method_getImplementation(inklingMethod) != method_getImplementation(appKitMethod))
    }

    @Test func existingDocumentsRequireExplicitSaving() {
        #expect(!InklingDocument.autosavesInPlace)
    }

    @Test @MainActor func printableChapterUsesBodyWithoutPrependingTitle() throws {
        let body = NSAttributedString(
            string: "A heading\nBody text",
            attributes: [.font: NSFont.systemFont(ofSize: 13)]
        )
        let data = try #require(body.rtf(
            from: NSRange(location: 0, length: body.length),
            documentAttributes: [:]
        ))

        let printable = ManuscriptPrinter.attributedString(
            for: PrintableChapter(title: "Chapter One", bodyData: data)
        )

        // The chapter title is not added to the printed body; the author's own
        // heading at the top of the body stands on its own.
        #expect(printable.string == "A heading\nBody text")
        #expect(printable.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .black)
        #expect(printable.attribute(.foregroundColor, at: printable.length - 1, effectiveRange: nil) as? NSColor == .black)
    }

    @Test @MainActor func printableChapterContentDetection() {
        #expect(PrintableChapter(title: "Empty", bodyData: nil).hasContent == false)
        #expect(PrintableChapter(title: "Blank", bodyData: rtf("   \n\t ")).hasContent == false)
        #expect(PrintableChapter(title: "Real", bodyData: rtf("Some prose.")).hasContent == true)

        // An image-only chapter counts as content (its attachment glyph survives
        // whitespace trimming).
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let attachment = NSTextAttachment(data: image.tiffRepresentation, ofType: "public.tiff")
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: 0, width: 10, height: 10)
        let imageData = RichTextCodec.encode(NSAttributedString(attachment: attachment))
        #expect(PrintableChapter(title: "Image", bodyData: imageData).hasContent == true)
    }

    @Test @MainActor func everyChapterStartsOnItsOwnPage() {
        let pageSize = NSSize(width: 360, height: 500)
        let chapters = [
            PrintableChapter(title: "One", bodyData: nil),
            PrintableChapter(title: "Two", bodyData: nil),
            PrintableChapter(title: "Three", bodyData: nil),
        ]

        let view = ManuscriptPrintView(chapters: chapters, pageSize: pageSize)

        #expect(view.pageCount == 3)
        #expect(view.chapterIndex(forPage: 1) == 0)
        #expect(view.chapterIndex(forPage: 2) == 1)
        #expect(view.chapterIndex(forPage: 3) == 2)
    }

    @Test @MainActor func longChapterUsesWholeLineFragmentsOnEachPage() {
        let body = NSAttributedString(
            string: String(repeating: "A comfortably long manuscript line that wraps across the printable page. ", count: 220),
            attributes: [.font: NSFont.systemFont(ofSize: 14)]
        )
        let data = body.rtf(
            from: NSRange(location: 0, length: body.length),
            documentAttributes: [:]
        )
        let view = ManuscriptPrintView(
            chapters: [PrintableChapter(title: "Long Chapter", bodyData: data)],
            pageSize: NSSize(width: 260, height: 180)
        )

        #expect(view.pageCount > 1)
        #expect(view.pagesUseWholeLineFragments)
    }

    private func rtf(_ string: String) -> Data? {
        let attributed = NSAttributedString(string: string)
        return attributed.rtf(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [:]
        )
    }

    @Test func plainTextExportJoinsTitlesAndBodiesAcrossChapters() {
        let text = PlainTextExporter.plainText(for: [
            PrintableChapter(title: "Chapter One", bodyData: rtf("The beginning of it all.")),
            PrintableChapter(title: "Chapter Two", bodyData: rtf("And then it continued."))
        ])

        #expect(text == """
        Chapter One

        The beginning of it all.

        Chapter Two

        And then it continued.

        """)
    }

    @Test func plainTextExportNamesUntitledChaptersAndDropsImageGlyphs() {
        let text = PlainTextExporter.plainText(for: [
            PrintableChapter(title: "", bodyData: rtf("Look here: \u{fffc} a picture."))
        ])

        #expect(text == "Untitled Chapter\n\nLook here:  a picture.\n")
    }

    @Test func plainTextExportEmitsTitleOnlyForEmptyBody() {
        let text = PlainTextExporter.plainText(for: [
            PrintableChapter(title: "Prologue", bodyData: nil)
        ])

        #expect(text == "Prologue\n")
    }

    @Test func plainTextExportOfNoChaptersIsEmpty() {
        #expect(PlainTextExporter.plainText(for: []) == "")
    }

    // MARK: - Callouts

    /// Applies a callout to the middle paragraph of a three-paragraph string and
    /// returns the string plus that paragraph's range.
    private func calloutBody(kind: CalloutKind) -> (body: NSMutableAttributedString, calloutRange: NSRange) {
        let body = NSMutableAttributedString(string: "Intro paragraph.\nThe callout body.\nOutro paragraph.")
        let middle = (body.string as NSString).paragraphRange(for: NSRange(location: 20, length: 0))
        CalloutStyling.apply(kind, to: body, range: middle)
        return (body, middle)
    }

    @Test func calloutKindLabelsAndColorsAreStable() {
        #expect(CalloutKind.note.exportLabel == "NOTE")
        #expect(CalloutKind.warning.exportLabel == "WARNING")
        #expect(CalloutKind(rawValue: "warning") == .warning)
        // The retired inline "sidebar" kind migrates to Note on load.
        #expect(CalloutKind(storedRawValue: "sidebar") == .note)
        #expect(CalloutKind(storedRawValue: "note") == .note)
        // Hex "3B82F6" → (59, 130, 246)/255.
        let note = CalloutKind.note.accentColor.usingColorSpace(.sRGB)
        #expect(abs((note?.redComponent ?? 0) - 59.0 / 255) < 0.001)
        #expect(abs((note?.blueComponent ?? 0) - 246.0 / 255) < 0.001)
    }

    @Test func applyingCalloutInsetsAndSpacesItsParagraph() {
        let (body, range) = calloutBody(kind: .note)
        let style = body.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.headIndent == CalloutStyling.sideInset)
        #expect(style?.firstLineHeadIndent == CalloutStyling.sideInset)
        #expect(style?.tailIndent == -CalloutStyling.sideInset)
        // Single-paragraph callout reserves both the label/top room and the bottom room.
        #expect(style?.paragraphSpacingBefore == CalloutStyling.topReserve)
        #expect(style?.paragraphSpacing == CalloutStyling.bottomReserve)
    }

    @Test @MainActor func calloutRangeAndKindRoundTripThroughEncodeAndDecode() throws {
        let (body, range) = calloutBody(kind: .warning)
        let encoded = try #require(RichTextCodec.encode(body))
        let decoded = try #require(RichTextCodec.decode(encoded))

        let kind = decoded.attribute(.inklingCallout, at: range.location, effectiveRange: nil) as? String
        #expect(kind == "warning")
        // The reserved-padding style is re-derived on decode, not just the tag.
        let style = decoded.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.headIndent == CalloutStyling.sideInset)
        // Body text outside the callout carries no callout tag.
        #expect(decoded.attribute(.inklingCallout, at: 0, effectiveRange: nil) == nil)
    }

    @Test @MainActor func bodyWithoutCalloutsEncodesNoCalloutSidecar() throws {
        // A plain body still round-trips with no callout tags anywhere.
        let body = NSAttributedString(string: "Just ordinary prose.")
        let encoded = try #require(RichTextCodec.encode(body))
        let decoded = try #require(RichTextCodec.decode(encoded))
        #expect(decoded.attribute(.inklingCallout, at: 0, effectiveRange: nil) == nil)
    }

    @Test @MainActor func applyCalloutTagsTheSelectedParagraphAndTracksCurrentKind() throws {
        let scrollView = PagedTextView.makePagedScrollView()
        let textView = try #require(scrollView.documentView as? PagedTextView)
        textView.textStorage?.setAttributedString(NSAttributedString(string: "First para.\nSecond para."))
        let controller = RichTextController()
        controller.textView = textView

        textView.setSelectedRange(NSRange(location: 2, length: 0))  // inside the first paragraph
        controller.applyCallout(.warning)

        #expect(textView.textStorage?.attribute(.inklingCallout, at: 0, effectiveRange: nil) as? String == "warning")
        #expect(controller.currentCallout == .warning)
        // The second paragraph is untouched.
        #expect(textView.textStorage?.attribute(.inklingCallout, at: 15, effectiveRange: nil) == nil)

        controller.removeCallout()
        #expect(textView.textStorage?.attribute(.inklingCallout, at: 0, effectiveRange: nil) == nil)
        #expect(controller.currentCallout == nil)
    }

    @Test @MainActor func plainTextExportWrapsCalloutsInLabeledMarkers() throws {
        let (body, _) = calloutBody(kind: .note)
        let data = try #require(RichTextCodec.encode(body))
        let text = PlainTextExporter.plainText(for: [PrintableChapter(title: "Ch", bodyData: data)])

        #expect(text == """
        Ch

        Intro paragraph.

        [NOTE]
        The callout body.
        [/NOTE]

        Outro paragraph.

        """)
    }

    @Test @MainActor func wordExportGivesCalloutsABorderedStyleAndLabel() throws {
        let (body, _) = calloutBody(kind: .warning)
        let data = try #require(RichTextCodec.encode(body))
        let docx = try WordDocumentExporter.docxData(for: PrintableChapter(title: "Ch", bodyData: data))
        let reader = try MinimalZipReader(data: docx)
        let documentXML = try #require(String(data: reader.contents(of: "word/document.xml"), encoding: .utf8))
        let stylesXML = try #require(String(data: reader.contents(of: "word/styles.xml"), encoding: .utf8))

        #expect(documentXML.contains(#"<w:pStyle w:val="WarningCallout"/>"#))
        #expect(documentXML.contains("WARNING — "))
        #expect(stylesXML.contains(#"w:styleId="WarningCallout""#))
        #expect(stylesXML.contains("<w:pBdr>"))
        #expect(stylesXML.contains(CalloutKind.warning.accentHex))
        #expect(stylesXML.contains(CalloutKind.warning.fillHex))
    }

    // MARK: - Floating image layout regressions (real-content failures)

    /// Reproduces the "text vanishes after an image" failure: large images near
    /// page boundaries in a multi-page chapter must not cause TextKit to drop the
    /// remaining text. Asserts every glyph is laid out.
    @Test @MainActor func largeImagesAcrossPagesDoNotDropText() throws {
        let scrollView = PagedTextView.makePagedScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 676, height: 792)
        scrollView.layoutSubtreeIfNeeded()
        let textView = try #require(scrollView.documentView as? PagedTextView)

        let paragraph = String(repeating: "This is a sentence of body text that fills the lines. ", count: 30) + "\n"
        let big = NSImage(size: NSSize(width: 300, height: 380), flipped: false) { rect in
            NSColor.systemTeal.setFill(); rect.fill(); return true
        }
        let content = NSMutableAttributedString()
        for index in 0..<8 {
            content.append(NSAttributedString(string: paragraph, attributes: [.font: TextStyle.body.font]))
            if index == 2 || index == 5 {
                let attachment = NSTextAttachment()
                attachment.image = big
                attachment.bounds = NSRect(x: 0, y: 0, width: 300, height: 380)
                content.append(NSAttributedString(attachment: attachment))
                content.append(NSAttributedString(string: paragraph, attributes: [.font: TextStyle.body.font]))
            }
        }
        textView.textStorage?.setAttributedString(content)
        textView.frame = NSRect(x: 0, y: 0, width: 676, height: 792 * 8)
        textView.prepareFloatingImages()
        textView.updatePageLayout()

        let layoutManager = try #require(textView.layoutManager)
        let container = try #require(textView.textContainer)
        layoutManager.ensureLayout(for: container)
        let laid = layoutManager.glyphRange(for: container)
        #expect(NSMaxRange(laid) == layoutManager.numberOfGlyphs,
                "text dropped: only \(NSMaxRange(laid)) of \(layoutManager.numberOfGlyphs) glyphs laid out")
    }

    /// Reproduces the real "text vanishes" failure: text fills page 1, then a
    /// tall image that can't fit in the remainder gets bumped to the top of page
    /// 2 (a first-line image on a later page — the documented fragile case), then
    /// more text follows. The trailing text must still lay out with real height,
    /// not collapse into a degenerate zero-height line.
    @Test @MainActor func imageBumpedToNextPageTopDoesNotDropTrailingText() throws {
        let scrollView = PagedTextView.makePagedScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 676, height: 792)
        scrollView.layoutSubtreeIfNeeded()
        let textView = try #require(scrollView.documentView as? PagedTextView)

        let line = "This is a line of ordinary body text that fills most of the column width. "
        // Roughly one page of text so the image lands low on page 1.
        let pageish = String(repeating: line, count: 34) + "\n"
        let trailing = "\n" + String(repeating: "Trailing sentence after the image. ", count: 20)

        let tall = NSImage(size: NSSize(width: 240, height: 460), flipped: false) { rect in
            NSColor.systemIndigo.setFill(); rect.fill(); return true
        }
        let attachment = NSTextAttachment()
        attachment.image = tall
        attachment.bounds = NSRect(x: 0, y: 0, width: 240, height: 460)

        let content = NSMutableAttributedString(string: pageish, attributes: [.font: TextStyle.body.font])
        let imageLocation = content.length
        content.append(NSAttributedString(attachment: attachment))
        content.append(NSAttributedString(string: trailing, attributes: [.font: TextStyle.body.font]))

        textView.textStorage?.setAttributedString(content)
        textView.prepareFloatingImages()
        textView.updatePageLayout()

        let lm = try #require(textView.layoutManager)
        let imageRect = try #require(textView.imageAttachmentRect(for: NSRange(location: imageLocation, length: 1)))

        // The last glyph of the trailing text must be laid out with a real line
        // height and sit below the image — not collapsed to a degenerate line.
        let total = lm.numberOfGlyphs
        let lastLine = lm.lineFragmentRect(forGlyphAt: total - 1, effectiveRange: nil)
        #expect(lastLine.height > 5,
                "trailing text collapsed to a degenerate line (height \(lastLine.height)) — text vanished")
        #expect(lastLine.minY > imageRect.minY,
                "trailing text should lay out at/after the image, not above it")
    }

    // MARK: - Floating sidebars

    /// A body with one floating sidebar anchored after "Body ".
    private func sidebarBody(text: String = "Context note.", width: CGFloat = 180) -> Data? {
        let content = RichTextCodec.encode(NSAttributedString(string: text))
        let sidebar = SidebarAttachment(
            contentData: content,
            width: width,
            position: FloatingImagePosition(page: 1, origin: CGPoint(x: 300, y: 200)),
            contentHeight: 40
        )
        let body = NSMutableAttributedString(string: "Body ")
        body.append(NSAttributedString(attachment: sidebar))
        return RichTextCodec.encode(body)
    }

    @Test @MainActor func sidebarRoundTripsThroughEncodeAndDecode() throws {
        let data = try #require(sidebarBody(text: "Historical context.", width: 200))
        let decoded = try #require(RichTextCodec.decode(data))
        let restored = try #require(
            decoded.attribute(.attachment, at: "Body ".count, effectiveRange: nil) as? SidebarAttachment
        )
        #expect(restored.width == 200)
        #expect(restored.position?.page == 1)
        #expect(restored.position?.origin == CGPoint(x: 300, y: 200))
        #expect(RichTextCodec.decode(restored.contentData)?.string == "Historical context.")
    }

    @Test @MainActor func sidebarStyleHeightGrowsWithContent() {
        let one = SidebarStyle.boxHeight(forContentHeight: 20)
        let taller = SidebarStyle.boxHeight(forContentHeight: 120)
        #expect(taller > one)
        // Room for header + padding is always reserved above the text.
        #expect(one >= SidebarStyle.headerHeight + SidebarStyle.minContentHeight)
    }

    @Test @MainActor func plainTextExportWrapsSidebarContentInMarkers() throws {
        let data = try #require(sidebarBody(text: "An aside."))
        let text = PlainTextExporter.plainText(for: [PrintableChapter(title: "Ch", bodyData: data)])
        #expect(text.contains("[SIDEBAR]"))
        #expect(text.contains("An aside."))
        #expect(text.contains("[/SIDEBAR]"))
    }

    @Test @MainActor func wordExportGivesSidebarABorderedStyleAndLabel() throws {
        let data = try #require(sidebarBody(text: "An aside."))
        let docx = try WordDocumentExporter.docxData(for: PrintableChapter(title: "Ch", bodyData: data))
        let reader = try MinimalZipReader(data: docx)
        let documentXML = try #require(String(data: reader.contents(of: "word/document.xml"), encoding: .utf8))
        let stylesXML = try #require(String(data: reader.contents(of: "word/styles.xml"), encoding: .utf8))

        #expect(documentXML.contains(#"<w:pStyle w:val="SidebarBox"/>"#))
        #expect(documentXML.contains("SIDEBAR — "))
        #expect(documentXML.contains(#"<w:t xml:space="preserve">An aside.</w:t>"#))
        #expect(stylesXML.contains(#"w:styleId="SidebarBox""#))
        #expect(stylesXML.contains(SidebarStyle.accentHex))
    }

    @Test @MainActor func insertingSidebarAddsAnEditableBox() throws {
        let scrollView = PagedTextView.makePagedScrollView()
        let textView = try #require(scrollView.documentView as? PagedTextView)
        textView.textStorage?.setAttributedString(NSAttributedString(string: "The body text."))
        textView.setSelectedRange(NSRange(location: 4, length: 0))

        textView.insertSidebar()

        var found: SidebarAttachment?
        textView.textStorage?.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: textView.textStorage?.length ?? 0)
        ) { value, _, stop in
            if let sidebar = value as? SidebarAttachment { found = sidebar; stop.pointee = true }
        }
        let sidebar = try #require(found)
        #expect(sidebar.position != nil)
        #expect(sidebar.width == SidebarStyle.defaultWidth)
    }

    // MARK: - Project metadata

    @Test func metadataTitleFallsBackToDocumentName() {
        #expect(ProjectMetadata.effectiveTitle(stored: nil, documentName: "The Invisible Child") == "The Invisible Child")
        #expect(ProjectMetadata.effectiveTitle(stored: "  ", documentName: "My Doc") == "My Doc")
        #expect(ProjectMetadata.effectiveTitle(stored: "Untitled Project", documentName: "My Doc") == "My Doc")
        #expect(ProjectMetadata.effectiveTitle(stored: "Real Title", documentName: "My Doc") == "Real Title")
    }

    @Test func metadataAuthorFallsBackToAccountName() {
        #expect(ProjectMetadata.effectiveAuthor(stored: "Jane Roe", accountName: "Acct") == "Jane Roe")
        #expect(ProjectMetadata.effectiveAuthor(stored: nil, accountName: "Acct") == "Acct")
        #expect(ProjectMetadata.effectiveAuthor(stored: "   ", accountName: "Acct") == "Acct")
    }

    @Test func metadataSubtitleHasNoDerivedDefault() {
        #expect(ProjectMetadata.effectiveSubtitle(stored: "A Tale") == "A Tale")
        #expect(ProjectMetadata.effectiveSubtitle(stored: "  Trim Me  ") == "Trim Me")
        #expect(ProjectMetadata.effectiveSubtitle(stored: nil) == "")
        #expect(ProjectMetadata.effectiveSubtitle(stored: "   ") == "")
    }

    // MARK: - Running heads

    @Test func runningHeadUsesVersoRectoAndSuppressesChapterStart() {
        // Chapter-opening page: no running head.
        #expect(ManuscriptRunningHead.headText(bookTitle: "Book", chapterTitle: "Ch", page: 1, isChapterStart: true) == nil)
        // Verso (even) page shows the book title; recto (odd) shows the chapter.
        #expect(ManuscriptRunningHead.headText(bookTitle: "Book", chapterTitle: "Ch", page: 2, isChapterStart: false) == "Book")
        #expect(ManuscriptRunningHead.headText(bookTitle: "Book", chapterTitle: "Ch", page: 3, isChapterStart: false) == "Ch")
        // Empty title yields no head rather than a blank line.
        #expect(ManuscriptRunningHead.headText(bookTitle: "  ", chapterTitle: "Ch", page: 2, isChapterStart: false) == nil)
    }

    @Test func runningHeadFolioAndAlignment() {
        #expect(ManuscriptRunningHead.folioText(page: 42) == "42")
        #expect(ManuscriptRunningHead.headAlignment(page: 2) == .left)
        #expect(ManuscriptRunningHead.headAlignment(page: 3) == .right)
    }

    @Test @MainActor func printViewMarksFirstPageOfEachChapterAsChapterStart() {
        let chapters = [
            PrintableChapter(title: "One", bodyData: nil),
            PrintableChapter(title: "Two", bodyData: nil),
        ]
        let view = ManuscriptPrintView(chapters: chapters, pageSize: NSSize(width: 360, height: 500))

        #expect(view.isChapterStart(page: 1) == true)
        #expect(view.isChapterStart(page: 2) == true)   // first page of chapter Two
        #expect(view.isChapterStart(page: 3) == false)  // past the end
    }

    // MARK: - Title page

    @Test func titlePageStringCentersTitleAndAuthor() {
        let page = ManuscriptTitlePage.attributedString(title: "My Book", author: "Jane Roe")

        #expect(page.string.contains("My Book"))
        #expect(page.string.contains("Jane Roe"))
        let alignment = (page.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.alignment
        #expect(alignment == .center)
    }

    @Test func titlePageIncludesSubtitleBetweenTitleAndAuthor() {
        let page = ManuscriptTitlePage.attributedString(
            title: "My Book", subtitle: "A Cautionary Tale", author: "Jane Roe")

        #expect(page.string.contains("A Cautionary Tale"))
        let titleRange = (page.string as NSString).range(of: "My Book")
        let subtitleRange = (page.string as NSString).range(of: "A Cautionary Tale")
        let authorRange = (page.string as NSString).range(of: "Jane Roe")
        #expect(titleRange.location < subtitleRange.location)
        #expect(subtitleRange.location < authorRange.location)
    }

    @Test func titlePageOmitsBlankSubtitle() {
        let page = ManuscriptTitlePage.attributedString(
            title: "My Book", subtitle: "   ", author: "Jane Roe")
        #expect(page.string.contains("My Book"))
        #expect(page.string.contains("Jane Roe"))
        // No stray blank-subtitle lines: title and author only.
        #expect(!page.string.contains("  \n"))
    }

    @Test func titlePageWithOnlySubtitleStillRenders() {
        let page = ManuscriptTitlePage.attributedString(
            title: "", subtitle: "Just a Subtitle", author: "")
        #expect(page.string.contains("Just a Subtitle"))
    }

    @Test func titlePageOmitsBlankMetadata() {
        #expect(ManuscriptTitlePage.attributedString(title: "  ", subtitle: "", author: "").length == 0)
    }

    @Test @MainActor func titlePageAddsAnUnnumberedLeadingPage() {
        let chapters = [
            PrintableChapter(title: "One", bodyData: nil),
            PrintableChapter(title: "Two", bodyData: nil),
        ]
        let view = ManuscriptPrintView(
            chapters: chapters,
            pageSize: NSSize(width: 360, height: 500),
            bookTitle: "My Book",
            author: "Jane Roe",
            includeTitlePage: true
        )

        #expect(view.pageCount == 3)                    // title page + two chapters
        #expect(view.isTitlePage(page: 1) == true)
        #expect(view.isTitlePage(page: 2) == false)
        #expect(view.chapterIndex(forPage: 1) == nil)   // the title page maps to no chapter
        #expect(view.chapterIndex(forPage: 2) == 0)     // first chapter follows it
        #expect(view.chapterIndex(forPage: 3) == 1)
        #expect(view.isChapterStart(page: 2) == true)   // chapter One opens after the title page
    }

    @Test @MainActor func titlePageActuallyRendersTitleAndAuthorOnPageOne() {
        let view = ManuscriptPrintView(
            chapters: [PrintableChapter(title: "One", bodyData: nil)],
            pageSize: NSSize(width: 360, height: 500),
            bookTitle: "My Book",
            author: "Jane Roe",
            includeTitlePage: true
        )

        // Render the first physical page region and confirm the title-page text
        // is actually drawn (pagination math alone doesn't prove it paints).
        let pageRect = NSRect(x: 0, y: 0, width: 360, height: 500)
        let pdf = view.dataWithPDF(inside: pageRect)
        let text = PDFDocument(data: pdf)?.page(at: 0)?.string ?? ""

        #expect(text.contains("My Book"))
        #expect(text.contains("Jane Roe"))
    }

    @Test @MainActor func defaultPrintViewHasNoTitlePage() {
        let view = ManuscriptPrintView(
            chapters: [PrintableChapter(title: "One", bodyData: nil)],
            pageSize: NSSize(width: 360, height: 500)
        )

        #expect(view.isTitlePage(page: 1) == false)
        #expect(view.chapterIndex(forPage: 1) == 0)
    }

    // MARK: - Floating image placement geometry

    @Test func placementClampsImageInsideThePaper() {
        let paper = CGSize(width: 612, height: 792)
        let size = CGSize(width: 200, height: 100)

        // Past the right/bottom edges pulls back so the image stays fully on.
        #expect(FloatingImagePlacement.clampedOrigin(
            CGPoint(x: 700, y: 900), imageSize: size, paperSize: paper)
            == CGPoint(x: 412, y: 692))
        // Negative origin clamps to the top-left corner.
        #expect(FloatingImagePlacement.clampedOrigin(
            CGPoint(x: -50, y: -30), imageSize: size, paperSize: paper)
            == CGPoint(x: 0, y: 0))
        // A point already fully inside is unchanged.
        #expect(FloatingImagePlacement.clampedOrigin(
            CGPoint(x: 100, y: 100), imageSize: size, paperSize: paper)
            == CGPoint(x: 100, y: 100))
    }

    @Test func placementClampsOversizedImageToTheCorner() {
        let paper = CGSize(width: 612, height: 792)
        let size = CGSize(width: 800, height: 900)  // larger than the paper
        #expect(FloatingImagePlacement.clampedOrigin(
            CGPoint(x: 50, y: 50), imageSize: size, paperSize: paper)
            == CGPoint(x: 0, y: 0))
    }

    @Test func contentRectIsRelativeToTheTextColumnOrigin() {
        // Image at paper (72, 72) with 72pt margins sits at the column origin.
        let rect = FloatingImagePlacement.contentRect(
            origin: CGPoint(x: 72, y: 72),
            imageSize: CGSize(width: 100, height: 60),
            leftMargin: 72, topMargin: 72)
        #expect(rect == CGRect(x: 0, y: 0, width: 100, height: 60))

        // An image out in the left margin has a negative content-x.
        let inMargin = FloatingImagePlacement.contentRect(
            origin: CGPoint(x: 20, y: 200),
            imageSize: CGSize(width: 40, height: 40),
            leftMargin: 72, topMargin: 72)
        #expect(inMargin.minX == -52)
    }

    @Test func exclusionRectClipsToTheColumnAndGrowsByGutter() {
        // Image spanning the left part of a 468pt column.
        let rect = FloatingImagePlacement.exclusionRect(
            contentRect: CGRect(x: 0, y: 100, width: 200, height: 80),
            contentWidth: 468, gutter: 8)
        #expect(rect != nil)
        // Left edge is already at the column edge, so it can't grow past 0.
        #expect(rect?.minX == 0)
        // Right/top/bottom grew by the gutter.
        #expect(rect?.maxX == 208)
        #expect(rect?.minY == 92)
        #expect(rect?.maxY == 188)
    }

    @Test func exclusionRectClampsRightEdgeToColumnWidth() {
        let rect = FloatingImagePlacement.exclusionRect(
            contentRect: CGRect(x: 300, y: 0, width: 200, height: 50),
            contentWidth: 468, gutter: 8)
        #expect(rect?.maxX == 468)  // clipped to the column, not 508
    }

    @Test func exclusionRectIsNilWhenImageSitsEntirelyInAMargin() {
        // Entirely left of the column (negative maxX after clipping).
        #expect(FloatingImagePlacement.exclusionRect(
            contentRect: CGRect(x: -100, y: 0, width: 20, height: 20),
            contentWidth: 468, gutter: 0) == nil)
        // Entirely right of the column.
        #expect(FloatingImagePlacement.exclusionRect(
            contentRect: CGRect(x: 500, y: 0, width: 20, height: 20),
            contentWidth: 468, gutter: 0) == nil)
    }

    @Test func horizontalSnapPullsToTheNearestGuideWithinThreshold() {
        let leftMargin: CGFloat = 72
        let contentWidth: CGFloat = 468
        let imageWidth: CGFloat = 100

        // Near the left content edge (target x = 72).
        let left = FloatingImagePlacement.horizontalSnap(
            originX: 78, imageWidth: imageWidth,
            leftMargin: leftMargin, contentWidth: contentWidth, threshold: 12)
        #expect(left.x == 72)
        #expect(left.guide == .left)

        // Near the centered position (target = 72 + (468-100)/2 = 256).
        let center = FloatingImagePlacement.horizontalSnap(
            originX: 250, imageWidth: imageWidth,
            leftMargin: leftMargin, contentWidth: contentWidth, threshold: 12)
        #expect(center.x == 256)
        #expect(center.guide == .center)

        // Near the right content edge (target = 72 + 468 - 100 = 440).
        let right = FloatingImagePlacement.horizontalSnap(
            originX: 435, imageWidth: imageWidth,
            leftMargin: leftMargin, contentWidth: contentWidth, threshold: 12)
        #expect(right.x == 440)
        #expect(right.guide == .right)
    }

    @Test func horizontalSnapLeavesOriginAloneOutsideThreshold() {
        let result = FloatingImagePlacement.horizontalSnap(
            originX: 150, imageWidth: 100,
            leftMargin: 72, contentWidth: 468, threshold: 12)
        #expect(result.x == 150)
        #expect(result.guide == nil)
    }

    // MARK: - Floating image position persistence

    private func floatingImageAttachment(
        size: NSSize = NSSize(width: 40, height: 20)
    ) -> FloatingImageAttachment {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.systemGreen.setFill()
            rect.fill()
            return true
        }
        let base = NSTextAttachment(data: image.tiffRepresentation, ofType: "public.tiff")
        base.image = image
        base.bounds = NSRect(origin: .zero, size: size)
        return FloatingImageAttachment(copying: base, displaySize: size)
    }

    @Test @MainActor func codecRoundTripsAFloatingImagePosition() throws {
        let floating = floatingImageAttachment()
        floating.position = FloatingImagePosition(page: 2, origin: CGPoint(x: 120, y: 200))

        let original = NSMutableAttributedString(string: "Hi ")
        original.append(NSAttributedString(attachment: floating))

        let encoded = try #require(RichTextCodec.encode(original))
        let decoded = try #require(RichTextCodec.decode(encoded))

        let position = decoded.attribute(
            .inklingFloatingImagePosition,
            at: "Hi ".count,
            effectiveRange: nil
        ) as? FloatingImagePosition
        #expect(position == FloatingImagePosition(page: 2, origin: CGPoint(x: 120, y: 200)))
    }

    @Test @MainActor func codecOmitsPositionForImagesThatWereNeverMoved() throws {
        let floating = floatingImageAttachment()  // position stays nil

        let original = NSMutableAttributedString(string: "X")
        original.append(NSAttributedString(attachment: floating))

        let encoded = try #require(RichTextCodec.encode(original))
        let decoded = try #require(RichTextCodec.decode(encoded))

        let position = decoded.attribute(
            .inklingFloatingImagePosition,
            at: 1,
            effectiveRange: nil
        ) as? FloatingImagePosition
        #expect(position == nil)
    }

    @Test func displayRectStacksPagesAndOffsetsByLeftMargin() {
        let layout = PagedEditorLayout.letter  // paper 612x792, 72pt margins, 24pt gap
        let rect = layout.displayRect(
            forPage: 1,
            origin: CGPoint(x: 100, y: 150),
            size: CGSize(width: 80, height: 60))
        // container x = 100 - 72 = 28; y = 1*(792+24) + 150 = 966
        #expect(rect == NSRect(x: 28, y: 966, width: 80, height: 60))
    }

    @Test func floatingPositionRoundTripsThroughDisplayRect() {
        let layout = PagedEditorLayout.letter
        let position = FloatingImagePosition(page: 2, origin: CGPoint(x: 120, y: 200))
        let size = CGSize(width: 90, height: 70)
        let rect = layout.displayRect(forPage: position.page, origin: position.origin, size: size)
        #expect(layout.position(forDisplayOrigin: rect.origin, size: size) == position)
    }

    @Test func draggedPositionClampsOntoItsPage() {
        let layout = PagedEditorLayout.letter
        // Displayed origin near the bottom of page 0; a 60pt-tall image would
        // spill into the page gap, so it clamps up to 792 - 60 = 732.
        let position = layout.position(
            forDisplayOrigin: CGPoint(x: 100, y: 760),
            size: CGSize(width: 80, height: 60))
        #expect(position.page == 0)
        #expect(position.origin == CGPoint(x: 172, y: 732))  // paperX = 100 + 72
    }

    @Test @MainActor func prepareFloatingImagesSeedsPositionFromTheDecodedAttribute() {
        let scroll = PagedTextView.makePagedScrollView()
        let textView = scroll.documentView as! PagedTextView

        let image = NSImage(size: NSSize(width: 50, height: 30), flipped: false) { rect in
            NSColor.systemOrange.setFill()
            rect.fill()
            return true
        }
        let attachment = NSTextAttachment(data: image.tiffRepresentation, ofType: "public.tiff")
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: 0, width: 50, height: 30)

        let string = NSMutableAttributedString(string: "A ")
        let attachmentString = NSMutableAttributedString(attachment: attachment)
        attachmentString.addAttribute(
            .inklingFloatingImagePosition,
            value: FloatingImagePosition(page: 1, origin: CGPoint(x: 90, y: 140)),
            range: NSRange(location: 0, length: 1)
        )
        string.append(attachmentString)
        textView.textStorage?.setAttributedString(string)

        textView.prepareFloatingImages()

        let floating = textView.textStorage?.attribute(
            .attachment,
            at: 2,
            effectiveRange: nil
        ) as? FloatingImageAttachment
        #expect(floating?.position == FloatingImagePosition(page: 1, origin: CGPoint(x: 90, y: 140)))
    }

    // MARK: - Printer floating-image parity

    @Test @MainActor func printerPlacesPositionedImageOnItsPageAndHoldsThePageOpen() throws {
        // A short chapter (one text line) with an image the user parked on the
        // chapter's second page (page index 1).
        let image = floatingImageAttachment(size: NSSize(width: 100, height: 80))
        image.position = FloatingImagePosition(page: 1, origin: CGPoint(x: 120, y: 120))
        let body = NSMutableAttributedString(string: "Short.\n")
        body.append(NSAttributedString(attachment: image))
        let data = try #require(RichTextCodec.encode(body))

        let view = ManuscriptPrintView(
            chapters: [PrintableChapter(title: "One", bodyData: data)],
            pageSize: NSSize(width: 468, height: 300),
            leftMargin: 72,
            topMargin: 72
        )

        // The image forces a second body page even though the text fits on one.
        #expect(view.pageCount >= 2)
        #expect(view.floatingImageCount(onPage: 2) == 1)
        #expect(view.floatingImageCount(onPage: 1) == 0)
    }

    /// An image the user has never dragged (`position == nil`, the default for
    /// every pasted/inserted image) must still print as a floating image beside
    /// its paragraph — matching the editor's auto-float behavior — rather than
    /// falling back to the old inline placement, which is what produced the
    /// "printing looks nothing like the editor" gap.
    @Test @MainActor func printerAutoFloatsAnUnplacedImageInsteadOfPrintingItInline() throws {
        let image = floatingImageAttachment(size: NSSize(width: 100, height: 80))
        let body = NSMutableAttributedString(string: "Some text.\n")
        body.append(NSAttributedString(attachment: image))
        let data = try #require(RichTextCodec.encode(body))

        let view = ManuscriptPrintView(
            chapters: [PrintableChapter(title: "One", bodyData: data)],
            pageSize: NSSize(width: 468, height: 648),
            leftMargin: 72,
            topMargin: 72
        )

        #expect(view.floatingImageCount(onPage: 1) == 1)
    }

    /// An unplaced image whose paragraph starts too late in a page to fit
    /// before the page's bottom edge must move to the top of the next page,
    /// mirroring the same rule already applied in the editor
    /// (`tallUnplacedImageNeverBleedsPastItsPagesPhysicalBottom`).
    @Test @MainActor func printerPushesAnUnplacedImageToTheNextPageWhenItDoesNotFit() throws {
        let image = floatingImageAttachment(size: NSSize(width: 100, height: 200))
        let body = NSMutableAttributedString(
            string: String(repeating: "Filler line.\n", count: 16)
        )
        body.append(NSAttributedString(attachment: image))
        let data = try #require(RichTextCodec.encode(body))

        let view = ManuscriptPrintView(
            chapters: [PrintableChapter(title: "One", bodyData: data)],
            pageSize: NSSize(width: 468, height: 300),
            leftMargin: 72,
            topMargin: 72
        )

        #expect(view.floatingImageCount(onPage: 1) == 0)
        #expect(view.floatingImageCount(onPage: 2) == 1)
    }

    /// An unplaced (never dragged) image floats from its paragraph's first
    /// line at its full display height, uncapped. If that paragraph starts
    /// deep enough into a page that the image can't fit before the page's
    /// bottom margin, the image must move to the top of the next page instead
    /// of being drawn past the current page's physical edge.
    @Test @MainActor func tallUnplacedImageNeverBleedsPastItsPagesPhysicalBottom() throws {
        let scrollView = PagedTextView.makePagedScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 676, height: 792)
        scrollView.layoutSubtreeIfNeeded()
        let textView = try #require(scrollView.documentView as? PagedTextView)
        let layout = textView.pageLayout

        // Many short paragraphs so some paragraph's first line lands deep
        // into a page — close enough to the bottom that a tall image
        // anchored there cannot fit in the remaining space.
        textView.string = String(repeating: "Row of text in its own short paragraph.\n", count: 45)

        let image = NSImage(size: NSSize(width: 200, height: 400), flipped: false) { r in
            NSColor.systemTeal.setFill(); r.fill(); return true
        }
        let insertionPoint = textView.textStorage?.length ?? 0
        RichTextImageInserter.insert(
            image, into: textView, at: NSRange(location: insertionPoint, length: 0),
            maximumWidth: layout.contentWidth
        )
        textView.prepareFloatingImages()
        textView.updatePageLayout()

        let range = NSRange(location: insertionPoint, length: 1)
        let imageRect = try #require(textView.imageAttachmentRect(for: range))
        let page = layout.pageIndex(atY: imageRect.minY)
        let pageLocalBottom = imageRect.maxY - CGFloat(page) * layout.pageStride
        #expect(pageLocalBottom <= layout.paperSize.height + 0.5)
    }

    /// A floating image parked at the very bottom of page 0's text column
    /// (its exclusion clamped flush to `contentBottom(0)`) must not squeeze the
    /// first line of page 1. TextKit tests each line's shape against the
    /// container's exclusion paths *before* our layout-manager delegate lifts
    /// that line down onto the next page, so a page-1 line is initially tested
    /// at a raw, continuous "as if pages didn't exist" Y that lands in the same
    /// numeric neighborhood as page 0's trailing content — colliding with an
    /// exclusion that has nothing to do with page 1.
    @Test @MainActor func imageAtBottomOfPageDoesNotSqueezeNextPagesFirstLine() throws {
        let scrollView = PagedTextView.makePagedScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 676, height: 792)
        scrollView.layoutSubtreeIfNeeded()
        let textView = try #require(scrollView.documentView as? PagedTextView)
        let layout = textView.pageLayout

        // Enough text to overflow onto page 1 (index 1).
        let para = String(repeating: "Lorem ipsum dolor sit amet consectetur. ", count: 80)
        textView.textStorage?.setAttributedString(NSAttributedString(
            string: para,
            attributes: [.font: NSFont.systemFont(ofSize: 12)]
        ))

        // Insert an image at the start and park it flush against the bottom of
        // page 0's text column.
        let image = NSImage(size: NSSize(width: 300, height: 150), flipped: false) { r in
            NSColor.systemBrown.setFill(); r.fill(); return true
        }
        RichTextImageInserter.insert(
            image, into: textView, at: NSRange(location: 0, length: 0),
            maximumWidth: layout.contentWidth
        )
        textView.prepareFloatingImages()

        let floating = try #require(textView.textStorage?.attribute(
            .attachment, at: 0, effectiveRange: nil) as? FloatingImageAttachment)
        // Bottom of page 0: contentBottom(0)=720, image height 150 → origin.y 570.
        floating.position = FloatingImagePosition(page: 0, origin: CGPoint(x: 72, y: 570))
        textView.updatePageLayout()

        let lm = try #require(textView.layoutManager)
        let tc = try #require(textView.textContainer)
        lm.ensureLayout(for: tc)

        // Find the first line fragment laid out on page 1. Check the *fragment*
        // rect (the available space TextKit reserved for the line), not the
        // used rect (the actual, possibly short, ink extent) — the bug is
        // about the reserved space being indented, not about how much of it
        // text happens to fill.
        var glyph = 0
        let n = lm.numberOfGlyphs
        var firstLineOnPage1: NSRect?
        while glyph < n {
            var lineRange = NSRange()
            let rect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineRange)
            if rect.minY >= layout.contentTop(forPage: 1) {
                firstLineOnPage1 = rect
                break
            }
            glyph = max(NSMaxRange(lineRange), glyph + 1)
        }

        let line = try #require(firstLineOnPage1)
        #expect(line.minX < 1)
        #expect(line.width > layout.contentWidth - 20)
    }

    /// Diagnostic reproduction: dragging a floating image several pages away
    /// (not just to an adjacent page) reportedly makes surrounding text stop
    /// rendering. Dumps per-line geometry before and after the move so a
    /// regression shows exactly which lines lost width/visibility.
    @Test @MainActor func movingAFloatingImageAcrossSeveralPagesKeepsAllTextVisible() throws {
        let scrollView = PagedTextView.makePagedScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 676, height: 792)
        scrollView.layoutSubtreeIfNeeded()
        let textView = try #require(scrollView.documentView as? PagedTextView)
        let layout = textView.pageLayout

        // Enough text to span several pages.
        let para = String(repeating: "Lorem ipsum dolor sit amet consectetur adipiscing elit. ", count: 400)
        textView.textStorage?.setAttributedString(NSAttributedString(
            string: para,
            attributes: [.font: NSFont.systemFont(ofSize: 12)]
        ))

        let image = NSImage(size: NSSize(width: 200, height: 120), flipped: false) { r in
            NSColor.systemBrown.setFill(); r.fill(); return true
        }
        RichTextImageInserter.insert(
            image, into: textView, at: NSRange(location: 0, length: 0),
            maximumWidth: layout.contentWidth
        )
        textView.prepareFloatingImages()

        let floating = try #require(textView.textStorage?.attribute(
            .attachment, at: 0, effectiveRange: nil) as? FloatingImageAttachment)
        floating.position = FloatingImagePosition(page: 0, origin: CGPoint(x: 72, y: 100))
        textView.updatePageLayout()

        let lm = try #require(textView.layoutManager)
        let tc = try #require(textView.textContainer)
        lm.ensureLayout(for: tc)

        struct LineDump: Equatable {
            let range: NSRange
            let rect: NSRect
        }

        func dumpLines() -> [LineDump] {
            var glyph = 0
            let n = lm.numberOfGlyphs
            var lines: [LineDump] = []
            while glyph < n {
                var lineRange = NSRange()
                let rect = lm.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: &lineRange)
                lines.append(LineDump(range: lineRange, rect: rect))
                glyph = max(NSMaxRange(lineRange), glyph + 1)
            }
            return lines
        }

        let before = dumpLines()
        let glyphsBefore = lm.numberOfGlyphs

        // Simulate the drop at the end of a drag that carried the image several
        // pages further down the document — the same state transition
        // `setFloatingPosition` commits on mouseUp.
        floating.position = FloatingImagePosition(page: 3, origin: CGPoint(x: 72, y: 100))
        textView.updatePageLayout()
        lm.ensureLayout(for: tc)

        let after = dumpLines()
        let glyphsAfter = lm.numberOfGlyphs

        #expect(glyphsAfter == glyphsBefore)

        // Every line must have positive width (a zero/negative-width line
        // fragment renders no visible glyphs even though the characters are
        // still present in the text storage — the "did it disappear or just
        // stop rendering" symptom).
        let collapsedLines = after.filter { $0.rect.width <= 0.5 && $0.range.length > 0 }
        #expect(collapsedLines.isEmpty, "collapsed line rects after move: \(collapsedLines)")

        // Every line must land within some page's printable band, not in the
        // inter-page gutter (which would place it behind/between pages).
        let misplacedLines = after.filter { line in
            let page = layout.pageIndex(atY: line.rect.minY)
            return line.rect.minY < layout.contentTop(forPage: page) - 0.5
                || line.rect.maxY > layout.contentBottom(forPage: page) + 0.5
        }
        #expect(misplacedLines.isEmpty, "lines outside their page's printable band: \(misplacedLines)")

        // The set of covered characters (by line ranges) must match before and
        // after — no character should fall between two line fragments.
        let coveredBefore = before.reduce(0) { $0 + $1.range.length }
        let coveredAfter = after.reduce(0) { $0 + $1.range.length }
        #expect(coveredAfter == coveredBefore)
    }

    // MARK: - Find

    @Test @MainActor func pagedEditorEnablesTheFindBar() throws {
        let scrollView = PagedTextView.makePagedScrollView()
        let textView = try #require(scrollView.documentView as? PagedTextView)

        #expect(textView.usesFindBar == true)
        #expect(textView.isIncrementalSearchingEnabled == true)
    }

    @Test @MainActor func editMenuHasFindWithCommandF() throws {
        let mainMenu = MainMenu.build()

        let editMenu = try #require(
            mainMenu.items.first { $0.title == "Edit" }?.submenu)
        let findMenu = try #require(
            editMenu.items.first { $0.title == "Find" }?.submenu)
        let findItem = try #require(
            findMenu.items.first { $0.title == "Find…" })

        #expect(findItem.keyEquivalent == "f")
        #expect(findItem.keyEquivalentModifierMask == .command)
        #expect(findItem.action == Selector(("performTextFinderAction:")))
        #expect(findItem.tag == NSTextFinder.Action.showFindInterface.rawValue)
    }

    @Test @MainActor func findMenuOffersNextAndPreviousMatch() throws {
        let mainMenu = MainMenu.build()
        let findMenu = try #require(
            mainMenu.items.first { $0.title == "Edit" }?.submenu?
                .items.first { $0.title == "Find" }?.submenu)

        let next = try #require(findMenu.items.first { $0.title == "Find Next" })
        #expect(next.keyEquivalent == "g")
        #expect(next.keyEquivalentModifierMask == .command)
        #expect(next.tag == NSTextFinder.Action.nextMatch.rawValue)

        let previous = try #require(findMenu.items.first { $0.title == "Find Previous" })
        #expect(previous.keyEquivalent == "g")
        #expect(previous.keyEquivalentModifierMask == [.command, .shift])
        #expect(previous.tag == NSTextFinder.Action.previousMatch.rawValue)
    }

    // MARK: - MinimalZipReader

    @Test func zipReaderRoundTripsAStoredEntry() throws {
        let data = "hello world".data(using: .utf8)!
        let zip = TestZipBuilder.makeZip(entries: [("greeting.txt", data)])

        let reader = try MinimalZipReader(data: zip)
        #expect(reader.names.sorted() == ["greeting.txt"])
        #expect(try reader.contents(of: "greeting.txt") == data)
    }

    @Test func zipReaderRoundTripsMultipleEntriesIncludingEmptyOnes() throws {
        let zip = TestZipBuilder.makeZip(entries: [
            ("a.txt", Data("first".utf8)),
            ("dir/b.txt", Data("second".utf8)),
            ("empty.txt", Data()),
        ])

        let reader = try MinimalZipReader(data: zip)
        #expect(try reader.contents(of: "a.txt") == Data("first".utf8))
        #expect(try reader.contents(of: "dir/b.txt") == Data("second".utf8))
        #expect(try reader.contents(of: "empty.txt") == Data())
    }

    @Test func zipReaderThrowsForAMissingEntry() throws {
        let zip = TestZipBuilder.makeZip(entries: [("a.txt", Data("x".utf8))])
        let reader = try MinimalZipReader(data: zip)

        #expect(throws: MinimalZipReader.ZipReaderError.entryNotFound("missing.txt")) {
            try reader.contents(of: "missing.txt")
        }
    }

    @Test func zipReaderThrowsForNonZipData() {
        let notAZip = Data("this is plainly not a zip archive".utf8)
        #expect(throws: MinimalZipReader.ZipReaderError.notAZipArchive) {
            try MinimalZipReader(data: notAZip)
        }
    }

    // MARK: - WordDocumentImporter

    private func makeDocx(documentXML: String, media: [String: Data] = [:]) -> Data {
        var entries: [(String, Data)] = [("word/document.xml", Data(documentXML.utf8))]
        if !media.isEmpty {
            let relationships = media.keys.enumerated().map { index, name in
                """
                <Relationship Id="rId\(index + 1)" \
                Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" \
                Target="media/\(name)"/>
                """
            }.joined()
            let relsXML = """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
                \(relationships)</Relationships>
                """
            entries.append(("word/_rels/document.xml.rels", Data(relsXML.utf8)))
            for (name, data) in media {
                entries.append(("word/media/\(name)", data))
            }
        }
        return TestZipBuilder.makeZip(entries: entries)
    }

    private func testPNGData(color: NSColor = .systemRed) -> Data {
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            rect.fill()
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return Data() }
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    private static let wordDocumentNamespaces = """
        xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
        xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
        """

    private func wrapInDocument(_ bodyXML: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document \(Self.wordDocumentNamespaces)><w:body>\(bodyXML)</w:body></w:document>
        """
    }

    @Test @MainActor func importerMapsWordHeadingStylesToInklingTextStyles() throws {
        let xml = wrapInDocument("""
            <w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr><w:r><w:t>My Book</w:t></w:r></w:p>
            <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Chapter One</w:t></w:r></w:p>
            <w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr><w:r><w:t>A Section</w:t></w:r></w:p>
            <w:p><w:r><w:t>Ordinary body text.</w:t></w:r></w:p>
            """)
        let url = try writeTempFile(makeDocx(documentXML: xml))
        defer { try? FileManager.default.removeItem(at: url) }

        let attributed = try WordDocumentImporter.importChapterBody(from: url, maximumImageWidth: 468)
        let ns = attributed.string as NSString

        func font(at needle: String) throws -> NSFont {
            let range = ns.range(of: needle)
            let font = try #require(attributed.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
            return font
        }

        #expect(try font(at: "My Book") == TextStyle.title.font)
        #expect(try font(at: "Chapter One") == TextStyle.heading.font)
        #expect(try font(at: "A Section") == TextStyle.subheading.font)
        #expect(try font(at: "Ordinary body text.") == TextStyle.body.font)
    }

    @Test @MainActor func importerAppliesBoldAndItalicRunProperties() throws {
        let xml = wrapInDocument("""
            <w:p><w:r><w:rPr><w:b/><w:i/></w:rPr><w:t>Bold italic text.</w:t></w:r></w:p>
            """)
        let url = try writeTempFile(makeDocx(documentXML: xml))
        defer { try? FileManager.default.removeItem(at: url) }

        let attributed = try WordDocumentImporter.importChapterBody(from: url, maximumImageWidth: 468)
        let font = try #require(attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let traits = font.fontDescriptor.symbolicTraits
        #expect(traits.contains(.bold))
        #expect(traits.contains(.italic))
    }

    @Test @MainActor func importerPrefixesListParagraphsWithABullet() throws {
        let xml = wrapInDocument("""
            <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>\
            <w:r><w:t>List item.</w:t></w:r></w:p>
            """)
        let url = try writeTempFile(makeDocx(documentXML: xml))
        defer { try? FileManager.default.removeItem(at: url) }

        let attributed = try WordDocumentImporter.importChapterBody(from: url, maximumImageWidth: 468)
        #expect(attributed.string.hasPrefix("•\tList item."))
    }

    @Test @MainActor func importerPlacesAnImageAtItsParagraphsPosition() throws {
        let imageData = testPNGData()
        let xml = wrapInDocument("""
            <w:p><w:r><w:t>Before the image.</w:t></w:r></w:p>
            <w:p><w:r><w:drawing><wp:anchor><a:graphic><a:graphicData>\
            <a:blip r:embed="rId1"/></a:graphicData></a:graphic></wp:anchor></w:drawing></w:r></w:p>
            <w:p><w:r><w:t>After the image.</w:t></w:r></w:p>
            """)
        let url = try writeTempFile(makeDocx(documentXML: xml, media: ["pic.png": imageData]))
        defer { try? FileManager.default.removeItem(at: url) }

        let attributed = try WordDocumentImporter.importChapterBody(from: url, maximumImageWidth: 468)
        let ns = attributed.string as NSString
        let beforeEnd = NSMaxRange(ns.range(of: "Before the image."))
        let afterStart = ns.range(of: "After the image.").location

        var attachmentLocation: Int?
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            if value is NSTextAttachment { attachmentLocation = range.location }
        }

        let location = try #require(attachmentLocation)
        #expect(location >= beforeEnd)
        #expect(location < afterStart)
    }

    @Test @MainActor func importerThrowsForANonZipFile() throws {
        let url = try writeTempFile(Data("not a docx".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: WordDocumentImporter.ImportError.self) {
            try WordDocumentImporter.importChapterBody(from: url, maximumImageWidth: 468)
        }
    }

    @Test @MainActor func importerThrowsWhenDocumentXMLIsMissing() throws {
        let zip = TestZipBuilder.makeZip(entries: [("word/other.xml", Data("<x/>".utf8))])
        let url = try writeTempFile(zip)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: WordDocumentImporter.ImportError.self) {
            try WordDocumentImporter.importChapterBody(from: url, maximumImageWidth: 468)
        }
    }

    // MARK: - WordDocumentExporter

    @Test @MainActor func wordExporterMapsInklingTextStylesToWordStyles() throws {
        let body = NSMutableAttributedString()
        body.append(NSAttributedString(string: "My Title\n", attributes: [.font: TextStyle.title.font]))
        body.append(NSAttributedString(string: "My Heading\n", attributes: [.font: TextStyle.heading.font]))
        body.append(NSAttributedString(string: "My Subheading\n", attributes: [.font: TextStyle.subheading.font]))
        body.append(NSAttributedString(string: "Body text.", attributes: [.font: TextStyle.body.font]))
        let data = try #require(RichTextCodec.encode(body))

        let docx = try WordDocumentExporter.docxData(for: PrintableChapter(title: "Chapter", bodyData: data))
        let reader = try MinimalZipReader(data: docx)
        let documentXML = try #require(String(data: reader.contents(of: "word/document.xml"), encoding: .utf8))

        #expect(documentXML.contains(#"<w:pStyle w:val="Title"/>"#))
        #expect(documentXML.contains(#"<w:pStyle w:val="Heading1"/>"#))
        #expect(documentXML.contains(#"<w:pStyle w:val="Heading2"/>"#))
        #expect(documentXML.contains(#"<w:t xml:space="preserve">Body text.</w:t>"#))
    }

    @Test @MainActor func wordExporterEmbedsImagesInTheDocumentPackage() throws {
        let imageData = testPNGData()
        let attachment = NSTextAttachment(data: imageData, ofType: "public.png")
        attachment.image = NSImage(data: imageData)
        let body = NSMutableAttributedString(string: "Before ")
        body.append(NSAttributedString(attachment: attachment))
        body.append(NSAttributedString(string: " after."))
        let data = try #require(RichTextCodec.encode(body))

        let docx = try WordDocumentExporter.docxData(for: PrintableChapter(title: "Chapter", bodyData: data))
        let reader = try MinimalZipReader(data: docx)
        let documentXML = try #require(String(data: reader.contents(of: "word/document.xml"), encoding: .utf8))

        #expect(documentXML.contains(#"r:embed="rId1""#))
        #expect(try reader.contents(of: "word/media/image1.png").isEmpty == false)
    }

    private func writeTempFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("docx")
        try data.write(to: url)
        return url
    }

    // MARK: - ProjectSearch

    private func searchableChapter(id: UUID = UUID(), title: String, text: String) -> SearchableChapter {
        SearchableChapter(id: id, title: title, bodyData: RichTextCodec.encode(NSAttributedString(string: text)))
    }

    @Test func projectSearchFindsMatchesAcrossMultipleChapters() {
        let chapters = [
            searchableChapter(title: "One", text: "The cat sat."),
            searchableChapter(title: "Two", text: "No match here."),
            searchableChapter(title: "Three", text: "A cat and another cat."),
        ]

        let matches = ProjectSearch.findMatches(in: chapters, query: "cat", caseSensitive: true)

        #expect(matches.count == 3)
        #expect(matches.filter { $0.chapterTitle == "One" }.count == 1)
        #expect(matches.filter { $0.chapterTitle == "Two" }.count == 0)
        #expect(matches.filter { $0.chapterTitle == "Three" }.count == 2)
    }

    @Test func projectSearchIsCaseSensitiveByDefault() {
        let chapters = [searchableChapter(title: "One", text: "Cat cat CAT")]

        let sensitive = ProjectSearch.findMatches(in: chapters, query: "cat", caseSensitive: true)
        let insensitive = ProjectSearch.findMatches(in: chapters, query: "cat", caseSensitive: false)

        #expect(sensitive.count == 1)
        #expect(insensitive.count == 3)
    }

    @Test func projectSearchReturnsNothingForAnEmptyQuery() {
        let chapters = [searchableChapter(title: "One", text: "Some text.")]
        #expect(ProjectSearch.findMatches(in: chapters, query: "", caseSensitive: true).isEmpty)
    }

    @Test func projectSearchSnippetIncludesSurroundingContextWithEllipsesWhenTruncated() {
        let padding = String(repeating: "x", count: 60)
        let chapters = [searchableChapter(title: "One", text: "\(padding) MATCH \(padding)")]

        let match = try! #require(
            ProjectSearch.findMatches(in: chapters, query: "MATCH", caseSensitive: true).first
        )

        #expect(match.snippetMatch == "MATCH")
        #expect(match.snippetBefore.hasPrefix("…"))
        #expect(match.snippetAfter.hasSuffix("…"))
        #expect(match.snippetBefore.contains("x"))
        #expect(match.snippetAfter.contains("x"))
    }

    @Test func projectSearchSnippetHasNoEllipsisNearDocumentEdges() {
        let chapters = [searchableChapter(title: "One", text: "MATCH at the very start.")]
        let match = try! #require(
            ProjectSearch.findMatches(in: chapters, query: "MATCH", caseSensitive: true).first
        )
        #expect(!match.snippetBefore.hasPrefix("…"))
        #expect(match.snippetBefore.isEmpty)
    }

    @Test func projectSearchReplaceAllReplacesEveryOccurrenceAcrossAffectedChapters() throws {
        let idOne = UUID()
        let idTwo = UUID()
        let idThree = UUID()
        let chapters = [
            searchableChapter(id: idOne, title: "One", text: "The cat sat on the cat mat."),
            searchableChapter(id: idTwo, title: "Two", text: "Untouched chapter."),
            searchableChapter(id: idThree, title: "Three", text: "One cat here."),
        ]

        let results = ProjectSearch.replaceAll(
            in: chapters, query: "cat", replacement: "dog", caseSensitive: true
        )

        #expect(results.count == 2)
        #expect(results[idTwo] == nil)

        let decodedOne = try #require(RichTextCodec.decode(results[idOne]))
        #expect(decodedOne.string == "The dog sat on the dog mat.")
        let decodedThree = try #require(RichTextCodec.decode(results[idThree]))
        #expect(decodedThree.string == "One dog here.")
    }

    @Test func projectSearchReplaceAllPreservesFormattingAroundTheReplacement() throws {
        let id = UUID()
        let boldFont = NSFont.boldSystemFont(ofSize: 14)
        let original = NSMutableAttributedString(string: "before ")
        original.append(NSAttributedString(string: "cat", attributes: [.font: boldFont]))
        original.append(NSAttributedString(string: " after"))
        let chapters = [SearchableChapter(id: id, title: "One", bodyData: RichTextCodec.encode(original))]

        let results = ProjectSearch.replaceAll(
            in: chapters, query: "cat", replacement: "dog", caseSensitive: true
        )

        let decoded = try #require(RichTextCodec.decode(results[id]))
        #expect(decoded.string == "before dog after")
        let range = (decoded.string as NSString).range(of: "dog")
        let font = try #require(decoded.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
        // RTF round-tripping doesn't preserve the exact system-font identity
        // (same as elsewhere in this suite) — check the bold trait survived,
        // not literal font equality.
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
    }

    // MARK: - ProjectFontStyler

    @Test func withFamilyPreservesSizeAndBoldWhileChangingTypeface() {
        let heading = TextStyle.heading.font
        let restyled = heading.withFamily("Georgia")

        #expect(restyled.familyName == "Georgia")
        #expect(restyled.pointSize == heading.pointSize)
        #expect(restyled.fontDescriptor.symbolicTraits.contains(.bold))
    }

    @Test func withFamilyFallsBackToTheOriginalFontForAnUnknownFamily() {
        let body = TextStyle.body.font
        let restyled = body.withFamily("Definitely Not An Installed Font Name")
        #expect(restyled == body)
    }

    @Test func withFamilyNilRestoresSystemDefault() {
        let georgiaHeading = TextStyle.heading.font(familyName: "Georgia")
        let restored = georgiaHeading.withFamily(nil)
        #expect(restored == georgiaHeading)
    }

    @Test func projectFontStylerRestyledRewritesEveryFontRunToTheNewFamily() throws {
        let mixed = NSMutableAttributedString()
        mixed.append(NSAttributedString(string: "Heading\n", attributes: [.font: TextStyle.heading.font]))
        mixed.append(NSAttributedString(string: "Body text.", attributes: [.font: TextStyle.body.font]))

        let restyled = ProjectFontStyler.restyled(mixed, familyName: "Georgia")

        let headingFont = try #require(restyled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(headingFont.familyName == "Georgia")
        #expect(headingFont.pointSize == TextStyle.heading.pointSize)
        #expect(headingFont.fontDescriptor.symbolicTraits.contains(.bold))

        let bodyRange = (restyled.string as NSString).range(of: "Body text.")
        let bodyFont = try #require(restyled.attribute(.font, at: bodyRange.location, effectiveRange: nil) as? NSFont)
        #expect(bodyFont.familyName == "Georgia")
        #expect(bodyFont.pointSize == TextStyle.body.pointSize)
        #expect(!bodyFont.fontDescriptor.symbolicTraits.contains(.bold))
    }

    @Test func projectFontStylerRestyledChaptersUpdatesBodyAndNotesForEveryChapter() throws {
        let id = UUID()
        let body = NSAttributedString(string: "Body", attributes: [.font: TextStyle.body.font])
        let notes = NSAttributedString(string: "Notes", attributes: [.font: TextStyle.body.font])
        let chapter = FontStyledChapter(
            id: id,
            bodyData: RichTextCodec.encode(body),
            notesData: RichTextCodec.encode(notes)
        )

        let results = ProjectFontStyler.restyledChapters([chapter], familyName: "Georgia")

        let newBody = try #require(RichTextCodec.decode(results[id]?.bodyData))
        let newBodyFont = try #require(newBody.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(newBodyFont.familyName == "Georgia")

        let newNotes = try #require(RichTextCodec.decode(results[id]?.notesData))
        let newNotesFont = try #require(newNotes.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(newNotesFont.familyName == "Georgia")
    }

    @Test func projectFontStylerRestyledChaptersSkipsChaptersWithNoDecodableRichText() {
        let chapter = FontStyledChapter(id: UUID(), bodyData: nil, notesData: nil)
        let results = ProjectFontStyler.restyledChapters([chapter], familyName: "Georgia")
        #expect(results.isEmpty)
    }

    // MARK: - ShelfDropParser

    @Test func shelfDropParserDecodesDroppedRTFData() throws {
        let original = NSAttributedString(string: "A dropped line.", attributes: [.font: TextStyle.heading.font])
        let rtfData = try #require(original.rtf(
            from: NSRange(location: 0, length: original.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ))

        let decoded = try #require(ShelfDropParser.attributedString(rtfData: rtfData))
        #expect(decoded.string == "A dropped line.")
    }

    @Test func shelfDropParserReturnsNilForGarbageRTFData() {
        let garbage = Data("not rtf at all".utf8)
        #expect(ShelfDropParser.attributedString(rtfData: garbage) == nil)
    }

    @Test func shelfDropParserWrapsDroppedPlainTextInTheGivenFont() throws {
        let data = Data("A stray idea.".utf8)
        let font = TextStyle.body.font

        let decoded = try #require(ShelfDropParser.attributedString(plainTextData: data, font: font))
        #expect(decoded.string == "A stray idea.")
        let appliedFont = try #require(decoded.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(appliedFont.pointSize == font.pointSize)
    }

    @Test func shelfDropParserReturnsNilForEmptyPlainText() {
        let data = Data("".utf8)
        #expect(ShelfDropParser.attributedString(plainTextData: data, font: TextStyle.body.font) == nil)
    }
}

/// Builds a minimal, uncompressed (STORED-method) ZIP archive in memory for
/// tests. CRC-32 fields are written as zero: `MinimalZipReader` never
/// validates them, so a real checksum implementation isn't needed here.
private enum TestZipBuilder {
    static func makeZip(entries: [(name: String, data: Data)]) -> Data {
        var result = Data()
        var localOffsets: [(name: String, data: Data, offset: Int)] = []

        for (name, data) in entries {
            let offset = result.count
            let nameData = Data(name.utf8)
            var header = Data()
            header.append(contentsOf: uint32LE(0x0403_4b50))
            header.append(contentsOf: uint16LE(20))
            header.append(contentsOf: uint16LE(0))
            header.append(contentsOf: uint16LE(0))
            header.append(contentsOf: uint16LE(0))
            header.append(contentsOf: uint16LE(0))
            header.append(contentsOf: uint32LE(0))
            header.append(contentsOf: uint32LE(UInt32(data.count)))
            header.append(contentsOf: uint32LE(UInt32(data.count)))
            header.append(contentsOf: uint16LE(UInt16(nameData.count)))
            header.append(contentsOf: uint16LE(0))
            header.append(nameData)

            result.append(header)
            result.append(data)
            localOffsets.append((name, data, offset))
        }

        var centralDirectory = Data()
        for (name, data, offset) in localOffsets {
            let nameData = Data(name.utf8)
            var entry = Data()
            entry.append(contentsOf: uint32LE(0x0201_4b50))
            entry.append(contentsOf: uint16LE(20))
            entry.append(contentsOf: uint16LE(20))
            entry.append(contentsOf: uint16LE(0))
            entry.append(contentsOf: uint16LE(0))
            entry.append(contentsOf: uint16LE(0))
            entry.append(contentsOf: uint16LE(0))
            entry.append(contentsOf: uint32LE(0))
            entry.append(contentsOf: uint32LE(UInt32(data.count)))
            entry.append(contentsOf: uint32LE(UInt32(data.count)))
            entry.append(contentsOf: uint16LE(UInt16(nameData.count)))
            entry.append(contentsOf: uint16LE(0))
            entry.append(contentsOf: uint16LE(0))
            entry.append(contentsOf: uint16LE(0))
            entry.append(contentsOf: uint16LE(0))
            entry.append(contentsOf: uint32LE(0))
            entry.append(contentsOf: uint32LE(UInt32(offset)))
            entry.append(nameData)
            centralDirectory.append(entry)
        }

        let centralDirectoryOffset = result.count
        result.append(centralDirectory)

        var eocd = Data()
        eocd.append(contentsOf: uint32LE(0x0605_4b50))
        eocd.append(contentsOf: uint16LE(0))
        eocd.append(contentsOf: uint16LE(0))
        eocd.append(contentsOf: uint16LE(UInt16(entries.count)))
        eocd.append(contentsOf: uint16LE(UInt16(entries.count)))
        eocd.append(contentsOf: uint32LE(UInt32(centralDirectory.count)))
        eocd.append(contentsOf: uint32LE(UInt32(centralDirectoryOffset)))
        eocd.append(contentsOf: uint16LE(0))
        result.append(eocd)

        return result
    }

    private static func uint16LE(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xff), UInt8((value >> 8) & 0xff)]
    }

    private static func uint32LE(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff),
        ]
    }
}

/// Serialized because every test swaps the shared `LastEditPositionStore.defaults`
/// static; running them concurrently would let one test's suite clobber another's.
@Suite(.serialized)
struct LastEditPositionStoreTests {

    /// Each test gets an isolated defaults suite so runs don't collide with the
    /// real app's stored positions or with each other.
    private func withIsolatedDefaults(_ body: (URL) -> Void) {
        let suiteName = "LastEditPositionStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let previous = LastEditPositionStore.defaults
        LastEditPositionStore.defaults = defaults
        defer {
            LastEditPositionStore.defaults = previous
            defaults.removePersistentDomain(forName: suiteName)
        }
        body(URL(fileURLWithPath: "/tmp/Some Project.inkling"))
    }

    @Test func returnsNilForNeverOpenedDocument() {
        withIsolatedDefaults { url in
            #expect(LastEditPositionStore.position(for: url) == nil)
        }
    }

    @Test func roundTripsSavedPosition() {
        withIsolatedDefaults { url in
            let position = LastEditPosition(chapterID: UUID(), caret: 137)
            LastEditPositionStore.save(position, for: url)
            #expect(LastEditPositionStore.position(for: url) == position)
        }
    }

    @Test func savingOverwritesTheEarlierPosition() {
        withIsolatedDefaults { url in
            LastEditPositionStore.save(LastEditPosition(chapterID: UUID(), caret: 5), for: url)
            let latest = LastEditPosition(chapterID: UUID(), caret: 90)
            LastEditPositionStore.save(latest, for: url)
            #expect(LastEditPositionStore.position(for: url) == latest)
        }
    }

    @Test func positionsAreKeyedPerDocument() {
        withIsolatedDefaults { url in
            let other = URL(fileURLWithPath: "/tmp/Another.inkling")
            let position = LastEditPosition(chapterID: UUID(), caret: 12)
            LastEditPositionStore.save(position, for: url)
            #expect(LastEditPositionStore.position(for: other) == nil)
        }
    }

    @Test func clearForgetsTheStoredPosition() {
        withIsolatedDefaults { url in
            LastEditPositionStore.save(LastEditPosition(chapterID: UUID(), caret: 3), for: url)
            LastEditPositionStore.clear(for: url)
            #expect(LastEditPositionStore.position(for: url) == nil)
        }
    }
}
