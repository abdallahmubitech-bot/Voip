import 'package:flutter/foundation.dart';

/// Tiny tagged logger. Debug-only so release builds never leak a call into
/// logcat; swap for `logger`/`talker` if you need persisted diagnostics.
class AppLogger {
  const AppLogger(this.tag);

  final String tag;

  void d(String message) {
    if (kDebugMode) {
      debugPrint('[D/$tag] $message');
    }
  }

  void i(String message) {
    if (kDebugMode) {
      debugPrint('[I/$tag] $message');
    }
  }

  void w(String message) {
    if (kDebugMode) {
      debugPrint('[W/$tag] $message');
    }
  }

  void e(String message, [Object? error, StackTrace? stackTrace]) {
    if (kDebugMode) {
      debugPrint('[E/$tag] $message${error == null ? '' : ' -> $error'}');
      if (stackTrace != null) {
        debugPrint(stackTrace.toString());
      }
    }
  }
}
