// ObjCExceptionCatcher.h
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, converting an Objective-C `NSException` into an `NSError`.
///
/// Swift cannot catch `NSException` at all — a throw from `NSPasteboard.writeObjects:`
/// or an AX call terminates the process. Those are exactly the APIs this app
/// leans on, so the risky calls go through here instead of killing the app.
/// Returns nil when the block completed normally.
FOUNDATION_EXPORT NSError * _Nullable VFPerformCatchingExceptions(void (NS_NOESCAPE ^block)(void));

/// Test helper: always raises an NSException.
FOUNDATION_EXPORT void VFTestRaiseException(void);

NS_ASSUME_NONNULL_END
