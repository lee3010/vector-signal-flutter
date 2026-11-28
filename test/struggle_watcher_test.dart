import 'package:flutter_test/flutter_test.dart';
import 'package:vector_signal_flutter/vector_signal_flutter.dart';

void main() {
  final t0 = DateTime.utc(2026, 11, 28, 8);
  DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

  late List<StruggleTrigger> fired;
  late StruggleWatcher watcher;
  setUp(() {
    fired = [];
    watcher = StruggleWatcher(fired.add, useTimer: false);
  });

  void tap(int ms,
          {double x = 100, double y = 200, String target = 'button'}) =>
      watcher.onEvent(
          r'$tap', {'x': x, 'y': y, 'target': target}, '/payout', at(ms));

  test('three quick taps in one place are a rage tap', () {
    tap(0, target: 'none');
    tap(300, x: 105, target: 'none');
    expect(fired, isEmpty);
    tap(600, y: 210, target: 'none');
    expect(fired, [StruggleTrigger.rageTap]);
  });

  test('quick taps far apart or slow taps are not a rage tap', () {
    tap(0, target: 'none');
    tap(300, x: 300, target: 'none');
    tap(1500, target: 'none');
    tap(2900, target: 'none');
    expect(fired, isEmpty);
  });

  test('a button tap with no answer within 1.5 s is a dead tap', () {
    tap(0);
    watcher.checkPending(at(1000));
    expect(fired, isEmpty);
    watcher.checkPending(at(1600));
    expect(fired, [StruggleTrigger.deadTap]);
  });

  test('a screen change or API call answers the tap', () {
    tap(0);
    watcher.onEvent(r'$screen', null, '/payout/confirm', at(400));
    watcher.checkPending(at(2000));
    tap(3000);
    watcher.onEvent(
        r'$api', {'success': true, 'durationMs': 200}, '/payout', at(3300));
    watcher.checkPending(at(5000));
    expect(fired, isEmpty);
  });

  test('taps on text fields, toggles or blank space are never dead', () {
    tap(0, target: 'text');
    tap(5000, target: 'toggle');
    tap(10000, target: 'none');
    watcher.checkPending(at(20000));
    expect(fired, isEmpty);
  });

  test('failed and slow API calls and app errors are struggles', () {
    watcher.onEvent(r'$api', {'success': false, 'durationMs': 100}, '/a', t0);
    watcher.onEvent(r'$api', {'success': true, 'durationMs': 4200}, '/a', t0);
    watcher.onEvent(r'$api', {'success': true, 'durationMs': 900}, '/a', t0);
    watcher.onEvent(r'$error', {'type': 'flutter'}, '/a', t0);
    expect(fired, [
      StruggleTrigger.apiError,
      StruggleTrigger.slowApi,
      StruggleTrigger.appError,
    ]);
  });
}
