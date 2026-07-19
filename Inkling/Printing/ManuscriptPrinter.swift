//
//  ManuscriptPrinter.swift
//  Inkling
//
//  Builds NSPrintOperations for printing/exporting a manuscript. Each chapter
//  is laid out independently and starts on a fresh page, because the Cocoa text
//  system has no built-in "page break before" — so we paginate ourselves in a
//  custom NSView (knowsPageRange/rectForPage/draw). The print panel's
//  "Save as PDF" provides PDF export for free.
//

import AppKit

struct PrintableChapter {
    let title: String?
    let bodyData: Data?

    /// Whether the chapter has anything worth printing: visible body text or an
    /// embedded image (whose object-replacement glyph survives whitespace
    /// trimming). Empty chapters are skipped so they don't print blank pages.
    var hasContent: Bool {
        guard let decoded = RichTextCodec.decode(bodyData) else { return false }
        return !decoded.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum ManuscriptPrinter {

    private static let margin: CGFloat = 72  // 1 inch

    static func printOperation(
        chapters: [PrintableChapter],
        jobTitle: String,
        bookTitle: String,
        subtitle: String = "",
        author: String = "",
        includeTitlePage: Bool = false,
        printInfo: NSPrintInfo
    ) -> NSPrintOperation {
        let info = printInfo.copy() as! NSPrintInfo
        info.topMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.rightMargin = margin

        let pageSize = NSSize(
            width: info.paperSize.width - info.leftMargin - info.rightMargin,
            height: info.paperSize.height - info.topMargin - info.bottomMargin
        )

        let view = ManuscriptPrintView(
            chapters: chapters,
            pageSize: pageSize,
            leftMargin: info.leftMargin,
            topMargin: info.topMargin,
            bookTitle: bookTitle,
            subtitle: subtitle,
            author: author,
            includeTitlePage: includeTitlePage
        )
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = jobTitle
        return operation
    }

    /// The chapter body, as written. The chapter title is intentionally not
    /// prepended — authors put their own heading at the top of the body, and the
    /// title still appears in the recto running head. Text is forced to black so
    /// default adaptive colors don't print invisibly on white paper.
    static func attributedString(for chapter: PrintableChapter) -> NSAttributedString {
        let result = NSMutableAttributedString()

        if let body = RichTextCodec.decode(chapter.bodyData) {
            result.append(body)
        }

        result.addAttribute(.foregroundColor, value: NSColor.black,
                            range: NSRange(location: 0, length: result.length))
        return result
    }
}

/// Pure text rules for the printed running head and page-number folio. Books
/// place the book title on verso (even) pages and the chapter title on recto
/// (odd) pages, and omit the running head on a chapter's opening page where the
/// chapter title already appears in the body.
enum ManuscriptRunningHead {

    static func headText(
        bookTitle: String,
        chapterTitle: String,
        page: Int,
        isChapterStart: Bool
    ) -> String? {
        guard !isChapterStart else { return nil }
        let raw = page.isMultiple(of: 2) ? bookTitle : chapterTitle
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func folioText(page: Int) -> String { "\(page)" }

    /// Verso (even) heads hug the left edge; recto (odd) heads hug the right.
    static func headAlignment(page: Int) -> NSTextAlignment {
        page.isMultiple(of: 2) ? .left : .right
    }
}

/// The standalone title page that precedes the manuscript: the book title,
/// optional subtitle, and author, centered. A pure builder so it can be tested
/// and reused independent of the print view. Returns an empty string when there
/// is no metadata to show, which the view treats as "no title page".
enum ManuscriptTitlePage {

    static func attributedString(
        title: String,
        subtitle: String = "",
        author: String
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        func line(_ text: String, size: CGFloat, weight bold: Bool) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [
                .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
                .foregroundColor: NSColor.black,
                .paragraphStyle: paragraph
            ])
        }

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSubtitle = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)

        let result = NSMutableAttributedString()
        if !cleanTitle.isEmpty {
            result.append(line(cleanTitle, size: 28, weight: true))
        }
        if !cleanSubtitle.isEmpty {
            if result.length > 0 { result.append(line("\n\n", size: 18, weight: false)) }
            result.append(line(cleanSubtitle, size: 18, weight: false))
        }
        if !cleanAuthor.isEmpty {
            if result.length > 0 { result.append(line("\n\n\n", size: 14, weight: false)) }
            result.append(line("by\n", size: 14, weight: false))
            result.append(line(cleanAuthor, size: 18, weight: false))
        }
        return result
    }
}

final class ManuscriptPrintView: NSView {

    private struct ChapterLayout {
        let textStorage: NSTextStorage
        let layoutManager: NSLayoutManager
    }

    private struct PlacedImage {
        let contentRect: NSRect
        let image: NSImage
    }

    private struct PlacedSidebar {
        let contentRect: NSRect
        let content: NSAttributedString
    }

    private struct PageLayout {
        let chapterIndex: Int
        let textContainer: NSTextContainer
        let glyphRange: NSRange
        var images: [PlacedImage] = []
        var sidebars: [PlacedSidebar] = []
    }

    private let pageSize: NSSize
    private let leftMargin: CGFloat
    private let topMargin: CGFloat
    private let bookTitle: String
    private let chapterTitles: [String]
    private let titlePage: NSAttributedString?
    private var layouts: [ChapterLayout] = []
    private var pages: [PageLayout] = []

    /// Number of floating images drawn on a physical page (title page excluded).
    /// Exposed for tests.
    func floatingImageCount(onPage physicalPage: Int) -> Int {
        let bodyPage = physicalPage - titlePageCount
        guard bodyPage >= 1, pages.indices.contains(bodyPage - 1) else { return 0 }
        return pages[bodyPage - 1].images.count
    }

    /// 1 when a leading title page is present, 0 otherwise. Body pages are
    /// shifted by this so the title page occupies physical page 1 on its own.
    private var titlePageCount: Int { titlePage == nil ? 0 : 1 }

    var pageCount: Int { max(titlePageCount + pages.count, 1) }

    /// Whether the given physical page is the standalone title page.
    func isTitlePage(page: Int) -> Bool { titlePage != nil && page == 1 }

    func chapterIndex(forPage page: Int) -> Int? {
        let bodyPage = page - titlePageCount
        guard bodyPage >= 1, pages.indices.contains(bodyPage - 1) else { return nil }
        return pages[bodyPage - 1].chapterIndex
    }

    /// True for the first page of each chapter (where the running head is
    /// suppressed). The page after the title page is a chapter start because the
    /// title page maps to no chapter.
    func isChapterStart(page: Int) -> Bool {
        guard let current = chapterIndex(forPage: page) else { return false }
        return chapterIndex(forPage: page - 1) != current
    }

    /// Exposed internally for a focused regression test. Page-sized text
    /// containers make TextKit move an entire line fragment to the next page
    /// instead of clipping a line at an arbitrary vertical offset.
    var pagesUseWholeLineFragments: Bool {
        for page in pages {
            let layoutManager = layouts[page.chapterIndex].layoutManager
            var glyph = page.glyphRange.location
            while glyph < NSMaxRange(page.glyphRange) {
                var lineRange = NSRange()
                let rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineRange)
                if rect.maxY > pageSize.height + 0.5 { return false }
                glyph = max(NSMaxRange(lineRange), glyph + 1)
            }
        }
        return true
    }

    init(
        chapters: [PrintableChapter],
        pageSize: NSSize,
        leftMargin: CGFloat = 0,
        topMargin: CGFloat = 0,
        bookTitle: String = "",
        subtitle: String = "",
        author: String = "",
        includeTitlePage: Bool = false
    ) {
        self.pageSize = pageSize
        self.leftMargin = leftMargin
        self.topMargin = topMargin
        self.bookTitle = bookTitle
        self.chapterTitles = chapters.map {
            ($0.title?.isEmpty == false) ? $0.title! : "Untitled Chapter"
        }
        if includeTitlePage {
            let page = ManuscriptTitlePage.attributedString(title: bookTitle, subtitle: subtitle, author: author)
            self.titlePage = page.length > 0 ? page : nil
        } else {
            self.titlePage = nil
        }
        super.init(frame: NSRect(origin: .zero, size: pageSize))
        buildLayouts(chapters)
        frame = NSRect(x: 0, y: 0, width: pageSize.width, height: pageSize.height * CGFloat(pageCount))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// Every image prints as a floating rect, drawn manually beside its
    /// paragraph, never as part of the text flow — matching the editor, where
    /// every image floats whether or not the user has dragged it. Positioned
    /// images (the user dragged them) already know their page. Un-positioned
    /// images don't, so building a chapter's pages takes two passes: the first
    /// discovers which page each un-positioned image's paragraph naturally
    /// falls on (using only the positioned images' exclusions, since those are
    /// known upfront and can shift surrounding text), and the second lays out
    /// the chapter for real with every image's page already known.
    private func buildLayouts(_ chapters: [PrintableChapter]) {
        for chapter in chapters {
            let baseText = ManuscriptPrinter.attributedString(for: chapter)
            let chapterIndex = layouts.count

            // Record each attachment's real display size before collapsing its
            // inline glyph to near nothing; every attachment is drawn manually
            // regardless of whether it ends up positioned or auto-floated.
            var sizes: [ObjectIdentifier: NSSize] = [:]
            baseText.enumerateAttribute(
                .attachment, in: NSRange(location: 0, length: baseText.length)
            ) { value, _, _ in
                guard let attachment = value as? NSTextAttachment,
                      !(attachment is SidebarAttachment),
                      let size = Self.displaySize(of: attachment)
                else { return }
                sizes[ObjectIdentifier(attachment)] = size
                attachment.bounds = NSRect(x: 0, y: 0, width: 0.1, height: 0.1)
            }

            let explicitPlacements = floatingPlacementsWithSavedPosition(in: baseText, sizes: sizes)
            let sidebarsByPage = sidebarPlacements(in: baseText)

            let discovery = layOutPages(
                chapterIndex: chapterIndex,
                text: baseText,
                placements: Self.groupedByPage(explicitPlacements),
                sidebars: sidebarsByPage
            )
            let discoveredPlacements = discoverUnplacedPlacements(
                in: discovery.storage,
                layoutManager: discovery.layoutManager,
                pages: discovery.pages,
                sizes: sizes
            )

            let final = layOutPages(
                chapterIndex: chapterIndex,
                text: baseText,
                placements: Self.groupedByPage(explicitPlacements + discoveredPlacements),
                sidebars: sidebarsByPage
            )
            layouts.append(ChapterLayout(textStorage: final.storage, layoutManager: final.layoutManager))
            pages.append(contentsOf: final.pages)
        }
    }

    private struct FloatingPlacement {
        let page: Int
        let contentRect: NSRect
        let image: NSImage
    }

    private struct LayoutPass {
        let storage: NSTextStorage
        let layoutManager: NSLayoutManager
        let pages: [PageLayout]
    }

    private static func displaySize(of attachment: NSTextAttachment) -> NSSize? {
        let boundsSize = attachment.bounds.size
        if boundsSize.width > 0, boundsSize.height > 0 { return boundsSize }
        guard let imageSize = attachment.image?.size, imageSize.width > 0, imageSize.height > 0 else { return nil }
        return imageSize
    }

    private static func groupedByPage(_ placements: [FloatingPlacement]) -> [Int: [FloatingPlacement]] {
        Dictionary(grouping: placements, by: \.page)
    }

    /// Finds attachments the user positioned (they carry a placement
    /// attribute) and converts each to a page + content-relative rect.
    private func floatingPlacementsWithSavedPosition(
        in text: NSAttributedString,
        sizes: [ObjectIdentifier: NSSize]
    ) -> [FloatingPlacement] {
        var placements: [FloatingPlacement] = []
        let fullRange = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.attachment, in: fullRange) { value, range, _ in
            guard let attachment = value as? NSTextAttachment,
                  let position = text.attribute(
                      .inklingFloatingImagePosition,
                      at: range.location,
                      effectiveRange: nil
                  ) as? FloatingImagePosition,
                  let size = sizes[ObjectIdentifier(attachment)],
                  let image = attachment.image
            else { return }

            let contentRect = FloatingImagePlacement.contentRect(
                origin: position.origin,
                imageSize: size,
                leftMargin: leftMargin,
                topMargin: topMargin
            )
            placements.append(FloatingPlacement(page: position.page, contentRect: contentRect, image: image))
        }
        return placements
    }

    /// Collects each floating sidebar's page + content-relative rect and its
    /// (forced-black) text, mirroring how positioned images are gathered.
    private func sidebarPlacements(in text: NSAttributedString) -> [Int: [PlacedSidebar]] {
        var byPage: [Int: [PlacedSidebar]] = [:]
        text.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: text.length)
        ) { value, _, _ in
            guard let sidebar = value as? SidebarAttachment, let position = sidebar.position else { return }
            let contentRect = FloatingImagePlacement.contentRect(
                origin: position.origin,
                imageSize: sidebar.displaySize,
                leftMargin: leftMargin,
                topMargin: topMargin
            )
            let content = NSMutableAttributedString()
            if let decoded = RichTextCodec.decode(sidebar.contentData) {
                content.append(decoded)
                content.addAttribute(.foregroundColor, value: NSColor.black,
                                     range: NSRange(location: 0, length: content.length))
            }
            byPage[position.page, default: []].append(
                PlacedSidebar(contentRect: contentRect, content: content)
            )
        }
        return byPage
    }

    /// Finds attachments *without* a saved position and locates each one's
    /// containing page and its paragraph's first line, mirroring the editor's
    /// auto-float anchor. An image that can't fit in what's left of its
    /// paragraph's page moves to the top of the next page instead of printing
    /// past the page's bottom edge.
    private func discoverUnplacedPlacements(
        in storage: NSTextStorage,
        layoutManager: NSLayoutManager,
        pages: [PageLayout],
        sizes: [ObjectIdentifier: NSSize]
    ) -> [FloatingPlacement] {
        var placements: [FloatingPlacement] = []
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.attachment, in: fullRange) { value, range, _ in
            guard let attachment = value as? NSTextAttachment,
                  !(attachment is SidebarAttachment),
                  storage.attribute(.inklingFloatingImagePosition, at: range.location, effectiveRange: nil) == nil,
                  let size = sizes[ObjectIdentifier(attachment)],
                  let image = attachment.image
            else { return }

            let glyphIndex = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: range.location, length: 1),
                actualCharacterRange: nil
            ).location
            guard let page = pages.firstIndex(where: { NSLocationInRange(glyphIndex, $0.glyphRange) })
            else { return }

            // Float beside the image's own line (matching the editor), so an
            // image referenced mid-paragraph lands beside that text rather than
            // being lifted to the paragraph's top.
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)

            let fits = lineRect.minY + size.height <= pageSize.height
            let placedPage = fits ? page : page + 1
            let y: CGFloat = fits ? lineRect.minY : 0
            let contentRect = NSRect(x: 0, y: y, width: min(size.width, pageSize.width), height: size.height)
            placements.append(FloatingPlacement(page: placedPage, contentRect: contentRect, image: image))
        }
        return placements
    }

    /// Lays out one chapter's pages given every floating image's page number
    /// (known upfront). Builds a fresh storage/layout manager each call so the
    /// discovery pass and the final pass never share layout state.
    private func layOutPages(
        chapterIndex: Int,
        text: NSAttributedString,
        placements: [Int: [FloatingPlacement]],
        sidebars: [Int: [PlacedSidebar]] = [:]
    ) -> LayoutPass {
        let storage = NSTextStorage(attributedString: text)
        // A callout-aware layout manager (pageLayout nil: the print view draws
        // one page per container, so each callout box is naturally page-bounded).
        let layoutManager = CalloutLayoutManager()
        storage.addLayoutManager(layoutManager)

        var exclusions: [Int: [NSBezierPath]] = [:]
        var drawables: [Int: [PlacedImage]] = [:]
        for (page, list) in placements {
            for placement in list {
                if let rect = FloatingImagePlacement.exclusionRect(
                    contentRect: placement.contentRect,
                    contentWidth: pageSize.width,
                    gutter: 8
                ) {
                    exclusions[page, default: []].append(NSBezierPath(rect: rect))
                }
                drawables[page, default: []].append(
                    PlacedImage(contentRect: placement.contentRect, image: placement.image)
                )
            }
        }
        // Sidebars reserve the same kind of exclusion so body text wraps around them.
        for (page, list) in sidebars {
            for sidebar in list {
                if let rect = FloatingImagePlacement.exclusionRect(
                    contentRect: sidebar.contentRect,
                    contentWidth: pageSize.width,
                    gutter: 8
                ) {
                    exclusions[page, default: []].append(NSBezierPath(rect: rect))
                }
            }
        }
        let maxImagePage = max(placements.keys.max() ?? -1, sidebars.keys.max() ?? -1)

        var laidOutPages: [PageLayout] = []
        var laidOutGlyphs = 0
        var pageIndex = 0
        while true {
            let container = NSTextContainer(size: pageSize)
            container.lineFragmentPadding = 0
            container.exclusionPaths = exclusions[pageIndex] ?? []
            layoutManager.addTextContainer(container)
            layoutManager.ensureLayout(for: container)

            let range = layoutManager.glyphRange(for: container)
            laidOutPages.append(PageLayout(
                chapterIndex: chapterIndex,
                textContainer: container,
                glyphRange: range,
                images: drawables[pageIndex] ?? [],
                sidebars: sidebars[pageIndex] ?? []
            ))

            let progressed = NSMaxRange(range) > laidOutGlyphs
            laidOutGlyphs = max(laidOutGlyphs, NSMaxRange(range))
            pageIndex += 1

            let moreText = progressed && laidOutGlyphs < layoutManager.numberOfGlyphs
            let moreImages = pageIndex <= maxImagePage
            if !moreText && !moreImages { break }
        }
        return LayoutPass(storage: storage, layoutManager: layoutManager, pages: laidOutPages)
    }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: pageCount)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(page - 1) * pageSize.height, width: pageSize.width, height: pageSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        if let titlePage {
            let pageRect = NSRect(x: 0, y: 0, width: pageSize.width, height: pageSize.height)
            if pageRect.intersects(dirtyRect) {
                drawTitlePage(titlePage, in: pageRect)
            }
        }

        for (bodyPage, page) in pages.enumerated() {
            let physicalPage = bodyPage + titlePageCount
            let pageRect = NSRect(x: 0, y: CGFloat(physicalPage) * pageSize.height,
                                  width: pageSize.width, height: pageSize.height)
            guard pageRect.intersects(dirtyRect) else { continue }

            let layoutManager = layouts[page.chapterIndex].layoutManager
            let origin = pageRect.origin

            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: pageRect).addClip()
            layoutManager.drawBackground(forGlyphRange: page.glyphRange, at: origin)
            layoutManager.drawGlyphs(forGlyphRange: page.glyphRange, at: origin)
            for placed in page.images {
                placed.image.draw(
                    in: placed.contentRect.offsetBy(dx: origin.x, dy: origin.y),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: true,
                    hints: nil
                )
            }
            for sidebar in page.sidebars {
                drawSidebar(sidebar, at: origin)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Draws the title-page block centered both horizontally (via the string's
    /// centered paragraph style) and vertically (by measuring the block and
    /// insetting it within the page).
    private func drawTitlePage(_ text: NSAttributedString, in pageRect: NSRect) {
        let measured = text.boundingRect(
            with: NSSize(width: pageRect.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let y = pageRect.minY + max(0, (pageRect.height - measured.height) / 2)
        let drawRect = NSRect(x: pageRect.minX, y: y, width: pageRect.width, height: measured.height)
        text.draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    /// Draws one floating sidebar box (fill, header, wrapped text, border) at its
    /// placed rect. Mirrors `SidebarTextView.draw` so screen and paper match.
    private func drawSidebar(_ sidebar: PlacedSidebar, at origin: NSPoint) {
        let box = sidebar.contentRect.offsetBy(dx: origin.x, dy: origin.y)
        let path = NSBezierPath(
            roundedRect: box.insetBy(dx: SidebarStyle.borderWidth / 2, dy: SidebarStyle.borderWidth / 2),
            xRadius: SidebarStyle.cornerRadius,
            yRadius: SidebarStyle.cornerRadius
        )
        SidebarStyle.fillColor.setFill()
        path.fill()

        (SidebarStyle.headerLabel as NSString).draw(
            at: NSPoint(x: box.minX + SidebarStyle.padding, y: box.minY + 5),
            withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 10),
                .foregroundColor: SidebarStyle.accentColor,
            ]
        )

        let textRect = NSRect(
            x: box.minX + SidebarStyle.padding,
            y: box.minY + SidebarStyle.headerHeight + SidebarStyle.padding,
            width: max(0, box.width - SidebarStyle.padding * 2),
            height: max(0, box.height - SidebarStyle.headerHeight - SidebarStyle.padding * 2)
        )
        sidebar.content.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])

        SidebarStyle.accentColor.setStroke()
        path.lineWidth = SidebarStyle.borderWidth
        path.stroke()
    }

    /// Draws the running head and page-number folio into the page margins. The
    /// print system invokes this once per page with the full paper size; we
    /// temporarily resize to that size so margin-band coordinates are valid,
    /// then restore. The current page number comes from the active operation.
    override func drawPageBorder(with borderSize: NSSize) {
        guard let operation = NSPrintOperation.current else { return }
        let page = operation.currentPage
        let info = operation.printInfo

        // The title page carries no running head or folio.
        guard !isTitlePage(page: page) else { return }
        // Body pages are numbered from 1, ignoring the unnumbered title page.
        let folioPage = page - titlePageCount

        let savedFrame = frame
        frame = NSRect(origin: .zero, size: borderSize)
        defer { frame = savedFrame }

        // Resizing to the full page and re-locking focus is the documented way
        // to draw into the margins from drawPageBorder(with:); it resets the
        // graphics origin to the page corner. `lockFocus`/`unlockFocus` are
        // soft-deprecated but have no replacement for this print-time use.
        lockFocus()
        defer { unlockFocus() }

        let left = info.leftMargin
        let contentWidth = borderSize.width - info.leftMargin - info.rightMargin

        let chapterTitle = chapterIndex(forPage: page).map { chapterTitles[$0] } ?? ""
        if let head = ManuscriptRunningHead.headText(
            bookTitle: bookTitle,
            chapterTitle: chapterTitle,
            page: folioPage,
            isChapterStart: isChapterStart(page: page)
        ) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = ManuscriptRunningHead.headAlignment(page: folioPage)
            paragraph.lineBreakMode = .byTruncatingTail
            let rect = NSRect(
                x: left,
                y: info.topMargin / 2 - 6,
                width: contentWidth,
                height: 12
            )
            (head as NSString).draw(in: rect, withAttributes: marginAttributes(paragraph))
        }

        let folioParagraph = NSMutableParagraphStyle()
        folioParagraph.alignment = .center
        let folioRect = NSRect(
            x: left,
            y: borderSize.height - info.bottomMargin / 2 - 6,
            width: contentWidth,
            height: 12
        )
        (ManuscriptRunningHead.folioText(page: folioPage) as NSString)
            .draw(in: folioRect, withAttributes: marginAttributes(folioParagraph))
    }

    private func marginAttributes(_ paragraph: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph
        ]
    }
}
