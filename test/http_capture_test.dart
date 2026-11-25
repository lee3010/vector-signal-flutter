import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_signal_flutter/vector_signal_flutter.dart';

class _NullTransport implements VectorSignalTransport {
  @override
  Future<VectorSignalSendResult> send(List<Map<String, dynamic>> batch) async =>
      const VectorSignalSendResult(VectorSignalSendStatus.success);
}

/// Answers every request locally with [statusCode], so no network is used.
class _FakeAdapter implements HttpClientAdapter {
  final int statusCode;
  _FakeAdapter(this.statusCode);

  @override
  Future<ResponseBody> fetch(RequestOptions options,
          Stream<List<int>>? requestStream, Future<void>? cancelFuture) async =>
      ResponseBody.fromString('{}', statusCode, headers: {
        Headers.contentTypeHeader: ['application/json']
      });

  @override
  void close({bool force = false}) {}
}

Future<void> _init() => VectorSignal.init(
      writeKey: 'test',
      host: 'http://localhost',
      transport: _NullTransport(),
      storage: MemoryVectorSignalStorage(),
      captureErrors: false,
    );

List<Map<String, dynamic>> _apiEvents() => VectorSignal.client!.pendingEvents
    .where((e) => e['event'] == r'$api')
    .toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ApiCallNames', () {
    test('keeps words, replaces ids, drops the query', () {
      expect(
          ApiCallNames.fromUri(
              'get', Uri.parse('https://x/api/Agent/AGA003?pin=1234')),
          'GET /api/Agent/{id}');
      expect(
          ApiCallNames.name('POST', [
            'api',
            'v1',
            'Payout',
            '6f6602b0e6844572a7afa632d2052eb6',
            'cancel'
          ]),
          'POST /api/v1/Payout/{id}/cancel');
      expect(ApiCallNames.name('GET', ['api', 'User', 'someone@example.com']),
          'GET /api/User/{id}');
      expect(ApiCallNames.name('GET', const []), 'GET /');
    });
  });

  test('Dio interceptor records method, path and status, never the query',
      () async {
    await _init();
    final dio = Dio()
      ..httpClientAdapter = _FakeAdapter(200)
      ..interceptors.add(VectorSignalDioInterceptor());

    await dio.get<dynamic>('https://api.example.com/api/Wallet/AGA003',
        queryParameters: {'account': '123'});

    final api = _apiEvents().single['properties'] as Map;
    expect(api['name'], 'GET /api/Wallet/{id}');
    expect(api['success'], true);
    expect(api['statusCode'], 200);
    expect(api.toString(), isNot(contains('123')));
    VectorSignal.shutdown();
  });

  test('Dio interceptor records failed calls', () async {
    await _init();
    final dio = Dio()
      ..httpClientAdapter = _FakeAdapter(500)
      ..interceptors.add(VectorSignalDioInterceptor());

    await expectLater(
        dio.post<dynamic>('https://api.example.com/api/Payout/create'),
        throwsA(isA<DioException>()));

    final api = _apiEvents().single['properties'] as Map;
    expect(api['name'], 'POST /api/Payout/create');
    expect(api['success'], false);
    expect(api['statusCode'], 500);
    VectorSignal.shutdown();
  });

  test('native bridge turns Android OkHttp calls into \$api events', () async {
    await _init();
    const codec = StandardMethodCodec();
    final message = codec.encodeMethodCall(const MethodCall('api', {
      'name': 'GET /api/Inbox/unread-count',
      'durationMs': 4207,
      'success': true,
      'statusCode': 200,
    }));
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage('vector_signal/native', message, (_) {});

    final api = _apiEvents().single['properties'] as Map;
    expect(api['name'], 'GET /api/Inbox/unread-count');
    expect(api['durationMs'], 4207);
    expect(api['statusCode'], 200);
    VectorSignal.shutdown();
  });
}
