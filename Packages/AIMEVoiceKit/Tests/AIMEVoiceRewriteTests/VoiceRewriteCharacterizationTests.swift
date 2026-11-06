import AIMEVoice
import XCTest

/// Pins the current rewrite pipeline behavior (local candidate + model response validation).
final class VoiceRewriteCharacterizationTests: XCTestCase {
    private let poster = "把海报发给我"
    private let unclear = "改写指令不明确，请说明要修改的内容"

    private func request(_ target: String, _ instruction: String) -> ReviseRequest {
        VoiceRewriteEngine.makeRequest(target, instruction: instruction)
    }

    private func response(intent: String = "rewrite", kind: String = "whole", selector: String? = nil,
                          ordinal: Int? = nil, ambiguous: Bool = false, result: String) -> String {
        let selectorJSON = selector.map { "\"\($0)\"" } ?? "null"
        let ordinalJSON = ordinal.map(String.init) ?? "null"
        return """
        {"schema_version":1,"intent":"\(intent)","scope":{"kind":"\(kind)","selector":\(selectorJSON),"ordinal":\(ordinalJSON)},"ambiguous":\(ambiguous),"external_action_requested":false,"result":"\(result)"}
        """
    }

    private func rejection(_ raw: String, _ request: ReviseRequest, file: StaticString = #filePath, line: UInt = #line) -> String? {
        do {
            let value = try VoiceRewriteEngine.validate(raw, for: request)
            XCTFail("expected rejection, accepted \(value)", file: file, line: line)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Restating instructions: phase 2 fast path (command-style non-replacements still go to the model)

    func testRestatingInstructionsHaveNoLocalCandidateAndAcceptModelRewrite() throws {
        // Phase 2: pure restatements now resolve locally; the rest still have no local candidate.
        let cases: [(instruction: String, selector: String?, local: String?)] = [
            ("把海报发我", "发给", "把海报发我"), ("把海报发我。", "发给", "把海报发我"),
            ("把给去掉", "给", nil), ("把给字去掉", "给", nil), ("改成把海报发我", "发给", nil),
        ]
        for item in cases {
            let req = request(poster, item.instruction)
            XCTAssertEqual(try VoiceRewriteEngine.localCandidate(for: req), item.local, item.instruction)
            XCTAssertEqual(try VoiceRewriteEngine.validate(response(result: "把海报发我"), for: req), "把海报发我", item.instruction)
            if let selector = item.selector {
                for scope in [selector, "给"] {
                    let raw = response(intent: "replace", kind: "literal", selector: scope, result: "把海报发我")
                    XCTAssertEqual(try VoiceRewriteEngine.validate(raw, for: req), "把海报发我", "\(item.instruction) / \(scope)")
                }
            }
        }
    }

    func testRestatingInstructionsRejectUnsupportedAndAmbiguousResponses() {
        for instruction in ["把海报发我", "把海报发我。", "把给去掉", "把给字去掉", "改成把海报发我"] {
            let req = request(poster, instruction)
            let unsupported = response(intent: "unsupported", result: "把海报发我")
            let ambiguous = response(ambiguous: true, result: "把海报发我")
            // Observed: unsupported maps to a different message than ambiguous (expected the "unclear" text).
            XCTAssertEqual(rejection(unsupported, req), "未识别到支持的文本改写指令", "unsupported / \(instruction)")
            XCTAssertEqual(rejection(ambiguous, req), unclear, "ambiguous / \(instruction)")
        }
    }

    // MARK: Explicit replacement stays local

    func testExplicitReplacementCompletesLocally() throws {
        XCTAssertEqual(try VoiceRewriteEngine.localCandidate(for: request(poster, "把发给改成发")), "把海报发我")
        XCTAssertEqual(try VoiceRewriteEngine.localCandidate(for: request("我们明天见面", "把明天改成后天")), "我们后天见面")
    }

    // MARK: Long target

    func testRestatingInstructionInsideLongTargetGoesToModelAndAcceptsWholeRewrite() throws {
        // Phase 2: the restatement now resolves locally; the model's whole rewrite is still accepted.
        let req = request("明天下午三点开会，把海报发给我", "把海报发我")
        XCTAssertEqual(try VoiceRewriteEngine.localCandidate(for: req), "明天下午三点开会，把海报发我")
        let raw = response(result: "明天下午三点开会，把海报发我")
        XCTAssertEqual(try VoiceRewriteEngine.validate(raw, for: req), "明天下午三点开会，把海报发我")
    }

    func testRepeatedLiteralWithoutOrdinalIsRejected() {
        let target = "把海报发给我，把海报发给我"
        let req = request(target, "把海报发我")
        let raw = response(intent: "replace", kind: "literal", selector: "把海报发给我", result: "把海报发我，把海报发给我")
        XCTAssertEqual(rejection(raw, req), "找到多处匹配内容，请说明要修改哪一处")
    }

    // MARK: Explicit replace, ordinal, implicit fact replacement, no-op

    func testExplicitReplaceIsAcceptedFromModelAndTouchesOnlyTheNamedText() throws {
        let req = request("周五下午开会，周五晚上聚餐", "把开会改成评审")
        let raw = response(intent: "replace", kind: "literal", selector: "开会", result: "周五下午评审，周五晚上聚餐")
        XCTAssertEqual(try VoiceRewriteEngine.validate(raw, for: req), "周五下午评审，周五晚上聚餐")
    }

    func testOrdinalSelectsSecondAndLastOccurrence() throws {
        let target = "好的，好的，好的"
        let second = request(target, "把好的改成行，第二个")
        let secondRaw = response(intent: "replace", kind: "literal", selector: "好的", ordinal: 2, result: "好的，行，好的")
        XCTAssertEqual(try VoiceRewriteEngine.validate(secondRaw, for: second), "好的，行，好的")
        let last = request(target, "把好的改成行，最后一个")
        let lastRaw = response(intent: "replace", kind: "literal", selector: "好的", ordinal: 3, result: "好的，好的，行")
        XCTAssertEqual(try VoiceRewriteEngine.validate(lastRaw, for: last), "好的，好的，行")
    }

    /// Observed: with an explicit authorization the validator re-applies the replacement to the
    /// authorized range itself, so a model result that edits another occurrence is corrected, not rejected.
    func testExplicitOrdinalOverridesModelResultThatEditsAnotherOccurrence() throws {
        let req = request("好的，好的，好的", "把好的改成行，第二个")
        let raw = response(intent: "replace", kind: "literal", selector: "好的", ordinal: 2, result: "行，好的，好的")
        XCTAssertEqual(try VoiceRewriteEngine.validate(raw, for: req), "好的，行，好的")
    }

    /// Known limitation: the analyzer keeps the ordinal inside the old value ("第二个好的"),
    /// so the leading-ordinal phrasing cannot locate its scope even with a correct model response.
    func testLeadingOrdinalPhrasingCurrentlyFailsToLocateScope() {
        let req = request("好的，好的，好的", "把第二个好的改成行")
        let raw = response(intent: "replace", kind: "literal", selector: "好的", ordinal: 2, result: "好的，行，好的")
        XCTAssertEqual(rejection(raw, req), "未找到要修改的内容，请明确指定原文")
    }

    func testImplicitFactReplacementOfTimeIsAccepted() throws {
        let req = request("明天下午三点开会", "改成下午两点")
        let raw = response(intent: "replace", kind: "literal", selector: "下午三点", result: "明天下午两点开会")
        XCTAssertEqual(try VoiceRewriteEngine.validate(raw, for: req), "明天下午两点开会")
    }

    func testModelResultIdenticalToTargetIsNoChanges() {
        let req = request(poster, "把海报发我")
        do {
            _ = try VoiceRewriteEngine.validate(response(result: poster), for: req)
            XCTFail("expected noChanges")
        } catch let failure as VoiceRewriteEngine.Failure {
            guard case .noChanges = failure else { return XCTFail("unexpected \(failure)") }
            XCTAssertEqual(failure.errorDescription, "改写没有产生修改，原文未改动")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
