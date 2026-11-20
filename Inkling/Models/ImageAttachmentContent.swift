//
//  ImageAttachmentContent.swift
//  Inkling
//
//  The one place that reads an image attachment's stored bytes and builds
//  attachments from them without letting AppKit re-encode them.
//
//  Assigning `NSTextAttachment.image` makes AppKit throw away the attachment's
//  file bytes and re-encode the image itself as PNG. Measured: a 2.9 MB camera
//  JPEG became a 10.9 MB PNG the first time a chapter was reopened and saved,
//  and every keystroke afterwards re-serialized the bloated chapter. Never
//  assign `.image` on an attachment that will be persisted. Build it with
//  `NSTextAttachment(data:ofType:)` and size it with `bounds` instead. That
//  keeps the original bytes and still honors the bounds (verified on TextKit 1).
//  See also `RichTextImageInserter.makeAttachment`, which keeps bytes with a
//  sized cell, and the memory note on attachment bytes vs display size.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ImageAttachmentContent {

    /// An image's stored bytes and the uniform type they are encoded in.
    struct Payload: Equatable {
        let data: Data
        let typeIdentifier: String
    }

    /// The attachment's image bytes in their original encoding, or a PNG made
    /// from its image when it has no bytes of its own (an image-only
    /// attachment, such as some pasteboard sources produce).
    ///
    /// Uncompressed TIFF, which is what a pasted screenshot usually arrives as,
    /// is converted to PNG when that is smaller. The conversion is lossless.
    static func payload(of attachment: NSTextAttachment) -> Payload? {
        if let stored = storedPayload(of: attachment) {
            if stored.typeIdentifier == UTType.tiff.identifier,
               let png = losslessPNG(fromTIFF: stored.data),
               png.count < stored.data.count {
                return Payload(data: png, typeIdentifier: UTType.png.identifier)
            }
            return stored
        }
        var image = attachment.image
        if image == nil, Thread.isMainThread {
            image = MainActor.assumeIsolated {
                (attachment.attachmentCell as? NSTextAttachmentCell)?.image
            }
        }
        guard let image, let png = pngData(from: image) else { return nil }
        return Payload(data: png, typeIdentifier: UTType.png.identifier)
    }

    /// The attachment's own image bytes and their type, untouched: no
    /// conversion and no fallback to rendering its image. Cheap enough for
    /// every decode, since it reads only the image header.
    static func storedPayload(of attachment: NSTextAttachment) -> Payload? {
        guard let data = storedBytes(of: attachment), !data.isEmpty else { return nil }
        if let type = imageType(of: data) {
            return Payload(data: data, typeIdentifier: type)
        }
        // ImageIO doesn't read PDF, but NSImage does, and a dragged-in vector
        // image should keep its bytes rather than be rasterized.
        if let type = typeFromFilename(of: attachment),
           let utType = UTType(type),
           utType.conforms(to: .pdf) || utType.conforms(to: .image) {
            return Payload(data: data, typeIdentifier: type)
        }
        return nil
    }

    /// Whether a file may be pasted or dropped into a chapter: an image, or a
    /// PDF (which `storedPayload` keeps as vector bytes). Anything else would
    /// become an attachment the editor can only show as the file's icon — and
    /// keep only as that icon, losing the file itself on the next save.
    static func isAcceptableFile(_ url: URL) -> Bool {
        guard !url.hasDirectoryPath else { return false }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        guard let type else { return false }
        return type.conforms(to: .image) || type.conforms(to: .pdf)
    }

    /// The raw bytes an attachment carries, whichever way it was built.
    static func storedBytes(of attachment: NSTextAttachment) -> Data? {
        attachment.contents ?? attachment.fileWrapper?.regularFileContents
    }

    /// The image type `data` is encoded in, read from its header.
    static func imageType(of data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        return CGImageSourceGetType(source) as String?
    }

    private static func typeFromFilename(of attachment: NSTextAttachment) -> String? {
        let name = attachment.fileWrapper?.preferredFilename ?? attachment.fileWrapper?.filename
        guard let ext = name.map({ ($0 as NSString).pathExtension }), !ext.isEmpty else {
            return attachment.fileType
        }
        return UTType(filenameExtension: ext)?.identifier ?? attachment.fileType
    }

    private static func losslessPNG(fromTIFF data: Data) -> Data? {
        // Only single-image RGB/grayscale TIFFs: PNG can't hold CMYK or extra
        // pages, and those must not be silently flattened.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let rep = NSBitmapImageRep(data: data),
              rep.colorSpace.colorSpaceModel == .rgb || rep.colorSpace.colorSpaceModel == .gray
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// A plain attachment holding `payload` that lays out at `size`, keeping
    /// the bytes exactly as they are.
    static func makeSizedAttachment(payload: Payload, size: NSSize) -> NSTextAttachment {
        let attachment = NSTextAttachment(data: payload.data, ofType: payload.typeIdentifier)
        attachment.bounds = NSRect(origin: .zero, size: size)
        return attachment
    }

    /// The full-fidelity image for printing or export. Prefers an image the
    /// attachment already holds, then its bytes.
    static func image(of attachment: NSTextAttachment) -> NSImage? {
        if let floating = attachment as? FloatingImageAttachment {
            return floating.fullImage
        }
        if let image = attachment.image { return image }
        if let data = storedBytes(of: attachment), let image = NSImage(data: data) {
            return image
        }
        guard Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated {
            (attachment.attachmentCell as? NSTextAttachmentCell)?.image
        }
    }

    /// A screen-resolution copy of the image in `data`, at most
    /// `maxPixelSize` pixels on its longer side, drawn at `pointSize`.
    ///
    /// The editor used to draw every floating image from its full-resolution
    /// decode: a 12-megapixel photo costs ~48 MB of bitmap and is resampled on
    /// every scroll frame. A downsampled copy keeps scrolling smooth and
    /// memory flat. Printing still uses the original (`fullImage`).
    static func displayImage(from data: Data, pointSize: NSSize, maxPixelSize: Int) -> NSImage? {
        guard maxPixelSize > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Matches NSImage, which honors EXIF orientation: without this a
            // portrait phone photo would be drawn sideways.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: thumbnail, size: pointSize)
    }
}
