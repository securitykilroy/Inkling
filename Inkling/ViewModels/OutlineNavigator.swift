//
//  OutlineNavigator.swift
//  Inkling
//
//  Shared coordinator for "jump to heading" navigation. The sidebar sets a
//  target (a chapter + a character range); the detail view, once that chapter
//  is selected and its editor is ready, scrolls to the range and clears it.
//

import Combine
import Foundation

struct OutlineJumpTarget: Equatable {
    let chapterID: UUID
    /// Relative to the text of `place`: the body, the notes, a sidebar box's
    /// own text, or (ignored) a caption.
    let range: NSRange
    var place: SearchPlace = .body
}

@MainActor
final class OutlineNavigator: ObservableObject {
    @Published var target: OutlineJumpTarget?
}
