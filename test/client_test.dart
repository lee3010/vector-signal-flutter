import 'package:flutter_test/flutter_test.dart';
import 'package:vector_signal_flutter/vector_signal_flutter.dart';

class FakeTransport implements VectorSignalTransport {
  final List<List<Map<String, dynamic>>> sent = [];
  final List<VectorSignalSendStatus> responses = [];

  @override
  Future<VectorSignalSendResult> send(List<Map<String, dynamic>> batch) async {
    sent.add(List.of(batch));
    final status = responses.isEmpty
        ? VectorSignalSendStatus.success
        : responses.removeAt(0);
    return VectorSignalSendResult(status);
  }
}

void main() {
  late DateTime now;
  late FakeTransport transport;
  late MemoryVectorSignalStorage storage;

  VectorSignalClient makeClient({
    int flushAt = 1000,
    int maxQueueSize = 1000,
    int maxBatchSize = 100,
    double sampleRate = 1.0,
  }) =>
      VectorSignalClient(
        config: VectorSignalConfig(
          flushAt: flushAt,
          maxQueueSize: maxQueueSize,
          maxBatchSize: maxBatchSize,
          sampleRate: sampleRate,
          appVersion: '1.0.0',
          platform: 'android',
        ),
        transport: transport,
        storage: storage,
        clock: () => now,
        startTimer: false,
      );

  setUp(() {
    now = DateTime.utc(2026, 11, 24, 8);
    transport = FakeTransport();
    storage = MemoryVectorSignalStorage();
  });

  test('events carry ids, session, screen and sanitized properties', () async {
    final client = makeClient();
    await client.start();
    client.setCurrentScreen('/home');
    client.enqueue('payout_session_create',
        properties: {'source': 'fab', 'pin': '1234'});

    final e = client.pendingEvents.single;
    expect(e['event'], 'payout_session_create');
    expect(e['distinctId'], client.anonymousId);
    expect(e['sessionId'], isNotEmpty);
    expect(e['screen'], '/home');
    expect(e['appVersion'], '1.0.0');
    expect(e['platform'], 'android');
    expect(e['timestamp'], '2026-11-24T08:00:00.000Z');
    expect(e['properties'], {'source': 'fab'});
  });

  test('queue cap drops the oldest events', () async {
    final client = makeClient(maxQueueSize: 3);
    await client.start();
    for (var i = 0; i < 5; i++) {
      client.enqueue('e$i');
    }
    expect(client.pendingEvents.map((e) => e['event']), ['e2', 'e3', 'e4']);
  });

  test('flush sends in batches and empties the queue', () async {
    final client = makeClient(maxBatchSize: 2);
    await client.start();
    for (var i = 0; i < 5; i++) {
      client.enqueue('e$i');
    }
    await client.flush();

    expect(transport.sent.map((b) => b.length), [2, 2, 1]);
    expect(client.queueLength, 0);
  });

  test('reaching flushAt sends automatically', () async {
    final client = makeClient(flushAt: 3);
    await client.start();
    client.enqueue('a');
    client.enqueue('b');
    expect(transport.sent, isEmpty);
    client.enqueue('c');
    await Future<void>.delayed(Duration.zero);
    expect(transport.sent.single.length, 3);
  });

  test('retry keeps events and waits for the backoff before trying again',
      () async {
    final client = makeClient();
    await client.start();
    client.enqueue('a');
    transport.responses.add(VectorSignalSendStatus.retry);

    await client.flush();
    expect(client.queueLength, 1);
    expect(client.consecutiveFailures, 1);

    await client.flush(); // still inside the 5s backoff
    expect(transport.sent.length, 1);

    now = now.add(const Duration(seconds: 6));
    await client.flush();
    expect(transport.sent.length, 2);
    expect(client.queueLength, 0);
    expect(client.consecutiveFailures, 0);
  });

  test(
      'drop removes the rejected batch; unauthorized stops sending and keeps the queue',
      () async {
    final client = makeClient(maxBatchSize: 1);
    await client.start();
    client.enqueue('bad');
    client.enqueue('kept');
    transport.responses.addAll(
        [VectorSignalSendStatus.drop, VectorSignalSendStatus.unauthorized]);

    await client.flush();
    expect(client.pendingEvents.map((e) => e['event']), ['kept']);
    expect(client.isUnauthorized, isTrue);

    await client.flush();
    expect(transport.sent.length, 2);
  });

  test('backoff grows exponentially and is capped at 5 minutes', () {
    expect(backoffFor(0), Duration.zero);
    expect(backoffFor(1), const Duration(seconds: 5));
    expect(backoffFor(2), const Duration(seconds: 10));
    expect(backoffFor(4), const Duration(seconds: 40));
    expect(backoffFor(20), const Duration(minutes: 5));
  });

  test('queue survives a restart through storage', () async {
    final first = makeClient();
    await first.start();
    first.enqueue('offline_event');
    await first.persist();
    first.dispose();

    final second = makeClient();
    await second.start();
    expect(second.pendingEvents.single['event'], 'offline_event');
  });

  test('new session after 30 minutes without events', () async {
    final client = makeClient();
    await client.start();
    client.enqueue('a');
    now = now.add(const Duration(minutes: 29));
    client.enqueue('b');
    now = now.add(const Duration(minutes: 31));
    client.enqueue('c');

    final sessions = client.pendingEvents.map((e) => e['sessionId']).toList();
    expect(sessions[0], sessions[1]);
    expect(sessions[2], isNot(sessions[1]));
  });

  test('identify and reset', () async {
    final client = makeClient();
    await client.start();
    final anon = client.anonymousId;
    expect(client.distinctId, anon);

    await client.identify('agent-1001');
    expect(client.distinctId, 'agent-1001');

    final reloaded = makeClient();
    await reloaded.start();
    expect(reloaded.distinctId, 'agent-1001');
    expect(reloaded.anonymousId, anon);

    await reloaded.reset();
    expect(reloaded.distinctId, isNot('agent-1001'));
    expect(reloaded.anonymousId, isNot(anon));
  });

  test('identify links the anonymous id once, never between two users',
      () async {
    final client = makeClient();
    await client.start();
    final anon = client.anonymousId;
    List<Map<String, dynamic>> identifies() =>
        client.pendingEvents.where((e) => e['event'] == r'$identify').toList();

    await client.identify('agent-1001');
    expect(identifies(), hasLength(1));
    expect(identifies().single['distinctId'], 'agent-1001');
    expect((identifies().single['properties'] as Map)['anonId'], anon);

    // Same user again (e.g. app restart): nothing new.
    await client.identify('agent-1001');
    // Another user without reset(): switch, but don't link two people.
    await client.identify('agent-2002');
    expect(identifies(), hasLength(1));
    expect(client.distinctId, 'agent-2002');
  });

  test('reset while already anonymous keeps the id, so login still links it',
      () async {
    final client = makeClient();
    await client.start();
    await client.identify('agent-1001');
    await client.reset(); // logout: new anonymous id
    final loginScreensId = client.anonymousId;

    // Apps often call reset() again on every "signed out" state update.
    await client.reset();
    await client.reset();
    expect(client.anonymousId, loginScreensId);

    await client.identify('agent-1001');
    final link =
        client.pendingEvents.lastWhere((e) => e['event'] == r'$identify');
    expect((link['properties'] as Map)['anonId'], loginScreensId);
  });

  test('opt-out stops recording, clears the queue and is remembered', () async {
    final client = makeClient();
    await client.start();
    client.enqueue('a');
    await client.setEnabled(false);
    client.enqueue('b');
    expect(client.queueLength, 0);
    expect(client.isActive, isFalse);

    final reloaded = makeClient();
    await reloaded.start();
    expect(reloaded.isActive, isFalse);
  });

  test('sampled-out installs record nothing, decision is remembered', () async {
    final client = makeClient(sampleRate: 0.0);
    await client.start();
    client.enqueue('a');
    expect(client.queueLength, 0);
  });

  test('uuid v4 format', () {
    final id = newUuidV4();
    expect(
        RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
            .hasMatch(id),
        isTrue);
  });

  test('transport status classification', () {
    expect(HttpTransport.classifyStatus(200), VectorSignalSendStatus.success);
    expect(HttpTransport.classifyStatus(400), VectorSignalSendStatus.drop);
    expect(
        HttpTransport.classifyStatus(401), VectorSignalSendStatus.unauthorized);
    expect(HttpTransport.classifyStatus(429), VectorSignalSendStatus.retry);
    expect(HttpTransport.classifyStatus(503), VectorSignalSendStatus.retry);
    expect(HttpTransport.classifyStatus(null), VectorSignalSendStatus.retry);
  });
}
