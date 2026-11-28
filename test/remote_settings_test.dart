import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_signal_flutter/vector_signal_flutter.dart';

class _NullTransport implements VectorSignalTransport {
  @override
  Future<VectorSignalSendResult> send(List<Map<String, dynamic>> batch) async =>
      const VectorSignalSendResult(VectorSignalSendStatus.success);
}

/// Answers with [settings]; null = offline.
class _FakeSource implements VectorSignalSettingsSource {
  ProjectSettings? settings;
  int calls = 0;
  _FakeSource(this.settings);

  @override
  Future<ProjectSettings?> fetch() async {
    calls++;
    return settings;
  }
}

ProjectSettings _replay(bool enabled,
        {double sampleRate = 0.1, double onStruggle = 1}) =>
    ProjectSettings(
      replay: ReplaySettings(
          enabled: enabled,
          sampleRate: sampleRate,
          onStruggleSampleRate: onStruggle),
    );

Future<void> _init(WidgetTester tester, MemoryVectorSignalStorage storage,
    _FakeSource source) async {
  await tester.runAsync(() async {
    await VectorSignal.init(
      writeKey: 'test',
      host: 'http://localhost',
      transport: _NullTransport(),
      storage: storage,
      captureErrors: false,
      captureNativeApi: false,
      settingsSource: source,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });
  await tester.pumpWidget(const MaterialApp(home: SizedBox()));
}

void main() {
  test('settings JSON: missing or bad values mean replay off', () {
    final s = ProjectSettings.fromJson({
      'replay': {'enabled': true, 'sampleRate': 3, 'onStruggleSampleRate': -1}
    });
    expect(s.replay.sampleRate, 1);
    expect(s.replay.onStruggleSampleRate, 0);
    expect(s.replay.records, isTrue);
    expect(ProjectSettings.fromJson({}).replay.records, isFalse);
    expect(
        ProjectSettings.fromJson({
          'replay': {'enabled': false, 'sampleRate': 1}
        }).replay.records,
        isFalse);
  });

  testWidgets('replay stays off until settings were loaded once',
      (tester) async {
    final storage = MemoryVectorSignalStorage();
    await _init(tester, storage, _FakeSource(null));
    expect(VectorSignal.replay, isNull);
    expect(VectorSignal.settings, isNull);
    VectorSignal.shutdown();
  });

  testWidgets('replay turned on in the dashboard starts with its rates',
      (tester) async {
    final storage = MemoryVectorSignalStorage();
    final source = _FakeSource(_replay(true, sampleRate: 0, onStruggle: 1));
    await _init(tester, storage, source);
    expect(source.calls, 1);
    expect(VectorSignal.replay, isNotNull);
    expect(VectorSignal.replay!.config.sampleRate, 0);
    expect(VectorSignal.replay!.config.onStruggleSampleRate, 1);
    // Saved for the next start (and for offline starts).
    expect(await ProjectSettings.load(storage), isNotNull);
    VectorSignal.shutdown();
  });

  testWidgets('offline start uses the saved settings', (tester) async {
    final storage = MemoryVectorSignalStorage();
    await _replay(true).save(storage);
    await _init(tester, storage, _FakeSource(null));
    expect(VectorSignal.replay, isNotNull);
    expect(VectorSignal.replay!.config.sampleRate, 0.1);
    VectorSignal.shutdown();
  });

  testWidgets('replay turned off in the dashboard stops at once',
      (tester) async {
    final storage = MemoryVectorSignalStorage();
    await _replay(true).save(storage);
    final source = _FakeSource(_replay(true));
    await _init(tester, storage, source);
    expect(VectorSignal.replay, isNotNull);

    source.settings = _replay(false);
    await tester.runAsync(VectorSignal.refreshSettings);
    expect(VectorSignal.replay, isNull);
    expect((await ProjectSettings.load(storage))!.replay.enabled, isFalse);
    VectorSignal.shutdown();
  });

  testWidgets('remoteSettings: false uses the rates in ReplayConfig',
      (tester) async {
    final source = _FakeSource(_replay(false));
    await tester.runAsync(() => VectorSignal.init(
          writeKey: 'test',
          host: 'http://localhost',
          transport: _NullTransport(),
          storage: MemoryVectorSignalStorage(),
          captureErrors: false,
          captureNativeApi: false,
          remoteSettings: false,
          settingsSource: source,
          replay: const ReplayConfig(sampleRate: 1),
        ));
    expect(source.calls, 0);
    expect(VectorSignal.replay, isNotNull);
    VectorSignal.shutdown();
  });
}
