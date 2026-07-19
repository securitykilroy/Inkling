//
//  RichTextEditor.swift
//  Inkling
//
//  SwiftUI wrapper around an AppKit NSTextView (SwiftUI's TextEditor can't do
//  rich text). It is field-agnostic: it binds to any `Data?` holding RTF, so
//  the same view drives both the chapter body and the notes panel. Edits are
//  written back to the binding (dirtying the document for autosave), and the
//  content reloads when `documentID` changes (i.e. a different chapter is
//  selected). Pass a `controller` to let a formatting toolbar drive it.
//

import SwiftUI
import AppKit
import CoreData

enum RichTextEditorPresentation {
    case continuous
    case paged
}

struct RichTextEditor: NSViewRepresentable {
    @Binding var data: Data?
    let documentID: NSManagedObjectID
    var controller: RichTextController? = nil
    var presentation: RichTextEditorPresentation = .continuous
    /// Called with the editor's plain text on every edit (used for live stats).
    var onTextChange: ((String) -> Void)? = nil
    var onPageCountChange: ((Int) -> Void)? = nil
    /// Called with the caret's character offset whenever the selection moves,
    /// so the document can remember where the user was for reopening.
    var onCaretChange: ((Int) -> Void)? = nil
    /// The project's chosen typeface (nil = system default). Drives both the
    /// initial/reload typing font and the empty-document display font.
    var fontFamilyName: String? = nil
    /// Only meaningful for `.paged` presentation; ignored otherwise.
    var isTypewriterScrollingEnabled = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // Experimental per-page-container editor, opt-in from Project Settings.
        // Text-only for now: images, sidebars, and callouts don't render yet.
        if presentation == .paged, PageStackView.isEnabled {
            return makePerPageEditor(context: context)
        }

        let scrollView: NSScrollView
        switch presentation {
        case .continuous:
            scrollView = NSTextView.scrollableTextView()
        case .paged:
            scrollView = PagedTextView.makePagedScrollView()
        }
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.importsGraphics = presentation == .paged
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        // Red squiggles under misspellings, checked as you type. Automatic
        // correction stays off so typos are flagged, never silently rewritten.
        textView.isContinuousSpellCheckingEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.usesAdaptiveColorMappingForDarkAppearance = presentation == .continuous
        let bodyFont = TextStyle.body.font(familyName: fontFamilyName)
        textView.font = bodyFont
        textView.typingAttributes = [
            .font: bodyFont,
            .paragraphStyle: RichTextCodec.defaultParagraphStyle,
        ]

        if let pagedTextView = textView as? PagedTextView {
            pagedTextView.textColor = .black
            pagedTextView.insertionPointColor = .black
            pagedTextView.isTypewriterScrollingEnabled = isTypewriterScrollingEnabled
            pagedTextView.pageCountDidChange = { [weak coordinator = context.coordinator] count in
                coordinator?.parent.onPageCountChange?(count)
            }
        } else {
            textView.textContainerInset = NSSize(width: 12, height: 16)
        }

        context.coordinator.load(data, documentID: documentID, into: textView)
        controller?.textView = textView
        return scrollView
    }

    /// Builds the experimental per-page-container editor. Deliberately separate
    /// from the main path so the shipping editor is unaffected and this can be
    /// deleted wholesale if the rearchitecture is abandoned.
    private func makePerPageEditor(context: Context) -> NSScrollView {
        let scrollView = PageStackView.makeScrollView()
        guard let stack = scrollView.documentView as? PageStackView else { return scrollView }

        let bodyFont = TextStyle.body.font(familyName: fontFamilyName)
        stack.pageTypingAttributes = [
            .font: bodyFont,
            .paragraphStyle: RichTextCodec.defaultParagraphStyle,
        ]
        stack.pageDelegate = context.coordinator
        stack.pageCountDidChange = { [weak coordinator = context.coordinator] count in
            coordinator?.parent.onPageCountChange?(count)
        }

        context.coordinator.loadStack(data, documentID: documentID, into: stack)
        controller?.textView = stack.pageViews.first
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        if let stack = scrollView.documentView as? PageStackView {
            context.coordinator.parent = self
            context.coordinator.loadStackIfChanged(data, documentID: documentID, into: stack)
            return
        }
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // Refresh the coordinator's reference so edits write to the *current*
        // chapter's binding (the struct is recreated on every SwiftUI update).
        context.coordinator.parent = self
        controller?.textView = textView
        (textView as? PagedTextView)?.isTypewriterScrollingEnabled = isTypewriterScrollingEnabled
        context.coordinator.loadIfChanged(data, documentID: documentID, into: textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        private var loadedID: NSManagedObjectID?
        /// The data this editor last loaded *or wrote*. Lets `loadIfChanged`
        /// tell "the binding changed because I just typed" (already reflected
        /// here, so no reload) apart from "the binding changed because
        /// something else touched this chapter's bodyData" (e.g. a
        /// project-wide Replace All), which does need a reload.
        private var loadedData: Data?
        private var isLoading = false

        init(_ parent: RichTextEditor) { self.parent = parent }

        func load(_ data: Data?, documentID: NSManagedObjectID, into textView: NSTextView) {
            isLoading = true
            defer { isLoading = false }

            (textView as? PagedTextView)?.clearImageSelection()
            if let attributed = RichTextCodec.decode(data) {
                textView.textStorage?.setAttributedString(attributed)
            } else {
                textView.string = ""
            }
            (textView as? PagedTextView)?.prepareFloatingImages()
            (textView as? PagedTextView)?.prepareSidebars()
            textView.typingAttributes = [
                .font: TextStyle.body.font(familyName: parent.fontFamilyName),
                .paragraphStyle: RichTextCodec.defaultParagraphStyle,
            ]
            (textView as? PagedTextView)?.updatePageLayout()
            loadedID = documentID
            loadedData = data
            parent.controller?.selectionDidChange()
        }

        func loadIfChanged(_ data: Data?, documentID: NSManagedObjectID, into textView: NSTextView) {
            guard loadedID != documentID || data != loadedData else { return }
            load(data, documentID: documentID, into: textView)
        }

        // MARK: - Experimental per-page editor

        func loadStack(_ data: Data?, documentID: NSManagedObjectID, into stack: PageStackView) {
            isLoading = true
            defer { isLoading = false }

            stack.clearImageSelection()
            stack.setAttributedString(RichTextCodec.decode(data) ?? NSAttributedString())
            stack.prepareFloatingImages()
            loadedID = documentID
            loadedData = data
            parent.controller?.selectionDidChange()
        }

        func loadStackIfChanged(
            _ data: Data?,
            documentID: NSManagedObjectID,
            into stack: PageStackView
        ) {
            guard loadedID != documentID || data != loadedData else { return }
            loadStack(data, documentID: documentID, into: stack)
        }

        func textDidChange(_ notification: Notification) {
            guard !isLoading, let textView = notification.object as? NSTextView else { return }
            (textView as? PagedTextView)?.prepareFloatingImages()
            let attributed = textView.attributedString()
            let encoded = RichTextCodec.encode(attributed)
            parent.data = encoded
            loadedData = encoded
            (textView as? PagedTextView)?.updatePageLayout()
            parent.onTextChange?(textView.string)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isLoading else { return }
            // In the per-page editor the caret moves between page views, so
            // point the formatting toolbar at whichever page now holds it.
            // (Any page view would edit the same shared storage, but the
            // toolbar reads the selection off the view it's given.)
            if let page = notification.object as? PageTextView {
                parent.controller?.textView = page
            }
            parent.controller?.selectionDidChange()
            if let textView = notification.object as? NSTextView {
                parent.onCaretChange?(textView.selectedRange().location)
            }
        }
    }
}
