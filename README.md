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
- **App performance metrics** — cold and hot start, time to initial and full display per screen, slow and frozen frames, hangs, unhandled errors, sessions, users and HTTP requests, aggregated on the device and sent as OTLP metrics; they fill the project's Flutter Performance dashboard
- **Taps that name the widget** — every tap is recorded with a CSS-like selector (`ElevatedButton#pay`, `IconButton[label="Delete"]`) that click steps of recording triggers match
- Screen recording — the last ~10 seconds encoded as MP4, uploaded as the clip of an exception, or as consecutive segments while a capture streams (Android, iOS, macOS)
- Touch/click positions rendered on recordings
- Privacy masking — blur or blank sensitive UI regions in recordings
- Sessions, with the breadcrumb timeline of each one
- **Any OpenTelemetry backend** — send logs, spans and metrics to an OpenTelemetry Collector, Grafana, Honeycomb or any OTLP/HTTP receiver with `telemetry:`, next to Traceway or without it (standalone)
- Telemetry that failed to send is kept on disk and retried; the ring buffer is saved when the app goes to the background, so a session that goes on after the system killed the app still has its breadcrumbs (`buffer.persist`)
- Simple one-line setup

## Installation

```bash
flutter pub add 'traceway:^2.0.0-beta.1'
```

`flutter pub add traceway` without a version installs the newest stable release, 1.x. An app that installed the preview from Git (`ref: v2-session-capture`) replaces that dependency with the version above.

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

The connection string is the project token and the server URL, as the project's Connection page shows it. The bare server URL (`your-token@https://your-traceway-instance.com`) works too. To send telemetry to another OpenTelemetry backend as well, or only there, see [Setups](#setups).

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

The SDK polls the server over [OpAMP](https://opentelemetry.io/docs/specs/opamp/) (plain HTTP: at start, every 5 minutes by default, when the app returns to the foreground, and about 2 seconds after `Traceway.setAttribute` or a new session, so a rule targeting an attribute applies soon) and applies the collection settings you define under **Project → Data Collection** in the dashboard: signal modes and sample rates, buffer sizes, extra triggers (for example "flush when `checkout_failed` happens twice in a minute") and on-demand captures of one user or device.

- The `capture*` options, `screenCapture` and `sessions` are **ceilings**. Remote settings can lower what is collected but never raise it: with `captureNetwork: false` no rule can turn network capture on, and without `screenCapture: true` nothing is recorded. `sampleRate`, `baselineSampleRate` and `recordAllSessions` are defaults: a rule can change them in either direction.
- The last applied settings are cached, so they are in effect from the first frame of the next start.
- Set `remoteConfig: false` to never poll. Standalone (no connection string) the SDK never polls either.

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
| `{"event": {"type": "hover", "value": "<selector>"}}` | the mouse entering a matching widget (desktop; never touch) |
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

You rarely write one by hand: every tap is recorded as `browser.user_action.click` with the selector of the control that handled it (`browser.css_selector`), shown on the session timeline. It prefers an id (`ElevatedButton#pay`, or `CheckoutButton#checkout` for your own widget with a key), then a key, the shown text, the label, and the type alone. Keys and `Semantics(identifier:)` (the ones integration tests and Appium/Maestro use) are the most stable choice. The shown text and the label of a widget inside `TracewayPrivacyMask` are never sent.

Widget type names are minified in `--obfuscate` builds: there, match by key, identifier, role, label or text, and recorded selectors leave the type out.

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

## App performance metrics

The SDK measures the app on the device and uploads the numbers as OTLP metrics: histograms and counters (delta temporality, base-2 exponential buckets at the server's scale), one small payload every five minutes and when the app goes to the background. Nothing is sent per observation, and no user, device or session id is a dimension. A new Flutter project starts with the **Flutter Performance** dashboard, which charts them as percentiles over every session.

| Metric | What it measures |
|--------|------------------|
| `app.start.duration` (`start_type` `cold` / `hot`) | Cold: from the process start (read from `/proc` on Android and Linux; elsewhere from when the SDK was initialized) to the first frame on screen. Hot: from the return to the foreground to the next frame |
| `app.screen.ttid` (`screen`) | Time to initial display: from the navigation to the end of the first frame that built the route |
| `app.screen.ttfd` (`screen`) | Time to full display: from the navigation until the app calls `Traceway.reportFullyDisplayed()` |
| `app.frames.slow`, `app.frames.frozen` (with `.total`, by `screen`) | From the engine's frame timings: slow when the UI or raster thread took longer than the display's frame budget, frozen at 700 ms or more |
| `app.hang`, `app.hang.duration` | The UI isolate ran no timer for 2 s or more while the app was in the foreground |
| `app.crash` | Errors nothing caught (`FlutterError.onError`, `PlatformDispatcher.onError`, the `Traceway.run` zone). They do not end a Flutter app, so the dashboard calls them unhandled errors |
| `app.session`, `app.user`, `app.user.affected` (`issue`) | Sessions; users counted once a day per installation, and once a day per problem they met (crash, hang, slow start, frozen frames, failed request), so no id leaves the device |
| `app.memory.peak` | The process's peak RSS, once per session |
| `app.request.duration`, `app.request.bytes`, `app.request.failed` (`host`) | Every HTTP request the SDK records |

Screens are route names with ids folded (`/orders/8841` → `/orders/:id`). Resource dimensions are the app version, environment, OS and its major version, form factor (`phone`, `tablet`, `desktop`) and a coarse device class from the RAM.

```dart
// The screen has what it loads: ends its time to full display.
Traceway.reportFullyDisplayed();

// App-defined metrics, charted like the built-in ones.
Traceway.metric('checkout.duration', 1234, {'plan': 'pro'});
Traceway.count('cart.add');
Traceway.setMetricDimension('experiment', 'b'); // `custom.experiment` on every metric
```

`captureMetrics: false` turns it all off. A rule's `metrics` section switches metrics off (`enabled`), samples sessions (`sampleRate`; counts are weighted back by the server) or changes the upload interval (`flushSeconds`, 30–3600). An upload that fails is kept and retried once.

## Setups

The SDK runs in one of three ways. The first needs nothing beyond the connection string.

### Everything on Traceway

```dart
Traceway.run(
  connectionString: 'your-token@https://traceway.example.com/api/report',
  options: const TracewayOptions(
    serviceName: 'shop-app',
    environment: 'production',
  ),
  child: const MyApp(),
);
```

The app polls Traceway for its collection settings, sends logs, request spans and metrics to Traceway's OTLP endpoints, and uploads screen recordings to the same host. What it collects is changed on the project's **Data Collection** page.

### Issues and recordings on Traceway, other telemetry elsewhere

Add `telemetry` to send ordinary logs, request spans and metrics to another OTLP/HTTP receiver, such as an OpenTelemetry Collector in front of a Grafana stack:

```dart
Traceway.run(
  connectionString: 'your-token@https://traceway.example.com/api/report',
  options: const TracewayOptions(
    serviceName: 'shop-app',
    telemetry: TracewayTelemetry(
      url: 'https://collector.example.com/otlp',
      headers: {'x-ingest-key': 'app-ingest-key'},
      // Optional overrides are complete signal URLs; no path is appended.
      metrics: TracewayTelemetryEndpoint(
        url: 'https://metrics.example.com/v1/metrics',
      ),
    ),
    collection: {
      'signals': {
        'console': {'mode': 'stream'},
        'network': {'mode': 'stream'},
      },
      'metrics': {'flushSeconds': 30},
    },
  ),
  child: const MyApp(),
);
```

The shared `url` gets `/v1/logs`, `/v1/traces` and `/v1/metrics` appended. Each signal (`logs`, `traces`, `metrics`) can override it with a `TracewayTelemetryEndpoint(url:, headers:)` whose URL is used as given. Without a shared `url`, the signals you do not list keep their Traceway destination, so `TracewayTelemetry(metrics: TracewayTelemetryEndpoint(url: ...))` moves the metrics only. URLs must use HTTP(S), without embedded credentials, a query or a fragment. Signal headers override the shared `headers` key by key; the Traceway token is never sent to these receivers.

When logs are redirected, exceptions, `captureMessage` issues and the SDK's session and control records (`session.start`, `session.end`, `traceway.session.update`, fired triggers, started captures, applied config) still go to Traceway, and only there. Ordinary logs (`print` / `debugPrint`, navigation, taps, `Traceway.recordAction`, `Traceway.track`) go to the logs receiver; request spans and metrics use their own destinations. Remote config (OpAMP) and screen recordings keep using the connection string. Breadcrumbs sent elsewhere are not copied into Traceway's session timeline; both destinations carry `session.id` for correlation.

Live exports, a ring buffer flushed by a trigger or restored after a restart, and retries all use the configured destinations and headers. Batches that failed are queued on disk per destination (`outbox` for Traceway, `outbox-<hash>` for each set of external destinations), and pending metric payloads and the daily user count are kept per destination, so a changed receiver is never sent what was meant for the previous one. Requests to the receivers are not recorded as network spans.

The receiver must accept OTLP/HTTP with protobuf bodies (`application/x-protobuf`); logs and spans are gzip-compressed (`Content-Encoding: gzip`). There is no CORS on mobile, but any key built into the app can be read out of it: use an ingestion key that can only write, or a collector that holds the backend credentials. Metrics are delta sums and base-2 exponential histograms, so configure the downstream pipeline to accept or convert those types.

### Standalone, without a Traceway server

Leave out the connection string:

```dart
Traceway.run(
  options: const TracewayOptions(
    serviceName: 'shop-app',
    telemetry: TracewayTelemetry(url: 'https://collector.example.com/otlp'),
    collection: {
      'signals': {
        'console': {'mode': 'stream'},
        'network': {'mode': 'stream', 'sampleRate': 0.25},
        'custom': {'mode': 'stream'},
      },
      'metrics': {'flushSeconds': 30},
    },
  ),
  child: const MyApp(),
);

Traceway.metric('checkout.duration', 840, {'plan': 'pro'});
Traceway.count('checkout.completed');
```

No Traceway server, account or token is required. `telemetry` must have a shared `url` or all three signal endpoints. Standalone mode turns off remote config, screen recording uploads and session records, whatever `remoteConfig`, `screenCapture` and `sessions` say. A local session id still exists for sampling and correlation (`session.id` on every record). Exceptions are ordinary OTLP log records with the event name `exception`, and messages carry `traceway.message`, sent to your collector. The collection defaults and the built-in exception trigger still apply: an exception uploads the buffered breadcrumbs.

### Invalid settings

A `telemetry` URL that is not HTTP(S) or carries credentials, a query or a fragment, standalone `telemetry` without a destination for every signal, or a malformed connection string does not take the app down. `Traceway.run` reports the error as a `FlutterError` (shown in the console, library `traceway`) and runs the app without the SDK, so nothing is collected until the settings are fixed. `TracewayClient.initialize`, called directly, throws the `ArgumentError` instead.

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `sampleRate` | `1.0` | Share of exceptions and messages that are reported (0.0 - 1.0) |
| `screenCapture` | `false` | Record the screen: the last ~10 seconds go up with an exception, and captures can stream it (Android, iOS, macOS) |
| `debug` | `false` | Print debug info to console |
| `version` | `''` | App version, sent as `service.version` (`unknown` when empty) |
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
| `captureMetrics` | `true` | Measure app start, screen display times, frames, hangs, unhandled errors, sessions, users and requests, and upload them as metrics |
| `metricDimensions` | `{}` | Up to two app-defined dimensions on every metric (`custom.<key>`) |
| `recordAllSessions` | `false` | Stream breadcrumbs and the screen recording all the time instead of keeping them for errors |
| `collection` | — | Local collection settings, the same document as a remote-config rule (see [Local config](#local-config)) |
| `sessions` | `true` | Send session records (`session.start` / `session.end`). The session id exists either way, so captures and rules that stream replay still work |
| `baselineSampleRate` | `0` | Share of sessions whose breadcrumbs are sent continuously, not only around errors |
| `remoteConfig` | `true` | Poll the server for collection settings over OpAMP |
| `exportDelayMs` | `1000` | How long finished records wait to be sent as one batch |
| `propagateTraceHeaderUrls` | `[]` | URLs (`String` prefixes or `RegExp`s) whose requests carry a W3C `traceparent` header (see [Connect requests to backend traces](#connect-requests-to-backend-traces)) |
| `telemetry` | — | Send logs, spans and metrics to another OTLP/HTTP receiver: `TracewayTelemetry(url:, headers:, logs:, traces:, metrics:)` (see [Setups](#setups)) |

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
- **Network** — every dart:io HTTP request as a client span (method, URL, status, duration, byte counts) via `HttpOverrides.global`. Catches `package:http`, Dio, Firebase, anything on dart:io. The SDK's own requests are not recorded. Clients that do not sit on dart:io need `TracewayHttpClient` (see below).
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

### Network capture with an explicit client

`HttpOverrides.global` only sees clients built on dart:io's `HttpClient`. A client that uses the platform's own stack, such as `cupertino_http` or `cronet_http`, bypasses it. Wrap such a client in `TracewayHttpClient`, a drop-in `http.Client`, and pass it to Dio, Chopper or any library that accepts a custom `http.Client`:

```dart
import 'package:cupertino_http/cupertino_http.dart';
import 'package:traceway/traceway.dart';

final client = TracewayHttpClient(CupertinoClient.defaultSessionConfiguration());
final res = await client.get(Uri.parse('https://api.example.com/users'));
```

`TracewayHttpClient()` without an argument wraps the default `http.Client`. That client sits on dart:io, so `captureNetwork` sees it too, but the SDK recognizes requests sent through `TracewayHttpClient` and records each one once, with one `traceparent`.

### Connect requests to backend traces

`propagateTraceHeaderUrls` lists the URLs whose requests carry a W3C `traceparent` header naming the request's client span, so the backend's spans join the app's trace in Traceway or any OpenTelemetry backend. A `String` matches URLs that start with it, a `RegExp` URLs it matches:

```dart
TracewayOptions(
  propagateTraceHeaderUrls: [
    'https://api.example.com/',
    RegExp(r'^https://[a-z]+\.example\.com/'),
  ],
)
```

It is empty by default, because a header a server does not expect can break a strict CORS or request-signature check. It applies, once the SDK has started, to every request sent through `TracewayHttpClient`, and to other dart:io requests only with `captureNetwork: true`, because the `HttpOverrides` that add the header are installed only then. A request that already carries a `traceparent` (the app's own tracing) keeps it, and its span is recorded as before. The client span of a propagated dart:io request starts when the request is opened, so it includes connecting and the TLS handshake. Requests to Traceway and to the `telemetry` receivers never carry it. The backend must extract `traceparent` (any OpenTelemetry HTTP instrumentation does).

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

The mask covers the widget where it is in each recorded frame: its place is read from the render tree when the frame is captured, so it stays on the widget while that scrolls in a list, animates or is transformed.

## Android build setup

The screen recorder's encoder plugin, `flutter_quick_video_encoder` 1.7.2, declares `compileSdk` 33, while the AndroidX libraries of current Flutter versions need 34. With a current Flutter template (seen with Flutter 3.50 and Android Gradle Plugin 9.3) `flutter build apk` stops with `:flutter_quick_video_encoder is currently compiled against android-33`. Raise it in `android/build.gradle.kts`, above the `subprojects { project.evaluationDependsOn(":app") }` block, as `example/android/build.gradle.kts` does:

```kotlin
// The encoder 1.7.2 declares API 33; the AndroidX libraries it builds with need 34.
project(":flutter_quick_video_encoder") {
    plugins.withId("com.android.library") {
        extensions.getByType<com.android.build.api.variant.LibraryAndroidComponentsExtension>().finalizeDsl {
            it.compileSdk = maxOf(it.compileSdk ?: 0, 34)
        }
    }
}
```

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

### 2.0

Measured with Flutter 3.50 on Android 14 (an x86_64 container with software rendering, so ratios matter more than absolute times):

- **App size**: a release arm64 APK grows by 1.77 MB (1.0.9: 0.98 MB). The SDK is 313 KB of Dart code, `protobuf` 120 KB and the OpenTelemetry SDK for Dart 160 KB.
- **Network**: about 40 KB an hour while idle (an OpAMP poll of 1.1 KB and a metrics upload of 0.5–0.7 KB every five minutes, headers included); breadcrumbs cost nothing until an error. An exception sends about 4.5 KB plus its clip, 10–280 KB on a UI and about 1.3 MB on a screen playing video.
- **Performance**, profile build of the benchmark below with app vitals running, median over the ten workloads: without screen capture, build and raster times and wall clock are within noise of the app without the SDK. With screen capture, raster time p90 is ×1.23 and RSS +23 MB; bursts of exceptions take ×1.3 as long while their clips encode. Capturing an exception takes 0.2–1.1 ms.

### 1.x

> The numbers below were measured on 1.x. The capture path (frames, encoding) is unchanged in 2.0.

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

To deliver unsent 1.x errors and their clips, set `TracewayOptions(legacyConnectionString: previousConnectionString)` to the connection string the old build used. Version 1.x stored these reports without a project identifier. The SDK retries eligible reports against that original project’s `/api/report` endpoint and expires them after 12 hours, the 1.x default. New reports use OTLP.

- **Server**: 2.0 sends OTLP to `/api/otel/v1/logs`, `/api/otel/v1/traces` and `/api/otel/v1/metrics`, polls `/api/otel/v1/opamp` and uploads clips to `/api/recordings`. There is no fallback to the 1.x `/api/report` protocol.
- **Connection string**: unchanged. `token@https://host/api/report` still works, as does `token@https://host`; the other endpoints are derived from it. It is now optional: without it the SDK runs [standalone](#standalone-without-a-traceway-server).
- **Behaviour**: logs and actions are no longer limited to the last 10 seconds and no longer travel inside the recording. They are buffered for up to 10 minutes and sent as their own records with an exception. `captureMessage` no longer attaches a screen recording.
- **Removed options**: `debounceMs`, `retryDelayMs`, `maxPendingExceptions`, `maxLocalFiles`, `localFileMaxAgeHours`, `eventsWindow`, `eventsMaxCount`.
- **Removed API**: the 1.x transport methods of `TracewayClient` (`addException`, `loadPendingFromDisk`, `pendingExceptions`, `pendingRecordings`, `bufferedEvents`, `collectDeviceInfo`, `collectSyncDeviceInfo`, `setDeviceAttributes`) and the `ReportSender` export. Use `captureException`, `Traceway.setAttribute` and `flush()`. `TracewayClient.initialize` returns the running client instead of replacing it: call `shutdown()` and wait for it before initializing with another connection string.
- **New API**: `Traceway.track`, `Traceway.setAttribute`, `Traceway.recordNavigation`, `Traceway.reportFullyDisplayed`, `Traceway.metric`, `Traceway.count`, `Traceway.setMetricDimension`, `TracewayTelemetry` and `TracewayTelemetryEndpoint`, `TracewayClient.refreshConfig`, `shutdown`, `getInstanceId`. New options include `telemetry`, `propagateTraceHeaderUrls`, `collection`, `captureUserActions`, `captureMetrics` and `recordAllSessions`.
- **OpenTelemetry**: the SDK initializes the global `OTel` instance of `dartastic_opentelemetry`. If your app already initializes OpenTelemetry, Traceway creates separate log and trace providers for its installation. The app keeps its own exporters and can continue tracing after Traceway shuts down.

## Flutter Web

This SDK does not support Flutter web: it relies on dart:io (`HttpOverrides`, `Platform`, files on disk) and on a native video encoder, none of which exist in a browser, and `TracewayHttpClient` is part of it. For web apps, use the [`@tracewayapp/frontend`](https://docs.tracewayapp.com/client/js-sdk?sdk=js-generic) JS SDK, which captures errors and records `fetch` and `XMLHttpRequest` calls automatically; those are what Dart's HTTP clients use in a web build.

Give the web build its own browser project (React, Svelte, Vue.js or jQuery in the framework picker) and use that project's connection string, not the Flutter project's.

**Add the CDN script to `web/index.html`:**

```html
<script src="https://cdn.jsdelivr.net/npm/@tracewayapp/frontend@2/dist/traceway.iife.global.js"></script>
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

See the full [JS SDK documentation](https://docs.tracewayapp.com/client/js-sdk?sdk=js-generic) for all options. Its session replay records the DOM; Flutter web paints its UI into a canvas, which the recorder does not capture, so a replay shows little of a Flutter app.

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
