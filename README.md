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

Error tracking, session context and session replay for Flutter apps, built on the standard [OpenTelemetry](https://opentelemetry.io) SDK for Dart. Exceptions arrive with full stack traces, the breadcrumbs that led up to them and, with `screenCapture: true`, the last seconds of session replay.

[Traceway](https://tracewayapp.com) is a completely open-source error tracking platform. You can [self-host](https://docs.tracewayapp.com/server) it or use [Traceway Cloud](https://tracewayapp.com).

> 2.x speaks OTLP and OpAMP and needs a Traceway server that supports Flutter projects on those endpoints (Traceway Cloud does). On an older self-hosted server stay on `traceway: ^1.0.9`. See [Migrating](#migrating).

## Features

- Automatic capture of all Flutter errors (framework, platform, and async)
- Full Dart stack traces, with symbolication for obfuscated builds
- **OpenTelemetry inside** — logs and spans go through the standard OTel SDK (`dartastic_opentelemetry`) and leave as OTLP/HTTP
- **Ring buffer** — logs, HTTP requests, navigation and custom events stay on the device and are uploaded only when something goes wrong
- **Remote config over OpAMP** — change what is collected from the dashboard, per app version, user or device, without a release; or ship the same settings in the app with `collection:`
- **Captures on demand** — from the dashboard, or from a recording trigger on the device (a journey of taps, navigations and log lines): the buffered lookback goes up, then logs, requests and the screen recording stream until the capture ends
- **App performance metrics** — cold and hot start, time to initial and full display per screen, slow and frozen frames, hangs, unhandled errors, sessions, users, peak memory and HTTP requests, aggregated on the device and sent as OTLP metrics; they fill the project's Flutter Performance dashboard
- **Taps that name the widget** — every tap is recorded with a CSS-like selector (`ElevatedButton#pay`, `IconButton[label="Delete"]`) that click steps of recording triggers match
- **Session replay** — a wireframe of the widget tree replayed as HTML by the dashboard's rrweb player (every platform, a few kilobytes per segment, no native code), or video encoded as MP4 with the [`traceway_video` add-on](#video-replay-add-on) (Android, iOS, macOS). Either is uploaded as the clip of an exception, or as consecutive segments while a capture streams
- Touch/click positions on recordings
- Masks — `TracewayMask` or a `ValueKey('traceway-mask')` blurs or blanks sensitive widgets in recordings and keeps their text out of tap records; typed text masked in wireframes and video; images in wireframes as small inlined pictures, URLs or placeholders, set remotely with `replay.images`
- Sessions, with the breadcrumb timeline of each one
- **Any OpenTelemetry backend** — send logs, spans and metrics to an OpenTelemetry Collector, Grafana, Honeycomb or any OTLP/HTTP receiver with `telemetry:`, next to Traceway or without it (standalone)
- Telemetry that failed to send is kept on disk and retried; the ring buffer is saved when the app goes to the background, so a session that goes on after the system killed the app still has its breadcrumbs (`buffer.persist`)
- Setup: `Traceway.run` around your app, plus the navigator observer

## Requirements

- Flutter 3.38.1 or later (Dart 3.10); tested with Flutter 3.50.
- iOS, Android, macOS, Linux or Windows. Flutter web is not supported: see [Platform support](#platform-support).
- Traceway Cloud, a self-hosted Traceway server whose Flutter projects take OTLP and OpAMP (2.0 or later), or any OTLP/HTTP receiver [standalone](#standalone-without-a-traceway-server).

## Installation

```bash
flutter pub add traceway
```

The package has no native code of its own and needs no Gradle or CocoaPods changes. Video replay is a separate add-on, [`traceway_video`](#video-replay-add-on).

### Platform setup

Traceway needs network access to send telemetry. Depending on the platform, add the permission yourself.

#### Android

Add the `INTERNET` permission to `android/app/src/main/AndroidManifest.xml`. Flutter's template declares it only in the debug and profile manifests, so without it a release build sends nothing (`SocketException`, visible only with `debug: true`):

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.INTERNET"/>
    <application
      ...
```

#### macOS

macOS apps are sandboxed and cannot make network requests without the `com.apple.security.network.client` entitlement. Add it to both `macos/Runner/DebugProfile.entitlements` and `macos/Runner/Release.entitlements`:

```xml
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
```

#### iOS

Nothing to add: iOS apps can make HTTPS requests by default.

## Quick start

1. Wrap your app with `Traceway.run()`, with your project's token:

```dart
import 'package:flutter/material.dart';
import 'package:traceway/traceway.dart';

void main() {
  Traceway.run(
    token: const String.fromEnvironment('TRACEWAY_TOKEN'),
    options: const TracewayOptions(
      screenCapture: true,
      version: '1.0.0',
    ),
    child: const MyApp(),
  );
}
```

```bash
flutter run --dart-define=TRACEWAY_TOKEN=YOUR_TOKEN
```

2. Attach the navigator observer, so issues, taps and screen metrics name the screen:

```dart
MaterialApp(
  navigatorObservers: [Traceway.navigatorObserver],
  home: const HomePage(),
)
```

With go_router: `GoRouter(observers: [Traceway.navigatorObserver], routes: [...])`.

That's it. All uncaught exceptions are captured automatically, and with `screenCapture: true` each one comes with a wireframe replay of the seconds before it.

The token is on the project's **Connection** page in the dashboard. It goes to Traceway Cloud (`https://cloud.tracewayapp.com`); for a self-hosted server pass its URL as well, `baseUrl: const String.fromEnvironment('TRACEWAY_URL')` with `--dart-define=TRACEWAY_URL=https://traceway.your-company.com`. Without the observer the SDK still records errors, taps and replay, but no screen names (with `debug: true` it says so once). To send logs, traces and metrics to another OpenTelemetry provider as well, or only there, see [Send telemetry to another OpenTelemetry provider](#send-telemetry-to-another-opentelemetry-provider).

Everything below goes through static methods on `Traceway`, which do nothing before the SDK has started. The running client is `Traceway.client` (`TracewayClient.instance`); it has the same methods, except that `metric` and `count` are `recordMetric` and `recordCount` there, and `recordNavigation` exists only on `Traceway`.

## Manual capture

### Errors and messages

```dart
// Capture a caught exception
try {
  await riskyOperation();
} catch (e, st) {
  Traceway.captureException(e, st, {'cart.items': '3'});
}

// Capture a message
Traceway.captureMessage('User completed checkout');

// Send what is ready now (optionally waiting at most that many ms)
await Traceway.flush(5000);
```

Every exception and message also says where the app was when it happened: `app.screen.name` (the screen on top; a dialog, sheet or menu over it does not change it), `app.screen.route` (its [route template](#naming-screens), when known), `app.screen.previous`, `app.screen.duration_ms` (how long the screen had been shown) and `viewport` (the window's size in logical pixels). Attributes you pass to `captureException` win over these.

Identical errors within a second are sent once, and at most 60 errors leave per minute; the next error sent carries how many were held back (`traceway.error.suppressed_count`).

**Errors you don't want.** By default, network failures are not reported: a `SocketException`, a `ClientException`, a `HandshakeException`, `Failed host lookup`, `Connection closed before full header was received`, `Connection reset by peer`, `Connection refused`, `Network is unreachable`, a timeout (`/timeout/i`) or a 4xx status (`/status code (of )?4\d{2}/`, `/failed: 4\d{2}/`, `/statusCode: 4\d{2}/`); the list is `defaultIgnoreErrors`. `ignoreErrors` replaces that list. A `String` matches if it occurs in the first line of the error's `Type: message`, and a `RegExp` if it matches that line; the stack is never matched. An empty list reports everything. `beforeCapture` sees every exception and message that is not ignored and can drop it:

```dart
TracewayOptions(
  ignoreErrors: [...defaultIgnoreErrors, 'PlatformException(camera_denied'],
  beforeCapture: (captured) => !(captured.error is PaymentDeclined),
)
```

An ignored unhandled error is not counted as a crash either.

### Logs

```dart
// A log line with a level (a printed line is info)
Traceway.log('payment declined', level: TracewayLogLevel.warn);
```

Logs carry a level, so the timeline shows warnings and errors and the console's minimum severity in the remote settings filters them:

- every `package:logging` record, with its level (`FINE` is debug, `WARNING` warn, `SEVERE` error, `SHOUT` fatal), logger name (`logger.name`), error and stack trace. An app that prints its records itself (`Logger.root.onRecord.listen(print)`) gets each one recorded once, not again as a printed line.
- `Traceway.log(message, level: ...)`, with an optional error, stack trace and attributes.
- every `print` / `debugPrint` line, as info, captured via a Zone print override. The console dump of an error the SDK already reported is not recorded again as lines. An app that sets the Flutter binding up before `Traceway.run` (to await plugins first) keeps its own zone, since `runApp` must run in the binding's: its printed lines are not captured, and its uncaught async errors arrive through `PlatformDispatcher.onError`.
- `dart:developer.log` is **not** captured: it does not go through the app's zone.

Each log says where it came from in `log.source` (`logging`, `api` or `print`). Debug and trace logs are dropped unless the console's minimum severity (`info` by default) is lowered in the settings.

### Actions and events

```dart
// A breadcrumb of your own
Traceway.recordAction(
  category: 'cart',
  name: 'add_item',
  data: {'sku': 'SKU-123', 'qty': 2},
);

// A named product event; triggers can match it by name
Traceway.track('checkout_failed', {'reason': 'card_declined'});
```

Both are breadcrumbs of the `custom` signal, kept on the device and shown on the session timeline with the exception that flushed them.

### Attributes and users

```dart
// Attributes attached to every later record, and usable to target this
// user or device from the dashboard.
Traceway.setAttribute('user.id', user.id);
Traceway.setAttributes({'plan': 'pro', 'team': 'acme'});
Traceway.removeAttribute('team');
Traceway.clearAttributes(); // also the ones from TracewayOptions.attributes
```

There is no `setUser`: a user is the `user.id` attribute, as in the browser SDK. Up to 64 attributes are kept. A change sends a `traceway.session.update`, so the session gets a `user.id` set after sign-in at once (changes made together send one), and asks the server for settings about 2 seconds later, so a rule targeting the attribute applies soon. `Traceway.refreshConfig()` asks at once. `Traceway.getInstanceId()` is the installation's id (`service.instance.id`) a dashboard capture can target, and `Traceway.currentSessionId` the current session's `session.id`.

### Interactions

An interaction traces one user action from start to end: a span named after it (`traceway.interaction: true`). Requests made inside its `run` are its child spans, and exceptions, messages and logs recorded there carry its trace id. A failed interaction is sent with its exception, so the issue links to its trace; one that succeeds waits in the buffer like other spans. One started inside another's `run` is its child.

```dart
final checkout = Traceway.startInteraction('checkout', attributes: {'cart.items': 3});
try {
  await checkout.run(() => api.placeOrder(cart));
} catch (e, st) {
  checkout.captureException(e, st);
} finally {
  checkout.end();
}
```

An interaction started in the first moments after `Traceway.run` (in `main` or the first screen's `initState`, while the SDK reads its state from disk) is recorded once the SDK is ready, from the time it started, with the requests and exceptions made inside it; its `traceId` is `null` until then.

### Your own spans

`Traceway.tracer` is the SDK's OpenTelemetry tracer (a `Tracer` of `package:dartastic_opentelemetry`; import it to name its types). Its spans go through Traceway like the request spans: they carry the session id, wait in the buffer with the `network` signal (or stream with it), and one started inside an interaction's `run`, after an `await` too, is that interaction's child. It is `null` until the SDK has started (`await Traceway.ready`) and after `shutdown()`. It is Traceway's own tracer, never the global `OTel.tracer()`: an app that sets OpenTelemetry up itself, before or after `Traceway.run`, keeps its own providers and exporters, and Traceway does not take its spans.

```dart
final span = Traceway.tracer?.startSpan('load-catalog');
try {
  await loadCatalog();
} finally {
  span?.end();
}
```

## How collection works

Every record is an OpenTelemetry log record or span and belongs to a *signal*. Each signal has a mode:

| Mode | Meaning |
|------|---------|
| `stream` | sent as soon as it is produced |
| `buffer` | kept in a ring buffer on the device (2 MiB / 10 minutes by default) until a trigger or a capture uploads it |
| `off` | dropped |

| Signal | Source | Default |
|--------|--------|---------|
| `errors` | uncaught errors, `captureException` | stream |
| `messages` | `captureMessage` | stream |
| `console` | `package:logging`, `Traceway.log`, `print` / `debugPrint` | buffer |
| `network` | HTTP requests (client spans) | buffer |
| `navigation` | `Traceway.navigatorObserver`, `Traceway.recordNavigation` | buffer |
| `userActions` | taps (`browser.user_action.click`) | buffer |
| `custom` | `Traceway.recordAction`, `Traceway.track` | buffer |
| replay | screen recording | buffer |

Breadcrumbs are OpenTelemetry records held in the ring buffer and shown on the session timeline next to the exception that flushed them. The built-in trigger fires on every exception: it uploads the buffered breadcrumbs of the last 10 minutes and the screen-recording clip. An app that never throws sends only its session and control records (`session.start`, `session.end`, `traceway.session.update`, `traceway.config.applied`) and its metrics. Clips are rationed to one per 5 seconds and 20 per session; breadcrumbs are still sent for the exceptions in between.

`recordAllSessions: true` streams every breadcrumb signal and the screen recording instead. The signal names, modes, triggers and limits are the browser SDK's, so one rule can target both.

Each channel can be turned off in the app, and then no rule can turn it on:

```dart
TracewayOptions(
  captureLogs: false,
  captureNetwork: false,
  captureNavigation: false,
)
```

Replay uploads are bounded per session: 50 MiB and 10,000 events (a video clip is one event, a wireframe clip counts each of its rrweb events). Sessions report the counts (`traceway.collection.bytes`, `.events`, `.dropped`, `.max_bytes`, `.max_events`, `traceway.replay.failed_segments`, `traceway.context.evicted`). When data is dropped (a clip over the budget, replay segments the server refused or that ran out of retries, errors the flood guard held back), the SDK sends a `traceway.collection.health` record with those counters and `traceway.error.suppressed_total`, 1 second later and then at most once per doubling delay up to 5 minutes, as the browser SDK does; the first one in a session also updates the session.

## Remote config

The SDK polls the server over [OpAMP](https://opentelemetry.io/docs/specs/opamp/) (plain HTTP: at start, at the interval the server sets (5 minutes by default, 60 seconds while a capture targets the device), when the app returns to the foreground and a poll is due, and about 2 seconds after an attribute changes or a new session starts, so a rule targeting an attribute applies soon) and applies the collection settings you define under **Project → Data Collection** in the dashboard: signal modes and sample rates, buffer sizes, extra triggers (for example "flush when `checkout_failed` happens twice in a minute"), replay settings (`replay.captureMode`, `replay.maskAllInputs`, `replay.images`) and on-demand captures of one user or device.

- The `capture*` options, `screenCapture`, `replayImages` and `sessions` are **ceilings**. Remote settings can lower what is collected but never raise it: with `captureNetwork: false` no rule can turn network capture on, and without `screenCapture: true` nothing is recorded. `sampleRate`, `baselineSampleRate`, `recordAllSessions` and `screenCaptureMode` are defaults: a rule can change them in either direction.
- The last applied settings are cached on disk, so the next start applies them before its first poll answers.
- Set `remoteConfig: false` to never poll. Standalone (no token) the SDK never polls either.

### Local config

`collection:` takes the same settings document a rule holds and lays it over the built-in defaults, so an app can define its own policy and triggers without the server. With `remoteConfig: true` the server's rules apply on top of it; with `remoteConfig: false` it is the whole policy.

```dart
Traceway.run(
  token: const String.fromEnvironment('TRACEWAY_TOKEN'),
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

A value the SDK cannot use (an unknown mode, an out-of-range number, a malformed trigger) is skipped and the rest applies. A document that cannot be encoded as JSON or names a `schemaVersion` other than 1 is ignored with a console warning, and the defaults apply.

## Captures

A capture uploads what the device holds from its lookback window and then streams the selected signals, and the screen recording when it asks for replay, until it ends. Records sent under a dashboard capture carry its id (`traceway.capture.ids`), so the dashboard shows when it is collecting; the log records of its lookback get the id when they are uploaded. Captures a trigger started are not stamped, as in the browser SDK.

- **From the dashboard**: the Capture button on a session or issue targets one installation (`service.instance.id`), user (`user.id`) or session. The device starts it at its next poll; cancelling it stops the streaming at the poll after that. Each capture's lookback is uploaded once per installation.
- **From a trigger** (`{"type": "capture", ...}` action): started on the device the moment the trigger fires, with the id `<trigger id>:<start time in ms>`. It survives app restarts until it ends; firing again only extends it.

While a capture streams replay, the recording leaves as consecutive segments of about 8 seconds that start where the previous one ended: rrweb segments in [wireframe](#wireframe) mode, MP4 segments with the [video add-on](#video-replay-add-on). An exception during a streaming capture still gets a clip of its own.

### Recording triggers

The dashboard's *recording trigger* steps work in Flutter: journeys of taps, navigations and logs. A step is one of:

| Step | Matches |
|------|---------|
| `{"event": {"type": "click", "value": "<selector>"}}` | a tap on a widget the selector matches, or inside one |
| `{"event": {"type": "hover", "value": "<selector>"}}` | the mouse entering a matching widget (desktop; never touch) |
| `{"event": {"type": "navigation", "value": "/users/{id}"}}` | arriving at a route; `{id}` is one non-empty segment |
| `{"event": {"type": "log", "value": "Profile loaded", "mode": "contains"}}` | a log line (`print` / `debugPrint`, `package:logging`, `Traceway.log`) or a `captureMessage` (`exact` by default) |

Steps match in order, each within its `withinSeconds` of the previous one; progress survives an app restart within the session. When a trigger that asks for replay fires, the session lists it as a recording reason with its sequence.

### Naming views

In Flutter the views a selector names are widgets. Flutter has no DOM, so click and hover selectors run over the element tree under the pointer. The syntax is the CSS subset the dashboard validates:

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

You rarely write one by hand: every tap is recorded as `browser.user_action.click` with the selector of the control that handled it (`browser.css_selector`), shown on the session timeline. It prefers an id (`ElevatedButton#pay`, or `CheckoutButton#checkout` for your own widget with a key), then a key, the shown text, the label, and the type alone. Keys and `Semantics(identifier:)` (the ones integration tests and Appium/Maestro use) are the most stable choice. The shown text, the label and the keys of a widget inside a [mask](#privacy-masks) are never sent.

Widget type names are minified in `--obfuscate` builds: there, match by key, identifier, role, label or text, and recorded selectors leave the type out.

### Naming screens

A screen is the route on top. A navigation step matches the path the observer reports for it:

- its name (`RouteSettings.name`): named routes, `onGenerateRoute`, and routers that name their pages,
- else `/` and the page widget's type, e.g. `/CheckoutPage` for `MaterialPageRoute(builder: (_) => const CheckoutPage())` or `PageRouteBuilder(pageBuilder: (_, __, ___) => const CheckoutPage())`,
- else `/` and the route's type, e.g. `/DialogRoute`.

Navigations are recorded by attaching the observer to your app:

```dart
MaterialApp(
  navigatorObservers: [Traceway.navigatorObserver],
  // ...
)
```

It records push / pop / replace / remove from any `Navigator`. An observer watches one `Navigator` at a time (Flutter asserts it): give a nested one (tabs, a go_router `ShellRoute`) its own, `Navigator(observers: [TracewayNavigatorObserver()], ...)`. Dialogs, bottom sheets, menus and dropdowns are recorded as navigations with `navigation.overlay: true`, but the screen under them stays the current screen, for issues, taps and screen metrics.

go_router reports to the observer: `GoRouter(observers: [Traceway.navigatorObserver], ...)` is all it needs. A router without `observers:` can report its location itself, with its route template when it knows it (here with go_router, to record its route templates too):

```dart
final router = GoRouter(routes: [...]);
router.routerDelegate.addListener(() {
  final match = router.routerDelegate.currentConfiguration;
  Traceway.recordNavigation(match.uri.path, route: match.fullPath);
});
```

**Route templates.** A route template (`/orders/:id`) names a screen the way metrics should group it. Screen metrics use it, and issues and navigations on the screen carry it as `app.screen.route`. Without one, ids in the path are replaced (`/orders/8841` becomes `/orders/:id`). Give it with `recordNavigation(..., route:)`, or name the current screen with `Traceway.setRoute`, which lasts until the next screen. For a router that hands out parameters but not the pattern, `routeFromParams` rebuilds the template:

```dart
Traceway.setRoute(routeFromParams('/teams/acme/users/42', {'team': 'acme', 'id': '42'}));
// '/teams/:team/users/:id'
```

## Session replay

With `screenCapture: true` the SDK records the screen, in one of two modes:

| Mode | What it records | Platforms |
|------|-----------------|-----------|
| `TracewayScreenCaptureMode.wireframe` (default) | the widget tree, as an HTML document and rrweb mutations | every platform |
| `TracewayScreenCaptureMode.video` | the app's pixels, as MP4; needs the [`traceway_video` add-on](#video-replay-add-on) | Android, iOS, macOS (a hardware encoder) |

Nothing is uploaded unless an exception is captured or a capture or a rule streams replay. The last frames stay on the device in a ring of `maxBufferFrames` frames (150); an exception uploads the replay of up to the last 30 seconds (the replay `lookbackSeconds` of the built-in trigger), cut to the frames the ring holds, as its clip, linked by its id, so a clip can never be longer than the frame buffer. While a capture streams, the session is uploaded as consecutive segments, each shorter than the frame buffer; every wireframe segment starts with a full snapshot, so it plays on its own.

`screenCaptureMode` is the app's choice, and the dashboard can change it without a release: a rule that sets `replay.captureMode` to `video` or `wireframe` (Data Collection → rule → Signals → Replay type) overrides it for the clients the rule targets. The change applies as soon as the settings arrive, unless the session has already uploaded replay in the other mode; then it applies from the next session, so one session's replay is all video or all wireframe. Without the video add-on, or where there is no video encoder (Linux, Windows), the SDK records a wireframe whichever mode is asked for.

### Wireframe

```dart
TracewayOptions(
  screenCapture: true, // a wireframe: the default mode
)
```

Instead of pictures, the SDK records the widget tree. After a frame the app drew (at most `fps` times a second, and not at all while nothing changes) it walks the elements under `Traceway` and turns what they paint into HTML: boxes with their colors, gradients, borders, corners and shadows, text with its size, weight and color, clips, opacity, transforms and scroll positions, as absolutely positioned elements nested the way Flutter paints them. What changes from one frame to the next becomes an rrweb mutation, so the dashboard replays the session with the same player as a browser session, taps and drags included. The Android and iOS SDKs record the same kind of wireframe, with the same stylesheet.

- **Small and cheap.** No screenshot is taken and no video is encoded: a segment is a few kilobytes of JSON (plus the small picture of each new image, made off the UI isolate, when `replay.images` allows), and recording costs a walk of the tree after the frames that changed something. A wireframe frame is taken only when the screen changed, so the ring of `maxBufferFrames` covers at least as long as video.
- **Every platform**, Linux and Windows included: no video encoder and no native code are needed.
- **Not pixel-exact.** The browser draws the text in its own font: Roboto's stack, or Apple's system font stack for an app running on iOS or macOS. Icons are drawn from a small picture of each glyph, made once per icon. Custom painting (`CustomPaint`, charts) is a dashed outline. Images are small pictures inlined into the replay, or URLs, or placeholders, as `replay.images` allows (see [Images](#images)). Web views, maps and other platform views, and video textures, are labeled placeholders: their pixels never pass through Flutter. Checkboxes, switches, radios, sliders, segmented buttons and progress indicators are drawn from their state; 3D transforms keep their perspective, blurs and grayscale filters are CSS filters, and shapes CSS has no shape for (beveled corners, stars, `ClipPath` clippers) become clip paths. The soft keyboard, which the platform draws, is a neutral "Keyboard" box while the view's bottom inset is up, as on Android and iOS.

How the capture works, node by node, is in [docs/wireframe.md](docs/wireframe.md).

### Images

The `replay.images` setting says when a wireframe may show the app's images: `off`, `wifi` (the default) or `always`. A rule sets it (Data Collection → rule → Signals → Replay images), or `collection: {'replay': {'images': 'off'}}` in the app. `TracewayOptions.replayImages` (`TracewayImagePolicy.off`, `.wifi`, `.always`; default `always`) is its ceiling: the policy in effect is the lower of the two, in the order `off < wifi < always`.

What a wireframe shows of an image is decided when the frame is captured (a picture recorded on Wi-Fi stays in its clip):

| `replay.images` | Network | Images (`Image`, `RawImage`, `FadeInImage`, `Ink.image`'s child…) |
|---|---|---|
| `off` | any | the `.im` placeholder (a gray box with a cross); no URL, no pixels |
| `wifi` (default) | metered or unknown | an image loaded from the network (`Image.network`, `NetworkImage` through `ResizeImage`, an `http(s)` URL) is an `<img>` with that URL, which the browser that plays the replay fetches; others are placeholders. Nothing is uploaded |
| `wifi` | unmetered (Wi-Fi, Ethernet) | the pixels of every image, network, asset, memory or file, inlined as a small picture |
| `always` | any | the same |

- **The picture** is made from the image's decoded pixels, never a screenshot: the part its `fit` and `alignment` show, at its displayed size (one pixel per logical pixel, longest side at most 384), tint and mirroring included. The raster thread draws it and a background isolate encodes it, as JPEG at quality 0.45; a picture with see-through pixels is never JPEG (it would replay as a box over white) but PNG, its longest side at most 192 px. One over 48 KiB is tried again at half size, then left out. The first frame shows the URL or the placeholder, a later one the picture. Until it is ready, or when it cannot be made, an image falls back to its URL or the placeholder.
- **Bounded**: the same image at the same size is one picture however many widgets show it; at most 128 per recorder (the one shown longest ago makes room), and 4 MiB of pictures per session, counted with the replay budget (`traceway.replay.image_bytes` on session events). An animated image (a GIF) is not recorded frame by frame.
- **Unmetered** is what `TracewayOptions.isUnmeteredNetwork` says when the app sets it (from `connectivity_plus`, say); otherwise the SDK guesses from the network interfaces that are up (Android `wlan*`/`eth*`, iOS `en0`, desktop Wi-Fi and Ethernet), without a plugin. The guess takes a hotspot shared by a phone for Wi-Fi; until it is known, the network counts as metered.
- A `DecorationImage` (a `BoxDecoration` image, `CircleAvatar.backgroundImage`) keeps its URL or the placeholder: its pixels are not inlined.
- `off` takes effect as soon as the setting arrives: the frames held are dropped and the screen is taken again. Every image inside a mask is a placeholder, and nothing of it is drawn or encoded.
- Video recordings are not affected.
- With `debug: true` the console says when a picture was dropped for its size or the session's budget.

Sessions report the policy in effect at their start (`traceway.replay.images`; `off` when the screen is not recorded). The Android and iOS SDKs inline the pictures of image views with the same encoding and limits.

```dart
TracewayOptions(
  screenCapture: true,
  screenCaptureMode: TracewayScreenCaptureMode.wireframe,
  isUnmeteredNetwork: () async => (await Connectivity().checkConnectivity())
      .any((c) => c == ConnectivityResult.wifi || c == ConnectivityResult.ethernet),
)
```

### Privacy masks

Wrap a widget in `TracewayMask` to hide it in screen recordings, or give it a marker key (below). Masks apply to the recording only: the user sees no change in the live app.

**Blur (pixelation):**

```dart
TracewayMask(
  child: Text('4242 4242 4242 4242'),
)
```

The default mode is `TracewayMaskMode.blur()` which pixelates the region. You can control the intensity with the `ratio` parameter (0.0 = light, 1.0 = heavy):

```dart
TracewayMask(
  mode: TracewayMaskMode.blur(ratio: 0.5),
  child: CreditCardWidget(),
)
```

**Blank (solid fill):**

```dart
TracewayMask(
  mode: TracewayMaskMode.blank(color: Color(0xFF000000)),
  child: SensitiveDataWidget(),
)
```

This replaces the region with a solid color (black by default) in the recording.

**Marker keys.** A widget keyed `ValueKey('traceway-mask')` is masked like `TracewayMask(child: ...)`, and one keyed `ValueKey('traceway-blank')` like a black `TracewayMaskMode.blank()`, in wireframes, videos and tap records, with no wrapper:

```dart
Text(card.number, key: const ValueKey('traceway-mask'))
ListTile(key: const ValueKey('traceway-blank'), title: Text(account.iban))
```

The marker takes the place of the widget's own key and is never reported as its id. Flutter requires the keys of the children of one `Row`, `Column`, `Stack` or other multi-child widget to differ, so mark one of them this way and wrap the others in `TracewayMask`.

In a [wireframe](#wireframe) a blank mask is a box of its color and nothing inside it is recorded; a blur mask keeps the layout but replaces its text with `*` and its images with placeholders. Text typed into fields is replaced with `*` unless remote settings set `replay.maskAllInputs: false`; obscured fields always are. Turning `maskAllInputs` on drops the frames recorded without it. In a video the same setting pixelates the text area of every field the user types into, like a blur mask; obscured and read-only fields are left as drawn.

The mask covers the widget where it is in each recorded frame: its place is read from the render tree when the frame is captured, so it stays on the widget while that scrolls in a list, animates or is transformed.

In tap records, the shown text, the label and the keys of a masked widget and of everything inside it are left out (see [Naming views](#naming-views)).

`TracewayPrivacyMask`, the name in 1.x and 2.0.0-beta.1, is a deprecated alias of `TracewayMask`.

## Video replay (add-on)

The `traceway` package records wireframes and has no native code. Video, the app's pixels encoded as MP4 with the device's hardware H.264 encoder (Android, iOS, macOS), is the separate package [`traceway_video`](packages/traceway_video), so apps that don't want it never build the encoder plugin:

```bash
flutter pub add traceway_video
```

```dart
import 'package:traceway_video/traceway_video.dart';

void main() {
  TracewayVideo.register();
  Traceway.run(
    token: const String.fromEnvironment('TRACEWAY_TOKEN'),
    options: const TracewayOptions(
      screenCapture: true,
      screenCaptureMode: TracewayScreenCaptureMode.video,
    ),
    child: const MyApp(),
  );
}
```

Frames are captured at `fps` (15) into a ring of `maxBufferFrames` frames (150, about 10 seconds), scaled by `capturePixelRatio` (0.75); a clip encodes the frames it covers, each held for as long as it was on screen, with the touches drawn on them and the masks applied. Without `TracewayVideo.register()`, video mode prints one warning that says what to add and records a wireframe; so does a platform without an encoder (Linux, Windows). The encoder plugin needs a Gradle change on Android and CocoaPods on iOS and macOS: see the [add-on's README](packages/traceway_video/README.md).

## Network requests

Every dart:io HTTP request is a client span (method, URL, status, duration, byte counts) via `HttpOverrides.global`, installed with `captureNetwork: true` (the default). It catches `package:http`, Dio and any other library on dart:io's `HttpClient`. Plugins that call a native SDK over a platform channel (Firebase, for example) send their requests outside Dart and are not recorded. The span ends when the response body has been read (or failed, or was cancelled); a body that is never read ends it after 10 s. No headers or bodies are recorded, and the SDK's own requests are not recorded.

**With an explicit client.** `HttpOverrides.global` only sees clients built on dart:io's `HttpClient`. A client that uses the platform's own stack, such as `cupertino_http` or `cronet_http`, bypasses it. Wrap such a client in `TracewayHttpClient`, a drop-in `http.Client`, and pass it to Dio, Chopper or any library that accepts a custom `http.Client`:

```dart
import 'package:cupertino_http/cupertino_http.dart';
import 'package:traceway/traceway.dart';

final client = TracewayHttpClient(CupertinoClient.defaultSessionConfiguration());
final res = await client.get(Uri.parse('https://api.example.com/users'));
```

`TracewayHttpClient()` without an argument wraps the default `http.Client`. That client sits on dart:io, so `captureNetwork` sees it too, but the SDK recognizes requests sent through `TracewayHttpClient` and records each one once, with one `traceparent`.

**Connect requests to backend traces.** `propagateTraceHeaderUrls` lists the URLs whose requests carry a W3C `traceparent` header naming the request's client span, so the backend's spans join the app's trace in Traceway or any OpenTelemetry backend. A `String` matches URLs that start with it, a `RegExp` URLs it matches:

```dart
TracewayOptions(
  propagateTraceHeaderUrls: [
    'https://api.example.com/',
    RegExp(r'^https://[a-z]+\.example\.com/'),
  ],
)
```

It is empty by default, because a header a server does not expect can break a strict CORS or request-signature check. It applies, once the SDK has started, to every request sent through `TracewayHttpClient`, and to other dart:io requests only with `captureNetwork: true`, because the `HttpOverrides` that add the header are installed only then. A request that already carries a `traceparent` (the app's own tracing) keeps it, and its span is recorded as before. The client span of a propagated dart:io request starts when the request is opened, so it includes connecting and the TLS handshake. Requests to Traceway and to the `telemetry` receivers never carry it. The backend must extract `traceparent` (any OpenTelemetry HTTP instrumentation does).

## App performance metrics

The SDK measures the app on the device and uploads the numbers as OTLP metrics: histograms and counters (delta temporality, base-2 exponential buckets at the server's scale), one small payload every five minutes and when the app goes to the background. Nothing is sent per observation, and no user, device or session id is a dimension. A new Flutter project starts with the **Flutter Performance** dashboard, which charts them as percentiles over every session.

| Metric | What it measures |
|--------|------------------|
| `app.start.duration` (`start_type` `cold` / `hot`) | Cold: from the process start (read from `/proc` on Android and Linux; elsewhere from when the SDK was initialized) to the first frame on screen. Hot: from the return to the foreground to the next frame |
| `app.screen.ttid` (`screen`) | Time to initial display: from the navigation to the end of the first frame that built the route |
| `app.screen.ttfd` (`screen`) | Time to full display: from the navigation until the app calls `Traceway.reportFullyDisplayed()` |
| `app.frames.slow`, `app.frames.frozen` (with `.total`, by `screen`) | From the engine's frame timings: slow when the UI or raster thread took longer than the display's frame budget, frozen at 700 ms or more |
| `app.hang`, `app.hang.duration` | The UI isolate ran no timer for 2 s (`appHangThresholdMs`) or more while the app was in the foreground; `captureAppHangs: false` turns it off. Not in debug builds, where a breakpoint or a hot reload looks the same, unless `reportHangsInDebug: true`. Flutter reports hangs as this metric only: no stack can be taken from the blocked UI isolate, so there is no `AppHang` issue (the Android and iOS SDKs report one, with the main thread's stack) |
| `app.crash` | Errors nothing caught (`FlutterError.onError`, `PlatformDispatcher.onError`, the `Traceway.run` zone). They do not end a Flutter app, so the dashboard calls them unhandled errors |
| `app.session`, `app.user`, `app.user.affected` (`issue`) | Sessions; users counted once a day per installation, and once a day per problem they met (crash, hang, slow start, frozen frames, failed request), so no id leaves the device |
| `app.memory.peak` | The process's peak RSS, once per session |
| `app.request.duration`, `app.request.bytes`, `app.request.failed` (`host`) | Every HTTP request the SDK records |

Screens are route names with ids folded (`/orders/8841` → `/orders/:id`), or the [route template](#naming-screens) when one is set. Resource dimensions are the service name, app version, environment and OS, and with `captureDeviceInfo` on, the form factor (`phone`, `tablet`, `desktop`) and, on Android and iOS, the OS major version and a coarse device class from the RAM (`low` under 3 GB, `mid` under 6 GB, else `high`).

```dart
// The screen has what it loads: ends its time to full display.
Traceway.reportFullyDisplayed();

// App-defined metrics, charted like the built-in ones.
Traceway.metric('checkout.duration', 1234, {'plan': 'pro'});
Traceway.count('cart.add');
Traceway.setMetricDimension('experiment', 'b'); // `custom.experiment` on every metric
```

`captureMetrics: false` turns it all off. A rule's `metrics` section switches metrics off (`enabled`), samples sessions (`sampleRate`; counts are weighted back by the server) or changes the upload interval (`flushSeconds`, 30–3600). An upload that fails is kept and retried once.

## Send telemetry to another OpenTelemetry provider

The SDK runs in one of three ways. The first needs nothing beyond the token.

### Everything on Traceway

```dart
Traceway.run(
  token: const String.fromEnvironment('TRACEWAY_TOKEN'),
  options: const TracewayOptions(
    serviceName: 'shop-app',
    environment: 'production',
  ),
  child: const MyApp(),
);
```

The app polls Traceway for its collection settings, sends logs, request spans and metrics to Traceway's OTLP endpoints, and uploads screen recordings to the same server. What it collects is changed on the project's **Data Collection** page.

### Issues and replays on Traceway, logs, traces and metrics elsewhere

Add `telemetry` to send ordinary logs, request spans and metrics to another OpenTelemetry provider (any OTLP/HTTP receiver, such as an OpenTelemetry Collector in front of a Grafana stack, Honeycomb or Grafana Cloud):

```dart
Traceway.run(
  token: const String.fromEnvironment('TRACEWAY_TOKEN'),
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

When logs are redirected, exceptions, `captureMessage` issues and the SDK's session and control records (`session.start`, `session.end`, `traceway.session.update`, fired triggers, started captures, applied config, collection health) still go to Traceway, and only there. Ordinary logs (`print` / `debugPrint`, navigation, taps, `Traceway.recordAction`, `Traceway.track`) go to the logs receiver; request spans and metrics use their own destinations. Remote config (OpAMP) and screen recordings stay on Traceway. Breadcrumbs sent elsewhere are not copied into Traceway's session timeline; both destinations carry `session.id` for correlation.

Live exports, a ring buffer flushed by a trigger or restored after a restart, and retries all use the configured destinations and headers. Batches that failed are queued on disk per destination (`outbox` for Traceway, `outbox-<hash>` for each set of external destinations), and pending metric payloads and the daily user count are kept per destination, so a changed receiver is never sent what was meant for the previous one. Requests to the receivers are not recorded as network spans.

The receiver must accept OTLP/HTTP with protobuf bodies (`application/x-protobuf`); logs, spans and metrics are gzip-compressed (`Content-Encoding: gzip`). There is no CORS on mobile, but any key built into the app can be read out of it: use an ingestion key that can only write, or a collector that holds the backend credentials. Metrics are delta sums and base-2 exponential histograms, so configure the downstream pipeline to accept or convert those types.

### Standalone, without a Traceway server

Leave out the token:

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

**Settings the SDK cannot use** never take the app down. A `baseUrl` that is not an HTTP(S) URL with a host prints one warning and the app runs without the SDK. No token and no `telemetry` destination (often a build without `--dart-define=TRACEWAY_TOKEN`), a `telemetry` URL that is not HTTP(S) or carries credentials, a query or a fragment, or standalone `telemetry` without a destination for every signal: `Traceway.run` reports the error as a `FlutterError` (shown in the console, library `traceway`) and runs the app without the SDK, so nothing is collected until the settings are fixed. `TracewayClient.initialize`, called directly, returns `null` for the first and throws the `ArgumentError` for the others.

## Options

Shared with the Android and iOS SDKs, in their order, then Flutter's own:

| Option | Default | Description |
|--------|---------|-------------|
| `sampleRate` | `1.0` | Share of exceptions and messages that are reported (0.0 - 1.0) |
| `debug` | `false` | Print debug info to console |
| `version` | `''` | App version, sent as `service.version` (`unknown` when empty) |
| `serviceName` | `flutter-app` | Sent as `service.name` |
| `environment` | — | Sent as `deployment.environment.name` |
| `attributes` | `{}` | Attributes attached to every record, and reported to the server for remote-config targeting |
| `screenCapture` | `false` | Record the screen: the last ~10 seconds go up with an exception, and captures can stream it (see [Session replay](#session-replay)) |
| `replayImages` | `always` | The most a wireframe may show of images (`TracewayImagePolicy.off`, `.wifi`, `.always`), the ceiling of `replay.images` (see [Images](#images)) |
| `fps` | `15` | Frames per second for screen capture (1–59) |
| `maxBufferFrames` | `150` | Frames in the recording ring buffer (~10s at 15fps); the upper bound of every clip |
| `persistToDisk` | `true` | Keep SDK state and undelivered telemetry on disk across restarts |
| `captureLogs` | `true` | Capture `package:logging` records, `Traceway.log` and every `print` / `debugPrint` |
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
| `telemetry` | — | Send logs, spans and metrics to another OTLP/HTTP receiver: `TracewayTelemetry(url:, headers:, logs:, traces:, metrics:)` (see [Send telemetry to another OpenTelemetry provider](#send-telemetry-to-another-opentelemetry-provider)) |
| `propagateTraceHeaderUrls` | `[]` | URLs (`String` prefixes or `RegExp`s) whose requests carry a W3C `traceparent` header (see [Network requests](#network-requests)) |
| `ignoreErrors` | network failures | Exceptions and messages not to report (see [Errors and messages](#errors-and-messages)); `[]` reports everything |
| `beforeCapture` | — | Called before an exception or message is recorded; return `false` to drop it |
| `screenCaptureMode` | `wireframe` | `TracewayScreenCaptureMode.wireframe` (the widget tree replayed as HTML, every platform) or `.video` (MP4 with the [`traceway_video` add-on](#video-replay-add-on), Android, iOS, macOS; a wireframe elsewhere); remote `replay.captureMode` overrides it |
| `capturePixelRatio` | `0.75` | Video frame resolution scale factor (the video add-on) |
| `captureDeviceInfo` | `true` | Describe the device (model, name, local IP, locale, screen, Dart runtime); `false` keeps only `os.name` and `os.version` |
| `reportHangsInDebug` | `false` | Report hangs in debug builds too |
| `captureAppHangs` | `true` | Report hangs, for the `app.hang` metric; Flutter reports no `AppHang` issue |
| `appHangThresholdMs` | `2000` | How long the UI isolate must be blocked to count as a hang, for the `app.hang` metric (at least 250) |
| `isUnmeteredNetwork` | — | `FutureOr<bool> Function()`: whether the device is on an unmetered network, for `replay.images = wifi`; without it the SDK guesses from the network interfaces (see [Images](#images)) |

## Crashes and symbolication

The Flutter SDK reports **Dart** errors: framework errors, uncaught async errors and unhandled platform errors, each with its Dart stack. A native crash (in a plugin's Kotlin, Java, Swift, Objective-C or C code, or in the engine) ends the process before Dart runs, so it is not reported, and neither is the stack of a hang (see `app.hang` in [App performance metrics](#app-performance-metrics)). To get native crashes, ANRs and app hangs with their stacks, add the Traceway Android and iOS SDKs to the host apps (`android/`, `ios/`) next to this one.

You usually don't need to do anything for symbols. A plain `flutter build --release` keeps
enough symbol information that crash stack traces are already readable
(function names + file:line), and the SDK reports them as-is.

You only need to upload debug symbols **if you build with `--obfuscate` and/or
`--split-debug-info`**. Those flags shrink the app and protect your code by
stripping and renaming that information, so release traces then arrive as bare
instruction offsets. In that case the SDK forwards the raw trace and Traceway
turns it back into `function (file:line:col)` server-side using the `.symbols`
files you upload.

**One-time setup.** Nothing on Traceway Cloud: the uploader sends to
`https://cloud.tracewayapp.com` unless you name another server. For a
self-hosted server, set `TRACEWAY_URL` or add a `traceway:` block to your
app's `pubspec.yaml`:

```yaml
traceway:
  url: https://traceway.mycompany.com   # only for a self-hosted server
  # upload_token: ...                   # prefer the env var below, especially in CI
```

The upload token is your project's upload token from the dashboard (the same
one used for JavaScript source maps), not the project token you pass to
`Traceway.run(token: …)`.

**Per release:**

```sh
flutter build apk --release --obfuscate --split-debug-info=build/symbols

TRACEWAY_UPLOAD_TOKEN=YOUR_UPLOAD_TOKEN dart run traceway:upload_symbols
```

The uploader reads the token and the server from env/config and
auto-discovers `build/symbols`, so no flags are required. Each value resolves
from a CLI flag first (`--token`, `--url`, `--symbols-dir`), then an env var
(`TRACEWAY_UPLOAD_TOKEN`, `TRACEWAY_URL`), then `pubspec.yaml`; a blank value
counts as unset, and the server is Traceway Cloud when none is named. The URL
is read like `baseUrl` (`https://` added when it has no scheme, a trailing
`/api` dropped). Use `--dry-run` to preview where it would send. Symbols are
unique to each build, so upload on every release; a crash can only be
symbolicated against the exact build it came from.

Each symbols file is keyed by its debug id plus architecture. On Android the
debug id is read from the file directly. On iOS and macOS the file doesn't carry
it, so the uploader reads it from the built app's Mach-O UUID (the same value
the runtime reports); it auto-discovers the `.app` under `build/`, or point it
explicitly with `--app build/macos/Build/Products/Release/YourApp.app`.

### Crash safety

The SDK itself never takes the app down. Every public call, every hook it
installs (the `Traceway` widget's pointer callbacks, lifecycle observers,
frame callbacks, the navigator observer, the HTTP overrides, the
`package:logging` listener) and every timer and background task runs inside
one guard: a failure there is contained, printed once per place with
`debug: true`, and the app's own operation completes. An error object whose
`toString()` throws, or an `ignoreErrors` pattern that throws, does not make a
call throw into the app's `catch` block. The app's own errors are recorded and
then handed on as without the SDK: to a zone around `Traceway.run`, or to the
app's own `PlatformDispatcher.onError` (Crashlytics, say), once each.
`flush()` and `shutdown()` wait at most 10 seconds for a clip whose encoder
never answers.

## What gets captured automatically

- **Flutter framework errors** — rendering, layout, gestures via `FlutterError.onError`
- **Unhandled root-isolate errors** — reported through `PlatformDispatcher.instance.onError`
- **Uncaught async errors** — unhandled futures via `runZonedGuarded`; each is then handed on as without the SDK, to a zone around `Traceway.run` or to the app's `PlatformDispatcher.onError`
- **Logs** — `print` / `debugPrint` and `package:logging` (see [Logs](#logs))
- **Network** — dart:io HTTP requests (see [Network requests](#network-requests))
- **Navigation** — with `Traceway.navigatorObserver` (see [Naming screens](#naming-screens))
- **Taps** — every tap inside the `Traceway` widget, with the selector, type, id, shown text and label of the widget, and the screen (`browser.user_action.click`, with the OpenTelemetry `app.widget.*` and `app.screen.*` attributes). A long press is not a tap.
- **Sessions and app performance metrics** (see [App performance metrics](#app-performance-metrics))

## Platform support

| Platform | Error Tracking | Screen Recording |
|----------|---------------|-----------------|
| iOS | Yes | Wireframe; video with `traceway_video` |
| Android | Yes | Wireframe; video with `traceway_video` |
| macOS | Yes | Wireframe; video with `traceway_video` |
| Linux, Windows | Yes | Wireframe (no video encoder: video falls back to it) |
| Web | No | No |

**Flutter web.** This SDK does not support Flutter web: it relies on dart:io (`HttpOverrides`, `Platform`, files on disk), which does not exist in a browser, and `TracewayHttpClient` is part of it. In a web build `Traceway.run` prints one line and runs the app without the SDK. For web apps, use the [`@tracewayapp/frontend`](https://docs.tracewayapp.com/client/js-sdk?sdk=js-generic) JS SDK, which captures errors and records `fetch` and `XMLHttpRequest` calls automatically; those are what Dart's HTTP clients use in a web build.

Give the web build its own browser project (React, Svelte, Vue.js or jQuery in the framework picker) and use that project's token, not the Flutter project's.

Add the CDN script to `web/index.html`:

```html
<script src="https://cdn.jsdelivr.net/npm/@tracewayapp/frontend@2/dist/traceway.iife.global.js"></script>
<script>
  Traceway.init({ token: "YOUR_TOKEN" });
</script>
```

Alternatively, if you use npm in your Flutter web project:

```bash
npm install @tracewayapp/frontend
```

```html
<script type="module">
  import { init } from '@tracewayapp/frontend';
  init({ token: 'YOUR_TOKEN' });
</script>
```

See the full [JS SDK documentation](https://docs.tracewayapp.com/client/js-sdk?sdk=js-generic) for all options. Its session replay records the DOM; Flutter web paints its UI into a canvas, which the recorder does not capture, so a replay shows little of a Flutter app.

### Platform differences

The API has the names of the browser, Android and iOS SDKs. Where Flutter differs, it is for these reasons:

- **Start**: `Traceway.run(token:, baseUrl:, child:, options:)` instead of `init`, because it wraps `runApp`: it starts the client, runs the app in a zone that catches uncaught async errors and `print` lines, installs `FlutterError.onError` and `PlatformDispatcher.onError`, and puts the app inside the `Traceway` widget, which records the screen and taps. `token` and `baseUrl` are the names of every SDK. Android starts with `Traceway.init`, iOS with `Traceway.initialize`. `TracewayClient.initialize(token:, baseUrl:, options:)` starts the client alone, for an app that runs `runApp` itself.
- **Masks are widgets**: `TracewayMask(child:, mode:)`. The marker that needs no wrapper is a key, `ValueKey('traceway-mask')` or `ValueKey('traceway-blank')`, where the browser uses CSS classes, Android `android:tag` / `testTag` and iOS `accessibilityIdentifier`. Mask colors are `Color`s.
- **Dart errors do not carry their stack**: `captureException(error, [stackTrace, attributes])` and `log(message, {level, error, stackTrace, attributes})` take it next to the error.
- **Named parameters**: `recordAction(category:, name:, data:)` and `recordNavigation(path, {from, action, route})` take theirs by name. `flush([timeoutMs])` waits at most that many milliseconds, as in the browser and Android (iOS takes seconds).
- **Getters**: `Traceway.currentSessionId` is a getter (a function in the browser); `getInstanceId()` is a method, as in the browser and Android (iOS: `instanceId`). `Traceway.client` is the running `TracewayClient` (`TracewayClient.instance`), like Android's and iOS's `Traceway.client` and the browser's `getClient()`. `Traceway.ready` completes when the SDK has started.
- **Navigation** is recorded by `Traceway.navigatorObserver` on the app's `Navigator`, not by itself; a router that does not report to it calls `recordNavigation`.
- **Selectors name widgets**: types, `ValueKey`s and `Semantics` identifiers, labels and roles (see [Naming views](#naming-views)).
- **Video** replay (`screenCaptureMode: video`, `fps`, `capturePixelRatio`) exists only in Flutter, as the `traceway_video` add-on.
- **Native crashes and hangs**: Flutter reports Dart errors only, and hangs as the `app.hang` metric only; native crashes, ANRs and hang stacks need the Android and iOS SDKs in the host app (see [Crashes and symbolication](#crashes-and-symbolication)).
- **Unmetered network**: Flutter has no network type API, so `replay.images = wifi` uses `isUnmeteredNetwork` or an interface heuristic where Android and iOS ask the system.
- **Replay images**: the pixels of `RenderImage`s are inlined; those of `DecorationImage`s are not (their URL or a placeholder).
- **`Traceway.tracer`** is a `Tracer` of `dartastic_opentelemetry` (Android and iOS: the OpenTelemetry Java and Swift SDKs' `Tracer`).

## Migrating

### From 2.0 to 2.1

- **Start with a token**: `Traceway.run(token: 'YOUR_TOKEN', child: …)`, with `baseUrl: 'https://your-server'` only for a self-hosted server (Traceway Cloud, `https://cloud.tracewayapp.com`, is the default). Keep the token out of the source with `--dart-define=TRACEWAY_TOKEN=…`. The `connectionString` parameter still works and is deprecated: it is read as the token and the server URL (the API path the old strings ended in dropped, `https://` added when there is no scheme) and prints one warning naming the new form. One it cannot read prints one warning and leaves the SDK off; it never throws.
- **`TracewayClient.initialize`** takes the same named parameters, `initialize(token:, baseUrl:, options:)`, and returns `null` when the server URL is unusable.
- **Video is an add-on**: the default `screenCaptureMode` is now `wireframe`, and the `traceway` package no longer depends on `flutter_quick_video_encoder` (no Gradle patch, no CocoaPods requirement). For video, add [`traceway_video`](#video-replay-add-on) and call `TracewayVideo.register()` before `Traceway.run`; without it, video mode warns once and records a wireframe. Remove the `flutter_quick_video_encoder` Gradle block from an app that does not use the add-on: Gradle fails on a project that no longer exists.
- **`legacyConnectionString` is gone**: the reports a 1.x build left on the device are sent as OTLP exception records of the running SDK, through its normal path, with the time they happened (their video clips are dropped); reports older than 12 hours, the 1.x default, are deleted. Nothing is sent to the 1.x report endpoint any more.

### From 1.x

- **Server**: 2.x sends OTLP to `/api/otel/v1/logs`, `/api/otel/v1/traces` and `/api/otel/v1/metrics`, polls `/api/otel/v1/opamp` and uploads clips to `/api/recordings`. There is no fallback to the 1.x protocol.
- **Start**: pass the token of the connection string as `token:`, and its server as `baseUrl:` when it is not Traceway Cloud (see above). Without a token the SDK runs [standalone](#standalone-without-a-traceway-server).
- **Unsent 1.x reports** are delivered by the first 2.1 start, as above.
- **Behaviour**: logs and actions are no longer limited to the last 10 seconds and no longer travel inside the recording. They are buffered for up to 10 minutes and sent as their own records with an exception. `captureMessage` no longer attaches a screen recording.
- **Renamed API**: `TracewayPrivacyMask` is now `TracewayMask`; the old name is a deprecated alias of it.
- **Removed options**: `debounceMs`, `retryDelayMs`, `maxPendingExceptions`, `maxLocalFiles`, `localFileMaxAgeHours`, `eventsWindow`, `eventsMaxCount`.
- **Removed API**: the 1.x transport methods of `TracewayClient` (`addException`, `loadPendingFromDisk`, `pendingExceptions`, `pendingRecordings`, `bufferedEvents`, `collectDeviceInfo`, `collectSyncDeviceInfo`, `setDeviceAttributes`) and the `ReportSender` export. Use `Traceway.captureException`, `Traceway.setAttribute` and `Traceway.flush()`. `TracewayClient.initialize` returns the running client instead of replacing it: call `shutdown()` before initializing with another token. An `initialize` while it is still stopping starts the new client.
- **New API**: `Traceway.captureException`, `captureMessage`, `log`, `track`, `setAttribute`, `setAttributes`, `removeAttribute`, `clearAttributes`, `recordNavigation`, `setRoute`, `startInteraction`, `reportFullyDisplayed`, `metric`, `count`, `setMetricDimension`, `flush`, `shutdown`, `refreshConfig`, `getInstanceId`, `currentSessionId`, `client`, `ready` and `tracer`; `TracewayTelemetry` and `TracewayTelemetryEndpoint`. `TracewayClient.instance` has the same methods (`metric` and `count` are `recordMetric` and `recordCount` there; `recordNavigation` is only on `Traceway`), so `TracewayClient.instance?.captureException(e, st)` keeps working. New options include `telemetry`, `propagateTraceHeaderUrls`, `collection`, `captureUserActions`, `captureMetrics`, `recordAllSessions` and `replayImages`.
- **OpenTelemetry**: Traceway records through log and trace providers of its own, so the app keeps its own exporters, whether it set OpenTelemetry up before Traceway or after (`OTel.initialize` then replaces the factory Traceway installed), and can continue tracing after Traceway shuts down. Spans the app makes through `OTel` are not sent to Traceway.

## Testing

The SDK's own tests run with `flutter test -j 1` (unit and widget tests in `test/`, about 500 of them; the video add-on's in `packages/traceway_video/test`). `test/fixtures/wireframe.css` is the stylesheet shared with the Android and iOS SDKs; a test checks that the wireframe's equals it byte for byte.

**Wireframe regression suite.** `tool/e2e/wireframe` runs a gallery app (`example/lib/wireframe_suite`: 26 scenarios and over 100 checkpoints of layouts, scrolling, animations, gestures, overlays, images and platform views) through the recorder on Linux desktop and compares every replayed screen in rrweb-player with the app's own picture of it (SSIM, edge alignment, color) and with a baseline rendering; see its README.

**End-to-end.** `tool/e2e/run.py` drives `example/lib/e2e_main.dart` against a real Traceway server (Linux desktop or an Android device) and checks the issue, breadcrumbs, taps, spans, sessions, wireframe clips, triggers, captures, metrics and the external-collector and standalone setups.

**Performance.** The benchmark harness lives in [`example/integration_test/`](example/integration_test/) (ten workloads: idle, scroll, navigation, video playback, exception bursts, and combinations, each with no SDK, the SDK idle, recording, and recording with disk persistence) and runs as a GitHub Action, the [Performance Benchmarks workflow](.github/workflows/benchmark.yml) — re-run it on your own device tier any time.

2.0, measured with Flutter 3.50 on Android 14 (an x86_64 container with software rendering, so ratios matter more than absolute times):

- **App size**: a release arm64 APK grows by 1.77 MB (1.0.9: 0.98 MB). The SDK is 313 KB of Dart code, `protobuf` 120 KB and the OpenTelemetry SDK for Dart 160 KB.
- **Network**: about 40 KB an hour while idle (an OpAMP poll of 1.1 KB and a metrics upload of 0.5–0.7 KB every five minutes, headers included); breadcrumbs cost nothing until an error. An exception sends about 4.5 KB plus its clip, 10–280 KB on a UI and about 1.3 MB on a screen playing video.
- **Performance**, profile build of the benchmark with app vitals running, median over the ten workloads: without screen capture, build and raster times and wall clock are within noise of the app without the SDK. With screen capture, raster time p90 is ×1.23 and RSS +23 MB; bursts of exceptions take ×1.3 as long while their clips encode. Capturing an exception takes 0.2–1.1 ms.

1.x, measured on Firebase Test Lab — Pixel 5 (API 30), Pixel 6 (API 33), Pixel 8 (API 34), iPhone 8 / 14 Pro / 16 Pro across the ten workloads for each of the four configs. The video capture path (frames, encoding) is unchanged in 2.0.

| Cost | When idle (`screenCapture: false` or no recording yet) | While actively recording |
|------|------|------|
| **Memory overhead** (RSS) | **+0 MB median**, max +10 MB across all tested devices | **+16 MB median** (≈ +8%), worst measured +66 MB during video-playback bursts on iPhone 14 Pro |
| **Wall-clock impact** (steady state) | **0%** | **0%** median |
| **Frame timing** (p50/p99 build duration) | Within measurement noise on every workload | Within measurement noise on every workload |
| **Exception capture latency** | n/a (SDK not initialized) | **0.09–0.35 ms on iOS**, 5–12 ms on Android — both well under one 60 Hz frame budget (16.7 ms) |
| **Disk persistence cost** | n/a | Adds no measurable RAM beyond in-memory recording |

What we guarantee (1.x measurements):

1. **If `screenCapture: false` or no recording is in progress, Traceway adds < 10 MB of RSS.** On most devices it adds zero measurable memory.
2. **Median memory overhead during active recording is under 20 MB.** In the worst measured scenario on the lowest-RAM device tested, it stayed under 80 MB.
3. **Disk persistence does not increase memory cost.** Writing recordings to disk consumes the same RAM as in-memory-only recording.
4. **Exception capture is sub-millisecond on iOS and under 15 ms on Android.** Both are below a single frame at 60 Hz, so capturing an exception cannot cause a dropped frame in steady state.
5. **Steady-state wall-clock impact is zero.** Your app does not run measurably slower with Traceway initialized.

Caveats:

- Numbers are from a single benchmark run; the underlying methodology is open. The exact `runId` and full per-device breakdown are produced by the Performance Benchmarks workflow.
- Frame-timing numbers carry measurement noise that can swing ±50% on individual scenarios; what we claim is "no statistically meaningful regression on any tested workload", not "the SDK speeds your app up".
- Worst-case memory peaks come from synthetic burst workloads (rapid exceptions during video playback). Real apps that throw 1-2 exceptions per session will sit close to the median numbers.

## Links

- [Traceway Website](https://tracewayapp.com)
- [Traceway GitHub](https://github.com/tracewayapp/traceway)
- [Documentation](https://docs.tracewayapp.com/client/flutter?sdk=flutter)
- [Flutter SDK Source](https://github.com/tracewayapp/traceway-flutter)

## License

MIT
