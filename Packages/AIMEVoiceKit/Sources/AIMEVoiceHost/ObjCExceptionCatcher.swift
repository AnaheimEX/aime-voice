public import Foundation
import ObjCExceptionCatcher
import os

/// Swift-facing wrapper. `nil` means the block completed normally.
public enum ObjCException {
    public static func catching(_ block: () -> Void) -> NSError? {
        // Imported from ObjC as `Error?`; narrow it back to NSError.
        VFPerformCatchingExceptions(block) as NSError?
    }

    /// Log and swallow. Use where a failure must not take the process down.
    @discardableResult
    public static func guardCall(_ label: String, _ block: () -> Void) -> Bool {
        if let error = catching(block) {
            Logger(subsystem: "app.zool.aime.voice", category: "objc").error(
                "\(label) raised \(String(describing: error.userInfo["name"] ?? "NSException")): \(error.localizedDescription)")
            return false
        }
        return true
    }
}
