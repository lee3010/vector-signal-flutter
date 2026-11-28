import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'client.dart';

/// Session replay settings. Replay is off unless a [ReplayConfig] is passed to
/// `VectorSignal.init(replay: ...)`.
///
/// Privacy first: masking happens on the device, before anything is sent.
/// By default every piece of text, every text field and every custom-painted
/// area (charts can draw amounts) is covered with a grey box. Icons stay
/// visible. Wrap anything else sensitive in [VSMask]; wrap content that is
/// safe to show in [VSUnmask].
class ReplayConfig {
  /// Share of sessions recorded in full, 0..1. With remote settings (the
  /// default) both rates come from the project's settings on the dashboard.
  final double sampleRate;

  /// Share of the other sessions that keep the last [bufferDuration] of
  /// frames on the device and send them only when a struggle happens (rage
  /// tap, dead tap, error, failed or slow API), then record the rest of the
  /// session in full. 0..1; 1 = every session with a struggle has a replay.
  /// Frames of sessions without a struggle never leave the device.
  final double onStruggleSampleRate;

  /// How much of the moments before a struggle is kept on the device.
  final Duration bufferDuration;

  /// Cover all text (recommended for payment apps). When false, only text
  /// fields and [VSMask] areas are covered.
  final bool maskAllText;

  /// Also cover images (photos, QR codes).
  final bool maskImages;

  /// While the user is active (tap, scroll, screen change, then
  /// [activeWindow]), at most one frame per [minInterval].
  final Duration minInterval;

  /// How long after the last touch or screen change frames keep coming at
  /// [minInterval] (to show the result: loading, transitions, scrolling).
  final Duration activeWindow;

  /// When nobody touches the phone, at most one frame per [idleInterval],
  /// even if something on screen is animating.
  final Duration idleInterval;

  /// After this long with no touch or screen change, recording pauses
  /// completely (an untouched screen tells nothing). The next touch resumes it.
  final Duration idleStopAfter;

  /// No more frames for a session after this many.
  final int maxFramesPerSession;

  /// Frames are scaled down to at most this width in pixels.
  final double maxWidth;

  /// WebP quality 1..100 (Android). Other platforms send PNG.
  final int quality;

  const ReplayConfig({
    this.sampleRate = 0.1,
    this.onStruggleSampleRate = 1.0,
    this.bufferDuration = const Duration(seconds: 60),
    this.maskAllText = true,
    this.maskImages = false,
    this.minInterval = const Duration(seconds: 1),
    this.activeWindow = const Duration(seconds: 3),
    this.idleInterval = const Duration(seconds: 10),
    this.idleStopAfter = const Duration(minutes: 2),
    this.maxFramesPerSession = 600,
    this.maxWidth = 360,
    this.quality = 50,
  });

  /// This config with other sampling rates (from the project's settings).
  ReplayConfig withRates(
          {required double sampleRate, required double onStruggleSampleRate}) =>
      ReplayConfig(
        sampleRate: sampleRate,
        onStruggleSampleRate: onStruggleSampleRate,
        bufferDuration: bufferDuration,
        maskAllText: maskAllText,
        maskImages: maskImages,
        minInterval: minInterval,
        activeWindow: activeWindow,
        idleInterval: idleInterval,
        idleStopAfter: idleStopAfter,
        maxFramesPerSession: maxFramesPerSession,
        maxWidth: maxWidth,
        quality: quality,
      );
}

/// Always covers [child] in session replay, whatever the masking settings.
class VSMask extends SingleChildRenderObjectWidget {
  const VSMask({super.key, required Widget super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderVSMask(mask: true);
}

/// Shows [child] in session replay even when [ReplayConfig.maskAllText] is on.
/// Use only for content with no personal or financial data (e.g. static labels).
/// A [VSMask] inside still masks.
class VSUnmask extends SingleChildRenderObjectWidget {
  const VSUnmask({super.key, required Widget super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderVSMask(mask: false);
}

/// Marker render object for [VSMask] / [VSUnmask]; paints nothing itself.
class RenderVSMask extends RenderProxyBox {
  final bool mask;
  RenderVSMask({required this.mask});
}

/// Finds the areas to cover in a frame. Pure render-tree walk, testable.
class ReplayMasker {
  ReplayMasker._();

  /// Rects in [root]'s coordinates (logical pixels).
  static List<Rect> collect(RenderObject root,
      {bool maskAllText = true, bool maskImages = false}) {
    final rects = <Rect>[];
    if (root is! RenderBox || !root.hasSize) return rects;
    final bounds = Offset.zero & root.size;

    void visit(RenderObject node, Rect clip, bool textMasked) {
      if (!_isVisible(node)) return;

      if (node is RenderBox && node.hasSize) {
        Rect? rect;
        try {
          rect = MatrixUtils.transformRect(
              node.getTransformTo(root), Offset.zero & node.size);
        } catch (_) {
          rect = null;
        }

        if (rect != null) {
          if (node is RenderVSMask) {
            if (node.mask) {
              _add(rects, rect, clip);
              return; // everything inside is covered
            }
            textMasked =
                false; // VSUnmask: show text below, unless VSMask again
          } else if (node is RenderEditable) {
            _add(rects, rect, clip); // text fields: always
            return;
          } else if (node is RenderParagraph) {
            if (textMasked && !_isIcon(node)) _add(rects, rect, clip);
            return;
          } else if (node is RenderCustomPaint &&
              textMasked &&
              (node.painter != null || node.foregroundPainter != null)) {
            _add(rects, rect, clip);
            return;
          } else if (node is RenderImage && maskImages) {
            _add(rects, rect, clip);
            return;
          }

          if (_clips(node)) {
            clip = clip.intersect(rect);
            if (clip.isEmpty) return;
          }
        }
      }

      if (node is RenderIndexedStack) {
        // Only the selected child is painted.
        var i = 0;
        final index = node.index;
        node.visitChildren((child) {
          if (i++ == index) visit(child, clip, textMasked);
        });
        return;
      }

      node.visitChildren((child) => visit(child, clip, textMasked));
    }

    visit(root, bounds, maskAllText);
    return rects;
  }

  static void _add(List<Rect> rects, Rect rect, Rect clip) {
    final visible = rect.intersect(clip);
    if (visible.width > 0.5 && visible.height > 0.5) rects.add(visible);
  }

  static bool _isVisible(RenderObject node) {
    if (node is RenderOffstage && node.offstage) return false;
    if (node is RenderOpacity && node.opacity == 0) return false;
    if (node is RenderAnimatedOpacity && node.opacity.value == 0) return false;
    if (node is RenderSliverOpacity && node.opacity == 0) return false;
    return true;
  }

  static bool _clips(RenderObject node) =>
      node is RenderClipRect ||
      node is RenderClipRRect ||
      node is RenderClipPath ||
      node is RenderClipOval ||
      node is RenderViewportBase;

  /// Icon glyphs (Material/Cupertino icons) are private-use code points,
  /// never real user text, so they stay visible.
  static bool _isIcon(RenderParagraph paragraph) {
    final text = paragraph.text.toPlainText(includeSemanticsLabels: false);
    if (text.isEmpty || text.runes.length > 2) return false;
    return text.runes.every(
        (r) => (r >= 0xE000 && r <= 0xF8FF) || (r >= 0xF0000 && r <= 0x10FFFD));
  }
}

/// How a session is recorded: not at all, kept on the device until a struggle
/// ([buffer]), or sent as it happens ([full]).
enum ReplayMode { off, buffer, full }

/// Captures masked frames of the app and hands them to [ReplayUploader]
/// (full sessions), or keeps the last [ReplayConfig.bufferDuration] on the
/// device until [onStruggle] (buffered sessions).
class ReplayRecorder {
  final ReplayConfig config;
  final VectorSignalClient client;
  final ReplayUploader uploader;
  final GlobalKey boundaryKey;
  final Random _random;

  final ReplayEncoder _encoder;

  bool _running = false;
  bool _dirty = false;
  bool _capturing = false;
  Timer? _timer;
  DateTime? _timerDue;
  DateTime _lastCapture = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _activeUntil = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastInteraction = DateTime.fromMillisecondsSinceEpoch(0);
  final DateTime Function() _now;
  int? _lastHash;
  String? _sampledSessionId;
  ReplayMode _mode = ReplayMode.off;
  final List<Map<String, dynamic>> _buffer = [];
  int _framesThisSession = 0;
  bool _frameCallbackAdded = false;

  ReplayRecorder({
    required this.config,
    required this.client,
    required this.uploader,
    required this.boundaryKey,
    ReplayEncoder? encoder,
    Random? random,
    DateTime Function()? clock,
  })  : _encoder = encoder ?? ReplayEncoder(quality: config.quality),
        _random = random ?? Random(),
        _now = clock ?? DateTime.now;

  /// Frames sent (or queued to send) for the current session. For tests and diagnostics.
  int get framesThisSession => _framesThisSession;

  /// Frames kept on the device for a buffered session. For tests and diagnostics.
  int get bufferedFrames => _buffer.length;

  /// How the current session is recorded. For tests and diagnostics.
  ReplayMode get mode {
    final sessionId = client.sessionId;
    return sessionId == null ? ReplayMode.off : _modeFor(sessionId);
  }

  /// A struggle happened: a buffered session sends what it kept and records
  /// the rest in full. [StruggleWatcher] calls this.
  void onStruggle() {
    final sessionId = client.sessionId;
    if (!_running || sessionId == null) return;
    if (_modeFor(sessionId) != ReplayMode.buffer) return;
    _mode = ReplayMode.full;
    _prune(_now());
    for (final frame in _buffer) {
      if (_framesThisSession >= config.maxFramesPerSession) break;
      _framesThisSession++;
      uploader.add(frame);
    }
    _buffer.clear();
    unawaited(uploader.flush());
    notifyInteraction(); // record what happens next closely
  }

  /// True while recording is paused because nobody touched the screen for
  /// [ReplayConfig.idleStopAfter]. For tests and diagnostics.
  bool get isIdle =>
      _now().difference(_lastInteraction) >= config.idleStopAfter;

  /// True when a frame capture is scheduled. For tests and diagnostics.
  bool get hasPendingCapture => _timer != null;

  /// Drops the scheduled capture without stopping. For tests.
  @visibleForTesting
  void cancelPendingCapture() {
    _timer?.cancel();
    _timer = null;
    _timerDue = null;
  }

  void start() {
    _running = true;
    if (!_frameCallbackAdded) {
      _frameCallbackAdded = true;
      // Persistent callbacks can't be removed; [_running] gates it instead.
      SchedulerBinding.instance.addPersistentFrameCallback(_onFrame);
    }
    notifyInteraction(); // first frame of the session / after resume
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
    _timerDue = null;
  }

  /// The user touched the screen or the screen changed: record the next few
  /// seconds closely. [VectorSignalTapCapture] and screen tracking call this.
  void notifyInteraction() {
    if (!_running) return;
    final now = _now();
    _lastInteraction = now;
    _activeUntil = now.add(config.activeWindow);
    _dirty = true;
    _schedule();
  }

  void _onFrame(Duration _) {
    if (!_running) return;
    _dirty = true;
    // Untouched for a while: only animations are changing. Wait for a touch.
    if (isIdle) return;
    _schedule();
  }

  /// Something changed on screen: capture at [ReplayConfig.minInterval] while
  /// the user is active, otherwise at [ReplayConfig.idleInterval] (animations).
  void _schedule() {
    if (_capturing) return;
    final now = _now();
    final interval =
        now.isBefore(_activeUntil) ? config.minInterval : config.idleInterval;
    var due = _lastCapture.add(interval);
    if (due.isBefore(now)) due = now;

    final pending = _timerDue;
    if (_timer != null && pending != null && !due.isBefore(pending)) return;
    _timer?.cancel();
    _timerDue = due;
    _timer = Timer(due.difference(now), () {
      _timer = null;
      _timerDue = null;
      unawaited(captureNow());
    });
  }

  ReplayMode _modeFor(String sessionId) {
    if (_sampledSessionId != sessionId) {
      _sampledSessionId = sessionId;
      _mode = _random.nextDouble() < config.sampleRate
          ? ReplayMode.full
          : _random.nextDouble() < config.onStruggleSampleRate
              ? ReplayMode.buffer
              : ReplayMode.off;
      _framesThisSession = 0;
      _buffer.clear();
      _lastHash = null;
    }
    return _mode;
  }

  /// Keeps frames from the last [ReplayConfig.bufferDuration], plus the one
  /// before (what was on screen when the window starts).
  void _prune(DateTime now) {
    final from = now.subtract(config.bufferDuration);
    var keepFrom = 0;
    for (var i = 0; i < _buffer.length; i++) {
      if ((_buffer[i]['_at'] as DateTime).isBefore(from)) keepFrom = i;
    }
    if (keepFrom > 0) _buffer.removeRange(0, keepFrom);
    if (_buffer.length > ReplayUploader.maxQueuedFrames) {
      _buffer.removeRange(0, _buffer.length - ReplayUploader.maxQueuedFrames);
    }
  }

  /// Captures one frame if the screen changed. Visible for tests.
  Future<void> captureNow() async {
    if (!_running || !_dirty || _capturing || !client.isActive) return;
    final sessionId = client.sessionId;
    if (sessionId == null) return;
    final mode = _modeFor(sessionId);
    if (mode == ReplayMode.off) return;
    if (_framesThisSession >= config.maxFramesPerSession) return;

    final boundary = boundaryKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary ||
        !boundary.attached ||
        !boundary.hasSize) {
      return;
    }

    _capturing = true;
    _dirty = false;
    _lastCapture = _now();
    try {
      final size = boundary.size;
      if (size.width <= 0 || size.height <= 0) return;
      final masks = ReplayMasker.collect(boundary,
          maskAllText: config.maskAllText, maskImages: config.maskImages);
      final ratio = min(1.0, config.maxWidth / size.width);

      final raw = await boundary.toImage(pixelRatio: ratio);
      final masked = await _mask(raw, masks, ratio);
      raw.dispose();
      final Uint8List? image;
      try {
        final rgba =
            await masked.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (rgba == null) return;
        final pixels = rgba.buffer.asUint8List();
        final hash = _fingerprint(pixels);
        if (hash == _lastHash) return; // nothing visible changed
        _lastHash = hash;
        image = await _encoder.encode(masked, pixels);
      } finally {
        masked.dispose();
      }
      if (image == null) return;
      final at = _now();
      final frame = {
        'sessionId': sessionId,
        'distinctId': client.distinctId,
        'timestamp': at.toUtc().toIso8601String(),
        'screen': client.currentScreen,
        'width': size.width.round(),
        'height': size.height.round(),
        'image': base64Encode(image),
      };
      if (_mode == ReplayMode.buffer) {
        _buffer.add({...frame, '_at': at});
        _prune(at);
        return;
      }
      _framesThisSession++;
      uploader.add(frame);
    } catch (_) {
      // e.g. a frame still being painted; the next change tries again.
      _dirty = true;
    } finally {
      _capturing = false;
    }
  }

  static final ui.Paint _maskPaint = ui.Paint()
    ..color = const ui.Color(0xFFD1D5DB);

  static Future<ui.Image> _mask(
      ui.Image raw, List<Rect> masks, double ratio) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImage(raw, Offset.zero, ui.Paint());
    for (final r in masks) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTRB(r.left * ratio, r.top * ratio, r.right * ratio,
                r.bottom * ratio),
            const Radius.circular(3)),
        _maskPaint,
      );
    }
    final picture = recorder.endRecording();
    final masked = await picture.toImage(raw.width, raw.height);
    picture.dispose();
    return masked;
  }

  /// FNV-1a over every 3rd pixel: enough to tell identical frames apart cheaply.
  static int _fingerprint(Uint8List rgba) {
    var hash = 0x811c9dc5;
    for (var i = 0; i < rgba.length; i += 12) {
      hash ^= rgba[i] | (rgba[i + 1] << 8) | (rgba[i + 2] << 16);
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }
}

/// Turns a masked frame into a small image file: WebP via Android's own
/// encoder (about 5x smaller than PNG), PNG elsewhere or if that fails.
class ReplayEncoder {
  static const MethodChannel _channel = MethodChannel('vector_signal/native');

  final int quality;
  bool _nativeAvailable =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  ReplayEncoder({this.quality = 50});

  Future<Uint8List?> encode(ui.Image image, Uint8List rgba) async {
    if (_nativeAvailable) {
      try {
        final webp = await _channel.invokeMethod<Uint8List>('encodeWebp', {
          'rgba': rgba,
          'width': image.width,
          'height': image.height,
          'quality': quality,
        });
        if (webp != null && webp.isNotEmpty) return webp;
      } on MissingPluginException {
        _nativeAvailable = false;
      } catch (_) {
        // Fall back to PNG for this frame.
      }
    }
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    return png?.buffer.asUint8List();
  }
}

/// Sends frames to `{host}/v1/replay` in small batches. Frames are kept in
/// memory only (never written to disk) and the oldest are dropped when the
/// buffer is full or the device is offline.
class ReplayUploader {
  /// Room for about a minute of frames (what a struggle sends at once).
  static const int maxQueuedFrames = 90;
  static const int sendAt = 5;

  /// The server takes at most 30 frames per request.
  static const int maxBatchFrames = 25;
  static const int _maxBatchChars = 3 * 1024 * 1024;

  final Dio _dio;
  final String writeKey;
  final List<Map<String, dynamic>> _queue = [];
  Timer? _timer;
  bool _sending = false;
  bool _disabled = false;

  ReplayUploader(
      {required this.writeKey,
      required String host,
      Dio? dio,
      Duration flushInterval = const Duration(seconds: 10)})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: host,
              connectTimeout: const Duration(seconds: 10),
              sendTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(seconds: 15),
            )) {
    _timer = Timer.periodic(flushInterval, (_) => unawaited(flush()));
  }

  /// True after the server said replay is off (or the key is wrong).
  bool get isDisabled => _disabled;
  int get queueLength => _queue.length;

  void add(Map<String, dynamic> frame) {
    if (_disabled) return;
    _queue.add(frame);
    if (_queue.length > maxQueuedFrames) {
      _queue.removeRange(0, _queue.length - maxQueuedFrames);
    }
    if (_queue.length >= sendAt) unawaited(flush());
  }

  Future<void> flush() async {
    if (_sending || _disabled || _queue.isEmpty) return;
    _sending = true;
    var sent = false;
    try {
      final batch = <Map<String, dynamic>>[];
      var chars = 0;
      for (final f in _queue) {
        final size = (f['image'] as String).length;
        if (batch.isNotEmpty &&
            (chars + size > _maxBatchChars || batch.length >= maxBatchFrames)) {
          break;
        }
        batch.add(f);
        chars += size;
      }

      final response = await _dio.post<dynamic>(
        '/v1/replay',
        data: {'frames': batch},
        options: Options(
          headers: {'X-VS-Write-Key': writeKey},
          contentType: Headers.jsonContentType,
          validateStatus: (_) => true,
        ),
      );
      final code = response.statusCode ?? 0;
      if ((code >= 200 && code < 300) || code == 400 || code == 413) {
        _queue.removeRange(0, batch.length); // sent, or never acceptable
        sent = true;
      } else if (code == 401 || code == 403 || code == 503) {
        _disabled = true; // wrong key, or replay off on this server
        _queue.clear();
        if (kDebugMode) {
          debugPrint('VectorSignal: replay upload stopped (HTTP $code)');
        }
      }
      // Other errors: keep the frames and try again on the next flush.
    } catch (_) {
      // Offline: keep the frames (the buffer cap drops the oldest).
    } finally {
      _sending = false;
    }
    // A struggle can queue more than one batch: send the rest straight away.
    if (sent && _queue.length >= sendAt) unawaited(flush());
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
