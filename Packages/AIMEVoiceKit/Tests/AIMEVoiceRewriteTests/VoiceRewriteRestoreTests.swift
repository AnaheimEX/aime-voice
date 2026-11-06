import AIMEVoice
import AIMEVoiceHost
import Foundation
import XCTest
@testable import AIMEVoiceHost

@MainActor final class VoiceRewriteRestoreTests: XCTestCase {
    private let dictated = "把海报发给我"
    private let span = NSRange(location: 2, length: 6)

    private struct Rig {
        let fake: FakeRewriteAccessibility
        let client: FakeTextInput
        let selection: VoiceRewriteSelection
    }

    /// Dictation lands in "你好", then the span is selected the way `prepare` does it.
    private func makeRecentDictation() async throws -> Rig {
                // The sandbox reports a secure-input session; silence the guard so the
        // dummy writer can open the flow.
        let probe = SecureEventInputShield.probe
        SecureEventInputShield.probe = { false }
        defer { SecureEventInputShield.probe = probe }
        let fake = FakeRewriteAccessibility(value: "你好", selection: NSRange(location: 2, length: 0))
        let client = FakeTextInput()
        let anchor = try XCTUnwrap(VoiceDictationAnchor.capture(client: client, accessibility: fake))
        fake.userEdits("你好" + dictated, selection: NSRange(location: 8, length: 0))
        let resolved = await anchor.resolve(sessionID: UUID(), transcript: dictated, committed: dictated, client: client)
        let origin = try XCTUnwrap(resolved)
        let selection = try XCTUnwrap(VoiceRewriteSelection(client: client, origin: origin, accessibility: fake))
        let prepared = await selection.prepare(in: client)
        XCTAssertTrue(prepared)
        XCTAssertEqual(fake.selection, span)
        return Rig(fake: fake, client: client, selection: selection)
    }

    private func assertNoTextWritten(_ fake: FakeRewriteAccessibility, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(fake.replaceSelectedTextCalls.isEmpty, file: file, line: line)
        XCTAssertTrue(fake.replaceValueCalls.isEmpty, file: file, line: line)
    }

    func testRestoreCollapsesCaretToSpanEndWithoutChangingText() async throws {
        let rig = try await makeRecentDictation()
        let before = rig.fake.selectCalls.count
        XCTAssertEqual(rig.selection.restoreCaretIfNeeded(client: rig.client), .restored)
        XCTAssertEqual(rig.fake.selectCalls.count, before + 1)
        XCTAssertEqual(rig.fake.selectCalls.last, NSRange(location: 8, length: 0))
        XCTAssertEqual(rig.fake.selection, NSRange(location: 8, length: 0))
        XCTAssertEqual(rig.fake.value, "你好" + dictated)
        assertNoTextWritten(rig.fake)
    }

    func testManualSelectionIsNeverTouched() async throws {
        // The sandbox reports a secure-input session; silence the guard so
        // the dummy voice isn't rejected on the nil-origin path.
        let probe = SecureEventInputShield.probe
        SecureEventInputShield.probe = { false }
        defer { SecureEventInputShield.probe = probe }
        let fake = FakeRewriteAccessibility(value: "你好" + dictated, selection: span)
        let client = FakeTextInput()
        let selection = try XCTUnwrap(VoiceRewriteSelection(client: client, accessibility: fake))
        XCTAssertFalse(selection.isRecentDictation)
        XCTAssertEqual(selection.restoreCaretIfNeeded(client: client), .notRecentDictation)
        XCTAssertTrue(fake.selectCalls.isEmpty)
        XCTAssertEqual(fake.selection, span)
    }

    func testFocusMovedToAnotherFieldDoesNothing() async throws {
        let rig = try await makeRecentDictation()
        let before = rig.fake.selectCalls.count
        rig.fake.focusNewField(value: "你好" + dictated, selection: span)
        XCTAssertEqual(rig.selection.restoreCaretIfNeeded(client: rig.client), .fieldChanged)
        XCTAssertEqual(rig.fake.selectCalls.count, before)
    }

    func testChangedFieldContentDoesNothing() async throws {
        let rig = try await makeRecentDictation()
        let before = rig.fake.selectCalls.count
        rig.fake.userEdits("你好" + dictated + "!", selection: span)
        XCTAssertEqual(rig.selection.restoreCaretIfNeeded(client: rig.client), .valueChanged)
        XCTAssertEqual(rig.fake.selectCalls.count, before)
    }

    func testSelectionNoLongerTheSpanDoesNothing() async throws {
        let rig = try await makeRecentDictation()
        let before = rig.fake.selectCalls.count
        rig.fake.userEdits("你好" + dictated, selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(rig.selection.restoreCaretIfNeeded(client: rig.client), .selectionChanged)
        XCTAssertEqual(rig.fake.selectCalls.count, before)
        XCTAssertEqual(rig.fake.selection, NSRange(location: 0, length: 0))
    }

    func testMissingClientDoesNothing() async throws {
        let rig = try await makeRecentDictation()
        let before = rig.fake.selectCalls.count
        XCTAssertEqual(rig.selection.restoreCaretIfNeeded(client: nil), .noClient)
        XCTAssertEqual(rig.fake.selectCalls.count, before)
    }

    func testBundleMismatchDoesNothing() async throws {
        let rig = try await makeRecentDictation()
        let before = rig.fake.selectCalls.count
        XCTAssertEqual(rig.selection.restoreCaretIfNeeded(client: FakeTextInput(bundle: "com.other.app")), .fieldChanged)
        XCTAssertEqual(rig.fake.selectCalls.count, before)
    }

    func testSuccessfullyInsertedSelectionIsNotRestored() async throws {
        let rig = try await makeRecentDictation()
        let rejection = await rig.selection.insert("把海报发我", into: rig.client)
        XCTAssertNil(rejection)
        let before = rig.fake.selectCalls.count
        XCTAssertEqual(rig.selection.restoreCaretIfNeeded(client: rig.client), .alreadyInserted)
        XCTAssertEqual(rig.fake.selectCalls.count, before)
        XCTAssertEqual(rig.fake.value, "你好把海报发我")
    }

    func testSecondRestoreIsIdempotent() async throws {
        let rig = try await makeRecentDictation()
        XCTAssertEqual(rig.selection.restoreCaretIfNeeded(client: rig.client), .restored)
        let after = rig.fake.selectCalls.count
        // Even if the user re-selects the span, the one allowed restore is spent.
        rig.fake.userEdits("你好" + dictated, selection: span)
        XCTAssertEqual(rig.selection.restoreCaretIfNeeded(client: rig.client), .alreadyRestored)
        XCTAssertEqual(rig.fake.selectCalls.count, after)
    }

    func testSelectFailureDoesNotThrowOrRetry() async throws {
        let rig = try await makeRecentDictation()
        let before = rig.fake.selectCalls.count
        rig.fake.selectSucceeds = false
        XCTAssertEqual(rig.selection.restoreCaretIfNeeded(client: rig.client), .selectFailed)
        XCTAssertEqual(rig.fake.selectCalls.count, before + 1)
        XCTAssertEqual(rig.selection.restoreCaretIfNeeded(client: rig.client), .alreadyRestored)
        XCTAssertEqual(rig.fake.selectCalls.count, before + 1)
        XCTAssertEqual(rig.fake.value, "你好" + dictated)
        XCTAssertEqual(rig.fake.selection, span)
        assertNoTextWritten(rig.fake)
    }

    func testPreconditionTable() {
        typealias Outcome = VoiceRewriteRestoreOutcome
        let rows: [(recent: Bool, inserted: Bool, restored: Bool, expected: Outcome?)] = [
            (true, false, false, nil),
            (false, false, false, .notRecentDictation),
            (false, true, true, .notRecentDictation),
            (true, true, false, .alreadyInserted),
            (true, true, true, .alreadyInserted),
            (true, false, true, .alreadyRestored),
        ]
        for row in rows {
            XCTAssertEqual(Outcome.precondition(isRecentDictation: row.recent, inserted: row.inserted,
                                                alreadyRestored: row.restored), row.expected, "\(row)")
        }
    }
}
