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
| `captureIntervalMs` | `67` | Frame capture interval (~15fps) |

## Screen Recording

When `screenCapture: true`, the SDK:

1. Wraps your app in a `RepaintBoundary`
2. Captures frames at ~15fps into a circular buffer
3. On exception, encodes the last ~10 seconds to MP4
4. Sends the video alongside the stack trace

Touch and click positions are drawn directly onto the recorded frames (invisible to the user) so you can see exactly what the user was doing before the crash.

## Platform Support

| Platform | Error Tracking | Screen Recording |
|----------|---------------|-----------------|
| iOS | Yes | Yes |
| Android | Yes | Yes |
| macOS | Yes | Yes |
| Web | No | No |

Flutter web apps should use the [Traceway JS SDK](https://github.com/tracewayapp/js-client) instead.

## What Gets Captured Automatically

- **Flutter framework errors** — rendering, layout, gestures via `FlutterError.onError`
- **Platform errors** — native plugin crashes via `PlatformDispatcher.onError`
- **Uncaught async errors** — unhandled futures via `runZonedGuarded`

## Links

- [Traceway Website](https://tracewayapp.com)
- [Traceway GitHub](https://github.com/tracewayapp/traceway)
- [Documentation](https://docs.tracewayapp.com/client/flutter)
- [Flutter SDK Source](https://github.com/tracewayapp/traceway-flutter)

## License

MIT
