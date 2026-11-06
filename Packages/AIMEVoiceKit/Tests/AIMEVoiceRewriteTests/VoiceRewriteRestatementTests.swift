@testable import AIMEVoice
import XCTest

final class VoiceRewriteRestatementTests: XCTestCase {
    private typealias Case = (target: String, instruction: String, expected: String?)

    private func run(_ cases: [Case], file: StaticString = #filePath, line: UInt = #line) {
        for item in cases {
            XCTAssertEqual(VoiceRewriteRestatement.candidate(target: item.target, instruction: item.instruction),
                           item.expected, "\(item.target) / \(item.instruction)", file: file, line: line)
        }
    }

    // MARK: Hits

    func testRestatementHitsAndKeepsTargetPunctuation() {
        run([
            ("把海报发给我", "把海报发我", "把海报发我"),
            ("把海报发给我", "把海报发我。", "把海报发我"),
            ("把海报发给我", "把海报发我吧", "把海报发我"),
            ("把海报发给我", "把海报发我吧。", "把海报发我"),
            ("明天下午三点开会，把海报发给我", "把海报发我", "明天下午三点开会，把海报发我"),
            ("把海报发给我。", "把海报发我", "把海报发我。"),
            // Pure deletion and pure insertion inside a longer target, outer punctuation kept.
            ("我们明天去大公园玩，然后吃饭", "我们明天去公园玩", "我们明天去公园玩，然后吃饭"),
            ("我们明天去公园玩，然后吃饭", "我们明天去公园玩耍", "我们明天去公园玩耍，然后吃饭"),
        ])
    }

    /// A substitution is a heuristic too far (it can swap words the fact checks do not see): the model decides.
    func testSubstitutionsAreLeftToTheModel() {
        run([
            ("我们明天去公园玩，然后吃饭", "我们明天去商场玩", nil),
            ("请把今天的海报交给张老师", "请把今天的海报交给李老师", nil),
            ("看看我的画", "看看他的画", nil),
            ("我们去公园玩耍", "我们去商园玩耍", nil),
            ("今天我们一起去公园玩", "今天我们一起去商场玩", nil),
            ("这件事很重要", "这件事非常重要", nil),
        ])
    }

    func testPureDeletionOrInsertionGate() {
        let gate = { (a: String, b: String) in VoiceRewriteRestatement.isPureDeletionOrInsertion(from: Array(a), to: Array(b)) }
        XCTAssertTrue(gate("abcd", "abd"))   // deletion
        XCTAssertTrue(gate("abd", "abcd"))   // insertion
        XCTAssertFalse(gate("abcd", "abxd")) // substitution
        XCTAssertFalse(gate("abcd", "axbd")) // deletion plus insertion
        XCTAssertFalse(gate("abcd", "abcd")) // no change
    }

    // MARK: Misses

    func testRestatementMisses() {
        run([
            ("把海报发给我，把海报发给我", "把海报发我", nil),            // window repeated: two disjoint matches
            ("今天天气很好适合出门", "请帮我订一张机票", nil),            // unrelated
            ("把海报发给我", "把海报发给我", nil),                       // d = 0
            ("把海报发给我", "把海报发给我吧", nil),                     // d = 0 once the particle is dropped
            ("今天我们去公园玩", "把海报发给我", nil),
            ("把海报发给我", "发我", nil),                              // m < 4
            ("把海报发给我", "发给我", nil),                            // m < 4
            ("把海报发给我", String(repeating: "把海报发我", count: 17), nil), // m > 80
            ("我想去公园", "我不想去公园", nil),                         // d = 1 but negation appears
            ("明天下午三点开会", "明天下午四点开会", nil),               // number changed
            ("会议室在三楼", "会议室在四楼", nil),                       // Chinese numeral changed
            ("把海报发给我", "把给去掉", nil),                          // command-style
            ("把海报发给我", "把给字去掉", nil),
            ("把海报发给我", "改成把海报发我", nil),
            ("好的，好的，好的", "好的，好的，好", nil),
            ("把海报发给我，然后明天见", "把海报发我，最后一个", nil),     // ordinal
        ])
    }

    func testTargetOverLimitGoesToModel() {
        let target = String(repeating: "字", count: 2000) + "把海报发给我"
        XCTAssertNil(VoiceRewriteRestatement.candidate(target: target, instruction: "把海报发我"))
    }

    // MARK: Thresholds

    func testDistanceThresholdBoundary() {
        run([
            // m = 12 -> limit 3: three deletions pass, four fail.
            ("请把今天的所有海报都交给张老师", "请把今天的海报交给张老师", "请把今天的海报交给张老师"),
            ("请把今天的所有的海报都交给张老师", "请把今天的海报交给张老师", nil),
            // m = 5 -> limit 1: one deletion passes, three fail.
            ("把海报发给我", "把海报发我", "把海报发我"),
            ("把那份海报发给我", "把海报发我", nil),
            // m = 7 -> limit 1: one deletion and one insertion pass, two fail.
            ("我们去大公园玩耍", "我们去公园玩耍", "我们去公园玩耍"),
            ("我们去公园玩", "我们去公园玩耍", "我们去公园玩耍"),
            ("我们去大大公园玩耍", "我们去公园玩耍", nil),
            // m = 10 -> limit 2: two deletions pass, three fail.
            ("今天我们一起都去大公园玩", "今天我们一起去公园玩", "今天我们一起去公园玩"),
            ("今天我们一起都去大的公园玩", "今天我们一起去公园玩", nil),
        ])
    }

    func testEquivalentOverlappingWindowsAreRefused() {
        // "玩" and "玩耍" are equally good matches for "玩乐": replacing either would leave a stray character.
        run([("我们去公园玩耍", "我们去公园玩乐", nil)])
        let optimal = VoiceRewriteRestatement.optimalWindows(pattern: Array("我们去公园玩乐"), text: Array("我们去公园玩耍"))
        XCTAssertEqual(optimal?.count, 2)
    }

    func testMaxDistanceFormula() {
        let limits = [4: 1, 7: 1, 8: 2, 11: 2, 12: 3, 80: 20]
        for (m, expected) in limits {
            XCTAssertEqual(max(VoiceRewriteRestatement.Limits.maxDistanceFloor, m / VoiceRewriteRestatement.Limits.maxDistanceDivisor), expected, "m=\(m)")
        }
    }

    // MARK: Tie rule and uniqueness

    func testBestWindowTieRuleShortestThenEarliest() {
        let chars = { (s: String) in Array(s) }
        // "abdd": "abd" (one deletion) and "abdd" (one substitution) both cost 1 with 3 matches -> shorter wins.
        let shorter = VoiceRewriteRestatement.bestWindow(pattern: chars("abcd"), text: chars("abdd"))
        XCTAssertEqual(shorter, .init(start: 0, end: 3, distance: 1))
        // Equal windows overlapping: earliest wins.
        let earliest = VoiceRewriteRestatement.bestWindow(pattern: chars("abab"), text: chars("ababab"))
        XCTAssertEqual(earliest, .init(start: 0, end: 4, distance: 0))
        // More exact matches beat a shorter window of equal distance.
        let matched = VoiceRewriteRestatement.bestWindow(pattern: chars("abcd"), text: chars("abcXd"))
        XCTAssertEqual(matched, .init(start: 0, end: 5, distance: 1))
    }

    func testEquivalentWindowsInOneRegionPickTheFullPhrase() {
        // "把海报发给" and "把海报发给我" are both one edit away; the one matching every character wins,
        // so the stray "我" is not left behind.
        XCTAssertEqual(VoiceRewriteRestatement.candidate(target: "把海报发给我", instruction: "把海报发我"), "把海报发我")
    }

    func testTwoEquivalentDisjointWindowsAreAmbiguous() {
        run([
            ("把海报发给我，再把海报发给你", "把海报发我", nil),
            ("把海报发给我，把海报发给我", "把海报发我", nil),
        ])
    }

    func testUniquenessBoundary() {
        let pattern = Array("把海报发我")
        let text = Array("把海报发给我，把海报发给他")
        let first = VoiceRewriteRestatement.bestWindow(pattern: pattern, text: text)!
        XCTAssertFalse(VoiceRewriteRestatement.isUnique(first, pattern: pattern, text: text))
        let single = Array("把海报发给我，今天下雨")
        let only = VoiceRewriteRestatement.bestWindow(pattern: pattern, text: single)!
        XCTAssertTrue(VoiceRewriteRestatement.isUnique(only, pattern: pattern, text: single))
    }

    // MARK: Boundary handling

    func testNormalization() {
        XCTAssertEqual(VoiceRewriteRestatement.trimmingBoundary(" 把海报发我吧。 "), "把海报发我吧")
        XCTAssertEqual(VoiceRewriteRestatement.normalizedVariants(of: "把海报发我吧"), ["把海报发我吧", "把海报发我"])
        XCTAssertEqual(VoiceRewriteRestatement.normalizedVariants(of: "把海报发我"), ["把海报发我"])
    }

    func testWindowDoesNotSwallowTargetPunctuation() {
        // The speaker's leading punctuation is dropped, and the comma in the target stays put.
        XCTAssertEqual(VoiceRewriteRestatement.candidate(target: "今天，海报发给我", instruction: "海报发我"), "今天，海报发我")
    }

    // MARK: Validator rejection is swallowed

    func testValidatorRejectionReturnsNilInsteadOfThrowing() throws {
        // The fast path swallows validator rejections: with a URL in the window the heuristic must bail out,
        // and the engine falls through to the model without an error.
        let target = "详情见 https://a.example/x 谢谢"
        let instruction = "详情见 https://b.example/x 谢谢"
        XCTAssertNil(VoiceRewriteRestatement.candidate(target: target, instruction: instruction))
        let request = VoiceRewriteEngine.makeRequest(target, instruction: instruction)
        XCTAssertNil(try VoiceRewriteEngine.localResolution(for: request))
    }

    func testRejectedValidatorResultMapsToNil() {
        // A multi-line target with a single-line control: the validator refuses a candidate with newline.
        let target = "第一行\n把海报发给我"
        let request = ReviseRequest(targetText: target, instruction: "第一行\n把海报发我", controlKind: .singleLine,
                                    sourceLanguage: ReviseLanguageProfile.detect(in: target), sourceModeKind: .voicePolish)
        XCTAssertNil(VoiceRewriteRestatement.candidate(for: request))
    }

    // MARK: Engine layer

    func testEngineClassifiesResolutions() throws {
        let poster = "把海报发给我"
        let explicit = VoiceRewriteEngine.makeRequest(poster, instruction: "把发给改成发")
        XCTAssertEqual(try VoiceRewriteEngine.localResolution(for: explicit), .explicit("把海报发我"))
        let restated = VoiceRewriteEngine.makeRequest(poster, instruction: "把海报发我")
        XCTAssertEqual(try VoiceRewriteEngine.localResolution(for: restated), .restatement("把海报发我"))
        XCTAssertEqual(try VoiceRewriteEngine.localCandidate(for: explicit), "把海报发我")
        XCTAssertEqual(try VoiceRewriteEngine.localCandidate(for: restated), "把海报发我")
        let unrelated = VoiceRewriteEngine.makeRequest(poster, instruction: "今天天气怎么样")
        XCTAssertNil(try VoiceRewriteEngine.localResolution(for: unrelated))
    }

    func testExplicitRejectionStillThrowsAndSkipsRestatement() {
        // Explicit replacement with a validator rejection (newline in a single-line field) still throws, no restatement fallback.
        let request = VoiceRewriteEngine.makeRequest("明天见\n后天见", instruction: "把明天改成后天", singleLine: true)
        XCTAssertThrowsError(try VoiceRewriteEngine.localResolution(for: request))
    }

    // MARK: Performance smoke

    func testLargeTargetPerformance() {
        let target = String((0..<2000).map { Character(UnicodeScalar(0x4E00 + ($0 * 7) % 3000)!) })
        let pattern = String(target.dropFirst(500).prefix(80))
        let instruction = "x" + pattern.dropFirst()
        let start = ContinuousClock.now
        let result = VoiceRewriteRestatement.candidate(target: target, instruction: String(instruction))
        let elapsed = start.duration(to: .now)
        print("restatement perf (2000 chars target, 80 chars instruction): \(elapsed), result nil=\(result == nil)")
        XCTAssertLessThan(elapsed, .seconds(1))
    }
}
