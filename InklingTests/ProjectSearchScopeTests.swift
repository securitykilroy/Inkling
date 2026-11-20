//
//  ProjectSearchScopeTests.swift
//  InklingTests
//
//  Project search used to read only each chapter's body text, missing the
//  words in its notes, its sidebar boxes and its image captions. Find and
//  Replace All now cover all four, and each match says where it is.
//

import AppKit
import Testing
@testable import Inkling

@MainActor
struct ProjectSearchScopeTests {

    private static let font = NSFont.systemFont(ofSize: 12)

    private static func rtf(_ text: String) -> Data? {
        RichTextCodec.encode(NSAttributedString(string: text, attributes: [.font: font]))
    }

    private static func image(caption: String?) throws -> NSAttributedString {
        let image = NSImage(size: NSSize(width: 20, height: 20))
        image.lockFocus()
        NSColor.gray.setFill()
        NSRect(x: 0, y: 0, width: 20, height: 20).fill()
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let attachment = NSMutableAttributedString(attachment: ImageAttachmentContent.makeSizedAttachment(
            payload: .init(data: png, typeIdentifier: "public.png"), size: NSSize(width: 80, height: 60)
        ))
        if let caption {
            attachment.addAttribute(.inklingImageCaption, value: caption, range: NSRange(location: 0, length: 1))
        }
        return attachment
    }

    /// "Body bell. " + box("Box bell rings", title "Aside") + " middle " +
    /// image(caption "Caption bell") + " end."
    private static func richBody() throws -> (data: Data, sidebarAnchor: Int, imageAnchor: Int) {
        let text = NSMutableAttributedString(string: "Body bell. ", attributes: [.font: font])
        let sidebarAnchor = text.length
        let sidebar = SidebarAttachment(
            contentData: rtf("Box bell rings"), width: 180,
            position: FloatingImagePosition(page: 0, origin: CGPoint(x: 300, y: 100)), contentHeight: 40
        )
        sidebar.title = "Aside"
        text.append(NSAttributedString(attachment: sidebar))
        text.append(NSAttributedString(string: " middle ", attributes: [.font: font]))
        let imageAnchor = text.length
        text.append(try image(caption: "Caption bell"))
        text.append(NSAttributedString(string: " end.", attributes: [.font: font]))
        return (try #require(RichTextCodec.encode(text)), sidebarAnchor, imageAnchor)
    }

    private static func chapter(body: Data?, notes: Data? = nil, id: UUID = UUID()) -> SearchableChapter {
        SearchableChapter(id: id, title: "One", bodyData: body, notesData: notes)
    }

    // MARK: - Find

    @Test func findsMatchesInEveryPlaceAndSaysWhere() throws {
        let (body, sidebarAnchor, imageAnchor) = try Self.richBody()
        let matches = ProjectSearch.findMatches(
            in: [Self.chapter(body: body, notes: Self.rtf("Notes about the bell."))],
            query: "bell", caseSensitive: true
        )

        #expect(matches.map(\.place) == [
            .body,
            .sidebar(anchor: sidebarAnchor, title: "Aside"),
            .caption(anchor: imageAnchor),
            .notes,
        ])
        // Each range is relative to its own place's text.
        #expect(matches[1].range == NSRange(location: 4, length: 4))
        #expect(matches[2].range == NSRange(location: 8, length: 4))
        #expect(matches[3].range == NSRange(location: 16, length: 4))
        #expect(matches[3].snippetBefore == "Notes about the ")
        #expect(matches.map { $0.place.label } == [nil, "Sidebar “Aside”", "Caption", "Notes"])
        // A box with no title of its own is just "Sidebar", not its
        // default heading quoted back.
        #expect(SearchPlace.sidebar(anchor: 0, title: "").label == "Sidebar")
    }

    @Test func caseInsensitiveSearchReachesTheOtherPlacesToo() throws {
        let (body, _, _) = try Self.richBody()
        let matches = ProjectSearch.findMatches(
            in: [Self.chapter(body: body, notes: Self.rtf("BELL"))], query: "Bell", caseSensitive: false
        )
        #expect(matches.count == 4)
    }

    // MARK: - Replace All

    @Test func replaceAllRewritesEveryPlace() throws {
        let id = UUID()
        let (body, _, _) = try Self.richBody()
        let results = ProjectSearch.replaceAll(
            in: [Self.chapter(body: body, notes: Self.rtf("Notes about the bell."), id: id)],
            query: "bell", replacement: "gong", caseSensitive: true
        )

        let result = try #require(results[id])
        let newBody = try #require(RichTextCodec.decode(result.bodyData))
        #expect(newBody.string.hasPrefix("Body gong. "))

        var boxText: String?
        var caption: String?
        newBody.enumerateAttribute(.attachment, in: NSRange(location: 0, length: newBody.length)) { value, range, _ in
            if let sidebar = value as? SidebarAttachment {
                boxText = RichTextCodec.decode(sidebar.contentData)?.string
                #expect(sidebar.title == "Aside")
            } else if value != nil {
                caption = newBody.attribute(.inklingImageCaption, at: range.location, effectiveRange: nil) as? String
            }
        }
        #expect(boxText == "Box gong rings")
        #expect(caption == "Caption gong")
        #expect(RichTextCodec.decode(result.notesData)?.string == "Notes about the gong.")

        // Nothing left to find.
        let again = ProjectSearch.findMatches(
            in: [Self.chapter(body: result.bodyData, notes: result.notesData)], query: "bell", caseSensitive: true
        )
        #expect(again.isEmpty)
    }

    /// A field with no match is left exactly as stored.
    @Test func aMatchOnlyInNotesLeavesTheBodyUntouched() throws {
        let id = UUID()
        let results = ProjectSearch.replaceAll(
            in: [Self.chapter(body: Self.rtf("Nothing here."), notes: Self.rtf("a bell"), id: id)],
            query: "bell", replacement: "gong", caseSensitive: true
        )
        let result = try #require(results[id])
        #expect(result.bodyData == nil)
        #expect(RichTextCodec.decode(result.notesData)?.string == "a gong")
    }

    @Test func aMatchOnlyInASidebarRewritesTheBodyButKeepsItsText() throws {
        let id = UUID()
        let (body, _, _) = try Self.richBody()
        let results = ProjectSearch.replaceAll(
            in: [Self.chapter(body: body, id: id)], query: "rings", replacement: "tolls", caseSensitive: true
        )
        let newBody = try #require(RichTextCodec.decode(try #require(results[id]?.bodyData)))
        let original = try #require(RichTextCodec.decode(body))
        #expect(newBody.string == original.string)
        #expect(results[id]?.notesData == nil)
    }

    /// Replacing a whole caption with nothing removes the caption rather
    /// than leaving an empty one behind.
    @Test func replacingAWholeCaptionWithNothingRemovesIt() throws {
        let id = UUID()
        let text = NSMutableAttributedString(string: "Before ", attributes: [.font: Self.font])
        text.append(try Self.image(caption: "bell"))
        let results = ProjectSearch.replaceAll(
            in: [Self.chapter(body: RichTextCodec.encode(text), id: id)],
            query: "bell", replacement: "", caseSensitive: true
        )
        let newBody = try #require(RichTextCodec.decode(try #require(results[id]?.bodyData)))
        var captions = 0
        newBody.enumerateAttribute(.inklingImageCaption, in: NSRange(location: 0, length: newBody.length)) { value, _, _ in
            if value != nil { captions += 1 }
        }
        #expect(captions == 0)
    }

    // MARK: - Jumps

    private static func editor(for body: Data) throws -> (PageStackView, NSWindow) {
        let stack = PageStackView()
        stack.setAttributedString(try #require(RichTextCodec.decode(body)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 1100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = stack
        stack.prepareFloatingImages(joiningImageOnlyLines: false)
        stack.prepareSidebars()
        stack.rebuildFloatingImageLayout()
        return (stack, window)
    }

    @Test func jumpingToASidebarMatchEntersTheBoxAndSelectsIt() throws {
        let (body, sidebarAnchor, _) = try Self.richBody()
        let (stack, window) = try Self.editor(for: body)
        _ = window

        stack.revealSidebar(anchor: sidebarAnchor, selecting: NSRange(location: 4, length: 4))

        let box = try #require(stack.enteredSidebarTextView)
        #expect(box.selectedRange() == NSRange(location: 4, length: 4))
        #expect((box.string as NSString).substring(with: box.selectedRange()) == "bell")
    }

    @Test func jumpingToACaptionMatchSelectsTheImage() throws {
        let (body, _, imageAnchor) = try Self.richBody()
        let (stack, window) = try Self.editor(for: body)
        _ = window

        stack.revealImage(at: imageAnchor)

        #expect(stack.selectedImageLocation == imageAnchor)
    }

    /// A stale match — the text changed after the search — does nothing.
    @Test func aStaleSidebarJumpDoesNothing() throws {
        let (body, _, _) = try Self.richBody()
        let (stack, window) = try Self.editor(for: body)
        _ = window

        stack.revealSidebar(anchor: 0, selecting: NSRange(location: 0, length: 4))

        #expect(stack.enteredSidebarTextView == nil)
    }
}
