import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'client.dart';
import 'error_capture.dart';
import 'http_capture.dart';
import 'replay.dart';
import 'storage.dart';
import 'transport.dart';

/// The app-facing API. Every method is a safe no-op before [init], when
/// disabled, opted out or sampled out, and none of them ever throw.
class VectorSignal {
  VectorSignal._();

  static VectorSignalClient? _client;
  static ErrorCapture? _errorCapture;
  static _LifecycleObserver? _lifecycle;
  static ReplayRecorder? _replay;
  static ReplayUploader? _replayUploader;

  /// The area session replay captures. [VectorSignalTapCapture] places it
  /// around the app, so wrapping the app in that widget is all that's needed.
  static final GlobalKey replayBoundaryKey =
      GlobalKey(debugLabel: 'VectorSignalReplay');

  /// The running client, or null before [init]. Mainly for tests and diagnostics.
  static VectorSignalClient? get client => _client;

  /// The session-replay recorder, or null when replay is off. For tests and diagnostics.
  static ReplayRecorder? get replay => _replay;

  /// Starts the SDK. Call once, after `WidgetsFlutterBinding.ensureInitialized()`.
  ///
  /// [writeKey] is the project's public write key (it can only send events).
  /// [host] is the Vector Signal API base URL, e.g. `https://signal.example.com`.
  static Future<void> init({
    required String writeKey,
    required String host,
    VectorSignalTransport? transport,
    VectorSignalStorage? storage,
    double sampleRate = 1.0,
    bool enabled = true,
    String? appVersion,
    Duration flushInterval = const Duration(seconds: 30),
    int flushAt = 20,
    int maxQueueSize = 1000,
    bool captureErrors = true,
    bool captureNativeApi = true,
    ReplayConfig? replay,
  }) async {
    if (_client != null) return;
    try {
      WidgetsFlutterBinding.ensureInitialized();
      final client = VectorSignalClient(
        config: VectorSignalConfig(
          sampleRate: sampleRate,
          enabled: enabled,
          appVersion: appVersion,
          platform: defaultTargetPlatform.name,
          flushInterval: flushInterval,
          flushAt: flushAt,
          maxQueueSize: maxQueueSize,
        ),
        transport: transport ?? HttpTransport(writeKey: writeKey, host: host),
        storage: storage ?? DefaultVectorSignalStorage(),
      );
      await client.start();
      _client = client;

      _lifecycle = _LifecycleObserver(client);
      WidgetsBinding.instance.addObserver(_lifecycle!);

      if (captureErrors) {
        _errorCapture = ErrorCapture(
          (type, message) => client.enqueue(
            VectorSignalEvents.error,
            properties: {'type': type, 'message': message},
          ),
        )..install();
      }

      client.enqueue(VectorSignalEvents.appOpen);

      // API calls recorded by the Android VectorSignalOkHttpInterceptor.
      if (captureNativeApi) unawaited(NativeApiBridge.start());

      // Session replay: masked frames, only for sampled sessions.
      if (replay != null && replay.sampleRate > 0) {
        final uploader = ReplayUploader(writeKey: writeKey, host: host);
        _replayUploader = uploader;
        _replay = ReplayRecorder(
          config: replay,
          client: client,
          uploader: uploader,
          boundaryKey: replayBoundaryKey,
        )..start();
        _lifecycle!.replay = _replay;
        _lifecycle!.replayUploader = uploader;
      }

      if (kDebugMode) {
        debugPrint(
            'VectorSignal: started (active: ${client.isActive}, queued: ${client.queueLength})');
      }
    } catch (_) {
      // Never break app start-up because of analytics.
    }
  }

  /// Links later events to a user id (use an internal id, not a phone/email).
  static Future<void> identify(String distinctId) async {
    try {
      await _client?.identify(distinctId);
    } catch (_) {}
  }

  /// Forgets the current user, e.g. on logout.
  static Future<void> reset() async {
    try {
      await _client?.reset();
    } catch (_) {}
  }

  /// Records a custom event, e.g. `track('payout_session_create')`.
  static void track(String name, [Map<String, Object?>? properties]) =>
      _client?.enqueue(name, properties: properties);

  /// Records a screen view. [VectorSignalObserver] calls this for you.
  static void screen(String name, [Map<String, Object?>? properties]) {
    final client = _client;
    if (client == null) return;
    client.setCurrentScreen(name);
    client.enqueue(VectorSignalEvents.screen,
        properties: properties, screen: name);
    _replay?.notifyInteraction(); // record the new screen
  }

  /// Records a tap. [VectorSignalTapCapture] calls this for you.
  /// [target] is what the finger hit (`button`, `toggle`, `text`, `none`);
  /// the server only treats `button` taps as possible dead taps.
  static void recordTap(Offset position, {String? label, String? target}) =>
      _client?.enqueue(
        VectorSignalEvents.tap,
        properties: {
          'x': double.parse(position.dx.toStringAsFixed(1)),
          'y': double.parse(position.dy.toStringAsFixed(1)),
          if (label != null) 'label': label,
          if (target != null) 'target': target,
        },
      );

  /// Records one backend/API call.
  static void trackApi(String name, Duration duration,
          {required bool success, int? statusCode}) =>
      _client?.enqueue(
        VectorSignalEvents.api,
        properties: {
          'name': name,
          'durationMs': duration.inMilliseconds,
          'success': success,
          if (statusCode != null) 'statusCode': statusCode,
        },
      );

  /// Times [call] and records it as an API call; the result or error is passed
  /// through unchanged. Wrap MethodChannel or HTTP calls with it:
  /// `await VectorSignal.timeApi('getWallet', () => channel.invokeMethod('getWallet'))`.
  static Future<T> timeApi<T>(String name, Future<T> Function() call) async {
    final watch = Stopwatch()..start();
    try {
      final result = await call();
      trackApi(name, watch.elapsed, success: true);
      return result;
    } catch (_) {
      trackApi(name, watch.elapsed, success: false);
      rethrow;
    }
  }

  /// Sends queued events now.
  static Future<void> flush() async {
    try {
      await _client?.flush();
    } catch (_) {}
  }

  /// Turns tracking on or off for this install (remembered across restarts).
  static Future<void> setEnabled(bool enabled) async {
    try {
      await _client?.setEnabled(enabled);
    } catch (_) {}
  }

  /// Stops the SDK and restores previous error handlers. Mainly for tests.
  @visibleForTesting
  static void shutdown() {
    unawaited(NativeApiBridge.stop());
    _replay?.stop();
    _replay = null;
    _replayUploader?.dispose();
    _replayUploader = null;
    _errorCapture?.uninstall();
    _errorCapture = null;
    if (_lifecycle != null) {
      WidgetsBinding.instance.removeObserver(_lifecycle!);
      _lifecycle = null;
    }
    _client?.dispose();
    _client = null;
  }
}

class _LifecycleObserver with WidgetsBindingObserver {
  final VectorSignalClient client;
  ReplayRecorder? replay;
  ReplayUploader? replayUploader;
  bool _inBackground = false;

  _LifecycleObserver(this.client);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        if (_inBackground) return;
        _inBackground = true;
        client.enqueue(VectorSignalEvents.appBackground);
        unawaited(client.flush().whenComplete(client.persist));
        replay?.stop();
        unawaited(replayUploader?.flush());
      case AppLifecycleState.resumed:
        if (!_inBackground) return;
        _inBackground = false;
        client.enqueue(VectorSignalEvents.appOpen);
        replay?.start();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }
}
