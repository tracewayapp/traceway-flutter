## 2.1.0 — unreleased

- **Start with a token** (breaking for direct `TracewayClient.initialize` callers): `Traceway.run(token: 'YOUR_TOKEN', baseUrl: …, child: …, options: …)` and `TracewayClient.initialize(token:, baseUrl:, options:)`; `baseUrl` defaults to Traceway Cloud, `https://cloud.tracewayapp.com`, so cloud apps pass only the token (`--dart-define=TRACEWAY_TOKEN=…`). The `connectionString:` parameter is deprecated: every form works (`token@url`, `/api`, `/api/report`, trailing slashes, no scheme, whitespace, `localhost` over http, servers under a sub-path), read as `token` + `baseUrl` with one deprecation warning naming the new form; a string or `baseUrl` it cannot read prints one warning and leaves the SDK off instead of throwing (`initialize` returns `null`). An empty token, a build without its `--dart-define`, is reported with a message that names `TRACEWAY_TOKEN`.
- **Nothing calls the 1.x `/api/report` any more**: `TracewayOptions.legacyConnectionString` is removed, and the reports a 1.x build left on the device become OTLP exception and message records of the running SDK, with their time, type, message, stack and attributes (no trigger fires for them; their video clips are dropped). Reports older than 12 hours, damaged files and the old directory are deleted.
- **Video replay is the `traceway_video` add-on** (breaking for video users): the `traceway` package has no native code and no `flutter_quick_video_encoder` dependency, so it builds on every Android, iOS and desktop setup without the Gradle patch or CocoaPods. The default `screenCaptureMode` is now `wireframe`. For video, add `traceway_video` and call `TracewayVideo.register()` before `Traceway.run`; video mode without it prints one warning saying what to add and records a wireframe. `package:traceway/video.dart` is the interface the add-on implements. Apps that kept the encoder's Gradle block must remove it unless they add the add-on.
- **Images with transparency are never JPEG** in wireframe replay: they are PNG, the longest side at most 192 px (resampled in the background isolate); before, one over 96 px became a JPEG on a white box.
- An interaction started in the first moments after `Traceway.run` (in `main` or the first screen's `initState`) is recorded once the SDK is ready, from the time it started, with its child request spans and exceptions; before, it recorded nothing. `Traceway.ready` completes when the SDK has started (`Traceway.tracer` is set from then on).
- `Traceway.client`, the running `TracewayClient`, as on Android and iOS.
- `dart run traceway:upload_symbols` reads its server like `baseUrl` (`https://` added when there is no scheme, a trailing `/api` dropped) and treats a blank `--url`, `TRACEWAY_URL` or `traceway.url` as unset, so it uploads to Traceway Cloud unless a self-hosted server is named. A quoted `pubspec.yaml` value followed by a comment is read without the comment.
- `TracewayOptions.captureAppHangs` (default `true`) and `appHangThresholdMs` (default `2000`, at least 250) for the `app.hang` metric, as on Android and iOS.
- With `debug: true` the SDK says why something was left out, once per reason: an error that matches `ignoreErrors` (and how to report everything), one `beforeCapture` dropped, one not sampled, the duplicate and flood guards, a replay picture dropped for its size or the session's budget, and that no screen is known yet when a tap or an exception comes before any navigation (add `Traceway.navigatorObserver`).
- Wireframe clips are measured without being JSON-encoded on the UI isolate, and replay uploads over 16 KiB are encoded and gzipped in a background isolate, once for all retries.
- A replay picture that failed for one session's image budget is made again in the next session; before, the image stayed a placeholder.
- With `debug: true` a Flutter error is printed once, not a second time as "Another exception was thrown".
- On Flutter web `Traceway.run` prints one line and runs the app without the SDK (`TracewayClient.initialize` throws an `UnsupportedError` saying so), instead of reporting an `UnsupportedError` at every start and leaking a logging listener.
- `pubspec.yaml` states what the package needs (Dart 3.10, Flutter 3.38.1, no web), so pub explains an older Flutter instead of failing on `device_info_plus`. Version 2.1.0; mobile leaves beta. `publish.sh` dates a `## <version> — unreleased` heading instead of adding a second one, and bumps the add-on's version too.
- README: quick start with `token:` and the navigator observer, a Platform setup section (Android `INTERNET`, the macOS network entitlement), "Send telemetry to another OpenTelemetry provider", "Video replay (add-on)", `Your own spans`, and host `cloud.tracewayapp.com`. The example reads `--dart-define=TRACEWAY_TOKEN` and has a README of its own.

- **Wireframe replay inlines image pixels**, like the Android and iOS SDKs: under `replay.images = always`, and `wifi` on an unmetered network, every `RenderImage` (network, asset, memory or file image) becomes a small picture of its decoded pixels, the part its fit and alignment show at its displayed size (longest side 384 px, tint and mirroring kept), drawn on the raster thread and encoded in a background isolate as JPEG at quality 0.45 (an image with transparency as PNG, longest side 192 px), at most 48 KiB after one retry at half size. The image's node gets `im p<N>` and an inline `background-size`/`background-position`; a style node holds `.im.p<N>{background:url(data:…) center/cover no-repeat}`. One picture per decoded image and size, at most 128 per recorder (the one shown longest ago evicted), 4 MiB per session (`traceway.replay.image_bytes`); an animated image and anything under a mask are never encoded. `wifi` on a metered or unknown network keeps network images as URL references; `off` keeps placeholders only. Before, Flutter showed network images by URL and every other image as a placeholder. `DecorationImage`s still use their URL.
- **`TracewayOptions.isUnmeteredNetwork`** (`FutureOr<bool> Function()?`): whether the device is on an unmetered network, for `replay.images = wifi`. Without it the SDK guesses from the network interfaces that are up (Android `wlan*`/`eth*`, iOS `en0`, desktop Wi-Fi and Ethernet), with no plugin.
- **Wireframe keyboard**: while the view's bottom inset is up, the wireframe draws the neutral "Keyboard" box of the Android and iOS SDKs (ids 12 and 14, the same colors, dark in dark mode) over the bottom of the screen.
- **`Traceway.tracer`** (and `TracewayClient.tracer`): the SDK's OpenTelemetry `Tracer`, for spans of the app's own, which carry the session id and nest under the interaction they are started in; `null` before the SDK has started and after `shutdown()`. It never replaces or uses the app's own OpenTelemetry set-up.
- README: Flutter reports Dart errors only and hangs as the `app.hang` metric only; native crashes, ANRs and hang stacks need the Android and iOS SDKs in the host app.
- Wireframe suite: a `keyboard` scenario (a soft keyboard shown on desktop by the suite's binding), pictures inlined (`replay.images = always`), and checkpoints wait until the recorder has made its pictures.

- **Crash safety**: the SDK never takes the app down. Every public call, hook (the `Traceway` widget's pointer callbacks, lifecycle observers, frame and post-frame callbacks, navigator observer, HTTP overrides, `package:logging` listener, OpenTelemetry processors), timer, microtask and background future runs through one `guarded` helper: a failure inside it is contained (printed once per place with `debug: true`) and the app's own operation completes. Start-up, `flush()` and `shutdown()` run each step on its own, so one failing step no longer leaves the rest undone. `test/crash_safety_test.dart` injects faults into each part.
- An error object whose `toString()` throws, a throwing `ignoreErrors` pattern or a hostile `package:logging` error no longer makes `captureException`, `log` or other calls throw into the app's `catch` block.
- Uncaught async errors of the `Traceway.run` zone are recorded, then handed on as without the SDK: to a zone around `Traceway.run`, or from the root zone to the app's own `PlatformDispatcher.onError` (Crashlytics, say), once each. Before, they stopped at Traceway.
- `Traceway.run` called twice (an integration test running `main` per test) no longer installs a second error handler and HTTP override, which recorded every error and request twice.
- dart:io requests keep the app's own `HttpOverrides.findProxyFromEnvironment` proxy; they went direct once `captureNetwork` wrapped the override.
- An app may now set OpenTelemetry up after `Traceway.run` (`OTel.initialize` threw a `StateError`): Traceway records through providers of its own and no longer puts the app's spans into its pipeline or shuts the app's OpenTelemetry down.
- An app that sets the Flutter binding up before `Traceway.run` no longer gets a "Zone mismatch" issue on every debug launch (or a blank app with `debugZoneErrorsAreFatal`): the app keeps its zone.
- **Video replay masks typed text**: with `replay.maskAllInputs` on (the default), the text area of every field the user types into is pixelated in video clips, as wireframes mask it. Before, video recorded it in clear.
- A trigger, recorder or restored record that fails no longer loses the exception that ran it (it is sent with `traceway.replay.status: buffer_unavailable`); a damaged pending metrics payload or restored buffer record is dropped instead of aborting start-up or filing an `app.crash` at every metrics upload.
- The `Traceway` widget follows the client: after `shutdown()` the app's widget state is kept, and a client started later gets a screen recorder.
- `flush()` and `shutdown()` wait at most 10 s for a clip whose platform encoder never answers.
- Reporting an exception no longer fsyncs on the UI isolate, and the disk queue is pruned every 16 batches instead of on each.
- A remote rule with a number out of range (`maxPerSession: 1e400`) is skipped alone, not the whole settings document; a heartbeat interval over a day is capped instead of polling in a loop.
- Starting the SDK again after `shutdown()` no longer leaks a frame callback that kept the old client alive.
- `Traceway.navigatorObserver` watches one Navigator: the docs now say to give a nested Navigator its own `TracewayNavigatorObserver()`.

- **`TracewayMask`** replaces `TracewayPrivacyMask`, which stays as a deprecated alias; the browser, Android and iOS SDKs use the same name. **Marker keys**: a widget keyed `ValueKey('traceway-mask')` is masked like a blur `TracewayMask` and one keyed `ValueKey('traceway-blank')` like a blank one, in wireframes, video clips and tap records, without a wrapper (the browser SDK's `traceway-mask` / `traceway-blank` classes). A marker key is not reported as the widget's id. Video mask regions are now found by walking the elements under the recorded boundary when each frame is taken.
- **Static API like the browser SDK's**: `Traceway.captureException(error, [stackTrace, attributes])`, `captureMessage`, `setAttributes`, `removeAttribute`, `clearAttributes`, `flush([timeoutMs])`, `shutdown()`, `refreshConfig()`, `getInstanceId()` and `currentSessionId`, pass-throughs to `TracewayClient.instance` that do nothing before the SDK has started.
- **`replay.images`** (`off`, `wifi` by default, `always`), a remote and local setting merged like `replay.maskAllInputs`, under the new ceiling `TracewayOptions.replayImages` (`TracewayImagePolicy`, default `always`). `off` turns the network images of a wireframe (`<img src>` and `DecorationImage` backgrounds) into `.im` placeholders and recaptures the screen at once; `wifi` and `always` keep their URLs, since Flutter uploads no image pixels. Video is not affected. Session events carry `traceway.replay.images`.
- **`traceway.collection.health`**: when a replay clip goes over the session's budget, the server refuses replay segments or they run out of retries, or the error flood guard holds errors back, the SDK reports the counters (`traceway.collection.*`, `traceway.error.suppressed_total`, `traceway.context.evicted`, `traceway.replay.failed_segments`) 1 s later, then at most once per doubling delay up to 5 minutes, and updates the session once, as the browser SDK does. Session events (`session.start`, `traceway.session.update`, `session.end`) carry `traceway.error.suppressed_total` too.
- The log records a dashboard capture's lookback uploads now carry the running captures' ids (`traceway.capture.ids`), as in the browser SDK.
- Wireframe: the shared stylesheet is byte-identical with the Android and iOS SDKs' (it gains iOS's `.sk` skeleton rules) and the screen node carries the platform's font stack (Apple's on iOS and macOS, Roboto's elsewhere); decoration images that cannot load get the `.im` placeholder class. Internals renamed to the vocabulary the three SDKs share (`wireframe_capture.dart`, `wireframe_css.dart`, `wireframe_diff.dart`, `wireframe_glyphs.dart`/`WireframeGlyphs`, `wireframe_roots.dart`, `replay/replay_source.dart`, `WireframePointer`); `docs/wireframe.md` describes the pipeline.
- README restructured to the layout the Flutter, Android and iOS SDKs share; the options table lists the shared options first.

- **Interactions** (manual spans): `Traceway.startInteraction('checkout')` returns a `TracewayInteraction` whose `run` makes the requests in it child spans and gives the exceptions, messages and logs recorded there its trace; `captureException`, `setAttribute`, `end`, `traceId`, `spanId`. A failed interaction is sent with its exception. As the browser SDK's `startInteraction`.
- **`ignoreErrors` and `beforeCapture`**: network failures (`SocketException`, `ClientException`, handshake failures, lost or refused connections, timeouts, 4xx statuses: `defaultIgnoreErrors`) are no longer reported by default; `ignoreErrors` replaces the list, matched against the first line of `Type: message`. `beforeCapture(TracewayCapturedError)` can drop an exception or message. An ignored unhandled error is not counted as a crash.
- **Route templates**: `Traceway.recordNavigation(path, route: '/orders/:id')`, `Traceway.setRoute(template)` and `routeFromParams(path, params)`. Screen metrics group by the template, and issues and navigations carry it as `app.screen.route`.
- `captureDeviceInfo: false` keeps only `os.name` and `os.version` on records: no model, device name, local IP, locale, screen or runtime.
- Hangs are no longer reported from debug builds, where a breakpoint, a hot reload or a slow first compile looks the same; `reportHangsInDebug: true` turns them back on.
- Slow and frozen frames are counted under the screen they were drawn on (matched by frame number), not the one showing when the engine reported them about a second later.

- **Wireframe session replay**: `TracewayOptions.screenCaptureMode: TracewayScreenCaptureMode.wireframe` records the widget tree instead of video. After the frames that changed something (at most `fps` a second) the elements under `Traceway` are turned into an HTML document of positioned boxes, text, clips, fades, transforms and scroll offsets, and what changes becomes rrweb mutations; taps and drags are rrweb touch events. Clips and streamed segments each start with a full snapshot and go to `/api/recordings` like video clips, and the dashboard replays them with its rrweb player. Works on every platform (Linux and Windows included), with segments of a few kilobytes. Text fields are masked unless remote settings set `replay.maskAllInputs: false`; `TracewayMask` blanks or masks its subtree.
- **Video or wireframe, from the dashboard**: remote `replay.captureMode` (`video` or `wireframe`) overrides `screenCaptureMode`, and the `Traceway` widget swaps its recorder when it changes. The change applies at once unless the session has already uploaded replay in the other mode, then from the next session (the mode is saved with the session, which may resume after a restart), so one session's replay is all video or all wireframe.
- Where there is no video encoder (Linux, Windows), `screenCapture` now records a wireframe instead of nothing.
- Wireframe fidelity: icons are drawn from a picture of their glyph (made once, used as a CSS mask in the icon's color) instead of squares; perspective transforms (3D cards, `ListWheelScrollView`, `CupertinoPicker`) are CSS `matrix3d`, and a wheel dims its off-center items; `ImageFiltered`/`BackdropFilter` blurs and grayscale `ColorFiltered` are CSS filters; beveled, star and custom `ClipPath` shapes are clip paths; a circle decoration in a box that is not square stays a circle; `SegmentedButton` gets its outline and dividers; platform views (web views, maps) and textures are labeled placeholders; `SelectableText` is no longer masked as an input.
- Wireframe regression suite in `tool/e2e/wireframe` and `example/lib/wireframe_suite`: 26 scenarios and over 100 checkpoints, replayed in rrweb-player and compared with the app's own pictures (SSIM, edge alignment, color) and with a baseline rendering.
- Replay byte budgets and the upload queue count the JSON size of rrweb events, not only base64 video.
- **Logs with levels**: `Traceway.log(message, level: TracewayLogLevel.warn, error:, stackTrace:, attributes:)`, and every `package:logging` record with its level, logger name (`logger.name`), error and stack trace. An app that prints its records itself gets each one recorded once. Printed lines stay info; each log has `log.source` (`logging`, `api`, `print`), so the timeline shows warnings and errors and `console.minSeverity` filters by level. The console dump of an error the SDK reported is no longer recorded again as log lines.
- **Where an issue happened**: exceptions and `captureMessage` carry `app.screen.name`, `app.screen.previous`, `app.screen.duration_ms` and `viewport`.
- **Navigation**: dialogs, bottom sheets, menus and dropdowns are navigations with `navigation.overlay: true` and no longer become the current screen (nor end its time to full display). `PageRouteBuilder` routes are named after their page widget. A screen pushed from a post-frame callback (a splash screen replacing itself) no longer records a time to initial display of ~0 ms. A long press is not a tap.
- `Traceway.setAttribute` / `setAttributes` / `removeAttribute` send a `traceway.session.update`, so the session gets a `user.id` set after sign-in at once (changes made together send one).
- Errors the framework marks silent (an image that failed to load with no `errorBuilder`) are no longer reported as exceptions and crashes. Uncaught async errors and unhandled platform errors are printed again, as without the SDK.
- Delivery: a batch that keeps failing no longer holds back the disk queue behind it (errors included); failing batches take turns and are given up after 10 failures while others go through, and an outage still stops each drain at its first batch. A batch written while a drain runs is sent by the next pass instead of waiting for another trigger. Records already queued when a rule or the kill switch turns their signal off are not sent, and baseline-sampled sessions respect a plan limit of `buffer`. Old 1.x reports: any 2xx is delivered, a report rejected for good is dropped, an unreadable one is skipped.
- Network spans end when the response body has been read (or failed, or was cancelled), not when the headers arrive, on dart:io and with `TracewayHttpClient`; a body that is never read ends the span after 10 s as before.
- Video replay plays in real time: each frame is held for as long as it was on screen, so slow captures and time in the background no longer speed the video up or shift it from the timeline. A clip ends at the end of the window it records, never after it, so streamed segments follow each other without overlapping (a capture timer slightly faster than `fps` made each 8 s segment run up to ~0.15 s into the next). A recorder restarted after the app came back records again; frames are released if a capture fails.
- Wireframe replay: pointer moves are batched like rrweb's (one event per ~500 ms), so dragging uses far less of the per-session budget of 10,000 events; turning `maskAllInputs` on drops the frames recorded without it; rich text inside a perspective transform no longer gets duplicate node ids.
- A session's replay stays one kind (video or wireframe) also when the mode changes while its first clip is still encoding, and the first session of a run uses its own id for that choice.
- Smaller fixes: remote config is polled on return to the foreground only when a poll is due; a trigger step's `withinSeconds` is capped at a day; `package:stack_trace` traces keep their frames; a server-assigned instance id applies to records at once; a session's peak memory is its own, not the process's lifetime peak; `initialize()` while a `shutdown()` is still running starts a new client; keys under a `TracewayMask` are left out of tap records.

## 2.0.0-beta.1 — 2026-11-26

Rebuilt on the standard OpenTelemetry SDK for Dart, at parity with the browser SDK 2.1: OTLP logs, spans and metrics, a ring buffer on the device, remote config over OpAMP, captures with video, recording triggers, taps and app performance metrics.

- **Breaking**: requires a server with OTLP/OpAMP support for Flutter projects; the 1.x `/api/report` protocol is gone. Options `debounceMs`, `retryDelayMs`, `maxPendingExceptions`, `maxLocalFiles`, `localFileMaxAgeHours`, `eventsWindow` and `eventsMaxCount` were removed.
- Logs and spans are OpenTelemetry records, built with `dartastic_opentelemetry` and sent as OTLP/HTTP.
- Ring buffer: logs, HTTP requests, navigation and custom events stay on the device (2 MiB / 10 minutes) and are uploaded when an exception or a trigger asks for them.
- Remote config over OpAMP: signal modes, sample rates, triggers and on-demand captures from the dashboard. Init options are ceilings.
- Screen recording is unchanged in size (150 frames, ~10 seconds). The clip of an exception is uploaded to `/api/recordings`.
- Sessions, `Traceway.track`, `Traceway.setAttribute`, `refreshConfig`, `shutdown`, `getInstanceId`.
- **App performance metrics**, aggregated on the device and uploaded as OTLP metrics (delta exponential histograms and monotonic sums) to `/api/otel/v1/metrics`, like the browser SDK's: cold and hot start, time to initial and full display per screen (`Traceway.reportFullyDisplayed()`), slow and frozen frames, hangs, unhandled errors, sessions, daily users and affected users, peak memory and HTTP requests by host. App-defined metrics with `Traceway.metric` / `Traceway.count`, and dimensions with `metricDimensions` / `Traceway.setMetricDimension`. Remote `metrics` settings (`enabled`, `sampleRate`, `flushSeconds`) and the plan's `limits.metrics` apply; `captureMetrics: false` turns them off. Resources gain `os.major`, `device.form_factor`, `device.class` and `traceway.metrics: aggregated`.
- **Captures stream video.** A capture from the dashboard or a trigger that asks for replay (`capture`, `startReplay`, `stream` with `replay`, or a rule with `replay.mode: stream`) uploads the buffered lookback and then streams the session as consecutive MP4 segments until it ends; logs, requests and taps stream with it. A capture known only from the cached config starts nothing until the server confirms it. Video needs a hardware encoder (Android, iOS, macOS); elsewhere `screenCapture` records nothing.
- **Recording triggers** (`event` steps of type `click`, `hover`, `navigation` and `log`) run in Flutter, with the browser SDK's sequence engine: overlapping progress, counts and windows, progress and fire counts kept across restarts within a session. Fired triggers that ask for replay report their steps, so the session lists them as recording reasons. The SDK advertises `io.traceway.sdk.sequence-triggers/v1`.
- **Taps** are recorded as `browser.user_action.click` (signal `userActions`, buffered by default) with a CSS-like selector naming the widget (`ElevatedButton#pay`, `IconButton[label="Delete"]`), plus `app.widget.*` and `app.screen.*` attributes. Selectors match keys, `Semantics` identifiers, roles, labels, shown text and widget types; see the README.
- **Routes** without a name are reported by their page widget (`/CheckoutPage`); `Traceway.recordNavigation` reports a router's location.
- **Local config**: `TracewayOptions.collection` takes a settings document, under the remote rules or on its own with `remoteConfig: false`. New options `captureUserActions` and `recordAllSessions`.
- Local captures from triggers survive app restarts until they end.
- The ring buffer is saved (OTLP protobuf) when the app goes to the background, on `flush()` and at shutdown, and restored when the same session goes on after a restart; the next trigger or capture uploads it. `buffer.persist: false` keeps it in memory only.
- Replay uploads are bounded per session (50 MiB, 10,000 events); sessions report `traceway.collection.*` and `traceway.replay.failed_segments`.
- Web vital events are buffered by default, as in the browser SDK; `longTasks` and `routeTiming` are known signal names.
- **Other OpenTelemetry backends**: `TracewayOptions.telemetry: TracewayTelemetry(url:, headers:, logs:, traces:, metrics:)` sends logs, spans and metrics to any OTLP/HTTP receiver, the browser SDK's `telemetry` option. The base `url` gets `/v1/logs`, `/v1/traces` and `/v1/metrics` appended; a `TracewayTelemetryEndpoint(url:, headers:)` per signal is a complete URL, used as given; a signal neither covers stays on Traceway. Signal headers override the shared ones, and the Traceway token is never sent to these receivers. With a connection string, exceptions, `captureMessage` issues and the SDK's session and control records still go to Traceway only, as do OpAMP and screen recordings; ordinary logs (console, navigation, taps, `recordAction`, `track`) go to the logs receiver. Both sides carry `session.id`. URLs must be HTTP(S) without credentials, query or fragment. Requests to the receivers are not recorded as network spans.
- **Standalone mode**: `Traceway.run(connectionString:)` is optional. Without it, `telemetry` must have a base `url` or all three signal endpoints (`ArgumentError` otherwise), every record goes there, and remote config, screen recording uploads and session records are off whatever the options say. Exceptions are OTLP log records with the event name `exception`.
- **Invalid settings no longer blank the app**: when the connection string or `telemetry` is invalid (a URL that is not HTTP(S) or has credentials, a query or a fragment; standalone without a destination for every signal), `Traceway.run` reports the error as a `FlutterError` (library `traceway`, shown in the console) and runs the app without the SDK. `TracewayClient.initialize` called directly still throws `ArgumentError`.
- **Trace propagation**: `TracewayOptions.propagateTraceHeaderUrls` (`List<Pattern>`, empty by default) selects requests that carry a W3C `traceparent` header naming their client span, so backend spans join the app's trace. A `String` matches URLs that start with it, a `RegExp` URLs it matches. Applies to `TracewayHttpClient` always and to other dart:io requests when `captureNetwork` is on; requests to Traceway and the `telemetry` receivers never carry it, and a request that already has a `traceparent` keeps its own. The client span of a propagated dart:io request starts when the request is opened (connect and TLS included). A request sent through `TracewayHttpClient` over a dart:io client is recorded once, not also by the `HttpOverrides` capture.
- Records are exported by the SDK's own OTLP/HTTP exporters, not the `dartastic_opentelemetry` ones: protobuf to exactly the configured URL, logs and spans gzip-compressed. Failed batches are queued on disk per destination (`outbox` for Traceway, `outbox-<hash>` for each set of external destinations); pending metric payloads and the daily user count are kept per destination too, so a changed receiver is never sent what was meant for the previous one.
- A cold start whose first frame came while the app was `inactive` (on screen without focus: an unfocused desktop window, iOS during its launch transition) is counted; only a start into the background (`hidden`, `paused`, `detached`) is not.
- `sessions: false` now only stops the session records (`session.start`, `session.end`, `traceway.session.update`); the session id still exists and correlates records, sampling and trigger progress, as in the browser SDK, so captures and rules that stream replay still work for those apps. Such apps now also count `app.session` metrics and ask for remote settings when a session starts, as browser apps do.

Fixes and cleanups:

- **Fixed: a privacy mask stayed behind when its widget moved.** `TracewayPrivacyMask` recorded its place when it was built, so a masked widget that scrolled in a list or moved with an animation was recorded unmasked, with the mask left where the widget had been. The place of every mask is now read from the render tree as each frame is captured.
- **Fixed: a large buffer lost its newest records on a flush.** Flushed breadcrumbs went through the batch processors, whose queues hold 2,048 records and drop the rest: with more than that buffered, the breadcrumbs right before the error were not uploaded, and with `persistToDisk: false` the error record itself could be dropped. A flush now hands the buffer to the exporters directly, 512 records per request.
- **Fixed: `HttpClient.get/post/open(host, port, path)` with a query in the path** was sent to the wrong URL while network capture was on (`?` and `#` were percent-encoded into the path). The path is now read as dart:io reads it.
- **Fixed: a rule whose `emit` action emits the event it matches** made the app spin without end. Rules may answer each other's emitted events four deep.
- **Fixed: a line printed while a record is emitted** (OpenTelemetry's own diagnostics, when the app turns them on) was recorded as a console record, which printed the next line, without end.
- A buffer restored after a restart is uploaded in requests of about 1 MiB. As one request, a buffer over 4 MiB (possible when a rule raises `buffer.maxBytes`) was dropped instead of queued.
- A clip whose encoding fails no longer leaves its file in the temporary directory.
- Removed the unused `LogEvent` and `CustomEvent` types and the JSON form of `TracewayEvent` (leftovers of the 1.x report format), the unused `uuid` dependency, and the `replay.maskAllInputs` and `buffer.replayMaxBytes` settings, which were read and never applied.

## 1.0.9 — 2026-06-16

Flutter symbolication for obfuscated builds

## 1.0.8 — 2026-05-07

Upped the version of device_info_plus

## 1.0.7 — 2026-05-04

updated device_info_plus version

## 1.0.6 — 2026-05-03

updated device_info_plus version

## 1.0.5 — 2026-05-02

Testing CI

## 1.0.4 — 2026-04-28

- Added logs and navigation to each recording

## 1.0.3 — 2026-04-16

- Updated readme

## 1.0.2 — 2026-04-16

- Updated the readme with all parameters and masking

## 1.0.1 — 2026-04-15

- Version update for clean git history

## 1.0.0 — 2026-04-15

- Implemented git issues from 1 to 4

## 0.1.4 — 2026-04-10

- Fix for the first issue sync addressed

## 0.1.3 — 2026-04-10

- Updated readme with new docs link

## 0.1.2 — 2026-04-10

- redeploying to test ci/cd flow

## 0.1.1 — 2026-04-10

- Lowered memory footprint
- Fixed capture causing the recording to stop
- Fixed zoned initialization issue

## 0.1.0

- Initial release
- Exception and error capture with full stack traces
- Screen recording (last ~10 seconds) via RepaintBoundary + ffmpeg
- Gzip-compressed transport to Traceway backend
- Simple widget wrapper API: `Traceway.run()`
