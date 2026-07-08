//
//  ShelfView.swift
//  Inkling
//
//  A project-wide parking lot for stray text and ideas: drag a sentence out
//  of a chapter and drop it here to set it aside without committing to
//  cutting it for good, or jot a thought that isn't tied to any chapter at
//  all. Each entry is its own small rich-text row, reordered by dragging and
//  removed with the trash button — never a single running blob of notes.
//

import SwiftUI
import CoreData
import UniformTypeIdentifiers

struct ShelfView: View {
    @ObservedObject var project: Project

    @Environment(\.managedObjectContext) private var context
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \ShelfEntry.sortIndex, ascending: true)])
    private var entries: FetchedResults<ShelfEntry>
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Drag text here to park it, or jot a stray idea.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button { addEntry(with: nil) } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add a Shelf Entry")
            }
            .padding(8)

            Divider()

            List {
                ForEach(entries, id: \.self) { entry in
                    ShelfEntryRow(entry: entry, fontFamilyName: project.bodyFontFamily) {
                        delete(entry)
                    }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                }
                .onMove(perform: move)
            }
            .listStyle(.plain)
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "Nothing on the Shelf",
                        systemImage: "tray",
                        description: Text("Drag text from your manuscript here, or click + to add an idea.")
                    )
                }
            }
        }
        .background(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(4)
            }
        }
        .onDrop(of: [UTType.rtf, UTType.utf8PlainText], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private func addEntry(with attributed: NSAttributedString?) {
        let entry = ShelfEntry(context: context)
        entry.id = UUID()
        entry.createdAt = Date()
        entry.sortIndex = (project.orderedShelfEntries.last?.sortIndex ?? -1) + 1
        entry.bodyData = RichTextCodec.encode(
            attributed ?? NSAttributedString(string: "", attributes: [.font: TextStyle.body.font(familyName: project.bodyFontFamily)])
        )
        entry.project = project
    }

    private func delete(_ entry: ShelfEntry) {
        context.delete(entry)
    }

    private func move(from source: IndexSet, to destination: Int) {
        var reordered = entries.map { $0 }
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, entry) in reordered.enumerated() {
            entry.sortIndex = Int64(index)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        let fallbackFont = TextStyle.body.font(familyName: project.bodyFontFamily)

        if provider.hasItemConformingToTypeIdentifier(UTType.rtf.identifier) {
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.rtf.identifier) { data, _ in
                guard let data, let attributed = ShelfDropParser.attributedString(rtfData: data) else { return }
                DispatchQueue.main.async { addEntry(with: attributed) }
            }
            return true
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier) {
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier) { data, _ in
                guard let data, let attributed = ShelfDropParser.attributedString(plainTextData: data, font: fallbackFont)
                else { return }
                DispatchQueue.main.async { addEntry(with: attributed) }
            }
            return true
        }

        return false
    }
}

/// Turns dropped pasteboard payloads into an attributed string for a new
/// Shelf entry. Pulled out of the drop handler so the parsing itself — the
/// part that can actually be wrong — is testable without faking a real
/// `NSItemProvider` drag session.
enum ShelfDropParser {
    static func attributedString(rtfData data: Data) -> NSAttributedString? {
        NSAttributedString(rtf: data, documentAttributes: nil)
    }

    static func attributedString(plainTextData data: Data, font: NSFont) -> NSAttributedString? {
        guard let string = String(data: data, encoding: .utf8), !string.isEmpty else { return nil }
        return NSAttributedString(string: string, attributes: [.font: font])
    }
}

private struct ShelfEntryRow: View {
    @ObservedObject var entry: ShelfEntry
    let fontFamilyName: String?
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            RichTextEditor(data: bodyBinding, documentID: entry.objectID, fontFamilyName: fontFamilyName)
                .frame(height: 64)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor))
                }

            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .opacity(isHovering ? 1 : 0)
            .help("Remove from Shelf")
        }
        .onHover { isHovering = $0 }
    }

    private var bodyBinding: Binding<Data?> {
        Binding(get: { entry.bodyData }, set: { entry.bodyData = $0 })
    }
}
