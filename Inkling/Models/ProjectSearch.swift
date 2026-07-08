//
//  ProjectSearch.swift
//  Inkling
//
//  Find & replace across every chapter in a project, not just the one
//  currently open in the editor. Pure and Core-Data-free (like
//  `PrintableChapter`/`ManuscriptPrinter`) so it's testable without an
//  in-memory managed object context; the caller is responsible for reading
//  `Chapter.bodyData` into `SearchableChapter` and writing the results back.
//

import Foundation

/// The chapter data search/replace needs — decoupled from the Core Data
/// `Chapter` type so this logic can run against plain values.
struct SearchableChapter {
    let id: UUID
    let title: String
    let bodyData: Data?
}

struct SearchMatch: Identifiable, Equatable {
    let id = UUID()
    let chapterID: UUID
    let chapterTitle: String
    let range: NSRange
    /// Snippet context split into three pieces (rather than one string with a
    /// baked-in delimiter) so the UI can render the match distinctly, e.g.
    /// `Text(before) + Text(match).bold() + Text(after)`.
    let snippetBefore: String
    let snippetMatch: String
    let snippetAfter: String
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
            guard let attributed = RichTextCodec.decode(chapter.bodyData) else { continue }
            let text = attributed.string as NSString
            for range in allRanges(of: query, in: text, caseSensitive: caseSensitive) {
                matches.append(SearchMatch(
                    chapterID: chapter.id,
                    chapterTitle: chapter.title,
                    range: range,
                    snippetBefore: snippetBefore(in: text, before: range),
                    snippetMatch: text.substring(with: range),
                    snippetAfter: snippetAfter(in: text, after: range)
                ))
            }
        }
        return matches
    }

    /// Replaces every occurrence of `query` in every chapter that contains
    /// at least one, and returns the new `bodyData` for just those chapters
    /// (chapters with no match are omitted, not returned unchanged) — the
    /// caller writes these back onto the real `Chapter.bodyData`.
    static func replaceAll(
        in chapters: [SearchableChapter],
        query: String,
        replacement: String,
        caseSensitive: Bool
    ) -> [UUID: Data] {
        guard !query.isEmpty else { return [:] }
        var results: [UUID: Data] = [:]
        for chapter in chapters {
            guard let attributed = RichTextCodec.decode(chapter.bodyData) else { continue }
            let mutable = NSMutableAttributedString(attributedString: attributed)
            let ranges = allRanges(of: query, in: mutable.string as NSString, caseSensitive: caseSensitive)
            guard !ranges.isEmpty else { continue }

            // Back-to-front so replacing one match doesn't shift the
            // locations of the ones still to come.
            for range in ranges.reversed() {
                let attributes = mutable.attributes(at: range.location, effectiveRange: nil)
                mutable.replaceCharacters(
                    in: range,
                    with: NSAttributedString(string: replacement, attributes: attributes)
                )
            }
            guard let encoded = RichTextCodec.encode(mutable) else { continue }
            results[chapter.id] = encoded
        }
        return results
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
