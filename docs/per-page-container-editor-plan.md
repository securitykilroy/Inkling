# Per-Page-Container Editor Rearchitecture

*Status: **done.** Planned and built 2026-07-19; made the default editor the same day; the old editor (`PagedTextView`) was deleted on 2026-09-17 (`b43c9f7`). This is now a record of why the editor is built the way it is, not a to-do list.*

## Why it was done

The original paged editor (`PagedTextView`) laid a whole chapter into **one** infinitely tall `NSTextContainer` and *faked* page breaks with a layout delegate that nudged each line's Y onto its page. Floating-image exclusion paths therefore had to be expressed in a pre-pagination ("proposed") coordinate space and translated back, and that translation was fragile.

It produced two real failures, both on a manuscript chapter with an image floating at the **first line of a later page**:

1. **Text vanished** — TextKit collapsed everything after the image into one degenerate zero-height line.
2. **Text rode under the image** instead of wrapping around it.

A safety net shipped first so text was never lost (it shed exclusions until layout completed). The real fix came from noticing that the printer (`ManuscriptPrintView.layOutPages`) never had these bugs because it uses **one container per page**. The goal was to make the editor work like the printer.

## What was built

One shared `NSTextStorage` → one shared `CalloutLayoutManager` → **one `NSTextContainer` per page** → one small `PageTextView` (an `NSTextView`) per page, stacked in a `PageStackView` inside the magnifying `PagedEditorScrollView`.

```
documentView: PageStackView (plain NSView, isFlipped)
 ├─ PageTextView 0  (frame = page 0 rect)  → NSTextContainer 0
 ├─ PageTextView 1  (frame = page 1 rect)  → NSTextContainer 1
 └─ …                                       (all in ONE shared layout manager)
```

- **Pagination is real.** TextKit flows text from container to container. When the last container has unlaid glyphs, a page is added; empty trailing pages are trimmed. Repagination is deferred to the next run-loop turn because adding/removing containers mid-edit re-enters TextKit.
- **Floating images and sidebars use page-local exclusions** (0…page height). A first-line image is just an exclusion at y≈0 — no special case, no coordinate translation.
- **Callouts** draw per container, so each page bounds its own callout boxes.
- Code: `Views/PageStackView.swift` (`PageStackView` + `PageTextView`). Page geometry stays in `Views/PagedEditorLayout.swift`.

## What turned out easier or harder than planned

- **Selection across pages came free.** The plan budgeted most of the effort for selection, caret movement, and first-responder handoff across N text views sharing one layout manager. TextKit 1 handles all of it natively, including cross-page mouse-drag selection. (`characterIndexForInsertion(at:)` clamps to a single page's container, which *looks* like proof drag selection can't cross pages — it isn't, because the mouse-tracking loop never uses it.)
- **Find needed real work.** `NSTextView` is a single-view `NSTextFinderClient`, so `PageTextView` overrides `contentView(at:)`, `rects(forCharacterRange:)`, `drawCharacters(in:forContentView:)`, `visibleCharacterRanges`, and `scrollRangeToVisible` (which otherwise ignores the page's 72pt inset and lands the match just below the fold).

## Leftovers

- `PagedEditorLayout` still contains `exclusionRect(forImageRect:)`, `proposedY(forLaidOutY:)`, and `lineOriginY(proposedY:lineHeight:)`. They served only the deleted single-container editor; nothing in the app calls them, only their own tests in `InklingTests.swift`. They can be deleted along with those tests.
- Editor/printer layout code is not shared; the two are kept in agreement by tests rather than by one implementation.

## Alternative considered — TextKit 2

`NSTextLayoutManager` could paginate via viewport fragments, but it was a different, larger migration and shared nothing with the TextKit 1 printer. Multi-container TextKit 1 mirrored what already worked in this codebase, and the selection gate it depended on passed immediately.
