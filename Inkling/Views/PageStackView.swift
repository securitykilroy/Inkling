//
//  PageStackView.swift
//  Inkling
//
//  MILESTONE 0 PROTOTYPE — the go/no-go gate for the per-page-container editor
//  rearchitecture (docs/per-page-container-editor-plan.md).
//
//  The shipping editor (`PagedTextView`) lays a whole chapter into ONE infinitely
//  tall text container and fakes page breaks with a layout delegate that nudges
//  each line's Y. That forces floating-image exclusion paths to be expressed in a
//  pre-pagination coordinate space, which is the root of the top-of-page image
//  bugs. The printer has none of those bugs because it uses one container per
//  page (`ManuscriptPrintView.layOutPages`).
//
//  This file mirrors the printer's structure for an *editable* surface: one
//  shared NSTextStorage + one shared layout manager feeding N containers, each
//  backed by its own small NSTextView. TextKit flows text container→container
//  natively, so pagination is real and every exclusion path is page-local.
//
//  Scope is deliberately text-only: no floating images, sidebars, callout
//  chrome, paper shadows, or typewriter scrolling. The single question this
//  prototype exists to answer is whether typing, the caret, and selection behave
//  acceptably across page boundaries when N NSTextViews share one layout
//  manager. Nothing here is wired into the shipping editor.
//

import AppKit

extension PagedEditorLayout {
    /// Height of one page's text area — the container height in the per-page
    /// model. (The single-container editor never needed this: its one container
    /// is infinitely tall.)
    var contentHeight: CGFloat {
        paperSize.height - topMargin - bottomMargin
    }

    /// The paper rect for `page`, in page-stack coordinates (y grows downward).
    func paperRect(forPage page: Int) -> NSRect {
        NSRect(
            x: 0,
            y: CGFloat(page) * pageStride,
            width: paperSize.width,
            height: paperSize.height
        )
    }
}

/// One page's editable text area. Fixed size: it never grows to fit text —
/// overflow is TextKit's cue to continue into the next page's container.
final class PageTextView: NSTextView {

    /// This view's index in the stack. Maintained by `PageStackView`.
    var pageIndex: Int = 0

    convenience init(pageIndex: Int, container: NSTextContainer, layout: PagedEditorLayout) {
        self.init(frame: layout.paperRect(forPage: pageIndex), textContainer: container)
        self.pageIndex = pageIndex

        // The view is a whole sheet of paper; the container is just the text
        // area, so the margins live in the inset. This is what makes container
        // coordinates page-local — an exclusion path for an image on this page
        // is expressed in 0…contentHeight, with no translation.
        textContainerInset = NSSize(width: layout.leftMargin, height: layout.topMargin)

        // Fixed-size, both axes. NSTextView's default is to grow to fit its
        // text; here the container's fixed height must be the binding
        // constraint, or text would never overflow to the next page.
        isHorizontallyResizable = false
        isVerticallyResizable = false
        autoresizingMask = []

        isEditable = true
        isSelectable = true
        isRichText = true
        allowsUndo = true

        drawsBackground = true
        backgroundColor = .white
        // Pages are paper: keep them light regardless of system appearance,
        // matching the shipping editor.
        appearance = NSAppearance(named: .aqua)
    }
}

/// The scrolling document view: a vertical stack of fixed-size page views, all
/// sharing one text storage and one layout manager.
final class PageStackView: NSView {

    let pageLayout: PagedEditorLayout
    let storage: NSTextStorage
    let sharedLayoutManager: CalloutLayoutManager

    private(set) var pageViews: [PageTextView] = []

    /// Guards against `rebuildPages` re-entering itself by way of the layout it
    /// triggers.
    private var isRebuilding = false

    override var isFlipped: Bool { true }

    init(pageLayout: PagedEditorLayout = .letter) {
        self.pageLayout = pageLayout
        self.storage = NSTextStorage()
        self.sharedLayoutManager = CalloutLayoutManager()
        // nil: each container is already exactly one page, so callout boxes are
        // page-bounded for free — the same reason the printer leaves it nil.
        self.sharedLayoutManager.pageLayout = nil
        super.init(frame: NSRect(origin: .zero, size: pageLayout.paperSize))

        storage.addLayoutManager(sharedLayoutManager)
        appendPage()
        resizeToFitPages()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var pageCount: Int { pageViews.count }

    /// Replaces the whole document and repaginates.
    func setAttributedString(_ text: NSAttributedString) {
        storage.setAttributedString(text)
        rebuildPages()
    }

    // MARK: - Pagination

    /// Grows or shrinks the page stack until it exactly holds the text, then
    /// resizes to match. Mirrors `ManuscriptPrintView.layOutPages`: add a
    /// container, ask the layout manager to fill it, repeat while glyphs remain.
    func rebuildPages() {
        guard !isRebuilding else { return }
        isRebuilding = true
        defer { isRebuilding = false }

        // Grow. `progressed` guards against a container that accepts no glyphs
        // at all (e.g. a line taller than the page), which would otherwise spin
        // forever adding pages.
        var guardCounter = 0
        while guardCounter < Self.maxPages {
            guardCounter += 1
            guard let last = pageViews.last?.textContainer else { break }
            sharedLayoutManager.ensureLayout(for: last)
            let laidOut = NSMaxRange(sharedLayoutManager.glyphRange(for: last))
            guard laidOut < sharedLayoutManager.numberOfGlyphs else { break }

            let before = pageViews.count
            appendPage()
            guard pageViews.count > before else { break }

            // If the newly added page accepted nothing, stop rather than loop.
            guard let added = pageViews.last?.textContainer else { break }
            sharedLayoutManager.ensureLayout(for: added)
            if sharedLayoutManager.glyphRange(for: added).length == 0 { break }
        }

        // Trim trailing pages that hold no glyphs, always keeping page 1.
        while pageViews.count > 1, let last = pageViews.last?.textContainer,
              sharedLayoutManager.glyphRange(for: last).length == 0 {
            removeLastPage()
        }

        resizeToFitPages()
    }

    /// Upper bound on pages, so a pathological layout can't hang the app.
    private static let maxPages = 5_000

    private func appendPage() {
        let index = pageViews.count
        let container = NSTextContainer(size: NSSize(
            width: pageLayout.contentWidth,
            height: pageLayout.contentHeight
        ))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        sharedLayoutManager.addTextContainer(container)

        let view = PageTextView(pageIndex: index, container: container, layout: pageLayout)
        view.frame = pageLayout.paperRect(forPage: index)
        addSubview(view)
        pageViews.append(view)
    }

    private func removeLastPage() {
        guard let view = pageViews.popLast() else { return }
        view.removeFromSuperview()
        let containerIndex = sharedLayoutManager.textContainers.count - 1
        if containerIndex >= 0 {
            sharedLayoutManager.removeTextContainer(at: containerIndex)
        }
    }

    private func resizeToFitPages() {
        let height = pageLayout.documentHeight(forPageCount: max(1, pageViews.count))
        let size = NSSize(width: pageLayout.paperSize.width, height: height)
        if abs(frame.width - size.width) > 0.5 || abs(frame.height - size.height) > 0.5 {
            setFrameSize(size)
        }
        for (index, view) in pageViews.enumerated() {
            view.pageIndex = index
            let rect = pageLayout.paperRect(forPage: index)
            if view.frame != rect { view.frame = rect }
        }
    }

    // MARK: - Selection helpers

    /// The page view that currently holds the insertion point / start of the
    /// selection, according to the shared layout manager.
    var focusedPageView: PageTextView? {
        sharedLayoutManager.textViewForBeginningOfSelection as? PageTextView
    }

    /// The page view whose container holds `characterIndex`.
    func pageView(forCharacterIndex characterIndex: Int) -> PageTextView? {
        guard sharedLayoutManager.numberOfGlyphs > 0 else { return pageViews.first }
        let clamped = min(max(0, characterIndex), max(0, storage.length - 1))
        let glyph = sharedLayoutManager.glyphIndexForCharacter(at: clamped)
        guard let container = sharedLayoutManager.textContainer(
            forGlyphAt: glyph, effectiveRange: nil
        ) else { return nil }
        return pageViews.first { $0.textContainer === container }
    }
}
