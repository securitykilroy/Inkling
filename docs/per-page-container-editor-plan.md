# Plan: Per-Page-Container Editor Rearchitecture

*Status: proposed, not started. Written 2026-07-19. This document is self-contained so a fresh session can pick it up.*

## 1. Why

The paged editor lays an entire chapter's text into **one** `NSTextContainer` (infinitely tall) and *fakes* page breaks with a pagination delegate that nudges each line's Y. Floating-image exclusion paths are therefore evaluated in a **pre-paginated ("proposed") coordinate space** and must be translated back to the laid-out space. That translation (`PagedEditorLayout.exclusionRect(forImageRect:)` + `proposedY` + the `layoutManager(_:shouldSetLineFragmentRect:...)` delegate) is fundamentally fragile.

It has produced two real, reported failures — both on Chapter 1 of "The Invisible Child", triggered by an image that floats at a **page's first line on a later page** (e.g. an image bumped to the top of the next page because it didn't fit at the bottom of the previous one):

1. **Text vanished** — TextKit collapsed everything after the image into "one degenerate zero-height line."
2. **Text rides under the image** — after the vanishing was patched, text overlaps the image instead of wrapping.

Both are the *same* fragile case. Dragging the image off the page-top fixes the wrap, because a positioned (absolute) image uses a normal exclusion and bypasses the translation. **It is positional, not about the image.**

A **stopgap safety net** already shipped (see §7) so text is never lost. This plan is the real fix.

**The tell:** the printer (`ManuscriptPrintView.layOutPages`) has none of these bugs because it uses **one container per page**. The editor is the only place using single-container-plus-hacks. The goal is to make the editor work like the printer.

## 2. Current architecture (what exists today)

- **`Views/PagedTextView.swift`** — `PagedTextView: NSTextView`, the whole editable surface.
  - `makePagedScrollView()` builds: 1 `NSTextStorage` → 1 `CalloutLayoutManager` → **1 `NSTextContainer`** (width = content width, height = `.greatestFiniteMagnitude`) → the `PagedTextView`.
  - `layoutManager(_:shouldSetLineFragmentRect:...)` + `PagedEditorLayout.lineOriginY(...)` shift each line onto its page (the fake pagination).
  - `rebuildFloatingImageLayout()` computes every floating image's rect + exclusion path and sets `textContainer.exclusionPaths`. Contains the **safety-net shed loop** (`applyExclusions`, `isTailLayoutCollapsed`).
  - Hosts floating images (drawn in `drawFloatingImages`) and **sidebar child views** (`SidebarTextView` subviews; see `syncSidebarViews`, `layoutSidebars`).
  - Draws page paper/shadows in `drawBackground(in:)`.
  - Typewriter scrolling hooks `setSelectedRanges(...)`.
  - Image drag (`mouseDown/Dragged/Up`, `ImageMoveSession`), autoscroll timer, select-jump suppression (`isSelectingFloatingImage`).
- **`Views/PagedTextView.swift` → `PagedEditorLayout`** — pure page geometry: `paperSize`, margins, `pageStride`, `contentTop/contentBottom(forPage:)`, `pageIndex(atY:)`, and the fragile `exclusionRect(forImageRect:)`, `proposedY(forLaidOutY:)`, `lineOriginY(...)`, `displayRect(forPage:origin:size:)`, `position(forDisplayOrigin:size:)`.
- **`ViewModels/CalloutLayoutManager.swift`** — `NSLayoutManager` subclass; draws callout boxes in `drawBackground(forGlyphRange:at:)`. Has a `pageLayout` for editor page-grouping (nil in the printer).
- **`Printing/ManuscriptPrinter.swift` → `ManuscriptPrintView.layOutPages(...)`** — **the reference implementation**: a bare `NSView` + one `NSLayoutManager` + **one `NSTextContainer` per page**, exclusions per-page-local. No editing, just drawing. This is the model to mirror.
- **`Views/RichTextEditor.swift`** — `NSViewRepresentable` wrapping the scroll view; `Coordinator` handles `load` / `textDidChange` (encode → `chapter.bodyData`) / `textViewDidChangeSelection`. `presentation: .paged` is used by `ChapterDetailView`.
- **`Models/FloatingImageAttachment.swift`**, **`Models/SidebarBox.swift` (`SidebarAttachment`)**, **`Views/SidebarTextView.swift`**, **`Models/Callout.swift` (`CalloutStyling`)**, **`Models/RichTextCodec.swift`** (RTFD + JSON sidecars for image sizes/positions, callouts, sidebars).

## 3. Target architecture

One storage → one layout manager → **N containers (one per page's text area)** → **N small page text views** stacked vertically in a scrolling document view. TextKit flows text container→container natively (no delegate). Each container's exclusions are **local to its page (0…pageHeight)**.

```
documentView: PageStackView (plain NSView, isFlipped)
 ├─ PageTextView 0  (frame = page 0 rect)  → NSTextContainer 0  (contentW × contentH)
 ├─ PageTextView 1  (frame = page 1 rect)  → NSTextContainer 1
 └─ …                                       (all containers in ONE shared NSLayoutManager)
shared: NSTextStorage + CalloutLayoutManager
```

### Components to build
- **`PageStackView: NSView`** (new documentView): owns `[PageTextView]`; adds/removes page views as page count changes; positions each at its page rect (with `pageGap`); draws paper/shadows (moves `drawBackground(in:)` here). Horizontal centering + magnification stay on the enclosing `PagedEditorScrollView`.
- **`PageTextView: NSTextView`** (new, one per page): initialized with page N's `NSTextContainer` (fixed `contentWidth × contentHeight`, `lineFragmentPadding = 0`). Responsibilities per page, all in **local coordinates**:
  - Its own `textContainer.exclusionPaths` for floating images/sidebars anchored on this page.
  - Draw its floating images; host `SidebarTextView` subviews whose anchor falls on this page.
  - Image drag / hit-testing within the page (cross-page drag handled by the stack; see §6).
- **Shared `CalloutLayoutManager` + `NSTextStorage`**, referenced by all page views' containers. Callout drawing stays in the layout manager but simplifies: `pageLayout` grouping can go away because each container is already one page.
- **`PageLayoutController`** (new, or folded into `PageStackView`): observes layout; when the last container has unlaid glyphs, append a container + `PageTextView`; when trailing pages are empty, trim. Reuses `PagedEditorLayout` geometry (paper size, margins, gap) — most of that struct survives; the fragile methods (`exclusionRect`, `proposedY`, `lineOriginY`) are deleted.

## 4. How each concern works in the new model

- **Pagination:** natural. The layout manager stops filling a container at its height and continues in the next. A "need another page" signal = `glyphRange(for: lastContainer)` didn't reach `numberOfGlyphs` → add a container+view and re-ask.
- **Floating images (the win):** an image on page 3 → exclusion added to **container 3** in coords 0…contentHeight. No translation. A first-line image is just an exclusion at y≈0 — no special case. Anchor-relative "float from the image's own line" (already shipped in slice 1) computes the line rect within the page container directly.
- **Callouts:** unchanged conceptually; `CalloutLayoutManager.drawBackground` runs per container, so each page draws its own callout boxes bounded to that page automatically (drop the manual page-grouping).
- **Sidebars:** each `SidebarTextView` is hosted by the `PageTextView` whose container holds its anchor; exclusion is that page's local rect. A sidebar taller than the remaining page space is clamped/split (decide: clamp to page, or allow overflow into next page's exclusion — see §6 open questions).
- **Print parity:** the printer already does this; extract the per-page container-building into shared code used by both editor and printer so they can't drift.

## 5. What gets deleted / simplified

- `PagedEditorLayout.exclusionRect(forImageRect:)`, `proposedY(forLaidOutY:)`, `lineOriginY(...)`.
- `PagedTextView.layoutManager(_:shouldSetLineFragmentRect:...)` and `pageHasImageAnchoredToItsFirstLine`.
- The **vanishing safety-net** (`isTailLayoutCollapsed` + the `applyExclusions` shed loop) — no longer needed once the fragility is gone.
- The single giant `PagedTextView` splits into `PageStackView` + `PageTextView`.

## 6. The hard parts (where the risk/effort is)

The reason the single-view hack exists in the first place. Budget most of the effort here:

1. **Selection / caret / arrow keys across page boundaries.** N `NSTextView`s share one layout manager; `NSTextView` likes to own its manager. Need one logical insertion point, caret moving off the bottom of page P onto page P+1, shift-selection spanning pages, click-drag selection across pages. **This is the crux.** Prototype it first (§8, milestone 0) before committing.
2. **First-responder handoff** between page views; keeping the "active" page in sync for the toolbar/formatting (`RichTextController.textView` currently points at one view — likely becomes "the focused page view" or a facade).
3. **Find bar** (currently `usesFindBar` on the single view's scroll view) and **spell-check** continuity across views.
4. **Typewriter scrolling** across the stack (the caret's page + offset → scroll position on the documentView).
5. **Image / sidebar drag across pages** — drag now crosses page-view boundaries; the drag session likely lives on the `PageStackView`, converting coordinates to the target page.
6. **Cross-page objects** — an image or sidebar whose box would straddle a page break.
7. **Performance** — many page views; only realize/draw visible ones (view reuse if needed; likely fine for book-length chapters).

## 7. The shipped stopgap (context, keep until this lands)

`PagedTextView.rebuildFloatingImageLayout` runs a safety net after layout: `isTailLayoutCollapsed(_:)` detects the degenerate zero-height final line; if collapsed, it sheds image exclusion paths nearest the collapse (`applyExclusions` re-layout loop) until all text lays out. Guarantees no text loss; the offending image overlaps text rather than wrapping. **Delete this once per-page containers remove the underlying fragility.**

## 8. Rollout (incremental, reversible)

Build alongside the current editor behind a flag; reach parity item by item; then flip default and delete the hacks.

- **Milestone 0 — de-risk selection.** Minimal `PageStackView` + 2–3 `PageTextView`s sharing one layout manager/storage; prove typing, caret, and selection cross page boundaries acceptably. **Go/no-go gate** — if selection is unworkable, reconsider (TextKit 2, §9).
- **Milestone 1 — pagination + text.** Dynamic page add/remove; scrolling; magnification; page paper/shadows; matches current text-only behavior.
- **Milestone 2 — floating images.** Per-page exclusions; anchor-relative placement; drag (incl. cross-page); verify **Chapter 1 of The Invisible Child** wraps cleanly with a top-of-page image (the original failure).
- **Milestone 3 — sidebars + callouts.** Per-page hosting/drawing; drag/resize; exports unaffected.
- **Milestone 4 — parity polish.** Find bar, typewriter scrolling, spell-check, undo, page-count footer, reopen-last-position, print agreement.
- **Milestone 5 — cut over.** Flip the flag; delete `exclusionRect`/`proposedY`/`lineOriginY`/the delegate/the safety net; share per-page layout code with the printer.

Verify against the real content each milestone (the sandbox blocks tests from reading `~/Documents`; extract a chapter's `bodydata` from the Core Data XML store and, if bundling as a test fixture, **stub the image pixels to 1×1 and scrub the prose** — do not commit the user's manuscript; see [[direct-file-editing-technique]]).

## 9. Alternative considered — TextKit 2

`NSTextLayoutManager` paginates via viewport text fragments and could be cleaner long-term. Rejected as the primary path because it's a *different, larger* migration and shares less with the existing **TextKit-1** printer. Multi-container TextKit 1 mirrors what already works in this codebase and is a proven Apple pattern (old TextEdit "wrap to page"). Revisit only if Milestone 0 shows selection-across-views is unworkable.

## 10. Related memory / references

- Memory: `floating-image-top-of-page-fragility` (the diagnosis this plan fixes), `floating-image-placement`, `page-count-sources`, `direct-file-editing-technique`, `xcodebuild-stale-test-bundle`.
- Reference impl to mirror: `ManuscriptPrintView.layOutPages` in `Printing/ManuscriptPrinter.swift`.
- Build/test: Xcode-beta 27 only; always `clean test` (see CLAUDE.md).
