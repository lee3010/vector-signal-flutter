import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'api_names.dart';
import 'vector_signal.dart';

/// Records every request made through a [Dio] client as a `$api` event:
/// method + path (see [ApiCallNames]), HTTP status and duration. Bodies,
/// headers and query strings are never read.
///
/// ```dart
/// dio.interceptors.add(VectorSignalDioInterceptor());
/// ```
class VectorSignalDioInterceptor extends Interceptor {
  static const _startKey = 'vector_signal.start';

  /// Hosts whose calls are not recorded.
  final Set<String> ignoreHosts;

  VectorSignalDioInterceptor({this.ignoreHosts = const {}});

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_startKey] = DateTime.now();
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    final code = response.statusCode;
    _record(response.requestOptions,
        statusCode: code, success: code != null && code >= 200 && code < 400);
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _record(err.requestOptions,
        statusCode: err.response?.statusCode, success: false);
    handler.next(err);
  }

  void _record(RequestOptions options,
      {required int? statusCode, required bool success}) {
    try {
      final start = options.extra[_startKey];
      if (start is! DateTime || ignoreHosts.contains(options.uri.host)) return;
      VectorSignal.trackApi(
        ApiCallNames.fromUri(options.method, options.uri),
        DateTime.now().difference(start),
        success: success,
        statusCode: statusCode,
      );
    } catch (_) {
      // Analytics must never break the app's requests.
    }
  }
}

/// Receives API calls recorded by the Android `VectorSignalOkHttpInterceptor`
/// (apps that call their API from Kotlin) and turns them into `$api` events.
class NativeApiBridge {
  NativeApiBridge._();

  static const MethodChannel _channel = MethodChannel('vector_signal/native');
  static bool _listening = false;

  /// Starts receiving. A no-op off Android or when the plugin isn't present.
  static Future<void> start() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      _channel.setMethodCallHandler(_handle);
      _listening = true;
      await _channel.invokeMethod<void>('ready');
    } catch (_) {
      // MissingPluginException in tests or apps without the Android part.
    }
  }

  static Future<void> stop() async {
    if (!_listening) return;
    _listening = false;
    try {
      _channel.setMethodCallHandler(null);
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
  }

  static Future<void> _handle(MethodCall call) async {
    if (call.method != 'api') return;
    final args = call.arguments;
    if (args is! Map) return;
    final name = args['name'];
    final durationMs = args['durationMs'];
    final success = args['success'];
    final statusCode = args['statusCode'];
    if (name is! String || durationMs is! int || success is! bool) return;
    VectorSignal.trackApi(
      name,
      Duration(milliseconds: durationMs),
      success: success,
      statusCode: statusCode is int ? statusCode : null,
    );
  }
}
