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

    @Test @MainActor func floatingImageAnchorsToStartOfContainingParagraph() throws {
        let scrollView = PagedTextView.makePagedScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 676, height: 792)
        scrollView.layoutSubtreeIfNeeded()
        let textView = try #require(scrollView.documentView as? PagedTextView)
        let prefix = String(repeating: "Words before the pasted image ", count: 8)
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

        #expect(abs(imageRect.minY - firstLine.minY) < 0.5)
        #expect(firstLine.minX > 120, "first paragraph line was not wrapped: \(firstLine)")
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

    private func writeTempFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("docx")
        try data.write(to: url)
        return url
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
