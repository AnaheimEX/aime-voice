#import "ObjCExceptionCatcher.h"

NSError *VFPerformCatchingExceptions(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        NSDictionary *info = @{
            NSLocalizedDescriptionKey: exception.reason ?: @"Objective-C exception",
            @"name": exception.name ?: @"NSException",
        };
        return [NSError errorWithDomain:@"app.zool.aime.ObjCException"
                                   code:1
                               userInfo:info];
    }
}

/// Test helper for the exception catcher: always raises an NSException.
void VFTestRaiseException(void) {
    @throw [NSException exceptionWithName:NSInvalidArgumentException
                                   reason:@"test exception from Objective-C"
                                 userInfo:@{ @"name": @"NSInvalidArgumentException" }];
}
