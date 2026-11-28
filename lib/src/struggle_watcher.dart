import 'dart:async';
import 'dart:math';

import 'client.dart';

/// Why [StruggleWatcher] fired: the same struggles the server detects.
enum StruggleTrigger { rageTap, deadTap, apiError, slowApi, appError }

/// Watches events on the device for the moments the server would mark as a
/// struggle, so session replay can send the recording around them
/// ("record on struggle"). Thresholds match the server's default rules.
///
/// Times come in with each event; dead taps also need [checkPending], which
/// the watcher's own timer calls (tests call it directly).
class StruggleWatcher {
  static const int rageTapCount = 3;
  static const Duration rageTapWindow = Duration(milliseconds: 1000);
  static const double rageTapRadius = 40;
  static const Duration deadTapWindow = Duration(milliseconds: 1500);
  static const int slowApiMs = 3000;

  final void Function(StruggleTrigger trigger) onStruggle;
  final bool useTimer;

  final List<({DateTime time, double? x, double? y, String? screen})> _taps =
      [];
  DateTime? _deadTapDue;
  Timer? _timer;

  StruggleWatcher(this.onStruggle, {this.useTimer = true});

  /// Every recorded event, in order.
  void onEvent(String name, Map<String, Object?>? properties, String? screen,
      DateTime time) {
    checkPending(time);
    switch (name) {
      case VectorSignalEvents.tap:
        _onTap(properties, screen, time);
      case VectorSignalEvents.appBackground:
        break; // leaving the app is not an answer to a tap, nor a struggle
      case VectorSignalEvents.error:
        _cancelDeadTap();
        onStruggle(StruggleTrigger.appError);
      case VectorSignalEvents.api:
        _cancelDeadTap(); // the tap did something
        final success = properties?['success'];
        final duration = properties?['durationMs'];
        if (success == false) {
          onStruggle(StruggleTrigger.apiError);
        } else if (duration is num && duration > slowApiMs) {
          onStruggle(StruggleTrigger.slowApi);
        }
      default:
        _cancelDeadTap(); // a screen change or custom event answers the tap
    }
  }

  /// Fires a dead tap when its window passed with no answer. Visible for tests.
  void checkPending(DateTime now) {
    final due = _deadTapDue;
    if (due != null && !now.isBefore(due)) {
      _cancelDeadTap();
      onStruggle(StruggleTrigger.deadTap);
    }
  }

  void _onTap(Map<String, Object?>? p, String? screen, DateTime time) {
    final x = (p?['x'] as num?)?.toDouble();
    final y = (p?['y'] as num?)?.toDouble();
    _taps.removeWhere((t) => time.difference(t.time) > rageTapWindow);
    _taps.add((time: time, x: x, y: y, screen: screen));

    final burst =
        _taps.where((t) => t.screen == screen && _near(t.x, t.y, x, y)).length;
    if (burst >= rageTapCount) {
      _taps.clear();
      _cancelDeadTap(); // repeated taps are a rage tap, not a dead one
      onStruggle(StruggleTrigger.rageTap);
      return;
    }

    // Only taps on something with a tap action can be dead (as on the server).
    final target = p?['target'];
    if (target == null || target == 'button') {
      _deadTapDue = time.add(deadTapWindow);
      if (useTimer) {
        _timer?.cancel();
        _timer = Timer(deadTapWindow + const Duration(milliseconds: 50),
            () => checkPending(DateTime.now().toUtc()));
      }
    }
  }

  static bool _near(double? x0, double? y0, double? x1, double? y1) {
    if (x0 == null || y0 == null || x1 == null || y1 == null) return true;
    final dx = x0 - x1;
    final dy = y0 - y1;
    return sqrt(dx * dx + dy * dy) <= rageTapRadius;
  }

  void _cancelDeadTap() {
    _deadTapDue = null;
    _timer?.cancel();
    _timer = null;
  }

  void dispose() => _cancelDeadTap();
}
