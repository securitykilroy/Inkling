//
//  ExportFilename.swift
//  Inkling
//
//  File names for the per-chapter exports (Word and plain text): a chapter's
//  title made safe for a file name, and a URL that never overwrites a file
//  already in the folder.
//

import Foundation

enum ExportFilename {

    nonisolated static func sanitized(_ value: String?, fallback: String) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? fallback : trimmed
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            .union(.controlCharacters)
        let clean = source
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? fallback : clean
    }

    /// `baseName.ext`, or `baseName 2.ext`, `baseName 3.ext`… if that exists.
    nonisolated static func uniqueURL(
        in folder: URL, baseName: String, extension pathExtension: String
    ) -> URL {
        var candidate = folder.appendingPathComponent(baseName).appendingPathExtension(pathExtension)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder
                .appendingPathComponent("\(baseName) \(suffix)")
                .appendingPathExtension(pathExtension)
            suffix += 1
        }
        return candidate
    }
}
