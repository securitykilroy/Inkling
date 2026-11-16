# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Inkling is a native macOS app for writing and organizing multi-chapter projects (novels, manuscripts). One `.inkling` document = one project = one Core Data store. The architecture is **MVVM with a 100% SwiftUI UI hosted inside an AppKit document app**.

## Build / Test / Run

Build with the current release of Xcode (`/Applications/Xcode.app`, Xcode 27 or later). The project is saved in Xcode 27's project format (`objectVersion = 110`), so older Xcodes can't open it. A plain `xcodebuild` works; no `DEVELOPER_DIR` override is needed.

Headless build:
```sh
xcodebuild -project Inkling.xcodeproj -scheme Inkling \
  -destination 'platform=macOS' -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

Run tests (the project uses the **Swift Testing** framework — `@Test`/`#expect`, not XCTest):
```sh
xcodebuild -project Inkling.xcodeproj -scheme Inkling \
  -destination 'platform=macOS' -configuration Debug clean test -only-testing:InklingTests
```

### Two ways a test run lies about having run

Both end in `** TEST SUCCEEDED **` while testing nothing, so neither is visible unless you look for it.

**Always use `clean test`, not bare `test`, when adding or changing tests.** Incremental `xcodebuild ... test` frequently reuses a *stale* compiled test bundle: new `@Test` methods silently don't run and edits to existing tests have no effect, while the run still reports success.

**Don't narrow `-only-testing:` to a single Swift Testing function.** `-only-testing:InklingTests/SomeSuite/someTest` matches nothing and runs nothing — silently. Narrow to the *suite* (`-only-testing:InklingTests/PageStackViewTests`) or run the whole bundle.

The same sanity check catches both: count the `Test case ... passed` lines and compare against the number of `@Test` functions you expected to run.

```sh
xcodebuild ... clean test -only-testing:InklingTests 2>&1 | tee /tmp/test.log | grep -E "Failing tests|TEST (SUCCEEDED|FAILED)"
grep -c "Test case .* passed" /tmp/test.log   # expect ~= total @Test count
```

A full run *sometimes* drops one test (a long-standing headless flake, a different test each time — observed as both 263 and 264 of 264 across consecutive runs), so a count one short of the total is normal. A count of zero, or one far short, means one of the two traps above.

Swift Testing's `#expect` and `Issue.record` messages do **not** reach `xcodebuild`'s stdout. Read them from the result bundle:
```sh
R=$(ls -td ~/Library/Developer/Xcode/DerivedData/Inkling-*/Logs/Test/*.xcresult | head -1)
xcrun xcresulttool get test-results tests --path "$R" | grep '"name" : "Expectation failed'
```

The Xcode project uses **synchronized folder groups**, so new files added anywhere under `Inkling/` are picked up automatically — you do not need to edit `project.pbxproj`.

## Architecture — the non-obvious parts

These decisions exist for specific reasons. Read the reason before "fixing" them.

- **AppKit lifecycle, not SwiftUI `DocumentGroup`.** `main.swift` is an explicit programmatic entry point that installs the `AppDelegate` and a hand-built menu (`MainMenu.swift`) before the run loop starts. Reason: `DocumentGroup` cannot host an `NSPersistentDocument`. The UI is still entirely SwiftUI — `InklingDocument.makeWindowControllers()` hosts `ProjectRootView` via `NSHostingController` and injects the managed object context.

- **No storyboard/xib, so the menu bar is built in code** (`MainMenu.swift`). Menu items use `nil` targets and route through the responder chain. The File menu deliberately omits Open Recent / Revert To / Rename / Move To — macOS auto-adds those for a document app, and adding them manually produces duplicates.

- **`InklingDocument` overrides `managedObjectModel` to return one shared `NSManagedObjectModel`.** Without this, opening a second document builds a second model; both claim the same `@objc` entity subclasses, `+[Project entity]` can no longer disambiguate, and object creation/fetch traps (`EXC_BREAKPOINT`).

- **Projects are single-file SQLite stores; older projects are XML** (`CoreData/ProjectFileFormat.swift`). The XML store was read whole on open and rewritten whole on every save, images base64'd inside it. `InklingDocument` sniffs the file header and opens a legacy XML file as XML, then converts it on its next plain Save (`convertLegacyStore`): the XML is copied aside and Core Data creates the SQLite file *at its final path*. Never build a SQLite file elsewhere and move it into place while it's open; SQLite logs "vnode renamed while in use" and drops its file handles. Every SQLite store is opened with `journal_mode=DELETE`, so no `-wal`/`-shm` files sit beside the project. **Sandbox:** an in-place save creates `<project>-journal` beside the file, which the sandbox denies (SQLite error 21, "could not be saved") unless *both* the `inkling-journal` related item type is declared in `Info.plist` (`NSIsRelatedItemType`) *and* a file presenter for the journal names the project as its primary item (`CoreData/SQLiteJournalAccess.swift`, registered from `fileURL`). The declaration alone was verified not to be enough. Unit tests run inside the app's own container, so they can't catch a regression here; check a real save of a file in `~/Documents`. Crash-recovery copies are still XML.

- **Explicit save semantics:** `autosavesInPlace` is `false`. Editing an existing project prompts to save on window close / quit. New untitled documents seed their root `Project` with undo registration disabled so a pristine, untouched window doesn't nag to save or write a stray "Untitled" file.

- **Crash recovery is a separate copy, never an autosave of the real file** (`CoreData/CrashRecovery.swift`). While a document has unsaved changes, `DocumentRecovery` writes a full copy every 30s to `Application Support/Inkling/Recovery/` (inside the sandbox container — an unsigned `CODE_SIGNING_ALLOWED=NO` build is *unsandboxed* and uses `~/Library/Application Support/Inkling/Recovery/` instead). Save, Revert, and Close (including "Don't Save") delete it; a copy that survives to launch is offered back by `AppDelegate` as an **untitled** document, so it can never overwrite the original. The launch prompt is skipped under XCTest — a modal there hangs the test runner.

- **SwiftUI bindings into Core Data go through `assignIfChanged`** (`Models/ManagedObjectEditing.swift`). A `TextField` writes its unchanged text back during layout, and Core Data counts even a same-value assignment as an edit — that made merely opening a project dirty it.

- **Rich-text blobs are never on Core Data's undo stack, and Undo can't change one** (`Models/ManagedObjectEditing.swift`, `CoreData/RichTextUndoGuard.swift`). Core Data undoes an edit by restoring the *whole object* as it was then, so with typing kept off its stack, undoing an earlier rename or reorder put back the body from that moment. The guard notes every blob before an undo/redo and puts it back after. Consequence: anything that writes a blob must use `assignRichTextIfChanged` (Replace All and font changes included) and cannot be undone through Core Data — a registered blob write would become an Undo step that silently does nothing. An operation that should be undoable (Replace All) goes through `applyRichTextChanges`, which registers its own action, tells the guard which values it means to change, and only touches a blob that still holds the value it expects.

- **Sidecar records are keyed by character offset, so saved text must round-trip exactly** (`RichTextCodec`, "Keeping sidecar offsets true"). RTF merges `\r\n` and drops NUL, U+FFFD and an attachment-less U+FFFC; one of those ahead of an image shifted every later record, losing image geometry and captions and, a save later, sidebar text. `encode` strips them first (`storable`); `decode` re-matches records to attachments when offsets miss (`realign`) and never drops a sidebar record. If you find another character RTF doesn't preserve, add it to `storable`.

- **Opening a chapter must not rewrite its text.** Anything that loads stored text calls `prepareFloatingImages(joiningImageOnlyLines: false)`. Joining an image-only line to the paragraph before it (`Models/ImageOnlyLine.swift`) is for images arriving in an edit or an import only, changes one newline, and never joins to a heading.

- **Lightweight migration is on** (`configurePersistentStoreCoordinator`), so files written by older model versions still open. The model is versioned (`Inkling.xcdatamodeld`); the current version is **Inkling 6** (2 added `Project.author`, 3 `Project.subtitle`, 4 `Project.bodyFontFamily`, 5 the `ShelfEntry` entity, 6 `Project.projectNotesData`). Schema changes must stay additive/optional so Core Data can infer the mapping — otherwise add a new model version, don't edit the current one in place.

- **Entity is named `Chapter`, not `Section`** — `Section` collides with `SwiftUI.Section`.

- **ViewModels never call `context.save()` directly.** Mutating the context dirties the document, and `NSPersistentDocument` drives saving. Insert/delete objects and let the document handle persistence.

## Data model

Three Core Data entities (`Inkling.xcdatamodeld`):
- **`Project`** — `id`, `title`, `subtitle`, `author`, `createdAt`, `bodyFontFamily`, `projectNotesData`, and cascade-delete to-many `chapters` and `shelfEntries`.
- **`Chapter`** — `id`, `title`, `sortIndex` (ordering), `createdAt`, `bodyData`, `notesData`.
- **`ShelfEntry`** — `id`, `sortIndex`, `createdAt`, `bodyData` (one scrap on the project-wide Shelf).

Rich text (chapter body + per-chapter notes) is stored as binary in `bodyData` / `notesData`. `RichTextCodec` is the single format boundary: it writes **RTFD** (so inline image attachments survive) with an **RTF fallback** so older files stay readable, and side-stores attachment sizes, floating-image positions, and image captions in embedded JSON (`__inkling_attachment_sizes.json`). On decode, position and caption ride as in-memory attributes (`.inklingFloatingImagePosition`, `.inklingImageCaption`) until the editor or printer builds a `FloatingImageAttachment`.

## Layout

- `main.swift`, `AppDelegate.swift`, `MainMenu.swift`, `InklingDocumentController.swift` — AppKit app/document plumbing.
- `CoreData/InklingDocument.swift` — the `NSPersistentDocument` subclass; also owns Print and "Export as Plain Text" actions.
- `Models/` — Core Data subclasses (`Project+CoreData`, `Chapter+CoreData`), `RichTextCodec`, `TextStatistics`, `ProjectMetadata`, image-attachment models.
- `ViewModels/` — `ProjectViewModel` (chapter list/document state), `StatisticsViewModel`, `RichTextController` (the editor's text engine), `OutlineNavigator`.
- `Views/` — SwiftUI: `ProjectRootView` (NavigationSplitView root), `ChapterSidebar`, `ChapterDetailView`, `RichTextEditor` (the NSTextView bridge, which hosts `PageStackView` for a chapter body and a plain text view for notes/shelf), `PageStackView` (the per-page editor: one NSTextView per page over one shared text storage), `PagedEditorLayout` (page geometry + the magnifying canvas), `NotesPanel`, `FormatToolbar`, settings.
- `Printing/ManuscriptPrinter.swift`, `Export/PlainTextExporter.swift` — output paths.

## Experimental: the Outline feature

The sidebar outline (expandable heading rows under each chapter) is **experimental and deliberately isolated for easy removal** — the user wanted to trial it. It is `Models/ChapterOutline.swift` (parses headings from a chapter's RTF: a paragraph is a heading if its font is **bold and ≥17pt**, matching the Style menu's Title/Heading/Subheading) plus `ViewModels/OutlineNavigator.swift` (shared jump target) and `RichTextController.scroll(to:)`. To remove: delete those two files, revert the sidebar to a flat chapter list, and drop the navigator plumbing. Don't deepen coupling to it without checking with the user.
