import AIMEVoice
import AIMEVoiceHost
import Foundation
import XCTest
@testable import AIMEVoiceHost

@MainActor final class FakeRewriteAccessibilityTests: XCTestCase {
    func testReplaceSelectedTextUpdatesFocusedFieldValueAndCaret() throws {
        let fake = FakeRewriteAccessibility(value: "把海报发给我", selection: NSRange(location: 3, length: 2))
        let field = try XCTUnwrap(fake.focusedField())
        XCTAssertTrue(fake.replaceSelectedText("", in: field))
        let after = try XCTUnwrap(fake.focusedField())
        XCTAssertEqual(after.value, "把海报我")
        XCTAssertEqual(after.selection, NSRange(location: 3, length: 0))
        XCTAssertTrue(after.element === field.element)
    }

    func testReadsStayStaleForConfiguredPollsAndIneffectiveWritesChangeNothing() throws {
        let fake = FakeRewriteAccessibility(value: "abc", selection: NSRange(location: 0, length: 1))
        fake.pollsBeforeUpdate = 2
        let field = try XCTUnwrap(fake.focusedField())
        XCTAssertTrue(fake.replaceSelectedText("X", in: field))
        XCTAssertEqual(fake.focusedField()?.value, "abc")
        XCTAssertEqual(fake.focusedField()?.value, "abc")
        XCTAssertEqual(fake.focusedField()?.value, "Xbc")

        fake.replaceSelectedTextIsEffective = false
        fake.pollsBeforeUpdate = 0
        let again = try XCTUnwrap(fake.focusedField())
        XCTAssertTrue(fake.select(NSRange(location: 1, length: 1), in: again))
        let selected = try XCTUnwrap(fake.focusedField())
        XCTAssertTrue(fake.replaceSelectedText("Y", in: selected))
        XCTAssertEqual(fake.focusedField()?.value, "Xbc")
        XCTAssertEqual(fake.replaceSelectedTextCalls, ["X", "Y"])
    }

    func testFocusNewFieldChangesElementIdentity() throws {
        let fake = FakeRewriteAccessibility(value: "one")
        let first = try XCTUnwrap(fake.focusedField())
        fake.focusNewField(value: "two")
        let second = try XCTUnwrap(fake.focusedField())
        XCTAssertFalse(first.element === second.element)
        fake.hasFocusedField = false
        XCTAssertNil(fake.focusedField())
    }

    func testAnchorResolveThenSelectionPrepareWorkAgainstFakeAndTextInputStub() async throws {
        let fake = FakeRewriteAccessibility(value: "你好", selection: NSRange(location: 2, length: 0))
        // The sandbox reports a secure-input session; silence the guard so the
        // dummy writer can open the flow.
        let probe = SecureEventInputShield.probe
        SecureEventInputShield.probe = { false }
        defer { SecureEventInputShield.probe = probe }
        let client = FakeTextInput()
        let anchor = try XCTUnwrap(VoiceDictationAnchor.capture(client: client, accessibility: fake))
        fake.userEdits("你好把海报发给我", selection: NSRange(location: 8, length: 0))
        let resolved = await anchor.resolve(sessionID: UUID(), transcript: "把海报发给我",
                                            committed: "把海报发给我", client: client)
        let origin = try XCTUnwrap(resolved)
        XCTAssertEqual(origin.range, NSRange(location: 2, length: 6))
        XCTAssertEqual(VoiceRewriteSelection.targetFailureReason(client: client, origin: origin, accessibility: fake), .selectionInvalid)

        let selection = try XCTUnwrap(VoiceRewriteSelection(client: client, origin: origin, accessibility: fake))
        XCTAssertEqual(selection.text, "把海报发给我")
        XCTAssertTrue(selection.isRecentDictation)
        let prepared = await selection.prepare(in: client)
        XCTAssertTrue(prepared)
        XCTAssertEqual(fake.selection, NSRange(location: 2, length: 6))
        let rejection = await selection.insert("把海报发我", into: client)
        XCTAssertNil(rejection)
        XCTAssertEqual(fake.value, "你好把海报发我")
    }

    func testTargetFailureReasonFollowsTheSameBranchesAsTheFailureMessage() async throws {
        let fake = FakeRewriteAccessibility(value: "你好", selection: NSRange(location: 2, length: 0))
        // The sandbox reports a secure-input session; silence the guard so the
        // dummy writer can open the flow.
        let probe = SecureEventInputShield.probe
        SecureEventInputShield.probe = { false }
        defer { SecureEventInputShield.probe = probe }
        let client = FakeTextInput()
        let anchor = try XCTUnwrap(VoiceDictationAnchor.capture(client: client, accessibility: fake))
        fake.userEdits("你好世界", selection: NSRange(location: 4, length: 0))
        let resolved = await anchor.resolve(sessionID: UUID(), transcript: "世界", committed: "世界", client: client)
        let origin = try XCTUnwrap(resolved)

        XCTAssertEqual(VoiceRewriteSelection.targetFailureReason(client: client, origin: nil, accessibility: fake), .noOrigin)
        fake.userEdits("你好世界!", selection: NSRange(location: 5, length: 0))
        XCTAssertEqual(VoiceRewriteSelection.targetFailureReason(client: client, origin: origin, accessibility: fake), .originMismatch)
        fake.isSecure = true
        XCTAssertEqual(VoiceRewriteSelection.targetFailureReason(client: client, origin: origin, accessibility: fake), .fieldUnusable)
        fake.hasFocusedField = false
        XCTAssertEqual(VoiceRewriteSelection.targetFailureReason(client: client, origin: origin, accessibility: fake), .noFocusedField)
        fake.isTrusted = false
        XCTAssertEqual(VoiceRewriteSelection.targetFailureReason(client: client, origin: origin, accessibility: fake), .untrusted)
    }
}
