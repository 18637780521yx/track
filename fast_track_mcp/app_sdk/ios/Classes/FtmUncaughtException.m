#import "FtmUncaughtException.h"

static FtmExceptionBlock ftmHandler = nil;
static NSUncaughtExceptionHandler *ftmPrevious = NULL;

static void FtmUncaughtTrampoline(NSException *exception) {
  FtmExceptionBlock handler = ftmHandler;
  NSUncaughtExceptionHandler *previous = ftmPrevious;
  if (handler != nil) {
    handler(exception);
  }
  if (previous != NULL && previous != FtmUncaughtTrampoline) {
    previous(exception);
  }
}

void FtmUncaughtExceptionInstall(FtmExceptionBlock handler) {
  ftmHandler = [handler copy];
  NSUncaughtExceptionHandler *current = NSGetUncaughtExceptionHandler();
  if (current != FtmUncaughtTrampoline) {
    ftmPrevious = current;
  }
  NSSetUncaughtExceptionHandler(&FtmUncaughtTrampoline);
}

void FtmUncaughtExceptionUninstall(void) {
  NSUncaughtExceptionHandler *previous = ftmPrevious;
  ftmPrevious = NULL;
  ftmHandler = nil;
  if (NSGetUncaughtExceptionHandler() == FtmUncaughtTrampoline) {
    NSSetUncaughtExceptionHandler(previous);
  }
}
