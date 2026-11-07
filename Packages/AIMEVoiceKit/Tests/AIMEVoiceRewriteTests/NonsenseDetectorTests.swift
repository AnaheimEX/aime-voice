import AIMEVoice
import XCTest

/// Unit tests for `NonsenseDetector`. The detector runs in `VoiceProcessor.process`
/// before the model is invoked.
final class NonsenseDetectorTests: XCTestCase {

    func testEmptyTranscriptIsNonsense() {
        XCTAssert(NonsenseDetector.isNonsense(""))
        XCTAssert(NonsenseDetector.isNonsense("   "))
    }

    func testOnlyPunctuation() {
        XCTAssert(NonsenseDetector.isNonsense("."))
        XCTAssert(NonsenseDetector.isNonsense("。"))
        XCTAssert(NonsenseDetector.isNonsense("!?"))
    }

    func testFillerWordsAreNonsense() {
        for word in NonsenseDetector.fillerWords {
            XCTAssert(NonsenseDetector.isNonsense(word))
            XCTAssert(NonsenseDetector.isNonsense(word + "."))
            XCTAssert(NonsenseDetector.isNonsense(" " + word + " "))
        }
    }

    func testShortFragments() {
        // A single character is still dictation in Chinese; filler noise is
        // rejected by the word list, not by a length floor.
        for word in ["你", "了", "点"] {
            XCTAssertFalse(NonsenseDetector.isNonsense(word))
        }
        for word in ["m", "啊", "嗯"] {
            XCTAssert(NonsenseDetector.isNonsense(word))
        }
    }

    func testRealUtterances() {
        XCTAssertFalse(NonsenseDetector.isNonsense("北京来到这里"))
        XCTAssertFalse(NonsenseDetector.isNonsense("你好世界"))
        XCTAssertFalse(NonsenseDetector.isNonsense("今天天气真好"))
        XCTAssertFalse(NonsenseDetector.isNonsense("请帮我打开"))
    }

    func testPunctuationDoesNotMakeItNonsense() {
        XCTAssertFalse(NonsenseDetector.isNonsense("你好。"))
        XCTAssertFalse(NonsenseDetector.isNonsense("请说。"))
        XCTAssertFalse(NonsenseDetector.isNonsense("是的，是的。"))
    }

    func testTrimming() {
        XCTAssertFalse(NonsenseDetector.isNonsense("\n \t 真的挺忙 \t\n"))
    }
}
