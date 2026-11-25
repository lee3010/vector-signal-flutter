import 'package:dio/dio.dart';

/// What the queue should do with a batch after one send attempt.
enum VectorSignalSendStatus {
  /// Delivered - remove the batch from the queue.
  success,

  /// Temporary problem (network, 429, 5xx) - keep it and try again later.
  retry,

  /// The server rejected the batch itself (400) - remove it, retrying won't help.
  drop,

  /// The write key is wrong or revoked (401/403) - stop sending, keep the queue.
  unauthorized,
}

class VectorSignalSendResult {
  final VectorSignalSendStatus status;
  final int? statusCode;

  const VectorSignalSendResult(this.status, [this.statusCode]);
}

/// How event batches reach the backend. The default [HttpTransport] posts to
/// Vector Signal directly. A host app whose traffic must go through its own
/// backend can supply its own implementation instead.
abstract class VectorSignalTransport {
  Future<VectorSignalSendResult> send(List<Map<String, dynamic>> batch);
}

/// Posts batches to `{host}/v1/batch` with the project's write key.
/// Owns its own Dio instance so it never interferes with the host app's
/// HTTP setup (interceptors, auth headers).
class HttpTransport implements VectorSignalTransport {
  final String writeKey;
  final Dio _dio;

  HttpTransport({required this.writeKey, required String host, Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: host,
              connectTimeout: const Duration(seconds: 10),
              sendTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 15),
            ));

  @override
  Future<VectorSignalSendResult> send(List<Map<String, dynamic>> batch) async {
    try {
      final response = await _dio.post<dynamic>(
        '/v1/batch',
        data: {'batch': batch},
        options: Options(
          headers: {'X-VS-Write-Key': writeKey},
          contentType: Headers.jsonContentType,
          validateStatus: (_) => true,
        ),
      );
      return VectorSignalSendResult(
          classifyStatus(response.statusCode), response.statusCode);
    } on DioException {
      return const VectorSignalSendResult(VectorSignalSendStatus.retry);
    } catch (_) {
      return const VectorSignalSendResult(VectorSignalSendStatus.retry);
    }
  }

  /// Maps an HTTP status code to what the queue should do.
  static VectorSignalSendStatus classifyStatus(int? code) {
    if (code == null) return VectorSignalSendStatus.retry;
    if (code >= 200 && code < 300) return VectorSignalSendStatus.success;
    if (code == 401 || code == 403) return VectorSignalSendStatus.unauthorized;
    if (code == 400 || code == 413 || code == 422) {
      return VectorSignalSendStatus.drop;
    }
    return VectorSignalSendStatus.retry;
  }
}
