//
//  RichTextImageInserter.swift
//  Inkling
//
//  Inserts an image attachment using the normal NSTextView editing path so
//  undo, document dirtying, pagination, and autosave all continue to work.
//

import AppKit
import UniformTypeIdentifiers

enum RichTextImageInserter {
    static func fittedSize(_ size: NSSize, maximumWidth: CGFloat) -> NSSize {
        guard size.width > 0, size.height > 0, maximumWidth > 0 else { return .zero }
        guard size.width > maximumWidth else { return size }
        let scale = maximumWidth / size.width
        return NSSize(width: maximumWidth, height: size.height * scale)
    }

    @MainActor
    @discardableResult
    static func fitOversizedAttachments(
        in textView: NSTextView,
        range requestedRange: NSRange? = nil,
        maximumWidth: CGFloat
    ) -> Bool {
        guard let storage = textView.textStorage, storage.length > 0 else { return false }
        let fullRange = NSRange(location: 0, length: storage.length)
        let range = requestedRange.map { NSIntersectionRange($0, fullRange) } ?? fullRange
        guard range.length > 0 else { return false }

        var changes: [(NSTextAttachment, NSRange, NSSize)] = []
        storage.enumerateAttribute(.attachment, in: range) { value, attachmentRange, _ in
            guard let attachment = value as? NSTextAttachment,
                  let currentSize = displaySize(of: attachment),
                  currentSize.width > maximumWidth
            else { return }
            changes.append((
                attachment,
                attachmentRange,
                fittedSize(currentSize, maximumWidth: maximumWidth)
            ))
        }

        guard !changes.isEmpty else { return false }
        for (attachment, attachmentRange, size) in changes {
            if let floating = attachment as? FloatingImageAttachment {
                floating.displaySize = size
                floating.bounds = NSRect(x: 0, y: 0, width: 0.1, height: 0.1)
            } else {
                attachment.bounds = NSRect(origin: .zero, size: size)
            }
            attachment.image?.size = size
            (attachment.attachmentCell as? NSTextAttachmentCell)?.image?.size = size
            storage.addAttribute(.attachment, value: attachment, range: attachmentRange)
            textView.layoutManager?.invalidateLayout(
                forCharacterRange: attachmentRange,
                actualCharacterRange: nil
            )
        }
        return true
    }

    private static func displaySize(of attachment: NSTextAttachment) -> NSSize? {
        if let floating = attachment as? FloatingImageAttachment,
           floating.displaySize.width > 0,
           floating.displaySize.height > 0 {
            return floating.displaySize
        }
        let boundsSize = attachment.bounds.size
        if boundsSize.width > 0, boundsSize.height > 0 { return boundsSize }
        if let image = attachment.image, image.size.width > 0, image.size.height > 0 {
            return image.size
        }
        if let cell = attachment.attachmentCell as? NSTextAttachmentCell {
            let cellSize = cell.cellSize()
            if cellSize.width > 0, cellSize.height > 0 { return cellSize }
        }
        if let data = attachment.fileWrapper?.regularFileContents,
           let image = NSImage(data: data),
           image.size.width > 0,
           image.size.height > 0 {
            return image.size
        }
        return nil
    }

    /// Builds a plain (non-floating) attachment for `image`, fitted to
    /// `maximumWidth`. Used both for live insertion into an editor and for
    /// offline construction of an attributed string (e.g. Word import) before
    /// any NSTextView exists.
    static func makeAttachment(for image: NSImage, maximumWidth: CGFloat) -> NSTextAttachment {
        let attachment = NSTextAttachment(
            data: image.tiffRepresentation,
            ofType: UTType.tiff.identifier
        )
        let displaySize = fittedSize(image.size, maximumWidth: maximumWidth)
        let displayImage = (image.copy() as? NSImage) ?? image
        displayImage.size = displaySize
        attachment.image = displayImage
        attachment.bounds = NSRect(origin: .zero, size: displaySize)
        return attachment
    }

    @MainActor
    @discardableResult
    static func insert(
        _ image: NSImage,
        into textView: NSTextView,
        at range: NSRange,
        maximumWidth: CGFloat
    ) -> Bool {
        guard let storage = textView.textStorage,
              range.location != NSNotFound,
              NSMaxRange(range) <= storage.length,
              textView.shouldChangeText(in: range, replacementString: "\u{fffc}")
        else { return false }

        let attachment = makeAttachment(for: image, maximumWidth: maximumWidth)

        storage.replaceCharacters(in: range, with: NSAttributedString(attachment: attachment))
        let insertionPoint = range.location + 1
        textView.setSelectedRange(NSRange(location: insertionPoint, length: 0))
        textView.didChangeText()
        textView.window?.makeFirstResponder(textView)
        return true
    }
}
