import 'dart:ui';

import 'package:flutter/foundation.dart';

/// Records uncaught Flutter and platform errors as `$error` events while
/// keeping whatever handlers were installed before (e.g. Firebase Crashlytics):
/// the previous handler is always called and its result returned.
class ErrorCapture {
  final void Function(String type, String message) onError;

  FlutterExceptionHandler? _previousFlutter;
  ErrorCallback? _previousPlatform;
  bool _installed = false;

  ErrorCapture(this.onError);

  static const int maxMessageLength = 300;

  void install() {
    if (_installed) return;
    _installed = true;

    _previousFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      _record(details.exception);
      final previous = _previousFlutter;
      if (previous != null) {
        previous(details);
      } else {
        FlutterError.presentError(details);
      }
    };

    _previousPlatform = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      _record(error);
      return _previousPlatform?.call(error, stack) ?? false;
    };
  }

  /// Puts the previous handlers back.
  void uninstall() {
    if (!_installed) return;
    FlutterError.onError = _previousFlutter;
    PlatformDispatcher.instance.onError = _previousPlatform;
    _installed = false;
  }

  void _record(Object error) {
    try {
      var message = error.toString();
      if (message.length > maxMessageLength) {
        message = message.substring(0, maxMessageLength);
      }
      onError(error.runtimeType.toString(), message);
    } catch (_) {
      // Never let error reporting cause another error.
    }
  }
}
