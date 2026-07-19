//
//  InklingDocumentDrop.swift
//  Inkling
//
//  Opens .inkling documents dropped onto an existing project window.
//

import AppKit
import UniformTypeIdentifiers

enum InklingDocumentDrop {
    static let acceptedTypes: [UTType] = [.fileURL]

    static func isInklingDocumentURL(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.caseInsensitiveCompare("inkling") == .orderedSame
    }

    static func fileURL(from item: Any?) -> URL? {
        if let url = item as? URL, url.isFileURL {
            return url
        }
        if let data = item as? Data,
           let string = String(data: data, encoding: .utf8),
           let url = URL(string: string),
           url.isFileURL {
            return url
        }
        return nil
    }

    static func openFirstInklingDocument(from providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let url = fileURL(from: item),
                  isInklingDocumentURL(url)
            else { return }

            DispatchQueue.main.async {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                    if let error {
                        NSApplication.shared.presentError(error)
                    }
                }
            }
        }
        return true
    }
}
