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

    /// `size` scaled down, keeping its proportions, until it fits inside
    /// `maximumSize` on both axes. Never scales up.
    static func fittedSize(_ size: NSSize, within maximumSize: NSSize) -> NSSize {
        guard size.width > 0, size.height > 0,
              maximumSize.width > 0, maximumSize.height > 0
        else { return .zero }
        let scale = min(1, maximumSize.width / size.width, maximumSize.height / size.height)
        return NSSize(width: size.width * scale, height: size.height * scale)
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
    static func makeAttachment(
        for image: NSImage,
        sourceData: Data? = nil,
        contentType: UTType? = nil,
        filename: String? = nil,
        preferredDisplaySize: NSSize? = nil,
        maximumWidth: CGFloat
    ) -> NSTextAttachment {
        let storedType = contentType ?? .tiff
        let data = sourceData ?? image.tiffRepresentation ?? Data()
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = filename
            ?? "image.\(storedType.preferredFilenameExtension ?? "tiff")"
        let attachment = NSTextAttachment(fileWrapper: wrapper)
        let requestedSize = preferredDisplaySize.flatMap {
            $0.width > 0 && $0.height > 0 ? $0 : nil
        } ?? image.size
        let displaySize = fittedSize(requestedSize, maximumWidth: maximumWidth)
        // Keep the file-wrapper bytes authoritative. Assigning `image` makes
        // NSTextAttachment immediately re-encode the wrapper (even when the
        // source is already a PNG), which needlessly changes imported files.
        // But a wrapper-only attachment lays out at the image's full pixel
        // size, ignoring `bounds`, so the sized display image goes on the cell
        // instead: that keeps the bytes and draws at the fitted size.
        let displayImage = (image.copy() as? NSImage) ?? image
        displayImage.size = displaySize
        attachment.attachmentCell = NSTextAttachmentCell(imageCell: displayImage)
        attachment.bounds = NSRect(origin: .zero, size: displaySize)
        return attachment
    }

    @MainActor
    @discardableResult
    static func insert(
        _ image: NSImage,
        sourceData: Data? = nil,
        contentType: UTType? = nil,
        filename: String? = nil,
        into textView: NSTextView,
        at range: NSRange,
        maximumWidth: CGFloat
    ) -> Bool {
        guard let storage = textView.textStorage,
              range.location != NSNotFound,
              NSMaxRange(range) <= storage.length,
              textView.shouldChangeText(in: range, replacementString: "\u{fffc}")
        else { return false }

        let attachment = makeAttachment(
            for: image,
            sourceData: sourceData,
            contentType: contentType,
            filename: filename,
            maximumWidth: maximumWidth
        )

        storage.replaceCharacters(in: range, with: NSAttributedString(attachment: attachment))
        let insertionPoint = range.location + 1
        textView.setSelectedRange(NSRange(location: insertionPoint, length: 0))
        textView.didChangeText()
        textView.window?.makeFirstResponder(textView)
        return true
    }
}
