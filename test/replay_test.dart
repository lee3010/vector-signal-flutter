import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_signal_flutter/vector_signal_flutter.dart';

class _NullTransport implements VectorSignalTransport {
  @override
  Future<VectorSignalSendResult> send(List<Map<String, dynamic>> batch) async =>
      const VectorSignalSendResult(VectorSignalSendStatus.success);
}

/// Records replay uploads and answers with [statusCode].
class _ReplayServer implements HttpClientAdapter {
  int statusCode;
  final List<Map<String, dynamic>> bodies = [];
  _ReplayServer(this.statusCode);

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<List<int>>? requestStream, Future<void>? cancelFuture) async {
    bodies.add(options.data as Map<String, dynamic>);
    return ResponseBody.fromString('{}', statusCode, headers: {
      Headers.contentTypeHeader: ['application/json']
    });
  }

  @override
  void close({bool force = false}) {}
}

const _pngSignature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

void main() {
  group('ReplayMasker', () {
    Future<List<Rect>> masksFor(WidgetTester tester, Widget body,
        {bool maskAllText = true}) async {
      final key = GlobalKey();
      await tester.pumpWidget(MaterialApp(
        home: RepaintBoundary(key: key, child: Scaffold(body: body)),
      ));
      return ReplayMasker.collect(key.currentContext!.findRenderObject()!,
          maskAllText: maskAllText);
    }

    Rect rectOf(WidgetTester tester, Finder f) => tester.getRect(f);

    bool covers(List<Rect> masks, Rect target) =>
        masks.any((m) => m.overlaps(target.deflate(1)));

    testWidgets('masks text, fields and VSMask; keeps icons and VSUnmask',
        (tester) async {
      final masks = await masksFor(
        tester,
        Column(children: [
          const Text('Balance 8,900,268.66'),
          const SizedBox(width: 200, child: TextField()),
          const Icon(Icons.home),
          const VSUnmask(child: Text('Payout')),
          VSMask(child: Container(width: 50, height: 50, color: Colors.red)),
        ]),
      );

      expect(covers(masks, rectOf(tester, find.text('Balance 8,900,268.66'))),
          isTrue);
      expect(covers(masks, rectOf(tester, find.byType(TextField))), isTrue);
      expect(covers(masks, rectOf(tester, find.byType(VSMask))), isTrue);
      expect(covers(masks, rectOf(tester, find.byIcon(Icons.home))), isFalse);
      expect(covers(masks, rectOf(tester, find.text('Payout'))), isFalse);
    });

    testWidgets('text fields stay masked even when text masking is off',
        (tester) async {
      final masks = await masksFor(
        tester,
        const Column(children: [
          Text('Label'),
          SizedBox(width: 200, child: TextField()),
        ]),
        maskAllText: false,
      );
      expect(covers(masks, rectOf(tester, find.text('Label'))), isFalse);
      expect(covers(masks, rectOf(tester, find.byType(TextField))), isTrue);
    });

    testWidgets('hidden content (offstage, other tabs) adds no masks',
        (tester) async {
      final masks = await masksFor(
        tester,
        const Column(children: [
          Offstage(child: Text('hidden')),
          IndexedStack(index: 0, children: [Text('tab one'), Text('tab two')]),
        ]),
      );
      // Only "tab one" is painted.
      expect(masks, hasLength(1));
    });
  });

  testWidgets('recorder captures a masked PNG once per visible change',
      (tester) async {
    final server = _ReplayServer(200);
    await tester.runAsync(() => VectorSignal.init(
          writeKey: 'test',
          host: 'http://localhost',
          transport: _NullTransport(),
          storage: MemoryVectorSignalStorage(),
          captureErrors: false,
          captureNativeApi: false,
        ));
    final uploader = ReplayUploader(
        writeKey: 'test',
        host: 'http://localhost',
        dio: Dio()..httpClientAdapter = server);
    final recorder = ReplayRecorder(
      config: const ReplayConfig(sampleRate: 1),
      client: VectorSignal.client!,
      uploader: uploader,
      boundaryKey: VectorSignal.replayBoundaryKey,
    );

    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => VectorSignalTapCapture(child: child!),
      home: const Scaffold(body: Center(child: Text('Wallet 1,000.00'))),
    ));

    // Make sure there is a session, as there is once any event was recorded.
    VectorSignal.track('screen_ready');
    recorder.start();
    await tester.runAsync(recorder.captureNow);
    expect(uploader.queueLength, 1);

    // Nothing changed on screen: the identical frame is skipped.
    await tester.pump();
    await tester.runAsync(recorder.captureNow);
    expect(uploader.queueLength, 1);

    await tester.runAsync(uploader.flush);
    final frame = (server.bodies.single['frames'] as List).single as Map;
    final png = base64Decode(frame['image'] as String);
    expect(png.take(8).toList(), _pngSignature);
    expect(frame['width'], 800);
    expect(frame['sessionId'], VectorSignal.client!.sessionId);

    recorder.stop();
    uploader.dispose();
    VectorSignal.shutdown();
  });

  testWidgets('recording pauses after 2 minutes untouched; a touch resumes it',
      (tester) async {
    await tester.runAsync(() => VectorSignal.init(
          writeKey: 'test',
          host: 'http://localhost',
          transport: _NullTransport(),
          storage: MemoryVectorSignalStorage(),
          captureErrors: false,
          captureNativeApi: false,
        ));
    final uploader = ReplayUploader(
        writeKey: 'test',
        host: 'http://localhost',
        dio: Dio()..httpClientAdapter = _ReplayServer(200));
    var now = DateTime(2026, 11, 25, 8);
    final recorder = ReplayRecorder(
      config: const ReplayConfig(sampleRate: 1),
      client: VectorSignal.client!,
      uploader: uploader,
      boundaryKey: VectorSignal.replayBoundaryKey,
      clock: () => now,
    );
    // An endless animation, like an animated mascot on a home screen.
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => VectorSignalTapCapture(child: child!),
      home: const Scaffold(body: Center(child: CircularProgressIndicator())),
    ));

    recorder.start(); // counts as an interaction
    expect(recorder.isIdle, isFalse);
    expect(recorder.hasPendingCapture, isTrue);
    recorder.cancelPendingCapture();

    // While active, an animation frame schedules a capture.
    await tester.pump(const Duration(milliseconds: 16));
    expect(recorder.hasPendingCapture, isTrue);
    recorder.cancelPendingCapture();

    // Nobody touched the phone for 3 minutes: animation frames are ignored.
    now = now.add(const Duration(minutes: 3));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(recorder.isIdle, isTrue);
    expect(recorder.hasPendingCapture, isFalse);

    recorder.notifyInteraction(); // a tap
    expect(recorder.isIdle, isFalse);
    expect(recorder.hasPendingCapture, isTrue);

    recorder.stop();
    uploader.dispose();
    VectorSignal.shutdown();
  });

  testWidgets('recorder stops at maxFramesPerSession', (tester) async {
    await tester.runAsync(() => VectorSignal.init(
          writeKey: 'test',
          host: 'http://localhost',
          transport: _NullTransport(),
          storage: MemoryVectorSignalStorage(),
          captureErrors: false,
          captureNativeApi: false,
        ));
    final uploader = ReplayUploader(
        writeKey: 'test',
        host: 'http://localhost',
        dio: Dio()..httpClientAdapter = _ReplayServer(200));
    final recorder = ReplayRecorder(
      config: const ReplayConfig(sampleRate: 1, maxFramesPerSession: 1),
      client: VectorSignal.client!,
      uploader: uploader,
      boundaryKey: VectorSignal.replayBoundaryKey,
    );

    var label = 'one';
    late StateSetter setLabel;
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => VectorSignalTapCapture(child: child!),
      home: Scaffold(
        body: StatefulBuilder(builder: (context, setState) {
          setLabel = setState;
          return Container(
              color: label == 'one' ? Colors.white : Colors.blue,
              child: Text(label));
        }),
      ),
    ));

    VectorSignal.track('screen_ready');
    recorder.start();
    await tester.runAsync(recorder.captureNow);
    expect(recorder.framesThisSession, 1);

    setLabel(() => label = 'two'); // the screen really changes
    await tester.pump();
    await tester.runAsync(recorder.captureNow);
    expect(recorder.framesThisSession, 1);
    expect(uploader.queueLength, 1);

    recorder.stop();
    uploader.dispose();
    VectorSignal.shutdown();
  });

  test('uploader stops for good when the server has replay off (503)',
      () async {
    final server = _ReplayServer(503);
    final uploader = ReplayUploader(
        writeKey: 'test',
        host: 'http://localhost',
        dio: Dio()..httpClientAdapter = server);
    uploader.add({'image': 'AAAA'});
    await uploader.flush();
    expect(uploader.isDisabled, isTrue);
    uploader.add({'image': 'AAAA'});
    expect(uploader.queueLength, 0);
    uploader.dispose();
  });

  test('uploader keeps frames when offline and caps the buffer', () async {
    final uploader = ReplayUploader(
        writeKey: 'test',
        host: 'http://localhost',
        dio: Dio()..httpClientAdapter = _ReplayServer(500));
    for (var i = 0; i < 30; i++) {
      uploader.add({'image': 'AAAA', 'i': i});
    }
    await uploader.flush();
    expect(uploader.isDisabled, isFalse);
    expect(uploader.queueLength, ReplayUploader.maxQueuedFrames);
    uploader.dispose();
  });

  test('RenderVSMask is a plain proxy', () {
    expect(RenderVSMask(mask: true), isA<RenderProxyBox>());
  });
}
