# vector_signal_flutter

Flutter SDK for **Vector Signal**, mobile UX analytics. It records screens, taps, API calls
and errors, and optionally masked session replay, so the Vector Signal dashboard can show
where users get stuck: rage taps, dead taps, slow or failing APIs, screen loops and
abandoned funnels.

The SDK needs a Vector Signal server and a project **write key**. It does nothing on its own.

## Install

```yaml
dependencies:
  vector_signal_flutter:
    git:
      url: https://github.com/lee3010/vector-signal-flutter.git
      ref: v0.2.0
```

Flutter 3.13 or newer. Android adds a small native part (API capture for OkHttp, fast
replay image encoding); other platforms use pure Dart.

## Start it

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await VectorSignal.init(
    writeKey: 'vs_...',                    // public project write key (can only send events)
    host: 'https://signal.example.com',   // your Vector Signal server
    appVersion: '1.4.0+2051',
  );
  runApp(const MyApp());
}
```

After login, link events to your **internal** user id (never a phone number or email). The
screens used before login are linked to the same user. On logout, forget the user:

```dart
await VectorSignal.identify(userId);
await VectorSignal.reset();
```

## Screens

```dart
MaterialApp(navigatorObservers: [VectorSignalObserver()], ...);
GoRouter(observers: [VectorSignalObserver()], routes: [...]);
```

Routes need a name. Pages inside a go_router `ShellRoute` / `StatefulShellRoute` use nested
navigators: add an observer there too, or call `VectorSignal.screen('/tab')` on tab change.

## Taps (and the replay area)

Wrap the app once:

```dart
MaterialApp(
  builder: (context, child) => VectorSignalTapCapture(child: child!),
  ...
);
```

Each tap records its position, the screen and what it hit (`button`, `toggle`, `text`,
`none`), never any text. Only button taps with no visible effect count as dead taps. Give
important buttons a stable label:

```dart
VSLabel(name: 'create_order', child: FilledButton(onPressed: create, child: Text(l10n.create)));
```

## API calls

One line where your app makes HTTP calls:

| Your app calls its API from | Add |
|---|---|
| Kotlin (OkHttp / Retrofit) | `OkHttpClient.Builder().addInterceptor(VectorSignalOkHttpInterceptor())` |
| Dart (Dio) | `dio.interceptors.add(VectorSignalDioInterceptor())` |
| Anything else | `await VectorSignal.timeApi('getWallet', () => call())` |

Only the method and path are recorded, with ids and personal values replaced:
`/api/user/12345` becomes `GET /api/user/{id}`. Query strings, headers and bodies are never
read.

## Custom events

```dart
VectorSignal.track('checkout_start');
VectorSignal.track('checkout_success', {'source': 'cart'});
```

## Errors

Uncaught Flutter and platform errors are recorded as `$error` (type plus a short message).
Handlers installed before `init`, such as Crashlytics, keep working. Turn off with
`captureErrors: false`.

## Session replay (optional, off by default)

```dart
await VectorSignal.init(..., replay: const ReplayConfig(sampleRate: 0.2));
```

- **Masked on the device, before upload:** all text, text fields and custom-painted areas
  (charts) are covered. Icons stay visible. Wrap anything else sensitive in `VSMask`; wrap
  safe labels in `VSUnmask`.
- Small frames only when something changes: about 1 per second for a few seconds after a
  touch or screen change, at most 1 per 10 s while untouched, and nothing after 2 minutes
  without a touch. At most 600 frames per session. WebP on Android.
- Frames are kept in memory only (never on the device's disk).
- Tell your users: mention usage analytics and screen recording in your privacy policy.

## Sending and offline

- Events are queued, saved to a private file and sent in batches: every 30 s, at 20 events,
  or when the app goes to the background. Network errors back off up to 5 minutes.
- At most 1,000 queued events; the oldest are dropped first.

## Privacy

- **Never collected:** text from widgets or text fields (in replay frames it is covered),
  contacts, location, device identifiers such as IMEI or advertising id.
- **Property filter:** keys that look sensitive (`password`, `pin`, `otp`, `token`,
  `balance`, `amount`, `account`, `card`, `bank`, `phone`, `email`, `address`...) are removed
  on the device and again on the server. Nested values are dropped, strings cut to 500
  characters, at most 50 properties per event.
- **Opt out:** `VectorSignal.setEnabled(false)` stops recording and clears unsent events.
- **Sampling:** `sampleRate: 0.1` records about 10% of installs.

## Example

See [example/](example/README.md).

## Licence

Free to use in apps that send data to a Vector Signal service. See [LICENSE](LICENSE).
