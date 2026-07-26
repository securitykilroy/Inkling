//
//  ImportedImageAnchor.swift
//  Inkling
//
//  Picks the character a floating image's page and vertical offset are
//  measured from. Shared by the editor and the printer so an imported image
//  lands on the same page in both.
//

import AppKit

enum ImportedImageAnchor {

    /// Inkling's own convention is that an un-placed image floats beside its
    /// anchor character's own line, so an image inserted mid-paragraph stays
    /// beside the text that mentions it.
    ///
    /// Word means something different by `positionV relativeFrom="paragraph"`:
    /// the offset is measured from the top of the *whole* anchor paragraph, and
    /// Word draws the image there no matter how deep inside the paragraph the
    /// drawing run happens to sit. Real manuscripts do put it deep — one sample
    /// chapter had drawing runs 438 and 640 characters into their paragraphs,
    /// which landed the imported images most of a page below where the Word
    /// document showed them.
    ///
    /// So an imported paragraph-relative anchor measures from its paragraph's
    /// first line; everything else keeps Inkling's beside-the-line rule.
    static func measurementLocation(
        for hint: ImportedImagePlacementHint?,
        attachmentLocation: Int,
        in text: NSAttributedString
    ) -> Int {
        guard let hint, hint.verticalReference == .paragraph else { return attachmentLocation }
        let string = text.string as NSString
        guard attachmentLocation >= 0, attachmentLocation < string.length else { return attachmentLocation }
        return string.paragraphRange(for: NSRange(location: attachmentLocation, length: 0)).location
    }
}
