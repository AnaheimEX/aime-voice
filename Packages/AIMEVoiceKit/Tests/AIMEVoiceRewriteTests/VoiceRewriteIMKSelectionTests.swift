import AIMEVoice
import AIMEVoiceHost
import Foundation
import InputMethodKit
import XCTest

/// The IMK rewrite path serves apps that expose no focused control to AX (Qt and
/// web editors): the target span is proven only by IMK readback.
@MainActor final class VoiceRewriteIMKSelectionTests: XCTestCase {
    private let dictated = "把海报发给我"

    /// Faithful IMK client backed by a real text buffer: inserts replace the range,
    /// the caret moves past the inserted text, and readback reads the buffer.
    private final class FakeIMKClient: NSObject, IMKTextInput {
        var text: String
        var selected: NSRange
        let bundle = "com.example.editor"
        init(_ text: String, selected: NSRange) { self.text = text; self.selected = selected }

        func bundleIdentifier() -> String! { bundle }
        func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
        func selectedRange() -> NSRange { selected }
        func insertText(_ string: Any!, replacementRange: NSRange) {
            let replacement = string as? String ?? ""
            let ns = text as NSString
            let range = replacementRange.location == NSNotFound
                ? NSRange(location: ns.length, length: 0) : replacementRange
            text = ns.replacingCharacters(in: range, with: replacement)
            selected = NSRange(location: range.location + (replacement as NSString).length, length: 0)
        }
        func insertText(_ string: Any!) { insertText(string, replacementRange: NSRange(location: NSNotFound, length: 0)) }
        func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {}
        /// Qt clients such as QQ never answer a range read for an unselected span.
        var canReadRanges = true
        func attributedSubstring(from range: NSRange) -> NSAttributedString! {
            guard canReadRanges, range.location != NSNotFound, range.location >= 0,
                  NSMaxRange(range) <= (text as NSString).length else { return nil }
            return NSAttributedString(string: (text as NSString).substring(with: range))
        }
        func length() -> Int { (text as NSString).length }
        func characterIndex(for point: NSPoint, tracking mappingMode: IMKLocationToOffsetMappingMode,
                            inMarkedRange: UnsafeMutablePointer<ObjCBool>!) -> Int { NSNotFound }
        func attributes(forCharacterIndex index: Int, lineHeightRectangle lineRect: UnsafeMutablePointer<NSRect>!) -> [AnyHashable: Any]! { [:] }
        func firstRect(forCharacterRange aRange: NSRange, actualRange: NSRangePointer!) -> NSRect { .zero }
        func overrideKeyboard(withKeyboardNamed keyboardUniqueName: String!) {}
        func selectMode(_ modeIdentifier: String!) {}
        func supportsUnicode() -> Bool { true }
        func supportsProperty(_ property: UInt32) -> Bool { false }
        func uniqueClientIdentifierString() -> String! { "imk-fake" }
        func string(from range: NSRange, actualRange: NSRangePointer!) -> String! { nil }
        func windowLevel() -> CGWindowLevel { 0 }
        func validAttributesForMarkedText() -> [Any]! { [] }
    }

    func testRecentDictationRewritesByIMKReadback() async throws {
        // The user dictated into "你好": the buffer already holds the committed text
        // and the caret sits right after it.
        let client = FakeIMKClient("你好" + dictated, selected: NSRange(location: 8, length: 0))
        guard let origin = await VoiceIMKDictationOrigin.afterDictation(
            before: NSRange(location: 2, length: 0), text: dictated, transcript: dictated,
            sessionID: UUID(), client: client) else {
            XCTFail("afterDictation should resolve the committed span"); return
        }
        XCTAssertEqual(origin.range, NSRange(location: 2, length: 6))

        let selection = try XCTUnwrap(VoiceRewriteIMKSelection(client: client, imkOrigin: origin))
        XCTAssertEqual(selection.text, dictated)
        XCTAssertTrue(selection.isRecentDictation)
        let prepared = await selection.prepare(in: client)
        XCTAssertTrue(prepared)

        let posterRejection = await selection.insert("把海报发我", into: client)
        XCTAssertNil(posterRejection)
        XCTAssertEqual(client.text, "你好把海报发我")
        XCTAssertEqual(client.selected, NSRange(location: 7, length: 0))
        let next = try XCTUnwrap(selection.committedOrigin(sessionID: UUID(), transcript: dictated, client: client))
        XCTAssertEqual(next.range, NSRange(location: 2, length: 5))
        XCTAssertEqual(next.rendered, "把海报发我")
    }

    func testManualSelectionTargetsTheSelectedText() async throws {
        let client = FakeIMKClient("你好" + dictated, selected: NSRange(location: 2, length: 6))
        let selection = try XCTUnwrap(VoiceRewriteIMKSelection(client: client, imkOrigin: nil))
        XCTAssertEqual(selection.text, dictated)
        XCTAssertFalse(selection.isRecentDictation)
        XCTAssertFalse(selection.isSingleLine)
        let prepared = await selection.prepare(in: client)
        XCTAssertTrue(prepared)
    }

    func testChangedTextRevertsWithoutWriting() async throws {
        let client = FakeIMKClient("你好" + dictated, selected: NSRange(location: 8, length: 0))
        guard let origin = await VoiceIMKDictationOrigin.afterDictation(
            before: NSRange(location: 2, length: 0), text: dictated, transcript: dictated,
            sessionID: UUID(), client: client) else {
            XCTFail("afterDictation should resolve the committed span"); return
        }
        let selection = try XCTUnwrap(VoiceRewriteIMKSelection(client: client, imkOrigin: origin))
        // The app's text moved on after the rewrite started.
        client.text = "你好，新内容"
        let rejection = await selection.insert("把海报发我", into: client)
        XCTAssertEqual(rejection, .contextChanged)
        XCTAssertEqual(client.text, "你好，新内容")
        XCTAssertNil(selection.committedOrigin(sessionID: UUID(), transcript: dictated, client: client))
    }

    func testDeletionLeavesCaretAtSpanStart() async throws {
        let client = FakeIMKClient("你好" + dictated, selected: NSRange(location: 8, length: 0))
        guard let origin = await VoiceIMKDictationOrigin.afterDictation(
            before: NSRange(location: 2, length: 0), text: dictated, transcript: dictated,
            sessionID: UUID(), client: client) else {
            XCTFail("afterDictation should resolve the committed span"); return
        }
        let selection = try XCTUnwrap(VoiceRewriteIMKSelection(client: client, imkOrigin: origin))
        let deletionRejection = await selection.insert("", into: client, allowEmpty: true)
        XCTAssertNil(deletionRejection)
        XCTAssertEqual(client.text, "你好")
        XCTAssertEqual(client.selected, NSRange(location: 2, length: 0))
    }

    func testChainedRewriteAdvancesTheSpan() async throws {
        let client = FakeIMKClient("你好" + dictated, selected: NSRange(location: 8, length: 0))
        guard let origin = await VoiceIMKDictationOrigin.afterDictation(
            before: NSRange(location: 2, length: 0), text: dictated, transcript: dictated,
            sessionID: UUID(), client: client) else {
            XCTFail("afterDictation should resolve the committed span"); return
        }
        let first = try XCTUnwrap(VoiceRewriteIMKSelection(client: client, imkOrigin: origin))
        let firstRejection = await first.insert("把海报发我", into: client)
        XCTAssertNil(firstRejection)
        let advanced = try XCTUnwrap(origin.advanced(target: first, replacement: "把海报发我", client: client))
        XCTAssertEqual(advanced.rendered, "把海报发我")

        let second = try XCTUnwrap(VoiceRewriteIMKSelection(client: client, imkOrigin: advanced))
        XCTAssertTrue(second.isRecentDictation)
        XCTAssertEqual(second.text, "把海报发我")
        XCTAssertEqual(second.range, NSRange(location: 2, length: 5))
        let secondRejection = await second.insert("把海报发给我", into: client)
        XCTAssertNil(secondRejection)
        XCTAssertEqual(client.text, "你好" + dictated)
    }

    func testOwnsAndMatches() async throws {
        let client = FakeIMKClient("你好" + dictated, selected: NSRange(location: 8, length: 0))
        guard let origin = await VoiceIMKDictationOrigin.afterDictation(
            before: NSRange(location: 2, length: 0), text: dictated, transcript: dictated,
            sessionID: UUID(), client: client) else {
            XCTFail("afterDictation should resolve the committed span"); return
        }
        let selection = try XCTUnwrap(VoiceRewriteIMKSelection(client: client, imkOrigin: origin))
        XCTAssertTrue(origin.owns(selection, client: client))
        client.text = "别的文字" + dictated
        XCTAssertFalse(origin.matches(client: client))
    }

    func testInvalidOriginsAreRefused() throws {
        // No origin and no selection: nothing to rewrite.
        let client = FakeIMKClient(dictated, selected: NSRange(location: 6, length: 0))
        XCTAssertNil(VoiceRewriteIMKSelection(client: client, imkOrigin: nil))
        // An origin that no longer matches the buffer.
        let stale = VoiceIMKDictationOrigin(sessionID: UUID(), transcript: dictated, rendered: "旧文本",
                                            range: NSRange(location: 0, length: 3), bundleID: "com.example.editor")
        XCTAssertNil(VoiceRewriteIMKSelection(client: client, imkOrigin: stale))
    }

    // MARK: Unreadable clients (QQ)

    /// QQ answers no `attributedSubstring` for an unselected span, and its proxy returns
    /// stale carets outside event handling. The span must then be placed by arithmetic
    /// from the caret captured while the event was handled, and proven by the caret.
    func testUnreadableClientStillGetsADictationOrigin() async throws {
        let client = FakeIMKClient("你好", selected: NSRange(location: 2, length: 0))
        client.canReadRanges = false
        client.insertText(dictated, replacementRange: NSRange(location: NSNotFound, length: 0))
        let origin = await VoiceIMKDictationOrigin.afterDictation(
            before: NSRange(location: 2, length: 0), text: dictated, transcript: dictated,
            sessionID: UUID(), client: client)
        let resolved = try XCTUnwrap(origin, "a span this process inserted must still be placeable")
        XCTAssertEqual(resolved.range, NSRange(location: 2, length: 6))
        XCTAssertEqual(resolved.provenance, .caret)
        XCTAssertTrue(resolved.matches(client: client))
    }

    func testUnreadableClientRewritesAndAdvancesTheSpan() async throws {
        let client = FakeIMKClient("你好", selected: NSRange(location: 2, length: 0))
        client.canReadRanges = false
        client.insertText(dictated, replacementRange: NSRange(location: NSNotFound, length: 0))
        guard let origin = await VoiceIMKDictationOrigin.afterDictation(
            before: NSRange(location: 2, length: 0), text: dictated, transcript: dictated,
            sessionID: UUID(), client: client) else {
            XCTFail("afterDictation should place the committed span"); return
        }

        let selection = try XCTUnwrap(VoiceRewriteIMKSelection(client: client, imkOrigin: origin))
        XCTAssertEqual(selection.text, dictated)
        XCTAssertTrue(selection.isRecentDictation)
        let prepared = await selection.prepare(in: client)
        XCTAssertTrue(prepared)

        let rejection = await selection.insert("把海报发我", into: client)
        XCTAssertNil(rejection, "an unverifiable write must not be reported as a change")
        XCTAssertEqual(client.text, "你好把海报发我")

        let next = try XCTUnwrap(origin.advanced(target: selection, replacement: "把海报发我", client: client))
        XCTAssertEqual(next.rendered, "把海报发我")
        XCTAssertEqual(next.range, NSRange(location: 2, length: 5))
    }

    func testUnreadableClientStillRefusesAMovedCaret() async throws {
        let client = FakeIMKClient("你好", selected: NSRange(location: 2, length: 0))
        client.canReadRanges = false
        client.insertText(dictated, replacementRange: NSRange(location: NSNotFound, length: 0))
        guard let origin = await VoiceIMKDictationOrigin.afterDictation(
            before: NSRange(location: 2, length: 0), text: dictated, transcript: dictated,
            sessionID: UUID(), client: client) else {
            XCTFail("afterDictation should place the committed span"); return
        }
        // The user typed elsewhere: the caret no longer proves the span.
        client.selected = NSRange(location: 0, length: 0)
        XCTAssertFalse(origin.matches(client: client))
        XCTAssertNil(VoiceRewriteIMKSelection(client: client, imkOrigin: origin))
    }

    func testReadableClientStillFailsClosedOnChangedText() async throws {
        let client = FakeIMKClient("你好", selected: NSRange(location: 2, length: 0))
        client.insertText(dictated, replacementRange: NSRange(location: NSNotFound, length: 0))
        guard let origin = await VoiceIMKDictationOrigin.afterDictation(
            before: NSRange(location: 2, length: 0), text: dictated, transcript: dictated,
            sessionID: UUID(), client: client) else {
            XCTFail("afterDictation should place the committed span"); return
        }
        XCTAssertEqual(origin.provenance, .readback)
        let selection = try XCTUnwrap(VoiceRewriteIMKSelection(client: client, imkOrigin: origin))
        // Somebody else changed the text while the caret stayed put.
        client.text = "你好别的文字"
        XCTAssertFalse(origin.matches(client: client))
        let rejection = await selection.insert("把海报发我", into: client)
        XCTAssertEqual(rejection, .contextChanged)
        XCTAssertEqual(client.text, "你好别的文字")
    }
}
