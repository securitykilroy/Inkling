//
//  FileDropTests.swift
//  InklingTests
//
//  A chapter holds text and images. A non-image file pasted or dropped into it
//  used to become an attachment, which the editor then turned into a floating
//  "image" of the file's icon — keeping only that icon, so the file's bytes
//  were gone after the next save. Such files are now refused at the door.
//

import AppKit
import Testing
import UniformTypeIdentifiers
@testable import Inkling

@MainActor
struct FileDropTests {

    private static func stack() -> PageStackView {
        let stack = PageStackView()
        stack.setAttributedString(NSAttributedString(
            string: "Alpha bravo charlie.", attributes: [.font: NSFont.systemFont(ofSize: 12)]
        ))
        stack.pageViews[0].setSelectedRange(NSRange(location: 6, length: 0))
        return stack
    }

    private static func temporaryFile(named name: String, contents: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    private static func pngData() throws -> Data {
        let image = NSImage(size: NSSize(width: 20, height: 20))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 20, height: 20).fill()
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    private static func pasteboard(with urls: [URL]) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("InklingTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        return pasteboard
    }

    @Test func aNonImageFileIsRefused() throws {
        let stack = Self.stack()
        let zip = try Self.temporaryFile(named: "notes.zip", contents: Data("PK\u{03}\u{04}not really".utf8))
        let before = stack.storage.string

        let accepted = stack.pageViews[0].readSelection(from: Self.pasteboard(with: [zip]))

        #expect(!accepted)
        #expect(stack.storage.string == before)
    }

    /// One wrong file in a multi-file drop refuses the whole drop rather than
    /// quietly keeping some of it.
    @Test func aDropMixingAnImageWithAnotherFileIsRefused() throws {
        let stack = Self.stack()
        let png = try Self.temporaryFile(named: "picture.png", contents: Self.pngData())
        let doc = try Self.temporaryFile(named: "letter.docx", contents: Data("PK\u{03}\u{04}".utf8))
        let before = stack.storage.string

        let accepted = stack.pageViews[0].readSelection(from: Self.pasteboard(with: [png, doc]))

        #expect(!accepted)
        #expect(stack.storage.string == before)
    }

    @Test func anImageFileIsStillAccepted() throws {
        let stack = Self.stack()
        let png = try Self.temporaryFile(named: "picture.png", contents: Self.pngData())

        let accepted = stack.pageViews[0].readSelection(from: Self.pasteboard(with: [png]))

        #expect(accepted)
    }

    /// The check the drag overrides (`draggingEntered`, `performDragOperation`)
    /// share with paste.
    @Test func theDragCheckRefusesOnlyPasteboardsCarryingOtherFiles() throws {
        let png = try Self.temporaryFile(named: "picture.png", contents: Self.pngData())
        let pdf = try Self.temporaryFile(named: "figure.pdf", contents: Data("%PDF-1.4".utf8))
        let zip = try Self.temporaryFile(named: "notes.zip", contents: Data("PK\u{03}\u{04}".utf8))

        #expect(!PageTextView.carriesUnacceptableFiles(Self.pasteboard(with: [png])))
        #expect(!PageTextView.carriesUnacceptableFiles(Self.pasteboard(with: [png, pdf])))
        #expect(PageTextView.carriesUnacceptableFiles(Self.pasteboard(with: [zip])))
        #expect(PageTextView.carriesUnacceptableFiles(Self.pasteboard(with: [png, zip])))

        // Plain text and web links aren't files, so they pass straight through.
        let text = NSPasteboard(name: NSPasteboard.Name("InklingTests-\(UUID().uuidString)"))
        text.clearContents()
        text.setString("just words", forType: .string)
        #expect(!PageTextView.carriesUnacceptableFiles(text))
        let link = NSPasteboard(name: NSPasteboard.Name("InklingTests-\(UUID().uuidString)"))
        link.clearContents()
        link.writeObjects([NSURL(string: "https://example.com/a.zip")!])
        #expect(!PageTextView.carriesUnacceptableFiles(link))
    }

    @Test func imageFileClassification() {
        #expect(ImageAttachmentContent.isAcceptableFile(URL(fileURLWithPath: "/tmp/a.png")))
        #expect(ImageAttachmentContent.isAcceptableFile(URL(fileURLWithPath: "/tmp/a.JPG")))
        #expect(ImageAttachmentContent.isAcceptableFile(URL(fileURLWithPath: "/tmp/a.pdf")))
        #expect(!ImageAttachmentContent.isAcceptableFile(URL(fileURLWithPath: "/tmp/a.zip")))
        #expect(!ImageAttachmentContent.isAcceptableFile(URL(fileURLWithPath: "/tmp/a.docx")))
        #expect(!ImageAttachmentContent.isAcceptableFile(URL(fileURLWithPath: "/tmp/folder", isDirectory: true)))
        #expect(!ImageAttachmentContent.isAcceptableFile(URL(fileURLWithPath: "/tmp/noextension")))
    }
}
