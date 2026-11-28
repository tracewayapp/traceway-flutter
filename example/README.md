# Traceway Flutter example

A small app that shows what the Traceway SDK records. Run it against your project:

```bash
flutter run --dart-define=TRACEWAY_TOKEN=YOUR_TOKEN
```

The token is on the project's **Connection** page in the dashboard; it sends to Traceway Cloud
(`https://cloud.tracewayapp.com`). For a self-hosted server add `--dart-define=TRACEWAY_URL=https://your-server`.
Without a token the app runs without Traceway and prints how to set it.

It starts the SDK with `Traceway.run`, `screenCapture: true` (wireframe replay) and `debug: true`, and attaches
`Traceway.navigatorObserver`. The buttons:

| Button | What reaches Traceway |
|---|---|
| Increment Counter | a tap, buffered with the session |
| Capture Caught Exception | an issue from `Traceway.captureException`, with its stack and a replay clip |
| Capture Message | an issue from `Traceway.captureMessage` |
| Throw Uncaught Exception / Trigger Null Error | an unhandled error, caught by the SDK's zone and error handlers |
| Print Log Lines | `print` lines, as logs on the session timeline |
| Burst HTTP Requests | client spans of `package:http` requests |
| Open Detail Page | a navigation, through the navigator observer |
| Record Custom Action | a breadcrumb from `Traceway.recordAction` |
| Generate Activity, Then Crash | breadcrumbs, then an error that uploads them with its clip |
| Flush (Force Send) | `Traceway.flush()` |

The text inside the `TracewayMask` is masked in the replay.

The app needs no native setup beyond the SDK's own: `INTERNET` in `android/app/src/main/AndroidManifest.xml` and the
network entitlement in `macos/Runner/*.entitlements` are there already.

Not examples, but test harnesses of the SDK:

- `lib/wireframe_suite/` — the wireframe regression gallery (`tool/e2e/wireframe`).
- `lib/e2e_main.dart` — the scripted end-to-end run against a real server (`tool/e2e/run.py`).
- `integration_test/` — the performance benchmarks.
