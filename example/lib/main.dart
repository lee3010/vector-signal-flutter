import 'package:flutter/material.dart';
import 'package:vector_signal_flutter/vector_signal_flutter.dart';

// Pass these with --dart-define. 10.0.2.2 is the PC as seen from the Android emulator.
const _host =
    String.fromEnvironment('VS_HOST', defaultValue: 'http://10.0.2.2:5181');
const _writeKey = String.fromEnvironment('VS_WRITE_KEY');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await VectorSignal.init(
    writeKey: _writeKey,
    host: _host,
    appVersion: '0.1.0-example',
    flushInterval: const Duration(seconds: 10),
  );
  await VectorSignal.identify('example-agent-1');
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vector Signal Example',
      theme: ThemeData(colorSchemeSeed: const Color(0xFFE16969)),
      navigatorObservers: [VectorSignalObserver()],
      builder: (context, child) => VectorSignalTapCapture(child: child!),
      initialRoute: '/home',
      routes: {
        '/home': (_) => const HomeScreen(),
        '/payout-session': (_) => const PayoutSessionScreen(),
        '/wallet': (_) => const WalletScreen(),
      },
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Home')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_writeKey.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                    'VS_WRITE_KEY is not set, so events cannot be delivered. See example/README.md.'),
              ),
            ),
          FilledButton(
            onPressed: () => Navigator.pushNamed(context, '/payout-session'),
            child: const Text('Open payout session'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => Navigator.pushNamed(context, '/wallet'),
            child: const Text('Open wallet'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () =>
                VectorSignal.track('example_custom_event', {'source': 'home'}),
            child: const Text('Send custom event'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () =>
                throw StateError('Example error from the home screen'),
            child: const Text('Throw an error'),
          ),
          const SizedBox(height: 8),
          const OutlinedButton(
            onPressed: VectorSignal.flush,
            child: Text('Flush now'),
          ),
        ],
      ),
    );
  }
}

class PayoutSessionScreen extends StatelessWidget {
  const PayoutSessionScreen({super.key});

  Future<void> _create(BuildContext context) async {
    VectorSignal.track('payout_session_create');
    final messenger = ScaffoldMessenger.of(context);
    try {
      // A slow "backend call" (over the 3 s slow-API threshold).
      await VectorSignal.timeApi('createPayoutSession',
          () => Future.delayed(const Duration(milliseconds: 3500)));
      VectorSignal.track('payout_session_success');
      messenger.showSnackBar(
          const SnackBar(content: Text('Session created (slow API recorded)')));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('Failed')));
    }
  }

  Future<void> _fail(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await VectorSignal.timeApi<void>('getPayoutSessions', () async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        throw Exception('Simulated server error');
      });
    } catch (_) {
      messenger
          .showSnackBar(const SnackBar(content: Text('API failed (recorded)')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Payout session')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
                'Tap "Create" several times quickly to produce a rage tap.'),
            const SizedBox(height: 12),
            VSLabel(
              name: 'create_payout_session',
              child: FilledButton(
                  onPressed: () => _create(context),
                  child: const Text('Create')),
            ),
            const SizedBox(height: 8),
            VSLabel(
              name: 'does_nothing',
              child: OutlinedButton(
                  onPressed: () {},
                  child: const Text('Button that does nothing (dead tap)')),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
                onPressed: () => _fail(context),
                child: const Text('Simulate failed API')),
          ],
        ),
      ),
    );
  }
}

class WalletScreen extends StatelessWidget {
  const WalletScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Wallet')),
      body: const Center(
          child: Text(
              'Go back and forth between Home and Wallet to produce a loop.')),
    );
  }
}
