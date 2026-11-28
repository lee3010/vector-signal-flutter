import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'client.dart';
import 'error_capture.dart';
import 'http_capture.dart';
import 'remote_settings.dart';
import 'replay.dart';
import 'storage.dart';
import 'struggle_watcher.dart';
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
  static StruggleWatcher? _struggleWatcher;
  static VectorSignalStorage? _storage;
  static VectorSignalSettingsSource? _settingsSource;
  static ReplayConfig _replayTemplate = const ReplayConfig();
  static ProjectSettings? _settings;
  static DateTime? _settingsFetchedAt;
  static bool _fetchingSettings = false;
  static String _writeKey = '';
  static String _host = '';

  /// Settings are fetched again when the app comes back after this long.
  static const Duration settingsRefreshInterval = Duration(minutes: 30);

  /// The area session replay captures. [VectorSignalTapCapture] places it
  /// around the app, so wrapping the app in that widget is all that's needed.
  static final GlobalKey replayBoundaryKey =
      GlobalKey(debugLabel: 'VectorSignalReplay');

  /// The running client, or null before [init]. Mainly for tests and diagnostics.
  static VectorSignalClient? get client => _client;

  /// The session-replay recorder, or null when replay is off. For tests and diagnostics.
  static ReplayRecorder? get replay => _replay;

  /// The project's settings in use (saved or fetched), or null before they
  /// were ever loaded. For tests and diagnostics.
  static ProjectSettings? get settings => _settings;

  /// Starts the SDK. Call once, after `WidgetsFlutterBinding.ensureInitialized()`.
  ///
  /// [writeKey] is the project's public write key (it can only send events).
  /// [host] is the Vector Signal API base URL, e.g. `https://signal.example.com`.
  ///
  /// Session replay is controlled on the dashboard (Project settings): the
  /// SDK reads the project's settings at start-up and uses the last saved
  /// ones until fresh ones arrive; replay stays off until they were loaded
  /// once. [replay] only tunes masking and capture timing. Set
  /// [remoteSettings] to false to use the rates in [replay] instead.
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
    bool remoteSettings = true,
    VectorSignalSettingsSource? settingsSource,
  }) async {
    if (_client != null) return;
    try {
      WidgetsFlutterBinding.ensureInitialized();
      final store = storage ?? DefaultVectorSignalStorage();
      _storage = store;
      _writeKey = writeKey;
      _host = host;
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
        storage: store,
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

      // Session replay: masked frames. Sampled sessions are recorded in full;
      // the others keep the last minute on the device and send it only when
      // a struggle happens. The rates come from the project's settings.
      _replayTemplate = replay ?? const ReplayConfig();
      if (remoteSettings) {
        _settingsSource = settingsSource ??
            HttpSettingsSource(writeKey: writeKey, host: host);
        final saved = await ProjectSettings.load(store);
        if (saved != null) _applySettings(saved);
        _lifecycle!.onResume = _refreshSettingsIfStale;
        unawaited(refreshSettings());
      } else if (replay != null) {
        _startReplay(replay);
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
  /// [screenSize] (logical pixels) lets heatmaps line up taps from phones of
  /// different sizes.
  static void recordTap(Offset position,
          {String? label, String? target, Size? screenSize}) =>
      _client?.enqueue(
        VectorSignalEvents.tap,
        properties: {
          'x': double.parse(position.dx.toStringAsFixed(1)),
          'y': double.parse(position.dy.toStringAsFixed(1)),
          if (screenSize != null && !screenSize.isEmpty) ...{
            'w': double.parse(screenSize.width.toStringAsFixed(1)),
            'h': double.parse(screenSize.height.toStringAsFixed(1)),
          },
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

  /// Loads the project's settings now and applies them: replay turned off on
  /// the dashboard stops at once; turned on, it starts. New rates for a
  /// running recorder apply from the next app start, so a session never
  /// changes how it is recorded halfway.
  static Future<void> refreshSettings() async {
    final source = _settingsSource;
    final store = _storage;
    if (source == null || store == null || _fetchingSettings) return;
    _fetchingSettings = true;
    try {
      final fresh = await source.fetch();
      if (fresh == null || _settingsSource != source) return;
      _settingsFetchedAt = DateTime.now();
      await fresh.save(store);
      _applySettings(fresh);
    } catch (_) {
      // Keep the saved settings.
    } finally {
      _fetchingSettings = false;
    }
  }

  static void _refreshSettingsIfStale() {
    final last = _settingsFetchedAt;
    if (last == null ||
        DateTime.now().difference(last) >= settingsRefreshInterval) {
      unawaited(refreshSettings());
    }
  }

  static void _applySettings(ProjectSettings settings) {
    _settings = settings;
    final replay = settings.replay;
    if (!replay.records) {
      _stopReplay(flush: true);
    } else if (_replay == null) {
      _startReplay(_replayTemplate.withRates(
        sampleRate: replay.sampleRate,
        onStruggleSampleRate: replay.onStruggleSampleRate,
      ));
    }
  }

  static void _startReplay(ReplayConfig config) {
    final client = _client;
    final lifecycle = _lifecycle;
    if (client == null || lifecycle == null) return;
    if (config.sampleRate <= 0 && config.onStruggleSampleRate <= 0) return;
    final uploader = ReplayUploader(writeKey: _writeKey, host: _host);
    _replayUploader = uploader;
    final recorder = ReplayRecorder(
      config: config,
      client: client,
      uploader: uploader,
      boundaryKey: replayBoundaryKey,
    );
    _replay = recorder;
    lifecycle.replay = recorder;
    lifecycle.replayUploader = uploader;
    if (config.onStruggleSampleRate > 0) {
      final watcher = StruggleWatcher((_) => _replay?.onStruggle());
      _struggleWatcher = watcher;
      client.onEvent = watcher.onEvent;
    }
    if (!lifecycle.inBackground) recorder.start();
  }

  static void _stopReplay({required bool flush}) {
    _struggleWatcher?.dispose();
    _struggleWatcher = null;
    _client?.onEvent = null;
    _replay?.stop();
    _replay = null;
    final uploader = _replayUploader;
    _replayUploader = null;
    if (uploader != null) {
      if (flush) {
        unawaited(uploader.flush().whenComplete(uploader.dispose));
      } else {
        uploader.dispose();
      }
    }
    _lifecycle?.replay = null;
    _lifecycle?.replayUploader = null;
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
    _stopReplay(flush: false);
    _settingsSource = null;
    _settings = null;
    _settingsFetchedAt = null;
    _fetchingSettings = false;
    _storage = null;
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
  void Function()? onResume;
  bool _inBackground = false;

  bool get inBackground => _inBackground;

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
        onResume?.call();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }
}
