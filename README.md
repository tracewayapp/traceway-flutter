<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/tracewayapp/traceway/main/Traceway%20Logo%20White.png" />
    <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/tracewayapp/traceway/main/Traceway%20Logo.png" />
    <img src="https://raw.githubusercontent.com/tracewayapp/traceway/main/Traceway%20Logo.png" alt="Traceway" width="200" />
  </picture>
</p>

<p align="center">
  <a href="https://pub.dev/packages/traceway"><img src="https://img.shields.io/pub/v/traceway.svg" alt="pub.dev"></a>
  <a href="https://github.com/tracewayapp/traceway-flutter/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License"></a>
</p>

# Traceway Flutter SDK

Error tracking and screen recording for Flutter apps. Capture exceptions with full stack traces and the last 10 seconds of screen recording — automatically.

[Traceway](https://tracewayapp.com) is a completely open-source error tracking platform. You can [self-host](https://docs.tracewayapp.com/server) it or use [Traceway Cloud](https://tracewayapp.com).

## Features

- Automatic capture of all Flutter errors (framework, platform, and async)
- Full Dart stack traces
- Screen recording — last ~10 seconds encoded as MP4 video
- Touch/click positions rendered on recordings
- **Logs** — every `print` / `debugPrint` from the last ~10 seconds
- **Actions** — HTTP requests, navigation transitions, and custom user-defined breadcrumbs from the last ~10 seconds
- Privacy masking — blur or blank sensitive UI regions in recordings
- Disk persistence — pending exceptions survive app restarts
- Gzip-compressed transport
- Simple one-line setup

## Installation

```bash
flutter pub add traceway
```

## Quick Start

Wrap your app with `Traceway.run()`:

```dart
import 'package:flutter/material.dart';
import 'package:traceway/traceway.dart';

void main() {
  Traceway.run(
    connectionString: 'your-token@https://your-traceway-instance.com/api/report',
    options: TracewayOptions(
      screenCapture: true,
      version: '1.0.0',
    ),
    child: MyApp(),
  );
}
```

That's it. All uncaught exceptions are captured automatically.

## Manual Capture

```dart
// Capture a caught exception
try {
  await riskyOperation();
} catch (e, st) {
  TracewayClient.instance?.captureException(e, st);
}

// Capture a message
TracewayClient.instance?.captureMessage('User completed checkout');

// Force send pending events
await TracewayClient.instance?.flush();
```

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `sampleRate` | `1.0` | Error sampling rate (0.0 - 1.0) |
| `screenCapture` | `false` | Record last ~10 seconds of screen |
| `debug` | `false` | Print debug info to console |
| `version` | `''` | App version string |
| `debounceMs` | `1500` | Milliseconds before sending batched events |
| `retryDelayMs` | `10000` | Retry delay on failed uploads |
| `capturePixelRatio` | `0.75` | Screenshot resolution scale factor |
| `maxBufferFrames` | `150` | Max frames in recording buffer (~10s at 15fps) |
| `fps` | `15` | Frames per second for screen capture (1–59) |
| `maxPendingExceptions` | `5` | Max exceptions held in memory before oldest is dropped |
| `persistToDisk` | `true` | Persist pending exceptions to disk so they survive app restarts |
| `maxLocalFiles` | `5` | Max exception files stored on disk |
| `localFileMaxAgeHours` | `12` | Hours after which unsynced local files are deleted |
| `captureLogs` | `true` | Mirror every `print` / `debugPrint` into the rolling log buffer |
| `captureNetwork` | `true` | Install `HttpOverrides.global` to record every dart:io HTTP call |
| `captureNavigation` | `true` | Record navigation transitions reported by `Traceway.navigatorObserver` |
| `eventsWindow` | `10s` | Rolling window kept in the log/action buffers |
| `eventsMaxCount` | `200` | Hard cap applied independently to logs and actions |

## Platform Setup

Traceway needs network access to send error reports. Depending on the platform, you may need to add permissions manually.

### Android

Add the `INTERNET` permission to `android/app/src/main/AndroidManifest.xml`:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.INTERNET"/>
    <application
      ...
```

### macOS

macOS apps are sandboxed by default and cannot make network requests without the `com.apple.security.network.client` entitlement.

Add it to both `macos/Runner/DebugProfile.entitlements` and `macos/Runner/Release.entitlements`:

```xml
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
```

### iOS

No additional configuration is required. iOS apps can make HTTPS requests by default.

## Screen Recording

When `screenCapture: true`, the SDK:

1. Wraps your app in a `RepaintBoundary`
2. Captures frames at ~15fps into a circular buffer
3. On exception, encodes the last ~10 seconds to MP4
4. Sends the video alongside the stack trace

Touch and click positions are drawn directly onto the recorded frames (invisible to the user) so you can see exactly what the user was doing before the crash.

## Logs & Actions

Every captured exception ships with the last ~10 seconds of session context, attached to the same session recording as the video:

- **Logs** — every `print` / `debugPrint` line, captured via a Zone print override. `dart:developer.log` is **not** captured.
- **Actions** are split into three channels:
  - **Network** — every dart:io HTTP request (method, URL, status, duration, byte counts) via `HttpOverrides.global`. Catches `package:http`, Dio, Firebase, anything on dart:io. On Flutter web use `TracewayHttpClient` (see below).
  - **Navigation** — push / pop / replace / remove from any `Navigator`, by attaching `Traceway.navigatorObserver` to your app.
  - **Custom** — anything you call `Traceway.recordAction(...)` with.

Logs and actions are kept in two separate rolling buffers, each capped at 200 entries / 10 seconds. They ship inside `sessionRecordings[].logs` and `sessionRecordings[].actions` on the wire — separate from the MP4 video chunks. Each recording also carries `startedAt` and `endedAt` ISO 8601 timestamps so the backend can align logs and actions onto the video timeline (`offsetIntoVideoMs = event.timestamp − recording.startedAt`).

### Wire up navigation capture

```dart
MaterialApp(
  navigatorObservers: [Traceway.navigatorObserver],
  // ...
)
```

### Record a custom action

```dart
Traceway.recordAction(
  category: 'cart',
  name: 'add_item',
  data: {'sku': 'SKU-123', 'qty': 2},
);
```

### Network capture on Flutter web (or with an explicit client)

`HttpOverrides.global` does not run on Flutter web. Use `TracewayHttpClient` instead — it's a drop-in `http.Client`:

```dart
import 'package:traceway/traceway.dart';

final client = TracewayHttpClient();
final res = await client.get(Uri.parse('https://api.example.com/users'));
```

Pass it to Dio, Chopper, or any library that accepts a custom `http.Client`.

### Disable a channel

Each channel can be turned off individually via `TracewayOptions`:

```dart
TracewayOptions(
  captureLogs: false,
  captureNetwork: false,
  captureNavigation: false,
)
```

## Privacy Masking

Use `TracewayPrivacyMask` to hide sensitive content in screen recordings. Masked regions are applied to the recorded frames only — the user sees no visual change in the live app.

**Blur (pixelation):**

```dart
TracewayPrivacyMask(
  child: Text('4242 4242 4242 4242'),
)
```

The default mode is `TracewayMaskMode.blur()` which pixelates the region. You can control the intensity with the `ratio` parameter (0.0 = light, 1.0 = heavy):

```dart
TracewayPrivacyMask(
  mode: TracewayMaskMode.blur(ratio: 0.5),
  child: CreditCardWidget(),
)
```

**Blank (solid fill):**

```dart
TracewayPrivacyMask(
  mode: TracewayMaskMode.blank(color: Color(0xFF000000)),
  child: SensitiveDataWidget(),
)
```

This replaces the region with a solid color (black by default) in the recording.

## Platform Support

| Platform | Error Tracking | Screen Recording |
|----------|---------------|-----------------|
| iOS | Yes | Yes |
| Android | Yes | Yes |
| macOS | Yes | Yes |
| Web | No | No |

For Flutter web, use the JS SDK instead — see [Flutter Web](#flutter-web) below.

## Performance

Measured on Firebase Test Lab — Pixel 5 (API 30), Pixel 6 (API 33), Pixel 8 (API 34), iPhone 8 / 14 Pro / 16 Pro across 10 workloads (idle, scroll, navigation, video playback, exception bursts, and combinations) for each of four configs: no SDK, SDK loaded but idle, SDK actively recording, and SDK recording with disk persistence. Full benchmark harness lives in [`example/integration_test/`](example/integration_test/) and runs as a GitHub Action — re-run it on your own device tier any time.

| Cost | When idle (`screenCapture: false` or no recording yet) | While actively recording |
|------|------|------|
| **Memory overhead** (RSS) | **+0 MB median**, max +10 MB across all tested devices | **+16 MB median** (≈ +8%), worst measured +66 MB during video-playback bursts on iPhone 14 Pro |
| **Wall-clock impact** (steady state) | **0%** | **0%** median |
| **Frame timing** (p50/p99 build duration) | Within measurement noise on every workload | Within measurement noise on every workload |
| **Exception capture latency** | n/a (SDK not initialized) | **0.09–0.35 ms on iOS**, 5–12 ms on Android — both well under one 60 Hz frame budget (16.7 ms) |
| **Disk persistence cost** | n/a | Adds no measurable RAM beyond in-memory recording |

### What we guarantee

1. **If `screenCapture: false` or no recording is in progress, Traceway adds < 10 MB of RSS.** On most devices it adds zero measurable memory.
2. **Median memory overhead during active recording is under 20 MB.** In the worst measured scenario on the lowest-RAM device tested, it stayed under 80 MB.
3. **Disk persistence does not increase memory cost.** Writing recordings to disk consumes the same RAM as in-memory-only recording.
4. **Exception capture is sub-millisecond on iOS and under 15 ms on Android.** Both are below a single frame at 60 Hz, so capturing an exception cannot cause a dropped frame in steady state.
5. **Steady-state wall-clock impact is zero.** Your app does not run measurably slower with Traceway initialized.

### Caveats

- Numbers are from a single benchmark run; the underlying methodology is open. The exact `runId` and full per-device breakdown are produced by the [Performance Benchmarks workflow](.github/workflows/benchmark.yml).
- Frame-timing numbers carry measurement noise that can swing ±50% on individual scenarios; what we claim is "no statistically meaningful regression on any tested workload", not "the SDK speeds your app up".
- Worst-case memory peaks come from synthetic burst workloads (rapid exceptions during video playback). Real apps that throw 1-2 exceptions per session will sit close to the median numbers.

## What Gets Captured Automatically

- **Flutter framework errors** — rendering, layout, gestures via `FlutterError.onError`
- **Platform errors** — native plugin crashes via `PlatformDispatcher.onError`
- **Uncaught async errors** — unhandled futures via `runZonedGuarded`

## Flutter Web

This SDK does not support Flutter web. For web apps, use the [`@tracewayapp/frontend`](https://docs.tracewayapp.com/client/js-sdk?sdk=js-generic) JS SDK which provides rrweb session replay and automatic fetch instrumentation.

**Add the CDN script to `web/index.html`:**

```html
<script src="https://cdn.jsdelivr.net/npm/@tracewayapp/frontend@1/dist/traceway.iife.global.js"></script>
<script>
  Traceway.init("your-token@https://traceway.example.com/api/report");
</script>
```

Alternatively, if you use npm in your Flutter web project:

```bash
npm install @tracewayapp/frontend
```

```html
<script type="module">
  import { init } from '@tracewayapp/frontend';
  init('your-token@https://traceway.example.com/api/report');
</script>
```

See the full [JS SDK documentation](https://docs.tracewayapp.com/client/js-sdk?sdk=js-generic) for all options.

## Links

- [Traceway Website](https://tracewayapp.com)
- [Traceway GitHub](https://github.com/tracewayapp/traceway)
- [Documentation](https://docs.tracewayapp.com/client/flutter?sdk=flutter)
- [Flutter SDK Source](https://github.com/tracewayapp/traceway-flutter)

## License

MIT
