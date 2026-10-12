# Image Captions — Implementation Overview

## Recommended first version

Give each image an optional plain-text caption. Display it directly below the
image in a fixed style, and treat the image plus caption as one floating object
for wrapping, movement, page bounds, printing, and PDF output.

## Storage

- Add `caption: String?` to `FloatingImageAttachment`.
- Add the same optional field to `RichTextCodec.AttachmentSizeRecord`, stored in
  the existing `__inkling_attachment_sizes.json` RTFD sidecar.
- Restore the caption as an in-memory attributed-string value when decoding,
  then copy it into `FloatingImageAttachment` in `prepareFloatingImages()`.
- When encoding, read from the floating attachment with the attributed-string
  value as a fallback, matching the existing position and import-hint handling.

This is additive: it requires no Core Data migration, old documents have no
caption, and older app versions can read the expanded JSON record. Saving with
an older app would discard captions.

## Editor and layout

- Add an **Add/Edit Caption…** action for the selected image, using a small
  popover or sheet. Caption edits must participate in undo and dirty the
  document.
- Measure wrapped caption text at the image width. Keep separate image and
  caption rectangles, plus a combined rectangle.
- Continue using the image rectangle for hit testing and resize handles, but
  use the combined rectangle for exclusion paths and page-boundary clamping.
- Re-measure and repaginate when the caption or image width changes.

## Output

- Extend `ManuscriptPrinter.PlacedImage` with caption data and draw the caption
  beneath the image using the same measurements as the editor. PDF then follows
  automatically.
- Plain-text export should replace a captioned image anchor with something like
  `[IMAGE: The lighthouse at dusk]`.
- The simplest Word export is a normal caption paragraph at the image anchor.
  Keeping a caption physically grouped with a freely positioned Word image
  requires more involved DrawingML and can be deferred.

## Initial limits

- Plain text only; no rich formatting inside captions.
- No automatic figure numbering.
- No Word-caption import in the first version.
- Captions belong to images and move or disappear with them.

## Important regression coverage

Test sidecar round trips and backward compatibility; undo and document dirtying;
caption wrapping after resize; bottom-of-page clamping; editor/print geometry
agreement; and plain-text and Word export behavior.
