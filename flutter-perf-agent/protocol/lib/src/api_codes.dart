/// Business codes for [ApiResponse.code] (not HTTP status).
abstract final class ApiCodes {
  static const int ok = 0;
  static const int badRequest = 400;
  static const int unavailable = 503;
  static const int noSession = 1001;
  static const int skillError = 1002;
  static const int sleuthError = 1003;
  static const int actionFailed = 1004;
  static const int internal = 1500;
}
