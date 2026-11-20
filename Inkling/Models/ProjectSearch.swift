//
//  ProjectSearch.swift
//  Inkling
//
//  Find & replace across every chapter in a project, not just the one
//  currently open in the editor. Pure and Core-Data-free (like
//  `PrintableChapter`/`ManuscriptPrinter`) so it's testable without an
//  in-memory managed object context; the caller is responsible for reading
//  `Chapter.bodyData`/`notesData` into `SearchableChapter` and writing the
//  results back.
//
//  A chapter's words live in four places, and search covers all of them: the
//  body, the chapter's notes (`notesData`), its sidebar boxes and its image
//  captions (both stored inside `bodyData`'s sidecar). Each match records its
//  `SearchPlace`, so the panel can say where it is and a jump can go there.
//

import AppKit

/// The chapter data search/replace needs — decoupled from the Core Data
/// `Chapter` type so this logic can run against plain values.
struct SearchableChapter {
    let id: UUID
    let title: String
    let bodyData: Data?
    var notesData: Data? = nil
}

/// Where in a chapter a match is. `range` in `SearchMatch` is relative to the
/// text of that place: the body, the notes, the sidebar box's own text, or
/// the caption.
enum SearchPlace: Hashable {
    case body
    case notes
    /// `anchor` is the box's anchor character in the body; `title` is the
    /// author's own title for the box, empty when it has none.
    case sidebar(anchor: Int, title: String)
    /// `anchor` is the image's attachment character in the body.
    case caption(anchor: Int)

    /// How the panel names the place; nil for the body, which needs no label.
    var label: String? {
        switch self {
        case .body: nil
        case .notes: "Notes"
        case .sidebar(_, let title): title.isEmpty ? "Sidebar" : "Sidebar “\(title)”"
        case .caption: "Caption"
        }
    }
}

/// The new stored data Replace All produced for one chapter; nil where that
/// field had no match and is left as it was.
struct ChapterReplacement: Equatable {
    var bodyData: Data?
    var notesData: Data?
}

struct SearchMatch: Identifiable, Equatable {
    let id = UUID()
    let chapterID: UUID
    let chapterTitle: String
    var place: SearchPlace = .body
    let range: NSRange
    /// Snippet context split into three pieces (rather than one string with a
    /// baked-in delimiter) so the UI can render the match distinctly, e.g.
    /// `Text(before) + Text(match).bold() + Text(after)`.
    let snippetBefore: String
    let snippetMatch: String
    let snippetAfter: String
}

/// A preview is safe to replace only while its search inputs still match the
/// controls. Keeping those inputs beside the matches prevents Replace All from
/// silently applying an edited query that the user has never previewed.
struct ProjectSearchResult {
    let query: String
    let caseSensitive: Bool
    let matches: [SearchMatch]

    func isCurrent(query: String, caseSensitive: Bool) -> Bool {
        self.query == query && self.caseSensitive == caseSensitive
    }
}

enum ProjectSearch {
    /// Characters of context shown on each side of a match in its snippet.
    static let snippetContextLength = 40

    static func findMatches(
        in chapters: [SearchableChapter],
        query: String,
        caseSensitive: Bool
    ) -> [SearchMatch] {
        guard !query.isEmpty else { return [] }
        var matches: [SearchMatch] = []
        for chapter in chapters {
            func collect(_ text: NSString, in place: SearchPlace) {
                for range in allRanges(of: query, in: text, caseSensitive: caseSensitive) {
                    matches.append(SearchMatch(
                        chapterID: chapter.id,
                        chapterTitle: chapter.title,
                        place: place,
                        range: range,
                        snippetBefore: snippetBefore(in: text, before: range),
                        snippetMatch: text.substring(with: range),
                        snippetAfter: snippetAfter(in: text, after: range)
                    ))
                }
            }

            // Text-only for the body: matching needs the string, not restored
            // images. Only a body with attachments has sidebars or captions,
            // and only then is the full decode (which rebuilds them) needed.
            if let body = RichTextCodec.decodeText(chapter.bodyData) {
                collect(body.string as NSString, in: .body)
                if body.string.contains(attachmentCharacter),
                   let full = RichTextCodec.decode(chapter.bodyData) {
                    for part in attachedText(in: full) {
                        collect(part.text as NSString, in: part.place)
                    }
                }
            }
            if let notes = RichTextCodec.decodeText(chapter.notesData) {
                collect(notes.string as NSString, in: .notes)
            }
        }
        return matches
    }

    private static let attachmentCharacter: Character = "\u{FFFC}"

    /// The text held by `body`'s attachments, in document order: each sidebar
    /// box's content and each image's caption.
    private static func attachedText(in body: NSAttributedString) -> [(place: SearchPlace, text: String)] {
        var parts: [(place: SearchPlace, text: String)] = []
        let all = NSRange(location: 0, length: body.length)
        body.enumerateAttribute(.attachment, in: all) { value, range, _ in
            if let sidebar = value as? SidebarAttachment {
                let text = RichTextCodec.decodeText(sidebar.contentData)?.string ?? ""
                let title = sidebar.title.trimmingCharacters(in: .whitespacesAndNewlines)
                parts.append((.sidebar(anchor: range.location, title: title), text))
            } else if value != nil,
                      let caption = body.attribute(.inklingImageCaption, at: range.location, effectiveRange: nil) as? String {
                parts.append((.caption(anchor: range.location), caption))
            }
        }
        return parts
    }

    /// Replaces every occurrence of `query` — in the body, the notes, the
    /// sidebar boxes and the captions — and returns the new data for just the
    /// chapters and fields that changed (a chapter with no match is omitted;
    /// an unchanged field is nil). The caller writes these back.
    static func replaceAll(
        in chapters: [SearchableChapter],
        query: String,
        replacement: String,
        caseSensitive: Bool
    ) -> [UUID: ChapterReplacement] {
        guard !query.isEmpty else { return [:] }
        var results: [UUID: ChapterReplacement] = [:]
        for chapter in chapters {
            var result = ChapterReplacement()
            if let body = RichTextCodec.decode(chapter.bodyData) {
                let mutable = NSMutableAttributedString(attributedString: body)
                var changed = replace(query, with: replacement, in: mutable, caseSensitive: caseSensitive)
                // After the body text: the attachments ride along with their
                // characters, so their new locations need no bookkeeping.
                changed = replaceInAttachments(
                    of: mutable, query: query, replacement: replacement, caseSensitive: caseSensitive
                ) || changed
                if changed { result.bodyData = RichTextCodec.encode(mutable) }
            }
            if let notes = RichTextCodec.decode(chapter.notesData) {
                let mutable = NSMutableAttributedString(attributedString: notes)
                if replace(query, with: replacement, in: mutable, caseSensitive: caseSensitive) {
                    result.notesData = RichTextCodec.encode(mutable)
                }
            }
            if result.bodyData != nil || result.notesData != nil {
                results[chapter.id] = result
            }
        }
        return results
    }

    /// Replaces every match in `text`, each taking the attributes of the text
    /// it replaces. Returns whether anything changed.
    private static func replace(
        _ query: String, with replacement: String,
        in text: NSMutableAttributedString, caseSensitive: Bool
    ) -> Bool {
        let ranges = allRanges(of: query, in: text.string as NSString, caseSensitive: caseSensitive)
        // Back-to-front so replacing one match doesn't shift the locations of
        // the ones still to come.
        for range in ranges.reversed() {
            let attributes = text.attributes(at: range.location, effectiveRange: nil)
            text.replaceCharacters(in: range, with: NSAttributedString(string: replacement, attributes: attributes))
        }
        return !ranges.isEmpty
    }

    /// Replaces matches inside each sidebar box's own text and each image's
    /// caption. Returns whether anything changed.
    private static func replaceInAttachments(
        of body: NSMutableAttributedString,
        query: String, replacement: String, caseSensitive: Bool
    ) -> Bool {
        var changed = false
        let all = NSRange(location: 0, length: body.length)
        var captions: [(range: NSRange, caption: String?)] = []
        body.enumerateAttribute(.attachment, in: all) { value, range, _ in
            if let sidebar = value as? SidebarAttachment {
                guard let content = RichTextCodec.decode(sidebar.contentData) else { return }
                let mutable = NSMutableAttributedString(attributedString: content)
                guard replace(query, with: replacement, in: mutable, caseSensitive: caseSensitive),
                      let encoded = RichTextCodec.encode(mutable)
                else { return }
                sidebar.contentData = encoded
                changed = true
            } else if value != nil,
                      let caption = body.attribute(.inklingImageCaption, at: range.location, effectiveRange: nil) as? String {
                let mutable = NSMutableString(string: caption)
                let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
                let count = mutable.replaceOccurrences(
                    of: query, with: replacement, options: options,
                    range: NSRange(location: 0, length: mutable.length)
                )
                guard count > 0 else { return }
                captions.append((range, ImageCaption.normalized(mutable as String)))
            }
        }
        // Outside the enumeration, which mustn't see its own attribute change.
        for (range, caption) in captions {
            if let caption {
                body.addAttribute(.inklingImageCaption, value: caption, range: range)
            } else {
                body.removeAttribute(.inklingImageCaption, range: range)
            }
            changed = true
        }
        return changed
    }

    private static func allRanges(of query: String, in text: NSString, caseSensitive: Bool) -> [NSRange] {
        let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var ranges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: text.length)
        while searchRange.length > 0 {
            let found = text.range(of: query, options: options, range: searchRange)
            guard found.location != NSNotFound else { break }
            ranges.append(found)
            let nextLocation = found.location + found.length
            searchRange = NSRange(location: nextLocation, length: text.length - nextLocation)
        }
        return ranges
    }

    private static func snippetBefore(in text: NSString, before range: NSRange) -> String {
        let start = max(0, range.location - snippetContextLength)
        let prefix = start > 0 ? "…" : ""
        return prefix + text.substring(with: NSRange(location: start, length: range.location - start))
    }

    private static func snippetAfter(in text: NSString, after range: NSRange) -> String {
        let end = min(text.length, NSMaxRange(range) + snippetContextLength)
        let suffix = end < text.length ? "…" : ""
        return text.substring(with: NSRange(location: NSMaxRange(range), length: end - NSMaxRange(range))) + suffix
    }
}
