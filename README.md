# Inkling

A native macOS app for writing and organizing multi-chapter projects — novels, manuscripts, anything long-form. One `.inkling` document is one project: its own file, its own store, its own window.

Inkling is deliberately **not** a productivity gamifier. There are no streaks, word-count goals, or motivational nudges. It's a quiet place to write and keep your material organized.

## Features

- **Chapter-based organization** — a sidebar of chapters you can reorder, each with its own rich-text body.
- **Paginated rich-text editor** — write on a real page (Letter size) with proper margins, headings, and a live page count, backed by TextKit.
- **Inline images** — drag images into a chapter; float them to a fixed spot on the page with text wrapping, and they print where you put them.
- **Per-chapter notes** — a notes panel alongside each chapter, kept separate from the manuscript so notes never bleed into your prose.
- **Project Notes** — a project-wide scratchpad in its own window (toggle from the Window menu) for thoughts that don't belong to any one chapter.
- **The Shelf** — a project-wide parking lot: drag a sentence out of a chapter to set it aside without deleting it, or jot a stray idea.
- **Typewriter scrolling** — optionally pin the caret at a fixed height so the line you're writing stays put.
- **Find & Replace across the whole project** (⇧⌘F), not just the open chapter.
- **Import & export**
  - Import Word (`.docx`) files as chapters.
  - Export chapters as Word documents.
  - Export the project as plain text.
  - Print a single chapter or the whole manuscript, with an optional title page.
- **Project metadata** — title, subtitle, author, and a project-wide body font.

## Requirements

- macOS (built and tested against the macOS 26 SDK).
- **Xcode 27 (beta).** The project is saved in Xcode 27's project format (`objectVersion = 110`), so it must be built with Xcode-beta, not the current stable Xcode.

## Building

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project Inkling.xcodeproj -scheme Inkling \
  -destination 'platform=macOS' -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

Or just open `Inkling.xcodeproj` in Xcode-beta and run.

## Testing

Tests use the **Swift Testing** framework (`@Test` / `#expect`), not XCTest:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project Inkling.xcodeproj -scheme Inkling \
  -destination 'platform=macOS' -configuration Debug clean test -only-testing:InklingTests
```

## Architecture

Inkling is **MVVM with a 100% SwiftUI UI hosted inside an AppKit document app**. A few deliberate choices worth knowing:

- **AppKit lifecycle, not SwiftUI `DocumentGroup`.** `main.swift` is an explicit entry point that installs an `AppDelegate` and a hand-built menu bar before the run loop starts, because `DocumentGroup` can't host an `NSPersistentDocument`. The UI itself is still entirely SwiftUI, hosted via `NSHostingController`.
- **Core Data per document.** Each `.inkling` file is one `NSPersistentDocument` backed by its own Core Data store, with two entities — `Project` (the root) and `Chapter` — plus a project-wide `ShelfEntry`. The model is versioned with lightweight migration on, so older files keep opening.
- **Rich text** (chapter bodies, notes, shelf scraps, project notes) is stored as binary through a single codec that writes RTFD — so inline image attachments survive — with an RTF fallback for older files.
- **Explicit save semantics.** Autosave-in-place is off: editing an existing project prompts to save on close, and a pristine untitled window won't nag you or leave a stray file behind.

## License

No license is currently specified. All rights reserved by the author unless and until a license is added.
