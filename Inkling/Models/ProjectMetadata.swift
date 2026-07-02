//
//  ProjectMetadata.swift
//  Inkling
//
//  Resolves the effective book title and author for a project. Stored values
//  win when present; otherwise we derive sensible defaults so the document
//  filename and the macOS account name can stand in until the user fills in
//  the project settings. Pure functions so derivation can be tested and reused
//  by both the settings sheet (as placeholders) and the print path.
//

import Foundation

enum ProjectMetadata {

    /// The default title seeded into a new project. Treated as "unset" so the
    /// derived document name takes over until the user picks a real title.
    static let defaultTitle = "Untitled Project"

    /// Stored title if the user set one, otherwise the document's file name.
    static func effectiveTitle(stored: String?, documentName: String) -> String {
        if let cleaned = meaningful(stored), cleaned != defaultTitle {
            return cleaned
        }
        let name = documentName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? defaultTitle : name
    }

    /// Stored author if the user set one, otherwise the macOS account's full
    /// name (which itself falls back to the short user name).
    static func effectiveAuthor(stored: String?, accountName: String = NSFullUserName()) -> String {
        if let cleaned = meaningful(stored) {
            return cleaned
        }
        let account = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        return account.isEmpty ? NSUserName() : account
    }

    /// Stored subtitle if the user set one. Unlike title and author there is no
    /// sensible default to derive, so an unset subtitle resolves to the empty
    /// string and callers simply omit it.
    static func effectiveSubtitle(stored: String?) -> String {
        meaningful(stored) ?? ""
    }

    /// Trimmed string, or nil when it has no visible content.
    private static func meaningful(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
