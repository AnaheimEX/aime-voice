import AIMEVoiceHost
import XCTest

/// Sanity for the crash-report format used by `CrashGuard`.
final class CrashLogTests: XCTestCase {

    func testReportIncludesFields() {
        let report = CrashLog.report(kind: .exception, name: "NSException", reason: "boom", stack: [])
        XCTAssertTrue(report.contains("time:"))
        XCTAssertTrue(report.contains("kind: exception"))
        XCTAssertTrue(report.contains("name: NSException"))
        XCTAssertTrue(report.contains("reason: boom"))
    }

    func testReportSkipsMissingFields() {
        let report = CrashLog.report(kind: .signal(Int32(4)), name: nil, reason: nil, stack: [])
        XCTAssertTrue(report.contains("kind: signal(4) SIGILL"))
        XCTAssertFalse(report.contains("name:"))
        XCTAssertFalse(report.contains("reason:"))
    }

    func testReportKeepsTheTrace() {
        let report = CrashLog.report(kind: .exception, name: "NSException", reason: "boom", stack: ["a", "b"])
        XCTAssertTrue(report.contains("trace:"))
        XCTAssertTrue(report.contains("b"))
    }

    func testOtherReportPaths() {
        if let url = try? CrashLog.newReportURL() {
            XCTAssertTrue(url.path.contains("/Library/Logs/AIME/"))
            XCTAssertTrue(CrashLog.sessionHeader().contains("pid:"))
        }
    }

    func testSignalNames() {
        let report = CrashLog.report(kind: .signal(SIGTRAP), name: nil, reason: nil, stack: [])
        XCTAssertTrue(report.contains("SIGTRAP"))
        XCTAssertFalse(report.contains("SIGABRT"))
    }
}
