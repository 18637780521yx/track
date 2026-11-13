#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^FtmExceptionBlock)(NSException *exception);

/// Installs the process uncaught-exception handler.
///
/// `NSSetUncaughtExceptionHandler` takes a C function pointer. Swift closures
/// and values loaded back out of a Swift property are not that pointer, so the
/// C function and the previous-handler chain stay on this side.
void FtmUncaughtExceptionInstall(FtmExceptionBlock _Nullable handler);

/// Restores the handler that was current before install.
void FtmUncaughtExceptionUninstall(void);

NS_ASSUME_NONNULL_END
