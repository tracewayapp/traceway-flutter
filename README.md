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

Error tracking, session context and screen recording for Flutter apps, built on the standard [OpenTelemetry](https://opentelemetry.io) SDK for Dart. Exceptions arrive with full stack traces, the breadcrumbs that led up to them and the last ~10 seconds of screen recording — automatically.

[Traceway](https://tracewayapp.com) is a completely open-source error tracking platform. You can [self-host](https://docs.tracewayapp.com/server) it or use [Traceway Cloud](https://tracewayapp.com).

> **2.0 is a beta.** It speaks OTLP and OpAMP and needs a Traceway server that supports Flutter projects on those endpoints. On an older server stay on `traceway: ^1.0.9`. See [Migrating from 1.x](#migrating-from-1x).

## Features

- Automatic capture of all Flutter errors (framework, platform, and async)
- Full Dart stack traces, with symbolication for obfuscated builds
- **OpenTelemetry inside** — logs and spans go through the standard OTel SDK (`dartastic_opentelemetry`) and leave as OTLP/HTTP
- **Ring buffer** — logs, HTTP requests, navigation and custom events stay on the device and are uploaded only when something goes wrong
- **Remote config over OpAMP** — change what is collected from the dashboard, per app version, user or device, without a release; or ship the same settings in the app with `collection:`
- **Captures on demand** — from the dashboard, or from a recording trigger on the device (a journey of taps, navigations and log lines): the buffered lookback goes up, then logs, requests and video stream until the capture ends
- **Taps that name the widget** — every tap is recorded with a CSS-like selector (`ElevatedButton#pay`, `IconButton[label="Delete"]`) that click steps of recording triggers match
- Screen recording — the last ~10 seconds encoded as MP4, uploaded as the clip of an exception, or as consecutive segments while a capture streams (Android, iOS, macOS)
- Touch/click positions rendered on recordings
- Privacy masking — blur or blank sensitive UI regions in recordings
- Sessions, with the breadcrumb timeline of each one
- Telemetry that failed to send is kept on disk and retried; the ring buffer is saved when the app goes to the background, so a session that goes on after the system killed the app still has its breadcrumbs (`buffer.persist`)
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

// A named product event; triggers can match it by name
Traceway.track('checkout_failed', {'reason': 'card_declined'});

// Attributes attached to every later record, and usable to target this
// user or device from the dashboard
Traceway.setAttribute('user.id', user.id);

// Send what is ready now
await TracewayClient.instance?.flush();
```

## How collection works

Every record is an OpenTelemetry log record or span and belongs to a *signal*. Each signal has a mode:

| Mode | Meaning |
|------|---------|
| `stream` | sent as soon as it is produced |
| `buffer` | kept in a ring buffer on the device (2 MB / 10 minutes by default) until a trigger flushes it |
| `off` | dropped |

| Signal | Source | Default |
|--------|--------|---------|
| `errors` | uncaught errors, `captureException` | stream |
| `messages` | `captureMessage` | stream |
| `console` | `print` / `debugPrint` | buffer |
| `network` | HTTP requests (client spans) | buffer |
| `navigation` | `Traceway.navigatorObserver`, `Traceway.recordNavigation` | buffer |
| `userActions` | taps (`browser.user_action.click`) | buffer |
| `custom` | `Traceway.recordAction`, `Traceway.track` | buffer |
| replay | screen recording | buffer |

The built-in trigger fires on every exception: it uploads the buffered breadcrumbs of the last 10 minutes and the screen-recording clip. An app that never throws sends only its session start and end. Clips are rationed to one per 5 seconds and 20 per session; breadcrumbs are still sent for the exceptions in between.

`recordAllSessions: true` streams every breadcrumb signal and the screen recording instead. The signal names, modes, triggers and limits are the browser SDK's, so one rule can target both.

## Remote config

The SDK polls the server over [OpAMP](https://opentelemetry.io/docs/specs/opamp/) (plain HTTP, every 5 minutes by default) and applies the collection settings you define under **Project → Data Collection** in the dashboard: signal modes and sample rates, buffer sizes, extra triggers (for example "flush when `checkout_failed` happens twice in a minute") and on-demand captures of one user or device.

- The options you pass to `Traceway.run` are **ceilings**. Remote settings can lower what is collected but never raise it: with `captureNetwork: false` no rule can turn network capture on, and without `screenCapture: true` nothing is recorded.
- The last applied settings are cached, so they are in effect from the first frame of the next start.
- Set `remoteConfig: false` to never poll.

### Local config

`collection:` takes the same settings document a rule holds and lays it over the built-in defaults, so an app can define its own policy and triggers without the server. With `remoteConfig: true` the server's rules apply on top of it; with `remoteConfig: false` it is the whole policy.

```dart
Traceway.run(
  connectionString: '...',
  options: const TracewayOptions(
    screenCapture: true,
    remoteConfig: false,
    collection: {
      'signals': {'network': {'mode': 'stream'}},
      'buffer': {'maxAgeSeconds': 300},
      'triggers': [
        {
          'id': 'checkout-failed-twice',
          'steps': [
            {'match': {'key': 'event.name', 'op': 'eq', 'value': 'checkout_failed'}, 'count': 2, 'periodSeconds': 60},
          ],
          'actions': [
            {'type': 'capture', 'durationSeconds': 300, 'lookbackSeconds': 120, 'replay': true},
          ],
        },
      ],
    },
  ),
  child: const MyApp(),
);
```

An invalid document is ignored with a console warning, and the defaults apply.

## Captures

A capture uploads what the device holds from its lookback window and then streams the selected signals, and the screen recording when it asks for replay, until it ends. Records sent under a capture carry its id (`traceway.capture.ids`), so the dashboard shows when it is collecting.

- **From the dashboard**: the Capture button on a session or issue targets one installation (`service.instance.id`), user (`user.id`) or session. The device starts it at its next poll; cancelling it stops the streaming at the poll after that. Each capture's lookback is uploaded once per installation.
- **From a trigger** (`{"type": "capture", ...}` action): started on the device the moment the trigger fires. It survives app restarts until it ends; firing again only extends it.

While a capture streams replay, the recording leaves as consecutive MP4 segments of about 8 seconds that start where the previous one ended. An exception during a streaming capture still gets a clip of its own. Video needs a hardware encoder: Android, iOS and macOS. On other platforms `screenCapture` records nothing and captures bring logs and requests only.

### Recording triggers: journeys of taps, navigations and logs

The dashboard's *recording trigger* steps work in Flutter. A step is one of:

| Step | Matches |
|------|---------|
| `{"event": {"type": "click", "value": "<selector>"}}` | a tap on a widget the selector matches, or inside one |
| `{"event": {"type": "hover", "value": "<selector>"}}` | the mouse entering a matching widget (desktop and web; never touch) |
| `{"event": {"type": "navigation", "value": "/users/{id}"}}` | arriving at a route; `{id}` is one non-empty segment |
| `{"event": {"type": "log", "value": "Profile loaded", "mode": "contains"}}` | a `print` / `debugPrint` line or a `captureMessage` (`exact` by default) |

Steps match in order, each within its `withinSeconds` of the previous one; progress survives an app restart within the session. When a trigger that asks for replay fires, the session lists it as a recording reason with its sequence.

#### Naming widgets

Flutter has no DOM, so click and hover selectors run over the element tree under the pointer. The syntax is the CSS subset the dashboard validates:

| Selector | Matches a widget that |
|----------|-----------------------|
| `ElevatedButton` | is of that type (generic arguments ignored) |
| `#checkout` | has `Key('checkout')` (a `ValueKey<String>`), or is `Semantics(identifier: 'checkout')` |
| `.button` | is a `Semantics` with that role: `button`, `link`, `header`, `image`, `textField`, `slider`, `checkbox`, `toggle`, `selected` |
| `[key="42"]` | has a `ValueKey` whose value reads `42` |
| `[identifier="..."]` | has that `Semantics.identifier` |
| `[label="Delete"]` | has that semantics label or tooltip (an `IconButton`'s tooltip, an `Icon`'s semantic label) |
| `[text="Pay"]` | shows that text: a `Text`'s own, or the text of the `Text` widgets under it; never the content of an input field |
| `[type="_Private"]` | is of a type that cannot be written as a tag |

Attribute values take `=`, `^=`, `$=`, `*=`, `~=` and `|=`. Combinators are descendant (space), child (`>`), adjacent (`+`) and general (`~`) sibling, in the element tree, where a widget such as `ElevatedButton` sits several elements above the `Text` it shows, so prefer the descendant combinator. A tap matches when the widget under the finger or any widget around it does, the way a browser click matches its target or an ancestor.

You rarely write one by hand: every tap is recorded as `browser.user_action.click` with the selector of the control that handled it (`browser.css_selector`), shown on the session timeline. It prefers an id (`ElevatedButton#pay`, or `CheckoutButton#checkout` for your own widget with a key), then a key, the shown text, the label, and the type alone. Keys and `Semantics(identifier:)` (the ones integration tests and Appium/Maestro use) are the most stable choice. The text of a widget inside `TracewayPrivacyMask` is never sent.

Widget type names are minified in `--obfuscate` builds and in Flutter web release builds: there, match by key, identifier, role, label or text, and recorded selectors leave the type out.

#### Naming routes

A navigation step matches the path the observer reports for the route on top:

- its name (`RouteSettings.name`): named routes, `onGenerateRoute`, and routers that name their pages,
- else `/` and the page widget's type, e.g. `/CheckoutPage` for `MaterialPageRoute(builder: (_) => const CheckoutPage())`,
- else `/` and the route's type, e.g. `/DialogRoute`.

A router that does not report to a `NavigatorObserver` can report its location itself:

```dart
final router = GoRouter(routes: [...]);
router.routerDelegate.addListener(() => Traceway.recordNavigation(
    router.routerDelegate.currentConfiguration.uri.path));
```

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `sampleRate` | `1.0` | Share of exceptions and messages that are reported (0.0 - 1.0) |
| `screenCapture` | `false` | Record the screen: the last ~10 seconds go up with an exception, and captures can stream it (Android, iOS, macOS) |
| `debug` | `false` | Print debug info to console |
| `version` | `''` | App version, sent as `service.version` |
| `serviceName` | `flutter-app` | Sent as `service.name` |
| `environment` | — | Sent as `deployment.environment.name` |
| `attributes` | `{}` | Attributes attached to every record |
| `capturePixelRatio` | `0.75` | Screenshot resolution scale factor |
| `maxBufferFrames` | `150` | Frames in the recording ring buffer (~10s at 15fps); the upper bound of every clip |
| `fps` | `15` | Frames per second for screen capture (1–59) |
| `persistToDisk` | `true` | Keep SDK state and undelivered telemetry on disk across restarts |
| `captureLogs` | `true` | Capture every `print` / `debugPrint` |
| `captureNetwork` | `true` | Install `HttpOverrides.global` to record every dart:io HTTP call |
| `captureNavigation` | `true` | Record navigation transitions reported by `Traceway.navigatorObserver` |
| `captureUserActions` | `true` | Record taps with the selector of the widget, and feed taps and hovers to recording triggers |
| `recordAllSessions` | `false` | Stream breadcrumbs and the screen recording all the time instead of keeping them for errors |
| `collection` | — | Local collection settings, the same document as a remote-config rule (see [Local config](#local-config)) |
| `sessions` | `true` | Track sessions |
| `baselineSampleRate` | `0` | Share of sessions whose breadcrumbs are sent continuously, not only around errors |
| `remoteConfig` | `true` | Poll the server for collection settings over OpAMP |
| `exportDelayMs` | `1000` | How long finished records wait to be sent as one batch |

## Screen Recording

When `screenCapture: true`, the SDK:

1. Wraps your app in a `RepaintBoundary`
2. Captures frames at ~15fps into a circular buffer of `maxBufferFrames` frames (~10 seconds)
3. On an exception, encodes the buffered frames to MP4
4. Uploads the clip to the recordings endpoint, linked to the exception by its id

Nothing is encoded or uploaded unless an exception is captured or a capture streams replay, and a clip can never be longer than the frame buffer. While a capture streams, the session is uploaded as consecutive segments, each shorter than the frame buffer. Touch and click positions are drawn directly onto the recorded frames (invisible to the user) so you can see exactly what the user was doing before the crash.

## Logs & Actions

Breadcrumbs are OpenTelemetry records held in the ring buffer and shown on the session timeline next to the exception that flushed them:

- **Logs** — every `print` / `debugPrint` line, captured via a Zone print override. `dart:developer.log` is **not** captured.
- **Network** — every dart:io HTTP request as a client span (method, URL, status, duration, byte counts) via `HttpOverrides.global`. Catches `package:http`, Dio, Firebase, anything on dart:io. The SDK's own requests are not recorded. On Flutter web use `TracewayHttpClient` (see below).
- **Navigation** — push / pop / replace / remove from any `Navigator`, by attaching `Traceway.navigatorObserver` to your app.
- **Taps** — every tap inside the `Traceway` widget, with the selector, type, id, shown text and label of the widget, and the screen (`browser.user_action.click`, with the OpenTelemetry `app.widget.*` and `app.screen.*` attributes).
- **Custom** — anything you call `Traceway.recordAction(...)` or `Traceway.track(...)` with.

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
| Linux, Windows | Yes | No (no video encoder) |
| Web | No | No |

For Flutter web, use the JS SDK instead — see [Flutter Web](#flutter-web) below.

## Performance

> These numbers were measured on 1.x. The capture path (frames, encoding) is unchanged in 2.0, but the transport is new and has not been re-benchmarked yet.

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

## Migrating from 1.x

- **Server**: 2.0 sends OTLP to `/api/otel/v1/logs` and `/api/otel/v1/traces`, polls `/api/otel/v1/opamp` and uploads clips to `/api/recordings`. There is no fallback to the 1.x `/api/report` protocol.
- **Connection string**: unchanged. `token@https://host/api/report` still works; the other endpoints are derived from it.
- **Behaviour**: logs and actions are no longer limited to the last 10 seconds and no longer travel inside the recording. They are buffered for up to 10 minutes and sent as their own records with an exception. `captureMessage` no longer attaches a screen recording.
- **Removed options**: `debounceMs`, `retryDelayMs`, `maxPendingExceptions`, `maxLocalFiles`, `localFileMaxAgeHours`, `eventsWindow`, `eventsMaxCount`.
- **New API**: `Traceway.track`, `Traceway.setAttribute`, `TracewayClient.refreshConfig`, `shutdown`, `getInstanceId`.
- **OpenTelemetry**: the SDK initializes the global `OTel` instance of `dartastic_opentelemetry`. If your app already initializes it, Traceway attaches its processors to the existing providers instead.

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

## Release symbolication (only for obfuscated/split builds)

You usually don't need to do anything. A plain `flutter build --release` keeps
enough symbol information that crash stack traces are already readable
(function names + file:line), and the SDK reports them as-is.

You only need to upload debug symbols **if you build with `--obfuscate` and/or
`--split-debug-info`**. Those flags shrink the app and protect your code by
stripping and renaming that information, so release traces then arrive as bare
instruction offsets. In that case the SDK forwards the raw trace and Traceway
turns it back into `function (file:line:col)` server-side using the `.symbols`
files you upload.

### One-time setup

Add a `traceway:` block to your app's `pubspec.yaml`:

```yaml
traceway:
  url: https://your-traceway-host   # omit if you use Traceway Cloud
  # upload_token: ...               # prefer the env var below, especially in CI
```

The upload token is your project's upload token from the dashboard (the same
one used for JavaScript source maps), not the runtime token in your
`Traceway.run()` connection string.

### Per release

```sh
flutter build apk --release --obfuscate --split-debug-info=build/symbols

TRACEWAY_UPLOAD_TOKEN=your-token dart run traceway:upload_symbols
```

The uploader reads `url` and the token from config/env and auto-discovers
`build/symbols`, so no flags are required. Each value resolves from a CLI flag
first (`--token`, `--url`, `--symbols-dir`), then an env var
(`TRACEWAY_UPLOAD_TOKEN`, `TRACEWAY_URL`), then `pubspec.yaml`. Use
`--dry-run` to preview. Symbols are unique to each build, so upload on every
release; a crash can only be symbolicated against the exact build it came from.

Each symbols file is keyed by its debug id plus architecture. On Android the
debug id is read from the file directly. On iOS and macOS the file doesn't carry
it, so the uploader reads it from the built app's Mach-O UUID (the same value
the runtime reports); it auto-discovers the `.app` under `build/`, or point it
explicitly with `--app build/macos/Build/Products/Release/YourApp.app`.

## Links

- [Traceway Website](https://tracewayapp.com)
- [Traceway GitHub](https://github.com/tracewayapp/traceway)
- [Documentation](https://docs.tracewayapp.com/client/flutter?sdk=flutter)
- [Flutter SDK Source](https://github.com/tracewayapp/traceway-flutter)

## License

MIT
