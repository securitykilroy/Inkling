//
//  RichTextCodec.swift
//  Inkling
//
//  One format boundary for chapter and note rich text. RTFD embeds image
//  attachments; the RTF fallback keeps every existing Inkling file readable.
//

import AppKit

enum RichTextCodec {
    nonisolated private static let attachmentMetadataFilename = "__inkling_attachment_sizes.json"
    nonisolated private static let calloutMetadataFilename = "__inkling_callouts.json"
    nonisolated private static let sidebarMetadataFilename = "__inkling_sidebars.json"

    /// Space after a paragraph, in points, so a plain "\n" between paragraphs
    /// reads as a paragraph break rather than a line break. Applied to newly
    /// typed text (via typing attributes) and backfilled on decode for
    /// chapters written before this existed, including Word imports.
    ///
    /// Half a line: body text is 14pt, so a line box is ~17pt. Paragraphs are
    /// marked by this gap alone — there is deliberately no first-line indent,
    /// and adding one would be redundant. This started at 6pt, which is only a
    /// third of a line: too small to read unambiguously as a break, and dense
    /// pages of long paragraphs ran together as a result.
    nonisolated static let defaultParagraphSpacing: CGFloat = 9

    /// First-line indent for body paragraphs. Deliberately smaller than the
    /// ~1em a book would use if the indent were the *only* paragraph marker:
    /// the gap above already does that job, so this is texture on the left
    /// edge rather than a signal, and a full-size indent alongside a gap reads
    /// as a mistake. Headings stay flush — see `applyDefaultParagraphStyling`.
    nonisolated static let defaultFirstLineIndent: CGFloat = 12

    nonisolated static var defaultParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = defaultParagraphSpacing
        style.firstLineHeadIndent = defaultFirstLineIndent
        return style
    }

    private struct AttachmentSizeRecord: Codable {
        var location: Int
        let width: Double
        let height: Double
        // Present only for images the user has positioned on a page. Optional so
        // older sidecars (sizes only) still decode, and un-moved images stay
        // free of a stored position.
        var page: Int?
        var originX: Double?
        var originY: Double?
        var importedPlacementHint: ImportedImagePlacementHint?
        // Optional so older sidecars decode; an older app reading a newer
        // sidecar ignores it (and would drop the caption if it saved).
        var caption: String?
    }

    /// A callout run: the paragraph range it covers and its kind. RTF can't
    /// carry the `.inklingCallout` attribute, so it rides in the sidecar and is
    /// re-applied (with its canonical styling) on decode.
    private struct CalloutRecord: Codable {
        var location: Int
        var length: Int
        let kind: String
    }

    /// A floating margin sidebar: its anchor location, box geometry, and content
    /// (RTF). The anchor character survives in the RTFD stream (the attachment
    /// carries a file wrapper); this record restores it to a full `SidebarAttachment`.
    private struct SidebarRecord: Codable {
        var location: Int
        let width: Double
        let contentHeight: Double
        var page: Int?
        var originX: Double?
        var originY: Double?
        var content: Data?
        /// Optional so sidecars written before titles existed still decode; a
        /// missing title means "no title of its own" and the header falls back
        /// to `SidebarStyle.defaultTitle`.
        var title: String?
    }

    nonisolated static func decode(_ data: Data?) -> NSAttributedString? {
        guard let data else { return nil }
        guard let attributed = NSAttributedString(rtfd: data, documentAttributes: nil)
            ?? NSAttributedString(rtf: data, documentAttributes: nil)
        else { return nil }
        let mutable = NSMutableAttributedString(attributedString: attributed)
        // Parsed once for all three sidecars. Each used to re-parse the whole
        // RTFD package, image bytes included, so a decode cost four parses.
        let sidecars = FileWrapper(serializedRepresentation: data)?.fileWrappers ?? [:]
        var sizes = records(AttachmentSizeRecord.self, named: attachmentMetadataFilename, in: sidecars)
        var callouts = records(CalloutRecord.self, named: calloutMetadataFilename, in: sidecars)
        var sidebars = records(SidebarRecord.self, named: sidebarMetadataFilename, in: sidecars)
        realign(sizes: &sizes, callouts: &callouts, sidebars: &sidebars, to: mutable)
        restoreAttachmentSizes(in: mutable, from: sizes)
        applyDefaultParagraphStyling(in: mutable)
        restoreCallouts(in: mutable, from: callouts)
        restoreSidebars(in: mutable, from: sidebars)
        return mutable
    }

    nonisolated private static func records<Record: Decodable>(
        _ type: Record.Type,
        named name: String,
        in sidecars: [String: FileWrapper]
    ) -> [Record] {
        guard let metadata = sidecars[name]?.regularFileContents else { return [] }
        return (try? JSONDecoder().decode([Record].self, from: metadata)) ?? []
    }

    // MARK: - Keeping sidecar offsets true
    //
    // Every sidecar record is keyed by a character offset, so the text that
    // comes back from RTFD has to have exactly the characters that went in.
    // It doesn't always: the RTF writer and reader between them merge "\r\n"
    // into one character and drop NUL, U+FFFD and an object-replacement
    // character that carries no attachment. One pasted Windows line ending
    // therefore moved every later offset by one, and on the next open each
    // image after it lost its size, position and caption, each callout covered
    // the wrong characters, and each sidebar lost its record — and with it,
    // on the following save, its text.
    //
    // Two defences. `storable` removes those characters before anything is
    // measured, so what is saved round-trips exactly. `realign` repairs data
    // saved before that existed (or shifted by a character not yet known to
    // do this) by matching records to the attachments actually present.

    /// `text` without the characters an RTFD round trip would drop or merge.
    /// Returns `text` itself, uncopied, in the overwhelmingly common case that
    /// it has none: this runs on every keystroke.
    nonisolated static func storable(_ text: NSAttributedString) -> NSAttributedString {
        let string = text.string as NSString
        let suspects = CharacterSet(charactersIn: "\r\u{0}\u{fffd}\u{fffc}")
        var doomed: [Int] = []
        var search = NSRange(location: 0, length: string.length)
        while search.length > 0 {
            let found = string.rangeOfCharacter(from: suspects, options: [], range: search)
            guard found.location != NSNotFound else { break }
            let index = found.location
            switch string.character(at: index) {
            case 0x0D:
                // A lone "\r" comes back as "\n", one for one. Only the pair shrinks.
                if index + 1 < string.length, string.character(at: index + 1) == 0x0A {
                    doomed.append(index)
                }
            case 0xFFFC:
                if text.attribute(.attachment, at: index, effectiveRange: nil) == nil {
                    doomed.append(index)
                }
            default:
                doomed.append(index)
            }
            search = NSRange(location: index + 1, length: string.length - index - 1)
        }
        guard !doomed.isEmpty else { return text }
        let mutable = NSMutableAttributedString(attributedString: text)
        for index in doomed.reversed() {
            mutable.deleteCharacters(in: NSRange(location: index, length: 1))
        }
        return mutable
    }

    /// Where each record offset's attachment really is, for records that no
    /// longer land on one; nil when every record already does.
    ///
    /// Characters only ever go missing, so an attachment sits at or before its
    /// recorded offset, and the shortfall never shrinks further down the
    /// text. Each record, in order, therefore takes the nearest unclaimed
    /// attachment at or before where the drift so far says it should be.
    nonisolated static func alignedLocations(
        of recordLocations: [Int],
        toAttachmentsAt attachmentLocations: [Int]
    ) -> [Int: Int]? {
        let present = Set(attachmentLocations)
        guard !recordLocations.allSatisfy(present.contains) else { return nil }

        let attachments = attachmentLocations.sorted()
        var mapping: [Int: Int] = [:]
        var drift = 0
        var next = 0
        for record in Set(recordLocations).sorted() {
            var chosen: Int?
            var index = next
            while index < attachments.count, attachments[index] <= record - drift {
                chosen = index
                index += 1
            }
            guard let chosen else { continue }
            mapping[record] = attachments[chosen]
            drift = record - attachments[chosen]
            next = chosen + 1
        }
        return mapping
    }

    nonisolated private static func realign(
        sizes: inout [AttachmentSizeRecord],
        callouts: inout [CalloutRecord],
        sidebars: inout [SidebarRecord],
        to text: NSAttributedString
    ) {
        guard !sizes.isEmpty || !sidebars.isEmpty else { return }
        var attachmentLocations: [Int] = []
        text.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: text.length)
        ) { value, range, _ in
            guard value != nil else { return }
            attachmentLocations.append(contentsOf: range.location..<NSMaxRange(range))
        }
        guard let mapping = alignedLocations(
            of: sizes.map(\.location) + sidebars.map(\.location),
            toAttachmentsAt: attachmentLocations
        ) else { return }

        for index in sizes.indices {
            sizes[index].location = mapping[sizes[index].location] ?? sizes[index].location
        }
        for index in sidebars.indices {
            sidebars[index].location = mapping[sidebars[index].location] ?? sidebars[index].location
        }
        // Callouts have no attachment of their own to match against, so they
        // take the drift of the nearest attachment before them. Exact when
        // the missing characters precede that attachment, which is the case
        // this exists for; a callout past the last attachment can still be off.
        let drifts = mapping.map { (offset: $0.key, drift: $0.key - $0.value) }
            .sorted { $0.offset < $1.offset }
        func moved(_ offset: Int) -> Int {
            offset - (drifts.last { $0.offset <= offset }?.drift ?? 0)
        }
        for index in callouts.indices {
            let start = moved(callouts[index].location)
            let end = moved(callouts[index].location + callouts[index].length)
            callouts[index].location = start
            callouts[index].length = max(0, end - start)
        }
    }

    /// The stored text and its character attributes only, with none of the
    /// sidecar restoration: no image sizing, placements, callouts or sidebars,
    /// and no paragraph-style backfill. The string, fonts and character
    /// offsets match `decode`.
    ///
    /// For readers that only need words or fonts, like word counts and the
    /// outline, which run once per chapter when a project opens and once per
    /// keystroke for the chapter being edited.
    nonisolated static func decodeText(_ data: Data?) -> NSAttributedString? {
        guard let data else { return nil }
        return NSAttributedString(rtfd: data, documentAttributes: nil)
            ?? NSAttributedString(rtf: data, documentAttributes: nil)
    }

    /// `decodeText` plus each sidebar box's title and content, read straight
    /// from the sidecar without rebuilding attachments. For word counts, which
    /// count what's written in sidebars along with the body. Parses the
    /// package once for both.
    nonisolated static func decodeTextAndSidebars(
        _ data: Data?
    ) -> (text: NSAttributedString, sidebars: [(title: String, content: Data?)])? {
        guard let data else { return nil }
        guard let wrapper = FileWrapper(serializedRepresentation: data),
              let text = NSAttributedString(rtfdFileWrapper: wrapper, documentAttributes: nil)
        else {
            return decodeText(data).map { ($0, []) }
        }
        guard let metadata = wrapper.fileWrappers?[sidebarMetadataFilename]?.regularFileContents,
              let records = try? JSONDecoder().decode([SidebarRecord].self, from: metadata)
        else { return (text, []) }
        return (text, records.map { ($0.title ?? "", $0.content) })
    }

    /// Rebuilds a full `SidebarAttachment` (content + placement + width) at each
    /// recorded anchor. The generic attachment produced by RTFD decoding is
    /// replaced in place, carrying over the surrounding run's attributes.
    ///
    /// A record is never thrown away: it holds the only copy of the box's
    /// text, and the next save writes records only for the sidebars it finds.
    /// Damaged geometry falls back to the defaults, and a record whose anchor
    /// can't be found gets a new anchor as near its old place as the text allows.
    nonisolated private static func restoreSidebars(
        in attributedString: NSMutableAttributedString,
        from records: [SidebarRecord]
    ) {
        var orphans: [(location: Int, sidebar: SidebarAttachment)] = []
        for record in records {
            let width = record.width.isFinite && record.width > 0 && record.width <= 10_000
                ? CGFloat(record.width) : SidebarStyle.defaultWidth
            let contentHeight = record.contentHeight.isFinite
                && record.contentHeight >= 0 && record.contentHeight <= 10_000
                ? CGFloat(record.contentHeight) : SidebarStyle.minContentHeight
            var position: FloatingImagePosition?
            if let page = record.page, let x = record.originX, let y = record.originY {
                let candidate = FloatingImagePosition(page: page, origin: CGPoint(x: x, y: y))
                if candidate.isValidForPersistence { position = candidate }
            }
            let sidebar = SidebarAttachment(
                contentData: record.content,
                width: width,
                position: position,
                contentHeight: contentHeight
            )
            sidebar.title = record.title ?? ""

            let anchored = record.location >= 0 && record.location < attributedString.length
                && attributedString.attribute(.attachment, at: record.location, effectiveRange: nil)
                    is NSTextAttachment
            guard anchored else {
                orphans.append((record.location, sidebar))
                continue
            }
            attributedString.addAttribute(
                .attachment,
                value: sidebar,
                range: NSRange(location: record.location, length: 1)
            )
        }

        // Back to front, so an insertion can't move a place still to be used.
        for orphan in orphans.sorted(by: { $0.location > $1.location }) {
            let location = min(max(0, orphan.location), attributedString.length)
            let anchor = NSMutableAttributedString(attachment: orphan.sidebar)
            if attributedString.length > 0 {
                var attributes = attributedString.attributes(
                    at: min(location, attributedString.length - 1), effectiveRange: nil
                )
                for key in [NSAttributedString.Key.attachment, .inklingFloatingImagePosition,
                            .inklingImportedImagePlacementHint, .inklingImageCaption] {
                    attributes[key] = nil
                }
                anchor.addAttributes(attributes, range: NSRange(location: 0, length: anchor.length))
            }
            attributedString.insert(anchor, at: location)
        }
    }

    /// Re-tags callout runs recorded in the sidecar and re-applies each kind's
    /// canonical styling. Runs after `applyDefaultParagraphSpacing` so callout
    /// paragraphs get their reserved box padding rather than the default spacing.
    nonisolated private static func restoreCallouts(
        in attributedString: NSMutableAttributedString,
        from records: [CalloutRecord]
    ) {
        for record in records {
            guard let kind = CalloutKind(storedRawValue: record.kind),
                  record.location >= 0,
                  record.location < attributedString.length
            else { continue }
            let length = min(record.length, attributedString.length - record.location)
            guard length > 0 else { continue }
            CalloutStyling.apply(kind, to: attributedString, range: NSRange(location: record.location, length: length))
        }
    }

    /// Backfills the default paragraph spacing and body first-line indent onto
    /// any paragraph missing them, preserving any other paragraph-style
    /// properties (alignment, etc.) already present. Safe to run on every
    /// decode: whatever a paragraph already carries is left untouched.
    ///
    /// The two properties are checked **independently**. Chapters saved before
    /// the indent existed already carry non-zero spacing, so a combined test
    /// would skip them and the indent would only ever reach newly typed text.
    ///
    /// Headings keep a flush left edge — an indented Title/Heading reads as a
    /// mistake — using the same bold-and-≥17pt test the sidebar outline uses.
    /// Callout styling runs after this and sets its own indents, so callouts
    /// are unaffected.
    nonisolated private static func applyDefaultParagraphStyling(in attributedString: NSMutableAttributedString) {
        guard attributedString.length > 0 else { return }
        let string = attributedString.string as NSString

        var location = 0
        while location < attributedString.length {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            guard paragraph.length > 0 else { break }

            let existing = attributedString.attribute(
                .paragraphStyle, at: paragraph.location, effectiveRange: nil
            ) as? NSParagraphStyle
            let updated = (existing?.mutableCopy() as? NSMutableParagraphStyle)
                ?? NSMutableParagraphStyle()
            var changed = false

            if (existing?.paragraphSpacing ?? 0) == 0 {
                updated.paragraphSpacing = defaultParagraphSpacing
                changed = true
            }
            if (existing?.firstLineHeadIndent ?? 0) == 0,
               !isHeadingParagraph(paragraph, in: attributedString) {
                updated.firstLineHeadIndent = defaultFirstLineIndent
                changed = true
            }
            if changed {
                attributedString.addAttribute(.paragraphStyle, value: updated, range: paragraph)
            }
            location = paragraph.location + paragraph.length
        }
    }

    /// The same bold-and-large test `ChapterOutline` uses to spot headings.
    nonisolated private static func isHeadingParagraph(
        _ range: NSRange,
        in attributedString: NSAttributedString
    ) -> Bool {
        guard let font = attributedString.attribute(
            .font, at: range.location, effectiveRange: nil
        ) as? NSFont else { return false }
        return font.fontDescriptor.symbolicTraits.contains(.bold) && font.pointSize >= 17
    }

    nonisolated static func encode(_ source: NSAttributedString) -> Data? {
        // Before anything is measured: see "Keeping sidecar offsets true".
        let attributedString = storable(source)
        let fullRange = NSRange(location: 0, length: attributedString.length)
        let sizeRecords = attachmentSizeRecords(in: attributedString)
        let calloutRecords = calloutRecords(in: attributedString)
        let sidebarRecords = sidebarRecords(in: attributedString)
        guard !sizeRecords.isEmpty || !calloutRecords.isEmpty || !sidebarRecords.isEmpty else {
            return attributedString.rtfd(from: fullRange, documentAttributes: [:])
        }
        // Build the package directly rather than serializing it, parsing it
        // back, and serializing again: with images, each of those steps copies
        // every image's bytes, and this runs on every keystroke.
        guard let wrapper = attributedString.rtfdFileWrapper(from: fullRange, documentAttributes: [:])
        else { return nil }

        if !sizeRecords.isEmpty, let metadata = try? JSONEncoder().encode(sizeRecords) {
            replaceFile(named: attachmentMetadataFilename, contents: metadata, in: wrapper)
        }
        if !calloutRecords.isEmpty, let metadata = try? JSONEncoder().encode(calloutRecords) {
            replaceFile(named: calloutMetadataFilename, contents: metadata, in: wrapper)
        }
        if !sidebarRecords.isEmpty, let metadata = try? JSONEncoder().encode(sidebarRecords) {
            replaceFile(named: sidebarMetadataFilename, contents: metadata, in: wrapper)
        }
        return wrapper.serializedRepresentation
    }

    /// A failed rich-text serialization must never replace content that was
    /// previously saved successfully. Kept as a small boundary helper so every
    /// editor/offline rewrite follows the same rule.
    nonisolated static func dataForPersistence(encoded: Data?, previous: Data?) -> Data? {
        encoded ?? previous
    }

    /// One record per floating sidebar, capturing its anchor, geometry, and RTF.
    nonisolated private static func sidebarRecords(in attributedString: NSAttributedString) -> [SidebarRecord] {
        var records: [SidebarRecord] = []
        attributedString.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributedString.length)
        ) { value, range, _ in
            guard let sidebar = value as? SidebarAttachment else { return }
            records.append(SidebarRecord(
                location: range.location,
                width: Double(sidebar.width),
                contentHeight: Double(sidebar.contentHeight),
                page: sidebar.position?.page,
                originX: sidebar.position.map { Double($0.origin.x) },
                originY: sidebar.position.map { Double($0.origin.y) },
                content: sidebar.contentData,
                title: sidebar.title.isEmpty ? nil : sidebar.title
            ))
        }
        return records
    }

    nonisolated private static func replaceFile(named name: String, contents: Data, in wrapper: FileWrapper) {
        if let existing = wrapper.fileWrappers?[name] {
            wrapper.removeFileWrapper(existing)
        }
        wrapper.addRegularFile(withContents: contents, preferredFilename: name)
    }

    /// One record per maximal callout run. `enumerateAttribute` already coalesces
    /// adjacent equal string values, so each callback is one contiguous callout.
    nonisolated private static func calloutRecords(in attributedString: NSAttributedString) -> [CalloutRecord] {
        var records: [CalloutRecord] = []
        attributedString.enumerateAttribute(
            .inklingCallout,
            in: NSRange(location: 0, length: attributedString.length)
        ) { value, range, _ in
            guard let kind = value as? String, CalloutKind(storedRawValue: kind) != nil else { return }
            records.append(CalloutRecord(location: range.location, length: range.length, kind: kind))
        }
        return records
    }

    /// RTFD embeds attachment files but does not preserve NSTextAttachment's
    /// display bounds. Store those bounds in a private sidecar inside the RTFD
    /// package without reducing the original image or migrating Core Data.
    nonisolated private static func attachmentSizeRecords(
        in attributedString: NSAttributedString
    ) -> [AttachmentSizeRecord] {
        var records: [AttachmentSizeRecord] = []
        attributedString.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributedString.length)
        ) { value, range, _ in
            guard let attachment = value as? NSTextAttachment,
                  !(attachment is SidebarAttachment) else { return }
            let size = (attachment as? FloatingImageAttachment)?.displaySize
                ?? attachment.bounds.size
            guard size.width > 0, size.height > 0
            else { return }
            // Only the editor and the printer build `FloatingImageAttachment`s.
            // Everything that rewrites a chapter offline — project-wide Replace
            // All, a project font change — works on the plain attributed string
            // `decode` produced, where the placement lives in the in-memory
            // attribute instead. Without this fallback that second round trip
            // dropped `page`/`originX`/`originY`, so every image the author had
            // dragged snapped back to its paragraph anchor.
            let position = (attachment as? FloatingImageAttachment)?.position
                ?? attributedString.attribute(
                    .inklingFloatingImagePosition,
                    at: range.location,
                    effectiveRange: nil
                ) as? FloatingImagePosition
            let importedPlacementHint = (attachment as? FloatingImageAttachment)?.importedPlacementHint
                ?? attributedString.attribute(
                    .inklingImportedImagePlacementHint,
                    at: range.location,
                    effectiveRange: nil
                ) as? ImportedImagePlacementHint
            // Same fallback as `position`, for the same offline rewrites.
            let caption = (attachment as? FloatingImageAttachment).map(\.caption)
                ?? attributedString.attribute(
                    .inklingImageCaption,
                    at: range.location,
                    effectiveRange: nil
                ) as? String
            records.append(AttachmentSizeRecord(
                location: range.location,
                width: size.width,
                height: size.height,
                page: position?.page,
                originX: position.map { Double($0.origin.x) },
                originY: position.map { Double($0.origin.y) },
                importedPlacementHint: position == nil ? importedPlacementHint : nil,
                caption: ImageCaption.normalized(caption)
            ))
        }
        return records
    }

    nonisolated private static func restoreAttachmentSizes(
        in attributedString: NSMutableAttributedString,
        from records: [AttachmentSizeRecord]
    ) {
        for record in records where record.location >= 0 && record.location < attributedString.length {
            guard let attachment = attributedString.attribute(
                .attachment,
                at: record.location,
                effectiveRange: nil
            ) as? NSTextAttachment,
                  record.width.isFinite,
                  record.height.isFinite,
                  record.width > 0,
                  record.height > 0,
                  record.width <= 10_000,
                  record.height <= 10_000
            else { continue }

            // Carry any stored page placement forward as an in-memory attribute
            // so the editor and printer can build a positioned attachment from it.
            if let page = record.page, let originX = record.originX, let originY = record.originY {
                let position = FloatingImagePosition(
                    page: page,
                    origin: CGPoint(x: originX, y: originY)
                )
                if position.isValidForPersistence {
                    attributedString.addAttribute(
                        .inklingFloatingImagePosition,
                        value: position,
                        range: NSRange(location: record.location, length: 1)
                    )
                }
            } else if let hint = record.importedPlacementHint {
                attributedString.addAttribute(
                    .inklingImportedImagePlacementHint,
                    value: hint,
                    range: NSRange(location: record.location, length: 1)
                )
            }

            if let caption = ImageCaption.normalized(record.caption) {
                attributedString.addAttribute(
                    .inklingImageCaption,
                    value: caption,
                    range: NSRange(location: record.location, length: 1)
                )
            }

            // RTFD decoding produces a *cell-backed* attachment whose layout size
            // comes from the embedded image and ignores `bounds`. Rebuild it as
            // a data-backed attachment, which honors `bounds` and keeps the
            // original bytes. This used to assign `attachment.image` instead,
            // and AppKit then re-encoded every image as PNG: a JPEG grew ~4x
            // the first time a chapter was reopened. See `ImageAttachmentContent`.
            let size = NSSize(width: record.width, height: record.height)
            let range = NSRange(location: record.location, length: 1)
            if let payload = ImageAttachmentContent.storedPayload(of: attachment) {
                attributedString.addAttribute(
                    .attachment,
                    value: ImageAttachmentContent.makeSizedAttachment(payload: payload, size: size),
                    range: range
                )
            } else {
                // No bytes to keep (an image-only attachment). Size it in
                // place; it has nothing for AppKit to re-encode.
                attachment.image?.size = size
                attachment.bounds = NSRect(origin: .zero, size: size)
            }
        }
    }
}
