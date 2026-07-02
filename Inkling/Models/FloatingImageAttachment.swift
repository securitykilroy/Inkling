//
//  FloatingImageAttachment.swift
//  Inkling
//
//  An editor-only attachment. Its tiny inline bounds act as a stable text
//  anchor while PagedTextView draws the full image and wraps text around it.
//

import AppKit
import UniformTypeIdentifiers

extension NSAttributedString.Key {
    /// Carries a `FloatingImagePosition` from `RichTextCodec.decode` to the code
    /// that builds `FloatingImageAttachment`s (the editor and the printer). This
    /// attribute lives only in memory — it is never serialized into RTFD.
    static let inklingFloatingImagePosition = NSAttributedString.Key("inklingFloatingImagePosition")
}

final class FloatingImageAttachment: NSTextAttachment {
    var displaySize: NSSize

    /// The image's fixed page placement, or nil for images that still use the
    /// automatic left-edge placement (legacy files and freshly inserted images
    /// the user hasn't moved yet).
    var position: FloatingImagePosition?

    init(copying source: NSTextAttachment, displaySize: NSSize) {
        self.displaySize = displaySize
        let filename = source.fileWrapper?.preferredFilename
            ?? source.fileWrapper?.filename
            ?? "image.tiff"
        let type = UTType(filenameExtension: (filename as NSString).pathExtension)?.identifier
            ?? UTType.tiff.identifier
        let data = source.fileWrapper?.regularFileContents ?? source.image?.tiffRepresentation
        super.init(data: data, ofType: type)

        if let sourceImage = source.image {
            image = (sourceImage.copy() as? NSImage) ?? sourceImage
        } else if let cell = source.attachmentCell as? NSTextAttachmentCell,
                  let cellImage = cell.image {
            image = (cellImage.copy() as? NSImage) ?? cellImage
        } else if let contents = source.fileWrapper?.regularFileContents {
            image = NSImage(data: contents)
        }
        image?.size = displaySize
        bounds = NSRect(x: 0, y: 0, width: 0.1, height: 0.1)
    }

    required init?(coder: NSCoder) {
        displaySize = .zero
        super.init(coder: coder)
    }
}
