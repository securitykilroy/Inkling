//
//  FindDiagnostics.swift
//  Inkling
//
//  TEMPORARY instrumentation for the find-doesn't-jump bug in the per-page
//  editor. Three theories about NSTextFinderClient geometry have failed, and
//  NSTextFinder cannot be driven headless, so this records what the finder
//  actually asks for and what it is told at runtime.
//
//  Messages go to the unified log and can be read with:
//    log show --last 5m --predicate 'eventMessage CONTAINS "INKLING-FIND"' --info
//
//  Delete this file, and its call sites, once the bug is understood.
//

import OSLog

enum FindDiagnostics {
    private static let logger = Logger(subsystem: "com.washere.Inkling", category: "find")

    /// Set false to silence without unpicking the call sites.
    static let isEnabled = true

    static func log(_ message: String) {
        guard isEnabled else { return }
        logger.info("INKLING-FIND \(message, privacy: .public)")
    }
}
