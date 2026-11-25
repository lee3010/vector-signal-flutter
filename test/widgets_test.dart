import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_signal_flutter/vector_signal_flutter.dart';

class _NullTransport implements VectorSignalTransport {
  @override
  Future<VectorSignalSendResult> send(List<Map<String, dynamic>> batch) async =>
      const VectorSignalSendResult(VectorSignalSendStatus.retry);
}

void main() {
  group('TapClassifier', () {
    test('short, still press is a tap', () {
      expect(
          TapClassifier.isTap(Offset.zero, const Offset(5, 5),
              const Duration(milliseconds: 120)),
          isTrue);
    });
    test('movement makes it a drag', () {
      expect(
          TapClassifier.isTap(Offset.zero, const Offset(40, 0),
              const Duration(milliseconds: 120)),
          isFalse);
    });
    test('long hold is not a tap', () {
      expect(
          TapClassifier.isTap(
              Offset.zero, Offset.zero, const Duration(milliseconds: 800)),
          isFalse);
    });
  });

  group('ErrorCapture', () {
    test('records errors and always calls the previous handlers', () {
      final savedFlutter = FlutterError.onError;
      final savedPlatform = PlatformDispatcher.instance.onError;
      addTearDown(() {
        FlutterError.onError = savedFlutter;
        PlatformDispatcher.instance.onError = savedPlatform;
      });

      var previousFlutterCalls = 0;
      var previousPlatformCalls = 0;
      FlutterError.onError = (_) => previousFlutterCalls++;
      PlatformDispatcher.instance.onError = (_, __) {
        previousPlatformCalls++;
        return true;
      };

      final recorded = <String>[];
      final capture =
          ErrorCapture((type, message) => recorded.add('$type: $message'))
            ..install();

      FlutterError.onError!(FlutterErrorDetails(exception: StateError('boom')));
      final handled = PlatformDispatcher.instance.onError!(
          ArgumentError('bad'), StackTrace.empty);

      expect(previousFlutterCalls, 1);
      expect(previousPlatformCalls, 1);
      expect(handled, isTrue, reason: 'previous handler result is returned');
      expect(recorded, hasLength(2));
      expect(recorded.first, startsWith('StateError'));

      capture.uninstall();
      FlutterError
          .onError!(FlutterErrorDetails(exception: StateError('after')));
      expect(recorded, hasLength(2));
    });
  });

  testWidgets('tap capture, VSLabel and observer record events',
      (tester) async {
    final storage = MemoryVectorSignalStorage();
    await VectorSignal.init(
      writeKey: 'test',
      host: 'http://localhost',
      transport: _NullTransport(),
      storage: storage,
      captureErrors: false,
    );

    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [VectorSignalObserver()],
      initialRoute: '/home',
      routes: {
        '/home': (context) => Scaffold(
              body: Center(
                child: VSLabel(
                  name: 'create',
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).pushNamed('/wallet'),
                    child: const Text('Create'),
                  ),
                ),
              ),
            ),
        '/wallet': (_) => const Scaffold(body: Text('Wallet')),
      },
      builder: (context, child) => VectorSignalTapCapture(child: child!),
    ));

    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    final events = VectorSignal.client!.pendingEvents;
    final names = events.map((e) => e['event']).toList();
    expect(names,
        containsAllInOrder([r'$app_open', r'$screen', r'$tap', r'$screen']));

    final tap = events.firstWhere((e) => e['event'] == r'$tap');
    expect(tap['screen'], '/home');
    expect((tap['properties'] as Map)['label'], 'create');

    final screens = events
        .where((e) => e['event'] == r'$screen')
        .map((e) => e['screen'])
        .toList();
    expect(screens, ['/home', '/wallet']);

    // Stop the flush/save timers before the test binding checks for pending timers.
    VectorSignal.shutdown();
  });

  testWidgets('tap target tells buttons from blank space, toggles and text',
      (tester) async {
    var on = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            ElevatedButton(onPressed: () {}, child: const Text('Go')),
            GestureDetector(onTap: () {}, child: const Text('Plain tap')),
            StatefulBuilder(
              builder: (context, setState) => Switch(
                value: on,
                onChanged: (v) => setState(() => on = v),
              ),
            ),
            const SizedBox(width: 200, child: TextField()),
            const SizedBox(height: 80, child: Text('Just text')),
          ],
        ),
      ),
    ));

    TapTarget at(Finder finder) => TapTargetClassifier.classify(
        tester.getCenter(finder), tester.view.viewId);

    expect(at(find.text('Go')), TapTarget.button);
    expect(at(find.text('Plain tap')), TapTarget.button);
    expect(at(find.byType(Switch)), TapTarget.toggle);
    expect(at(find.byType(TextField)), TapTarget.text);
    expect(at(find.text('Just text')), TapTarget.none);
  });
}
