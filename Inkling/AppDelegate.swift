//
//  AppDelegate.swift
//  Inkling
//
//  Application delegate for the AppKit document architecture
//  (NSDocumentController + NSPersistentDocument). The app is launched from
//  main.swift, which installs this delegate and the hand-built main menu.
//

import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// The first document-controller instance created during launch becomes
    /// AppKit's shared controller. Keep it alive for the application's life.
    private var documentController: InklingDocumentController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        documentController = InklingDocumentController()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // After the launch's own windows are up, so the prompt lands on top.
        DispatchQueue.main.async { [weak self] in
            self?.offerCrashRecovery()
        }
    }

    // MARK: - Crash recovery

    /// Safety copies that survived to this launch mean Inkling last ended
    /// without the writer saving or discarding those changes. Offer them back.
    /// Nothing is opened, overwritten, or deleted without a choice here.
    private func offerCrashRecovery() {
        // A modal prompt would hang a test run hosted in this app.
        let environment = ProcessInfo.processInfo.environment
        guard environment["XCTestConfigurationFilePath"] == nil,
              environment["XCTestBundlePath"] == nil
        else { return }

        let entries = CrashRecovery.entries()
        guard !entries.isEmpty else { return }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let list = entries.map { entry in
            "• \(entry.displayName) — \(formatter.string(from: entry.snapshotDate))"
        }.joined(separator: "\n")

        let alert = NSAlert()
        alert.messageText = entries.count == 1
            ? "Inkling found unsaved work from when it last quit unexpectedly."
            : "Inkling found unsaved work in \(entries.count) projects from when it last quit unexpectedly."
        alert.informativeText = list + "\n\nRecovered work opens as a new, untitled project, so your saved files are left exactly as they were. Use Save As to keep it."
        alert.addButton(withTitle: entries.count == 1 ? "Open Recovered Copy" : "Open Recovered Copies")
        alert.addButton(withTitle: "Decide Later")
        alert.addButton(withTitle: "Delete…")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            entries.forEach(openRecoveredCopy)
        case .alertThirdButtonReturn:
            confirmDeletingRecoveredCopies(entries)
        default:
            break
        }
    }

    private func openRecoveredCopy(_ entry: CrashRecovery.Entry) {
        do {
            // Read from a scratch copy: the document keeps its store attached
            // to the file it was read from, and the safety copy itself gets
            // rewritten by later snapshots.
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).inkling")
            try FileManager.default.copyItem(at: entry.url, to: scratch)

            // No file URL: the result is untitled, so Save asks where to put
            // it instead of writing over the original file.
            let controller = NSDocumentController.shared
            let document = try controller.makeDocument(
                for: nil,
                withContentsOf: scratch,
                ofType: controller.defaultType ?? "com.washere.inkling-project"
            )
            document.displayName = "\(entry.displayName) (Recovered)"
            controller.addDocument(document)
            document.makeWindowControllers()
            document.showWindows()
            (document as? InklingDocument)?.adoptRecoveredCopy(at: entry.url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func confirmDeletingRecoveredCopies(_ entries: [CrashRecovery.Entry]) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Delete the recovered work?"
        alert.informativeText = "The unsaved changes in these copies will be gone for good. Your saved project files are not affected."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for entry in entries {
            try? FileManager.default.removeItem(at: entry.url)
        }
    }

    /// Keep the app running when all document windows close (standard macOS
    /// document-app behavior: the user can make a new document from the Dock
    /// or File menu).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
