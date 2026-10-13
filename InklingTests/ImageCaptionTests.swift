//
//  ImageCaptionTests.swift
//  InklingTests
//
//  Captions beneath floating images: stored in the attachment sidecar, laid
//  out with their image as one object in both the editor and the printer, and
//  carried into plain-text and Word export.
//

import AppKit
import Testing
@testable import Inkling

@MainActor
struct ImageCaptionTests {

    // MARK: - Fixtures

    private static let bodyFont = NSFont.systemFont(ofSize: 12)

    private static func image(_ size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        if let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, Int(size.width)),
            pixelsHigh: max(1, Int(size.height)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) {
            rep.size = size
            image.addRepresentation(rep)
        }
        return image
    }

    private static func floatingImage(
        size: NSSize = NSSize(width: 200, height: 150),
        caption: String? = nil
    ) -> FloatingImageAttachment {
        let base = NSTextAttachment(data: image(size).tiffRepresentation, ofType: "public.tiff")
        base.image = image(size)
        base.bounds = NSRect(origin: .zero, size: size)
        let floating = FloatingImageAttachment(copying: base, displaySize: size)
        floating.caption = caption
        return floating
    }

    private static func filler(lines: Int) -> String {
        (1...lines).map { "Line \($0) of the text that wraps beside the image." }.joined(separator: "\n")
    }

    /// Text with one image after `lines` lines, encoded the way a chapter is.
    private static func chapterData(
        lines: Int,
        imageSize: NSSize = NSSize(width: 200, height: 150),
        caption: String?
    ) throws -> Data {
        let body = NSMutableAttributedString(
            string: filler(lines: lines) + "\n",
            attributes: [.font: bodyFont]
        )
        body.append(NSAttributedString(attachment: floatingImage(size: imageSize, caption: caption)))
        body.append(NSAttributedString(string: "\n" + filler(lines: lines), attributes: [.font: bodyFont]))
        return try #require(RichTextCodec.encode(body))
    }

    private static func stack(lines: Int, caption: String?) throws -> PageStackView {
        let decoded = try #require(RichTextCodec.decode(try chapterData(lines: lines, caption: caption)))
        let stack = PageStackView()
        stack.setAttributedString(decoded)
        stack.prepareFloatingImages()
        return stack
    }

    private static func imageLocation(in stack: PageStackView) -> Int? {
        var found: Int?
        stack.storage.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: stack.storage.length)
        ) { value, range, stop in
            if value is FloatingImageAttachment {
                found = range.location
                stop.pointee = true
            }
        }
        return found
    }

    private static let longCaption = "The lighthouse at dusk, seen from the harbour wall, "
        + "a little before the storm reached the point and the lamp was lit for the night."

    // MARK: - Storage

    @Test func codecRoundTripsACaption() throws {
        let decoded = try #require(RichTextCodec.decode(try Self.chapterData(lines: 2, caption: "The lighthouse")))
        var captions: [String] = []
        decoded.enumerateAttribute(.inklingImageCaption, in: NSRange(location: 0, length: decoded.length)) { value, _, _ in
            if let value = value as? String { captions.append(value) }
        }
        #expect(captions == ["The lighthouse"])
    }

    @Test func aBlankCaptionIsNotStored() throws {
        let decoded = try #require(RichTextCodec.decode(try Self.chapterData(lines: 2, caption: "   ")))
        var found = false
        decoded.enumerateAttribute(.inklingImageCaption, in: NSRange(location: 0, length: decoded.length)) { value, _, _ in
            if value != nil { found = true }
        }
        #expect(!found)
    }

    /// Replace All and a project font change re-encode a chapter from its
    /// decoded form, where the caption lives in an attribute rather than on a
    /// `FloatingImageAttachment`. It must survive that round trip.
    @Test func aCaptionSurvivesAnOfflineRewrite() throws {
        let decoded = try #require(RichTextCodec.decode(try Self.chapterData(lines: 2, caption: "Kept")))
        let reencoded = try #require(RichTextCodec.encode(decoded))
        let again = try #require(RichTextCodec.decode(reencoded))
        var captions: [String] = []
        again.enumerateAttribute(.inklingImageCaption, in: NSRange(location: 0, length: again.length)) { value, _, _ in
            if let value = value as? String { captions.append(value) }
        }
        #expect(captions == ["Kept"])
    }

    // MARK: - Editor

    @Test func theEditorDrawsTheCaptionBelowItsImage() throws {
        let stack = try Self.stack(lines: 4, caption: "The lighthouse")
        let page = try #require(stack.pageViews.first { !$0.floatingImages.isEmpty })
        let image = try #require(page.floatingImages.first)
        let caption = try #require(page.floatingCaptions.first)

        #expect(caption.text == "The lighthouse")
        #expect(caption.rect.minY >= image.rect.maxY)
        #expect(caption.rect.minX == image.rect.minX)
        #expect(caption.rect.width == image.rect.width)
    }

    @Test func textWrapsAroundTheCaptionAsWellAsTheImage() throws {
        let plain = try Self.stack(lines: 4, caption: nil)
        let captioned = try Self.stack(lines: 4, caption: Self.longCaption)

        func firstExclusion(_ stack: PageStackView) -> NSBezierPath? {
            stack.pageViews.compactMap(\.textContainer).flatMap(\.exclusionPaths).first
        }
        let plainExclusion = try #require(firstExclusion(plain))
        let captionedExclusion = try #require(firstExclusion(captioned))
        let caption = try #require(captioned.pageViews.compactMap(\.floatingCaptions.first).first)

        #expect(captionedExclusion.bounds.height > plainExclusion.bounds.height)
        #expect(captionedExclusion.bounds.maxY >= caption.rect.maxY)
    }

    @Test func settingACaptionIsUndoableAndReachesTheSavedText() throws {
        let stack = try Self.stack(lines: 4, caption: nil)
        let location = try #require(Self.imageLocation(in: stack))

        stack.setCaption("  Added later ", ofImageAt: location)

        #expect(stack.floatingAttachment(at: location)?.caption == "Added later")
        #expect(stack.pageViews.contains { $0.floatingCaptions.first?.text == "Added later" })
        let saved = try #require(RichTextCodec.decode(RichTextCodec.encode(stack.storage)))
        #expect(saved.attribute(.inklingImageCaption, at: location, effectiveRange: nil) as? String == "Added later")

        #expect(stack.sharedUndoManager.canUndo)
        stack.sharedUndoManager.undo()
        #expect(stack.floatingAttachment(at: location)?.caption == nil)
        #expect(stack.pageViews.allSatisfy { $0.floatingCaptions.isEmpty })
    }

    @Test func aBlankCaptionRemovesTheCaption() throws {
        let stack = try Self.stack(lines: 4, caption: "Going")
        let location = try #require(Self.imageLocation(in: stack))

        stack.setCaption("   ", ofImageAt: location)

        #expect(stack.floatingAttachment(at: location)?.caption == nil)
    }

    // MARK: - Printing

    /// A caption has to stay on its image's page. Some image heights fit the
    /// space left on page 1 on their own but not with a caption beneath them;
    /// those must move to page 2 with the caption. None may go the other way.
    @Test func printingKeepsAnImageAndItsCaptionOnOnePage() throws {
        func page(ofImageWithHeight height: CGFloat, caption: String?) throws -> Int? {
            let view = ManuscriptPrintView(
                chapters: [PrintableChapter(
                    title: "One",
                    bodyData: try Self.chapterData(
                        lines: 10, imageSize: NSSize(width: 200, height: height), caption: caption
                    )
                )],
                pageSize: NSSize(width: 468, height: 400),
                leftMargin: 72,
                topMargin: 72
            )
            return (1...view.pageCount).first { view.floatingImageCount(onPage: $0) > 0 }
        }

        var movedByCaption = 0
        for height in stride(from: 100, through: 300, by: 10) {
            let plain = try #require(try page(ofImageWithHeight: CGFloat(height), caption: nil))
            let captioned = try #require(try page(ofImageWithHeight: CGFloat(height), caption: Self.longCaption))
            #expect(captioned >= plain)
            if captioned > plain { movedByCaption += 1 }
        }
        #expect(movedByCaption > 0)
    }

    // MARK: - Export

    @Test func plainTextExportNamesACaptionedImage() throws {
        let body = try #require(RichTextCodec.decode(try Self.chapterData(lines: 1, caption: "The lighthouse")))

        let text = PlainTextExporter.bodyText(from: body)

        #expect(text.contains("[IMAGE: The lighthouse]"))
        #expect(!text.contains("\u{fffc}"))
    }

    @Test func wordExportAddsACaptionParagraphAfterTheImage() throws {
        let data = try Self.chapterData(lines: 1, caption: "Dusk & storm")
        let docx = try WordDocumentExporter.docxData(for: PrintableChapter(title: "Ch", bodyData: data))
        let reader = try MinimalZipReader(data: docx)
        let documentXML = try #require(String(data: reader.contents(of: "word/document.xml"), encoding: .utf8))

        let drawing = try #require(documentXML.range(of: "<w:drawing>"))
        let caption = try #require(documentXML.range(of: "Dusk &amp; storm"))
        #expect(drawing.upperBound < caption.lowerBound)
        #expect(documentXML.contains("<w:i/>"))
    }
}
