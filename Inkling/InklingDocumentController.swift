//
//  InklingDocumentController.swift
//  Inkling
//
//  Adds one small piece of document-window polish to AppKit's standard
//  controller: a successfully opened file replaces the active, untouched
//  untitled document instead of leaving an unnecessary blank window behind.
//

import AppKit

final class InklingDocumentController: NSDocumentController {

    static func isReplaceableUntitled(fileURL: URL?, isDocumentEdited: Bool) -> Bool {
        fileURL == nil && !isDocumentEdited
    }

    override func openDocument(
        withContentsOf url: URL,
        display displayDocument: Bool,
        completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void
    ) {
        let untitledDocument = currentDocument.flatMap { document in
            Self.isReplaceableUntitled(
                fileURL: document.fileURL,
                isDocumentEdited: document.isDocumentEdited
            ) ? document : nil
        }

        super.openDocument(
            withContentsOf: url,
            display: displayDocument
        ) { [weak self] document, documentWasAlreadyOpen, error in
            if document != nil,
               let untitledDocument,
               untitledDocument !== document,
               Self.isReplaceableUntitled(
                   fileURL: untitledDocument.fileURL,
                   isDocumentEdited: untitledDocument.isDocumentEdited
               ),
               self?.documents.contains(where: { $0 === untitledDocument }) == true {
                untitledDocument.close()
            }

            completionHandler(document, documentWasAlreadyOpen, error)
        }
    }
}
