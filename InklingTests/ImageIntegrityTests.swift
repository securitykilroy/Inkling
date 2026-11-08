//
//  ImageIntegrityTests.swift
//  InklingTests
//
//  Image bytes must survive every round trip unchanged, and the per-keystroke
//  write path must not accumulate copies of the chapter.
//

import AppKit
import CoreData
import Testing
import UniformTypeIdentifiers
@testable import Inkling

@MainActor
struct ImageIntegrityTests {

    /// A photo-like JPEG: noisy enough that a PNG of it is several times larger,
    /// which is exactly what made silent re-encoding expensive.
    private static func photoJPEG(width: Int = 1600, height: Int = 1200) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        var seed: UInt32 = 12345
        for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: width, by: 4) {
                seed = seed &* 1_103_515_245 &+ 12345
                let noise = CGFloat(seed % 255) / 255
                context.setFillColor(CGColor(
                    red: CGFloat(x) / CGFloat(width), green: noise,
                    blue: CGFloat(y) / CGFloat(height), alpha: 1
                ))
                context.fill(CGRect(x: x, y: y, width: 4, height: 4))
            }
        }
        let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])!
    }

    private static func chapter(with jpeg: Data, caption: String? = nil) -> NSAttributedString {
        let image = NSImage(data: jpeg)!
        let attachment = RichTextImageInserter.makeAttachment(
            for: image, sourceData: jpeg, contentType: .jpeg,
            filename: "photo.jpg", maximumWidth: 468
        )
        let text = NSMutableAttributedString(string: "Before the photo. ")
        text.append(NSAttributedString(attachment: attachment))
        if let caption {
            text.addAttribute(
                .inklingImageCaption, value: caption,
                range: NSRange(location: text.length - 1, length: 1)
            )
        }
        text.append(NSAttributedString(string: " After the photo.\nMore text."))
        return text
    }

    private static func imageBytes(in data: Data) -> [Data] {
        guard let decoded = RichTextCodec.decode(data) else { return [] }
        var result: [Data] = []
        decoded.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: decoded.length)
        ) { value, _, _ in
            if let attachment = value as? NSTextAttachment,
               let bytes = ImageAttachmentContent.storedBytes(of: attachment) {
                result.append(bytes)
            }
        }
        return result
    }

    /// Regression: decoding assigned `attachment.image`, and AppKit then
    /// re-encoded the image as PNG on the next save, about 4x the size of the
    /// original JPEG. Every later keystroke re-serialized the bloated chapter.
    @Test func codecRoundTripsKeepTheOriginalJPEGBytes() throws {
        let jpeg = Self.photoJPEG()
        var data = try #require(RichTextCodec.encode(Self.chapter(with: jpeg)))
        for _ in 0..<3 {
            let decoded = try #require(RichTextCodec.decode(data))
            data = try #require(RichTextCodec.encode(decoded))
        }
        #expect(Self.imageBytes(in: data) == [jpeg])
        #expect(data.count < jpeg.count + 20_000)
    }

    /// The editor converts every image to a `FloatingImageAttachment`; the
    /// bytes it writes back must still be the original JPEG.
    @Test func editorRoundTripKeepsTheOriginalJPEGBytes() throws {
        let jpeg = Self.photoJPEG()
        let stored = try #require(RichTextCodec.encode(Self.chapter(with: jpeg)))

        let stack = PageStackView()
        stack.setAttributedString(try #require(RichTextCodec.decode(stored)))
        stack.prepareFloatingImages()
        let floating = try #require(stack.floatingAttachment(at: 18))
        #expect(floating.image == nil, "assigning .image is what triggers re-encoding")

        let resaved = try #require(RichTextCodec.encode(stack.storage))
        #expect(Self.imageBytes(in: resaved) == [jpeg])
        #expect(resaved.count < jpeg.count + 20_000)
    }

    /// Images are drawn on screen from a downsampled copy, not the full
    /// decode, but at the size the user chose.
    @Test func floatingImagesDrawFromAScreenResolutionCopy() throws {
        let jpeg = Self.photoJPEG(width: 3000, height: 2000)
        let source = NSTextAttachment(data: jpeg, ofType: UTType.jpeg.identifier)
        let floating = FloatingImageAttachment(
            copying: source, displaySize: NSSize(width: 240, height: 160)
        )
        // `representations.first?.pixelsWide` reports 2x the point size for a
        // CGImage-backed NSImage, whatever its real resolution, so measure the
        // CGImage itself.
        func pixelWidth(_ image: NSImage?) -> Int? {
            image?.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width
        }
        let image = try #require(floating.displayImage)
        let width = try #require(pixelWidth(image))
        #expect(image.size == NSSize(width: 240, height: 160))
        #expect(width <= 240 * 3 * 2)
        #expect(width >= 240 * 2)

        // Growing past the cached copy's resolution re-renders it.
        floating.displaySize = NSSize(width: 450, height: 300)
        #expect(try #require(pixelWidth(floating.displayImage)) >= 450 * 3)
        #expect(floating.fullImage?.representations.first?.pixelsWide == 3000)
    }

    /// The outline, word counts and project search read the text-only decode.
    /// It must agree with the full decode character for character, or a jump
    /// to a heading or search hit would land on the wrong text.
    @Test func textOnlyDecodeMatchesTheFullDecode() throws {
        let text = NSMutableAttributedString(attributedString: Self.chapter(
            with: Self.photoJPEG(width: 200, height: 100), caption: "A caption"
        ))
        text.append(NSAttributedString(
            string: "\nHeading\n",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 22)]
        ))
        CalloutStyling.apply(.warning, to: text, range: NSRange(location: 0, length: 17))
        let data = try #require(RichTextCodec.encode(text))

        let full = try #require(RichTextCodec.decode(data))
        let light = try #require(RichTextCodec.decodeText(data))
        #expect(full.string == light.string)
        #expect(ChapterOutline.headings(in: data).map(\.range.location)
            == [(full.string as NSString).range(of: "Heading").location])
    }

    /// An image taller than the page is shrunk so that it *and its caption*
    /// fit. Fitting the image alone to the full page height pushed the caption
    /// off the bottom of the paper.
    @Test func aTallCaptionedImageFitsOnThePageWithItsCaption() throws {
        let tall = Self.photoJPEG(width: 400, height: 2400)
        let text = Self.chapter(with: tall, caption: "A caption long enough to wrap onto a second line beneath a narrow image")
        let stack = PageStackView()
        stack.setAttributedString(text)
        stack.prepareFloatingImages()

        let floating = try #require(stack.floatingAttachment(at: 18))
        let footprint = stack.footprintSize(of: floating, at: 18)
        #expect(footprint.height <= stack.pageLayout.contentHeight + 0.5)
        #expect(footprint.height > floating.displaySize.height, "caption is counted")
    }

    /// Typing rewrites the chapter's bytes on every keystroke. Core Data's undo
    /// manager used to keep the previous version each time (1 GB after 200
    /// edits to a 5 MB chapter); the document must still be marked edited.
    @Test func richTextWritesDoNotAccumulateOnTheUndoStack() throws {
        let document = InklingDocument()
        let context = try #require(document.managedObjectContext)
        let undoManager = try #require(context.undoManager)
        NSDocumentController.shared.addDocument(document)
        defer { NSDocumentController.shared.removeDocument(document) }

        let chapter = Chapter(context: context)
        chapter.id = UUID()
        context.processPendingChanges()
        undoManager.removeAllActions()
        document.updateChangeCount(.changeCleared)

        for index in 0..<5 {
            assignRichTextIfChanged(chapter, \.bodyData, Data(repeating: UInt8(index + 1), count: 1000))
        }

        #expect(chapter.bodyData == Data(repeating: 5, count: 1000))
        #expect(!undoManager.canUndo)
        #expect(document.isDocumentEdited)
    }

    /// Word reads JPEG directly, so export passes the stored bytes through
    /// rather than converting a photo into a PNG several times its size.
    @Test func wordExportEmbedsJPEGsAsStored() throws {
        let jpeg = Self.photoJPEG()
        let data = try #require(RichTextCodec.encode(Self.chapter(with: jpeg)))
        let docx = try WordDocumentExporter.docxData(for: PrintableChapter(title: "Ch", bodyData: data))
        let reader = try MinimalZipReader(data: docx)

        #expect(try reader.contents(of: "word/media/image1.jpeg") == jpeg)
        let types = try #require(String(data: reader.contents(of: "[Content_Types].xml"), encoding: .utf8))
        let rels = try #require(String(data: reader.contents(of: "word/_rels/document.xml.rels"), encoding: .utf8))
        #expect(types.contains(#"<Default Extension="jpeg" ContentType="image/jpeg"/>"#))
        #expect(rels.contains(#"Target="media/image1.jpeg""#))
    }
}
