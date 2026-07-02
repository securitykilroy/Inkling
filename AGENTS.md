# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## What this is

Inkling is a native macOS app for writing and organizing multi-chapter projects (novels, manuscripts). One `.inkling` document = one project = one Core Data store. The architecture is **MVVM with a 100% SwiftUI UI hosted inside an AppKit document app**.

## Build / Test / Run

The project is saved in Xcode 27's project format (`objectVersion = 110`), so it **must** be built with **Xcode-beta** (`/Applications/Xcode-beta.app`), not the stable Xcode that the default `xcodebuild` resolves to. Always prefix `xcodebuild` with `DEVELOPER_DIR`.

Headless build:
```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project Inkling.xcodeproj -scheme Inkling \
  -destination 'platform=macOS' -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

Run tests (the project uses the **Swift Testing** framework — `@Test`/`#expect`, not XCTest):
```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project Inkling.xcodeproj -scheme Inkling \
  -destination 'platform=macOS' -configuration Debug clean test -only-testing:InklingTests
```

**Always use `clean test`, not bare `test`, when adding or changing tests.** Incremental `xcodebuild ... test` frequently reuses a *stale* compiled test bundle: new `@Test` methods silently don't run and edits to existing tests have no effect, while the run still reports success. Sanity check: a deliberately-broken assertion should fail, and the count of `Test case ... passed` lines should match the number of `@Test` functions.

The Xcode project uses **synchronized folder groups**, so new files added anywhere under `Inkling/` are picked up automatically — you do not need to edit `project.pbxproj`.

## Architecture — the non-obvious parts

These decisions exist for specific reasons. Read the reason before "fixing" them.

- **AppKit lifecycle, not SwiftUI `DocumentGroup`.** `main.swift` is an explicit programmatic entry point that installs the `AppDelegate` and a hand-built menu (`MainMenu.swift`) before the run loop starts. Reason: `DocumentGroup` cannot host an `NSPersistentDocument`. The UI is still entirely SwiftUI — `InklingDocument.makeWindowControllers()` hosts `ProjectRootView` via `NSHostingController` and injects the managed object context.

- **No storyboard/xib, so the menu bar is built in code** (`MainMenu.swift`). Menu items use `nil` targets and route through the responder chain. The File menu deliberately omits Open Recent / Revert To / Rename / Move To — macOS auto-adds those for a document app, and adding them manually produces duplicates.

- **`InklingDocument` overrides `managedObjectModel` to return one shared `NSManagedObjectModel`.** Without this, opening a second document builds a second model; both claim the same `@objc` entity subclasses, `+[Project entity]` can no longer disambiguate, and object creation/fetch traps (`EXC_BREAKPOINT`).

- **Explicit save semantics:** `autosavesInPlace` is `false`. Editing an existing project prompts to save on window close / quit. New untitled documents seed their root `Project` with undo registration disabled so a pristine, untouched window doesn't nag to save or write a stray "Untitled" file.

- **Lightweight migration is on** (`configurePersistentStoreCoordinator`), so files written by older model versions still open. The model is versioned (`Inkling.xcdatamodeld`); the current version is **Inkling 3**, which added `Project.subtitle` (Inkling 2 added `Project.author`). Schema changes must stay additive/optional so Core Data can infer the mapping — otherwise add a new model version, don't edit the current one in place.

- **Entity is named `Chapter`, not `Section`** — `Section` collides with `SwiftUI.Section`.

- **ViewModels never call `context.save()` directly.** Mutating the context dirties the document, and `NSPersistentDocument` drives saving. Insert/delete objects and let the document handle persistence.

## Data model

Two Core Data entities (`Inkling.xcdatamodeld`):
- **`Project`** — `id`, `title`, `subtitle`, `author`, `createdAt`, and a cascade-delete to-many `chapters`.
- **`Chapter`** — `id`, `title`, `sortIndex` (ordering), `createdAt`, `bodyData`, `notesData`.

Rich text (chapter body + per-chapter notes) is stored as binary in `bodyData` / `notesData`. `RichTextCodec` is the single format boundary: it writes **RTFD** (so inline image attachments survive) with an **RTF fallback** so older files stay readable, and side-stores attachment sizes in embedded JSON.

## Layout

- `main.swift`, `AppDelegate.swift`, `MainMenu.swift`, `InklingDocumentController.swift` — AppKit app/document plumbing.
- `CoreData/InklingDocument.swift` — the `NSPersistentDocument` subclass; also owns Print and "Export as Plain Text" actions.
- `Models/` — Core Data subclasses (`Project+CoreData`, `Chapter+CoreData`), `RichTextCodec`, `TextStatistics`, `ProjectMetadata`, image-attachment models.
- `ViewModels/` — `ProjectViewModel` (chapter list/document state), `StatisticsViewModel`, `RichTextController` (the editor's text engine), `OutlineNavigator`.
- `Views/` — SwiftUI: `ProjectRootView` (NavigationSplitView root), `ChapterSidebar`, `ChapterDetailView`, `RichTextEditor`/`PagedTextView` (NSTextView-backed editor), `NotesPanel`, `FormatToolbar`, settings.
- `Printing/ManuscriptPrinter.swift`, `Export/PlainTextExporter.swift` — output paths.

## Experimental: the Outline feature

The sidebar outline (expandable heading rows under each chapter) is **experimental and deliberately isolated for easy removal** — the user wanted to trial it. It is `Models/ChapterOutline.swift` (parses headings from a chapter's RTF: a paragraph is a heading if its font is **bold and ≥17pt**, matching the Style menu's Title/Heading/Subheading) plus `ViewModels/OutlineNavigator.swift` (shared jump target) and `RichTextController.scroll(to:)`. To remove: delete those two files, revert the sidebar to a flat chapter list, and drop the navigator plumbing. Don't deepen coupling to it without checking with the user.
