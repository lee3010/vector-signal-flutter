import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'property_guard.dart';
import 'session.dart';
import 'storage.dart';
import 'transport.dart';

/// Reserved event names the backend's struggle rules understand.
class VectorSignalEvents {
  VectorSignalEvents._();

  static const screen = r'$screen';
  static const tap = r'$tap';
  static const api = r'$api';
  static const error = r'$error';
  static const appOpen = r'$app_open';
  static const appBackground = r'$app_background';

  /// Sent once when an anonymous user signs in: links the anonymous id
  /// (property `anonId`) to the signed-in id, so one person is one user.
  static const identify = r'$identify';
}

class VectorSignalConfig {
  final double sampleRate;
  final bool enabled;
  final String? appVersion;
  final String platform;
  final Duration flushInterval;
  final int flushAt;
  final int maxQueueSize;
  final int maxBatchSize;
  final Duration sessionTimeout;

  const VectorSignalConfig({
    this.sampleRate = 1.0,
    this.enabled = true,
    this.appVersion,
    this.platform = 'unknown',
    this.flushInterval = const Duration(seconds: 30),
    this.flushAt = 20,
    this.maxQueueSize = 1000,
    this.maxBatchSize = 100,
    this.sessionTimeout = const Duration(minutes: 30),
  });
}

/// Exponential backoff after [failures] consecutive failed sends:
/// 5s, 10s, 20s, ... capped at 5 minutes.
Duration backoffFor(int failures) {
  if (failures <= 0) return Duration.zero;
  final seconds = 5 * pow(2, min(failures - 1, 10)).toInt();
  return Duration(seconds: min(seconds, 300));
}

/// The SDK engine: ids, sessions, the persisted queue and sending.
/// [VectorSignal] is the static facade apps use; this class is public so it
/// can be tested and embedded with fake storage, transport and clock.
class VectorSignalClient {
  static const _anonIdKey = 'anonymous_id';
  static const _distinctIdKey = 'distinct_id';
  static const _optOutKey = 'opt_out';
  static const _sampleKey = 'sample';

  final VectorSignalConfig config;
  final VectorSignalTransport transport;
  final VectorSignalStorage storage;
  final DateTime Function() clock;
  final Random _random;
  final bool _startTimer;

  late final SessionTracker _sessions =
      SessionTracker(timeout: config.sessionTimeout);
  final List<Map<String, dynamic>> _queue = [];

  String _anonymousId = '';
  String? _distinctId;
  bool _optedOut = false;
  bool _sampledIn = true;
  bool _started = false;
  bool _sending = false;
  bool _unauthorized = false;
  int _failures = 0;
  DateTime? _nextAttemptAt;
  String? _currentScreen;

  /// Called after each recorded event (on the device only; e.g. session
  /// replay watches for struggles). Errors in it are ignored.
  void Function(String name, Map<String, Object?>? properties, String? screen,
      DateTime time)? onEvent;
  Timer? _flushTimer;
  Timer? _saveTimer;
  Future<void> _saveChain = Future.value();

  VectorSignalClient({
    required this.config,
    required this.transport,
    required this.storage,
    DateTime Function()? clock,
    Random? random,
    bool startTimer = true,
  })  : clock = clock ?? DateTime.now,
        _random = random ?? Random.secure(),
        _startTimer = startTimer;

  /// True when events are being recorded (started, enabled, not opted out, sampled in).
  bool get isActive => _started && config.enabled && !_optedOut && _sampledIn;

  String get distinctId => _distinctId ?? _anonymousId;
  String get anonymousId => _anonymousId;
  String? get currentScreen => _currentScreen;
  String? get sessionId => _sessions.currentId;
  int get queueLength => _queue.length;
  int get consecutiveFailures => _failures;
  bool get isUnauthorized => _unauthorized;
  List<Map<String, dynamic>> get pendingEvents => List.unmodifiable(_queue);

  Future<void> start() async {
    if (_started) return;
    _anonymousId = await storage.read(_anonIdKey) ?? '';
    if (_anonymousId.isEmpty) {
      _anonymousId = newUuidV4(_random);
      await storage.write(_anonIdKey, _anonymousId);
    }
    _distinctId = await storage.read(_distinctIdKey);
    _optedOut = await storage.read(_optOutKey) == 'true';
    _sampledIn = await _decideSampling();
    _queue.addAll(await storage.loadQueue());
    _trimQueue();
    _started = true;
    if (_startTimer) {
      _flushTimer = Timer.periodic(config.flushInterval, (_) => flush());
    }
  }

  /// Sampling is decided once per install (per sample rate), so a device is
  /// either always in or always out - never half a session.
  Future<bool> _decideSampling() async {
    final rate = config.sampleRate.clamp(0.0, 1.0);
    if (rate >= 1.0) return true;
    final stored = await storage.read(_sampleKey);
    final prefix = '$rate:';
    if (stored != null && stored.startsWith(prefix)) {
      return stored.substring(prefix.length) == 'in';
    }
    final inSample = _random.nextDouble() < rate;
    await storage.write(_sampleKey, '$prefix${inSample ? 'in' : 'out'}');
    return inSample;
  }

  Future<void> identify(String distinctId) async {
    final id = distinctId.trim();
    if (id.isEmpty || id.length > 200 || id == _distinctId) return;
    // Only an anonymous user is linked. Switching from one signed-in user to
    // another (no reset in between) must not merge the two people.
    final wasAnonymous = _distinctId == null;
    _distinctId = id;
    await storage.write(_distinctIdKey, id);
    if (wasAnonymous && _anonymousId.isNotEmpty) {
      enqueue(VectorSignalEvents.identify,
          properties: {'anonId': _anonymousId});
    }
  }

  /// Forgets the identified user (e.g. on logout): new anonymous id, new session.
  /// Does nothing while already anonymous, so apps may call it on every
  /// "signed out" state update: the screens before login keep one anonymous
  /// id, and that id is what the next [identify] links to the user.
  Future<void> reset() async {
    if (_distinctId == null) return;
    _distinctId = null;
    _anonymousId = newUuidV4(_random);
    _sessions.end();
    await storage.write(_distinctIdKey, null);
    await storage.write(_anonIdKey, _anonymousId);
  }

  Future<void> setEnabled(bool enabled) async {
    _optedOut = !enabled;
    await storage.write(_optOutKey, enabled ? null : 'true');
    if (!enabled) {
      // Opting out also discards anything not yet sent.
      _queue.clear();
      _scheduleSave(immediate: true);
    }
  }

  void setCurrentScreen(String screen) => _currentScreen = screen;

  /// Records one event. Never throws.
  void enqueue(String name,
      {Map<String, Object?>? properties, String? screen}) {
    if (!isActive) return;
    try {
      final eventName = name.trim();
      if (eventName.isEmpty || eventName.length > 100) return;

      final now = clock().toUtc();
      final sanitized = PropertyGuard.sanitize(properties);
      _queue.add({
        'event': eventName,
        'distinctId': distinctId,
        'sessionId': _sessions.touch(now),
        'timestamp': now.toIso8601String(),
        'screen': screen ?? _currentScreen,
        if (config.appVersion != null) 'appVersion': config.appVersion,
        'platform': config.platform,
        if (sanitized.clean.isNotEmpty) 'properties': sanitized.clean,
      });
      _trimQueue();
      _scheduleSave();
      try {
        onEvent?.call(eventName, properties, screen ?? _currentScreen, now);
      } catch (_) {}

      if (_queue.length >= config.flushAt) {
        unawaited(flush());
      }
    } catch (_) {
      // Analytics must never break the host app.
    }
  }

  void _trimQueue() {
    final overflow = _queue.length - config.maxQueueSize;
    if (overflow > 0) {
      _queue.removeRange(0, overflow); // drop the oldest
    }
  }

  /// Sends queued events in batches. Safe to call any time; concurrent calls
  /// and calls during backoff return immediately.
  Future<void> flush() async {
    if (!_started || _sending || _unauthorized || _queue.isEmpty) return;
    final next = _nextAttemptAt;
    if (next != null && clock().isBefore(next)) return;

    _sending = true;
    try {
      while (_queue.isNotEmpty) {
        final count = min(config.maxBatchSize, _queue.length);
        final batch = _queue.sublist(0, count);
        VectorSignalSendResult result;
        try {
          result = await transport.send(batch);
        } catch (_) {
          result = const VectorSignalSendResult(VectorSignalSendStatus.retry);
        }

        switch (result.status) {
          case VectorSignalSendStatus.success:
          case VectorSignalSendStatus.drop:
            _removeSent(batch);
            _failures = 0;
            _nextAttemptAt = null;
            if (kDebugMode && result.status == VectorSignalSendStatus.drop) {
              debugPrint(
                  'VectorSignal: server rejected a batch of ${batch.length} events');
            }
          case VectorSignalSendStatus.retry:
            _failures++;
            _nextAttemptAt = clock().add(backoffFor(_failures));
            return;
          case VectorSignalSendStatus.unauthorized:
            _unauthorized = true;
            if (kDebugMode) {
              debugPrint(
                  'VectorSignal: write key rejected; sending stopped, ${_queue.length} events kept');
            }
            return;
        }
      }
    } finally {
      _sending = false;
      _scheduleSave(immediate: true);
    }
  }

  /// Removes exactly the sent events (new events may have been added meanwhile;
  /// old ones may have been dropped by the size cap).
  void _removeSent(List<Map<String, dynamic>> batch) {
    final sent = Set<Map<String, dynamic>>.identity()..addAll(batch);
    _queue.removeWhere(sent.contains);
  }

  void _scheduleSave({bool immediate = false}) {
    _saveTimer?.cancel();
    if (immediate) {
      _save();
    } else {
      _saveTimer = Timer(const Duration(seconds: 1), _save);
    }
  }

  /// Persists the queue; writes are chained so they never overlap.
  Future<void> _save() {
    final snapshot = List<Map<String, dynamic>>.from(_queue);
    _saveChain =
        _saveChain.then((_) => storage.saveQueue(snapshot)).catchError((_) {});
    return _saveChain;
  }

  /// Writes the queue now (call when the app goes to the background).
  Future<void> persist() {
    _saveTimer?.cancel();
    return _save();
  }

  void dispose() {
    _flushTimer?.cancel();
    _saveTimer?.cancel();
  }
}
