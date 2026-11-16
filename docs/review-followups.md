# Review follow-ups

Left over from the November 2026 code review. The three confirmed data-loss
problems from that review are fixed (sidecar offsets, Undo rolling back text,
opening a chapter rewriting it); see the "Architecture" notes in `CLAUDE.md`
and `DataIntegrityFixTests`. Everything below is still open, roughly in the
order worth doing.

"Confirmed" means it was reproduced in a test during the review. The rest is
from reading the code and should be reproduced before it is fixed.

## Created by the fixes

### 1. Replace All and a font change can no longer be undone
`RichTextUndoGuard` stops Undo from ever changing a chapter's text, so these two
now write outside Core Data's undo (`ProjectFindReplaceView.replaceAll`,
`ProjectSettingsView.applyFont`). Before, they were undoable only with focus
outside the editor, and that undo discarded anything typed since.

- Give Replace All an explicit undo: register an action on the document's undo
  manager holding the old `bodyData` of each affected chapter, and restore a
  chapter only if its body is still exactly what Replace All wrote.
- The guard puts back whatever it noted before the undo, so that action has to
  tell it the new value is intended. Add something like
  `RichTextUndoGuard.accept(_:key:)` that updates the noted value.
- A font change is cheap to redo by picking the old font, so it may not need one.

### 2. The real app's Undo routing was not driven
The guard is tested against the document's undo manager directly. Not checked
in the running app: ⌘Z with focus in the chapter title field and in the chapter
list, after rename → type. Expected: the rename is undone, the text is not.

### 3. Callouts in an already-damaged file can still be off
`RichTextCodec.realign` repairs images and sidebars exactly, by matching records
to attachments. Callouts have no attachment, so they take the drift of the
nearest attachment before them. A callout after the last attachment, with a
dropped character in between, is still shifted. Only affects files saved before
the fix. A fix would snap a shifted callout to whole paragraphs.

### 4. Line endings are normalised on paste only
`PasteStyling.normalizeLineEndings` runs in the two paste commands of the page
and sidebar editors. Drag-and-drop, Services and the notes/shelf editors don't
go through it. Nothing saved is at risk (`RichTextCodec.storable` covers every
save); the cost is that on-screen offsets differ from saved ones until the
chapter is reloaded, so a project-wide Find jump can land a character off.

## From the review

### 5. One bad number drops a chapter's whole image sidecar (confirmed)
`RichTextCodec.encode` writes each sidecar with `try? JSONEncoder().encode`.
`JSONEncoder` throws on a non-finite `Double`, so one infinite or NaN size or
origin silently omits every image's size, position and caption. Reproduced by
setting a `displaySize.width` to infinity; no path through the UI was found.

- Drop or clamp non-finite values per record when building records.
- If a sidecar still fails to encode, return nil from `encode` so the existing
  "can't save your latest changes" alert fires, instead of saving without it.

### 6. Deleting a chapter has no confirmation
`ChapterSidebar` deletes on the Delete key and the context menu immediately.
Undo is the only way back. Add a confirmation naming the chapter and its word
count; skip it for an empty chapter.

### 7. Sidebars are not protected from deletion the way images are
`PageTextView.shouldChangeText` refuses a replacement over a range containing a
`FloatingImageAttachment` (`containsProtectedFloatingImage`) but not a
`SidebarAttachment`, so typing over a selection that spans a sidebar's anchor
removes the box and its text. Extend the same rule, with the same exemption for
the selected sidebar.

### 8. A refused deletion gives no feedback
Select All then Delete in a chapter with an image does nothing and says
nothing. At least beep; better, say that the selection contains an image.

### 9. A dropped non-image file becomes a picture of its icon (confirmed)
`prepareFloatingImages` converts every attachment. For a non-image file,
`ImageAttachmentContent.payload` falls back to rendering the attachment cell,
so the file's bytes are replaced by a PNG of its icon. Refuse non-image
attachments at the drop/paste, or leave them unconverted.

### 10. Crash recovery rewrites the whole project every 30 seconds
`CrashRecovery.snapshot` fetches every object, faulting in every chapter, and
`write` saves the lot as an XML store with images base64'd. That is the cost
the move to SQLite removed from Save. Measure on a large illustrated project
first. Options: a SQLite recovery store, or writing only chapters changed since
the last snapshot.

### 11. Legacy conversion leaves a window with no file at the original path
`InklingDocument.convertLegacyStore` copies the XML file to a UUID-named folder
in the temp directory, removes the original, then migrates. A crash in between
leaves the only copy somewhere the author won't find. Put the copy in
`CrashRecovery.directory` instead: it is already an XML store, so the launch
prompt would offer it back.

### 12. Project find and replace skips sidebar text
`ProjectSearch` searches chapter bodies only. Word counts include sidebar
titles and text, so the two disagree about what the manuscript contains. Also
not searched: chapter notes, captions. Decide which of these belong.

### 13. Print and export can differ from the screen for a chapter not yet edited
The editor fits an oversized image to the page (`fittedFloatingSize`) when it
loads a chapter; that size is saved only on the next edit. `ManuscriptPrintView`
uses the stored size. Affects imported chapters printed before being edited.

### 14. Smaller, from reading only
- `selectedImageLocation` is a character index that isn't updated when text
  before the image changes; the deletion exemption in
  `containsProtectedFloatingImage` keys off it.
- Image undo actions (move, resize, caption) capture a character index. Safe
  while undo is strictly last-in-first-out; worth a test with text edits
  interleaved.
- A positioned image or sidebar with a very high stored page index creates
  that many page views (bounded at 5,000).
- A sidebar with no stored position is laid out in the editor but skipped by
  the printer.
- Recovered-copy scratch files in the temp directory are never removed.

## Not reviewed
`WordDocumentExporter`, `MainMenu`, `CalloutLayoutManager`. `WordDocumentImporter`
and `MinimalZipReader` were skimmed for bounds handling only.
