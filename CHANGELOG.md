## 2.0.0-beta.1 — 2026-11-14

Rebuilt on the standard OpenTelemetry SDK for Dart, matching the browser SDK's 2.0 architecture.

- Logs and spans go through `dartastic_opentelemetry` and are exported as OTLP/HTTP.
- Ring buffer: logs, HTTP requests, navigation and custom events stay on the device (2 MB / 10 minutes) and are uploaded when an exception or a trigger asks for them.
- Remote config over OpAMP: signal modes, sample rates, triggers and on-demand captures from the dashboard. Init options are ceilings.
- Screen recording is unchanged in size (150 frames, ~10 seconds) and is uploaded only as the clip of an exception, to `/api/recordings`. It cannot be streamed, locally or by remote config.
- Sessions, `Traceway.track`, `Traceway.setAttribute`, `refreshConfig`, `shutdown`, `getInstanceId`.
- **Breaking**: requires a server with OTLP/OpAMP support for Flutter projects; the 1.x `/api/report` protocol is gone. Options `debounceMs`, `retryDelayMs`, `maxPendingExceptions`, `maxLocalFiles`, `localFileMaxAgeHours`, `eventsWindow` and `eventsMaxCount` were removed.

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
