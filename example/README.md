# Vector Signal example app

A small app for trying the SDK against a locally running Vector Signal API. It sends screens, taps, a slow API call, a failed API call, errors and custom events.

## Run it

1. Start the API (`VectorSignal.Api`). In Development it prints a dev project's `X-VS-Write-Key` on start-up.
2. Run the app with that key:

   ```
   flutter run --dart-define=VS_WRITE_KEY=<write key> --dart-define=VS_HOST=http://10.0.2.2:5181
   ```

   - **Android emulator:** `10.0.2.2` is your PC, so the default host works.
   - **Physical phone:** use your PC's LAN IP instead, e.g. `--dart-define=VS_HOST=http://192.168.1.20:5181`. The phone must be on the same network, and the API must listen on that address (e.g. `ASPNETCORE_URLS=http://0.0.0.0:5181`).
   - **Plain `http://`:** Android blocks cleartext HTTP by default. For local testing, add `android:usesCleartextTraffic="true"` to the example's debug `AndroidManifest.xml`, or use HTTPS. Never ship that setting in a real app.

## Things to try

| Do this | What the dashboard should show |
|---|---|
| Tap **Create** 3+ times quickly | RageTap on `/payout-session` |
| Tap **Button that does nothing** once | DeadTap |
| Tap **Create** once and wait | SlowApi (`createPayoutSession`, ~3.5 s) |
| **Simulate failed API** | ApiError (`getPayoutSessions`) |
| **Throw an error** | AppError |
| Go Home → Wallet → Home → Wallet → Home → Wallet | Loop |

Events are sent every 10 seconds, when 20 are queued, when the app goes to the background, or when you tap **Flush now**.
