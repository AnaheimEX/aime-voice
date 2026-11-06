import AIMEVoiceHost
import ObjCExceptionCatcher
import os
import XCTest

/// `NSException` from Objective-C: an uncaught throw aborts the process, so the
/// wrapper keeps the dangerous calls themselves guarded.
final class ObjCExceptionTests: XCTestCase {

    /// The caller never compiles an NSException.
    func testCatching() {
        let caught = ObjCException.catching { VFTestRaiseException() }
        let nsError = caught as? NSError
        XCTAssertNotNil(nsError, "an NSException must be delivered as an NSError")
        if let subject = nsError {
            XCTAssertEqual(subject.domain, "app.zool.aime.ObjCException")
            XCTAssertEqual(subject.userInfo["name"] as? String, "NSInvalidArgumentException")
            XCTAssertEqual(subject.localizedDescription, "test exception from Objective-C")
        }
    }

    /// The guarded call logs and returns false instead of aborting.
    func testGuardCallSwallows() {
        XCTAssertFalse(ObjCException.guardCall("raise") { VFTestRaiseException() })
    }
}
